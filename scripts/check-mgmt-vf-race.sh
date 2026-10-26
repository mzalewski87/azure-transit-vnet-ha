#!/usr/bin/env bash
###############################################################################
# scripts/check-mgmt-vf-race.sh
# Detect (and optionally recover from) the PAN-OS MGMT "late VF" boot race
# on Panorama and VM-Series.
#
# BACKGROUND (README → "Panorama boots without MGMT network after upgrade"):
#   On Azure the host may attach an SR-IOV Virtual Function (MANA or Mellanox)
#   to the MGMT NIC — observed even with enableAcceleratedNetworking=false.
#   If the VF joins eth0 AFTER PAN-OS PANNET has configured the management
#   interface, PAN-OS does not follow the rename and loses MGMT connectivity:
#   VM "running", agent "Not Ready", WebUI/SSH dead, waagent loops on
#   "No route to host". It is a timing race — it can hit any reboot,
#   most visibly the reboot at the end of a software upgrade.
#   A fresh host allocation (deallocate + start) has recovered it.
#
# WHEN TO RUN:
#   - Before a PAN-OS upgrade:   ./scripts/check-mgmt-vf-race.sh --prepare
#     (ensures boot diagnostics is on, so the next boot is captured)
#   - After the upgrade reboot:  ./scripts/check-mgmt-vf-race.sh
#   - If a VM is stuck:          ./scripts/check-mgmt-vf-race.sh --recover vm-panos-fw1
#
# USAGE:
#   ./scripts/check-mgmt-vf-race.sh [options] [vm-name ...]
#     (default VMs: vm-panorama vm-panos-fw1 vm-panos-fw2)
#
#   --prepare          enable boot diagnostics (managed storage) where missing
#   --recover          deallocate + start every VM found in RACE/NO-MGMT state,
#                      then wait until the VM agent reports Ready
#   --yes              do not ask for confirmation before --recover
#   --log-file <file>  analyse a saved serial log instead of querying Azure
#   -g <rg>            resource group (default: rg-transit-hub)
#
# VERDICTS (exit code = worst verdict):
#   OK        0  no VF on MGMT, or VF joined well before PANNET networking
#   TIGHT     0  VF joined <5s before PANNET — healthy now, but the next
#                reboot may lose the race (observed 0.3s / 2.5s on FWs)
#   UNKNOWN   3  serial log does not contain a full boot (enable boot
#                diagnostics BEFORE the reboot you want to inspect)
#   RACE      2  VF joined/renamed after PANNET networking start
#   NO-MGMT   2  waagent cannot reach 168.63.129.16 (MGMT has no network)
#
# Serial-log signals used:
#   "<mana|mlx5_core> <pci> ethX: joined to eth0"   → MGMT VF (PCI address)
#   "<pci> ...: renamed from ethX"                  → VF rename time
#   "pannet[..]: [..] Starting Networking"          → PANNET networking start
#   "No route to host" (waagent → WireServer)       → MGMT network dead
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

RG="rg-transit-hub"
PREPARE=false
RECOVER=false
ASSUME_YES=false
LOG_FILE=""
VMS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prepare)  PREPARE=true ;;
    --recover)  RECOVER=true ;;
    --yes)      ASSUME_YES=true ;;
    --log-file) LOG_FILE="$2"; shift ;;
    -g)         RG="$2"; shift ;;
    -h|--help)  sed -n '3,45p' "$0"; exit 0 ;;
    -*)         error "Unknown option: $1"; exit 1 ;;
    *)          VMS+=("$1") ;;
  esac
  shift
done
[[ ${#VMS[@]} -eq 0 ]] && VMS=(vm-panorama vm-panos-fw1 vm-panos-fw2)

# ─── Serial log analysis ─────────────────────────────────────────────────────
# Prints "VERDICT|details" for the LAST boot contained in the log on stdin.
# The serial-log blob uses CRLF line endings and is NUL-padded — strip both.
analyse_log() {
  tr -d '\000\r' | awk '
    function ts(line,   m) {
      if (match(line, /\[ *[0-9]+\.[0-9]+\]/)) {
        m = substr(line, RSTART + 1, RLENGTH - 2); gsub(/ /, "", m); return m + 0
      }
      return -1
    }
    { lines[NR] = $0 }
    /Linux version/ { boot = NR }
    END {
      if (!boot) { print "UNKNOWN|no kernel boot in serial log (enable boot diagnostics before rebooting)"; exit }
      pci = ""; vf_t = -1; net_t = -1; while_up = 0; noroute = 0
      for (i = boot; i <= NR; i++) {
        l = lines[i]
        if (pci == "" && l ~ /(mana|mlx5_core|mlx4_core) [0-9a-f]+:[0-9a-f:.]+ .*joined to eth0/) {
          match(l, /(mana|mlx5_core|mlx4_core) [0-9a-f]+:[0-9a-f:.]+/)
          split(substr(l, RSTART, RLENGTH), p, " "); pci = p[2]
          t = ts(l); if (t > vf_t) vf_t = t
        }
        if (pci != "" && index(l, pci) && l ~ /renamed from/) {
          t = ts(l); if (t > vf_t) vf_t = t
          if (l ~ /while UP/) while_up = 1
        }
        # Panorama: "pannet[N]: Starting Networking:"
        # VM-Series: "pannet[N]: <date> PANNET start. Starting Networking."
        if (net_t < 0 && l ~ /pannet\[[0-9]+\]:.*Starting Networking/) net_t = ts(l)
        if (l ~ /No route to host/) noroute++
      }
      d = sprintf("mgmt_vf=%s vf_t=%.1fs pannet_t=%.1fs noroute=%d", (pci == "" ? "none" : pci), vf_t, net_t, noroute)
      if (noroute >= 3)                                 { print "NO-MGMT|" d; exit }
      if (pci != "" && (while_up || (net_t >= 0 && vf_t > net_t))) { print "RACE|" d; exit }
      if (pci != "" && net_t < 0)                       { print "UNKNOWN|" d " (boot still in progress?)"; exit }
      if (pci != "" && net_t - vf_t < 5)                { print "TIGHT|" d " (VF won the race by <5s)"; exit }
      print "OK|" d
    }'
}

verdict_rc() {
  case "$1" in
    OK|TIGHT) echo 0 ;; UNKNOWN) echo 3 ;; *) echo 2 ;;
  esac
}

if [[ -n "$LOG_FILE" ]]; then
  res=$(analyse_log < "$LOG_FILE")
  echo "${res%%|*}  ${res#*|}"
  exit "$(verdict_rc "${res%%|*}")"
fi

# ─── Azure helpers ───────────────────────────────────────────────────────────
bootdiag_enabled() {
  [[ "$(az vm show -g "$RG" -n "$1" --query diagnosticsProfile.bootDiagnostics.enabled -o tsv 2>/dev/null)" == "true" ]]
}

agent_status() {
  az vm get-instance-view -g "$RG" -n "$1" \
    --query "instanceView.vmAgent.statuses[0].displayStatus" -o tsv 2>/dev/null || echo "n/a"
}

check_vm() {
  local vm=$1 res
  if ! bootdiag_enabled "$vm"; then
    echo "UNKNOWN|boot diagnostics disabled (run with --prepare)"
    return
  fi
  # Fetch the raw blob via its SAS URI: `az vm boot-diagnostics get-boot-log`
  # returns the log as one JSON-escaped string, which breaks line parsing.
  local uri
  uri=$(az vm boot-diagnostics get-boot-log-uris -g "$RG" -n "$vm" \
    --query serialConsoleLogBlobUri -o tsv 2>/dev/null)
  res=$(curl -sf "$uri" | analyse_log)
  echo "$res agent=$(agent_status "$vm")"
}

recover_vm() {
  local vm=$1 waited=0 status
  info "$vm: deallocate + start (fresh host allocation)..."
  az vm deallocate -g "$RG" -n "$vm" -o none
  az vm start -g "$RG" -n "$vm" -o none
  info "$vm: started — waiting for VM agent Ready (PAN-OS boot takes ~5-10 min)..."
  while (( waited < 1500 )); do
    sleep 30; waited=$((waited + 30))
    status=$(agent_status "$vm")
    if [[ "$status" == "Ready" ]]; then
      info "$vm: agent Ready after ${waited}s — $(check_vm "$vm" | cut -d'|' -f2)"
      return 0
    fi
  done
  error "$vm: agent still '$status' after ${waited}s — check the console screenshot / Serial Console"
  return 1
}

# ─── Main ────────────────────────────────────────────────────────────────────
az account show -o none 2>/dev/null || { error "Not logged in: az login"; exit 1; }

if $PREPARE; then
  for vm in "${VMS[@]}"; do
    if bootdiag_enabled "$vm"; then
      info "$vm: boot diagnostics already enabled"
    else
      info "$vm: enabling boot diagnostics (managed storage, no reboot)..."
      az vm boot-diagnostics enable -g "$RG" -n "$vm" -o none
    fi
  done
fi

worst=0
affected=()
for vm in "${VMS[@]}"; do
  res=$(check_vm "$vm")
  verdict=${res%%|*}
  case "$verdict" in
    OK)      info  "$vm: OK       ${res#*|}" ;;
    TIGHT)   warn  "$vm: TIGHT    ${res#*|}" ;;
    UNKNOWN) warn  "$vm: UNKNOWN  ${res#*|}" ;;
    *)       error "$vm: $verdict ${res#*|}"; affected+=("$vm") ;;
  esac
  rc=$(verdict_rc "$verdict")
  (( rc == 2 || (rc == 3 && worst == 0) )) && worst=$rc
done

if $RECOVER && [[ ${#affected[@]} -gt 0 ]]; then
  if ! $ASSUME_YES; then
    read -r -p "Deallocate + start ${affected[*]}? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { warn "Recovery skipped"; exit "$worst"; }
  fi
  worst=0
  for vm in "${affected[@]}"; do
    recover_vm "$vm" || worst=2
  done
elif [[ ${#affected[@]} -gt 0 ]]; then
  warn "Recover with: $0 --recover ${affected[*]}"
  warn "If it recurs: Serial Console → 'debug swm revert' → 'request restart system'"
fi

exit "$worst"
