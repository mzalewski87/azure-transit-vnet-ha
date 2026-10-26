#!/usr/bin/env bash
###############################################################################
# scripts/upgrade-panos.sh — Phase 2c (optional): PAN-OS upgrade orchestrated
# from Panorama
#
# Upgrades Panorama (if it is older than the target) and then both VM-Series
# firewalls, one at a time, through the Panorama XML API. Only ONE Bastion
# tunnel is needed (to Panorama); firewall commands are proxied by Panorama
# (XML API target=<serial>). Logic lives in scripts/lib/panos_upgrade.py —
# see its header for the full procedure and the upgrade-path rules
# (skip up to 3 feature releases, full base-image chain downloaded on the
# firewall before the first install).
#
# USAGE:
#   bash scripts/upgrade-panos.sh --plan-only          # show the plan, no changes
#   bash scripts/upgrade-panos.sh                      # upgrade to the TF target
#   bash scripts/upgrade-panos.sh --target 12.2.4      # override the target
#   bash scripts/upgrade-panos.sh --auto               # Phase 2b hook: no-op
#                                                      # unless panos_auto_upgrade
#
# TARGET VERSION comes from terraform.tfvars (via `terraform output -json
# panos_upgrade`):
#   panos_auto_upgrade           = true
#   panos_upgrade_target_version = "12.2.4"
#   panos_upgrade_panorama       = true   # upgrade Panorama first if older
#
# REQUIREMENTS: Phase 2b completed (both FWs connected to Panorama), az CLI
# logged in, python3. Password: $PAN_PASS or admin_password in terraform.tfvars.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PANORAMA_PORT="${PANORAMA_PORT:-44310}"
PAN_USER="${PAN_USER:-panadmin}"
BASTION_NAME="bastion-management"
BASTION_RG="rg-transit-hub"

TARGET=""
AUTO=false
PY_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)              TARGET="$2"; shift ;;
    --plan-only)           PY_ARGS+=(--plan-only) ;;
    --no-upgrade-panorama) PY_ARGS+=(--no-upgrade-panorama) ;;
    --auto)                AUTO=true ;;
    -h|--help)             sed -n '3,30p' "$0"; exit 0 ;;
    *) echo "[ERROR] Unknown option: $1"; exit 1 ;;
  esac
  shift
done

cd "$ROOT_DIR"

# ─── Target version from Terraform ───────────────────────────────────────────
TF_UPGRADE=$(terraform output -json panos_upgrade 2>/dev/null || echo '{}')
if [[ "$TF_UPGRADE" == "{}" && -f "$ROOT_DIR/terraform.tfvars" ]]; then
  # Output not in state yet (no apply since the variables were added):
  # read the three settings straight from terraform.tfvars.
  TF_UPGRADE=$(python3 - "$ROOT_DIR/terraform.tfvars" <<'PY'
import json, re, sys
src = open(sys.argv[1]).read()
def get(name, default):
    m = re.search(r'^\s*%s\s*=\s*("([^"]*)"|true|false)' % name, src, re.M)
    if not m:
        return default
    return m.group(2) if m.group(2) is not None else m.group(1) == "true"
print(json.dumps({"enabled": get("panos_auto_upgrade", False),
                  "target_version": get("panos_upgrade_target_version", ""),
                  "upgrade_panorama": get("panos_upgrade_panorama", True)}))
PY
)
fi
tf_field() {
  python3 -c 'import json,sys; v=json.loads(sys.argv[1] or "{}").get(sys.argv[2]); print("" if v is None else str(v).lower() if isinstance(v,bool) else v)' \
    "$TF_UPGRADE" "$1"
}

if $AUTO; then
  if [[ "$(tf_field enabled)" != "true" ]]; then
    echo "[INFO] panos_auto_upgrade = false — skipping PAN-OS upgrade (Phase 2c)."
    exit 0
  fi
fi
[[ -z "$TARGET" ]] && TARGET="$(tf_field target_version)"
if [[ -z "$TARGET" ]]; then
  echo "[ERROR] No target version. Set panos_upgrade_target_version in terraform.tfvars"
  echo "        (then terraform apply) or pass --target <version>."
  exit 1
fi
[[ "$(tf_field upgrade_panorama)" == "false" ]] && PY_ARGS+=(--no-upgrade-panorama)

echo "============================================================"
echo "  Phase 2c: PAN-OS upgrade to $TARGET (orchestrated from Panorama)"
echo "============================================================"

# ─── Credentials ─────────────────────────────────────────────────────────────
if [[ -z "${PAN_PASS:-}" && -f "$ROOT_DIR/terraform.tfvars" ]]; then
  PAN_PASS=$(grep -E '^\s*admin_password\s*=' "$ROOT_DIR/terraform.tfvars" \
    | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/')
fi
if [[ -z "${PAN_PASS:-}" ]]; then
  read -rs -p "Admin password ($PAN_USER): " PAN_PASS; echo
fi
export PAN_PASS

PANORAMA_ID=$(terraform output -raw panorama_vm_id)
FW1_IP=$(terraform output -raw fw1_mgmt_private_ip)
FW2_IP=$(terraform output -raw fw2_mgmt_private_ip)

# ─── Bastion tunnel to Panorama (respawned — Panorama reboots mid-run) ───────
TUNNEL_PID=""
cleanup() {
  [[ -n "$TUNNEL_PID" ]] && kill -- -"$TUNNEL_PID" 2>/dev/null || kill "$TUNNEL_PID" 2>/dev/null || true
  lsof -ti:"$PANORAMA_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "[1/3] Opening Bastion tunnel to Panorama (port $PANORAMA_PORT)..."
set -m
(
  while true; do
    az network bastion tunnel --name "$BASTION_NAME" --resource-group "$BASTION_RG" \
      --target-resource-id "$PANORAMA_ID" --resource-port 443 --port "$PANORAMA_PORT" \
      &>/dev/null || true
    sleep 5
  done
) &
TUNNEL_PID=$!
set +m
for _ in $(seq 1 24); do
  curl -sk --max-time 3 -o /dev/null "https://127.0.0.1:$PANORAMA_PORT" && break
  sleep 5
done

# ─── Boot diagnostics on, so every upgrade reboot is captured ────────────────
echo "[2/3] Ensuring boot diagnostics (MGMT VF race detection)..."
"$SCRIPT_DIR/check-mgmt-vf-race.sh" --prepare >/dev/null 2>&1 \
  || echo "  [WARN] could not verify boot diagnostics — the VF race check may report UNKNOWN"

# ─── Orchestrate ─────────────────────────────────────────────────────────────
echo "[3/3] Running upgrade orchestrator..."
python3 "$SCRIPT_DIR/lib/panos_upgrade.py" \
  --url "https://127.0.0.1:$PANORAMA_PORT" \
  --user "$PAN_USER" \
  --target "$TARGET" \
  --vm-map "$FW1_IP=vm-panos-fw1,$FW2_IP=vm-panos-fw2" \
  --panorama-vm vm-panorama \
  --vf-check "$SCRIPT_DIR/check-mgmt-vf-race.sh" \
  ${PY_ARGS[@]+"${PY_ARGS[@]}"}
