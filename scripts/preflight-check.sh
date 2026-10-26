#!/usr/bin/env bash
###############################################################################
# preflight-check.sh — run BEFORE the first `terraform apply` (Phase 1a)
#
# Catches the problems that bite a FRESH Azure subscription, each of which
# was hit in practice and costs 30+ minutes if found late:
#
#   1. Resource providers not registered (Terraform silently blocks up to
#      ~30 min, then fails with "context deadline exceeded").
#   2. VM sizes restricted / unavailable in the chosen region
#      (SkuNotAvailable / NotAvailableForSubscription) — e.g. all v3 sizes,
#      or whole D-series in some regions on lab subscriptions.
#   3. Marketplace terms for Panorama / VM-Series not accepted.
#   4. pan_os_version newer than the Panorama image (Panorama then silently
#      refuses the firewalls: Connected=no, "device_registered no").
#
# Usage:   bash scripts/preflight-check.sh            (reads ./terraform.tfvars)
# Exit 0 = ready to deploy; exit 1 = fix the [FAIL] items first.
###############################################################################
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TFVARS="$ROOT_DIR/terraform.tfvars"
FAILS=0

ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; }
fail() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

# value of a simple `key = "value"` line from terraform.tfvars (or default)
tfvar() {
  local v
  v=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFVARS" 2>/dev/null | head -1 \
      | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | tr -d '[:space:]')
  echo "${v:-$2}"
}

echo "============================================================"
echo "  Pre-flight check"
echo "============================================================"

[ -f "$TFVARS" ] || { echo "[FAIL] $TFVARS not found — cp terraform.tfvars.example terraform.tfvars first."; exit 1; }

SUB=$(tfvar hub_subscription_id "")
LOCATION=$(tfvar location "germanywestcentral")
PAN_SIZE=$(tfvar panorama_vm_size "Standard_D16s_v5")
FW_SIZE=$(tfvar fw_vm_size "Standard_D8s_v5")
APP_SIZE=$(tfvar app1_vm_size "Standard_D2s_v5")
DC_SIZE=$(tfvar dc_vm_size "Standard_B2s_v2")
PAN_OS=$(tfvar pan_os_version "12.1.9")

# ---------------------------------------------------------------------------
echo ""
echo "[1/5] Azure login / subscription"
ACTIVE=$(az account show --query id -o tsv 2>/dev/null || true)
if [ -z "$ACTIVE" ]; then
  fail "az CLI not logged in (az login --tenant <tenant>)"
  exit 1
fi
if echo "$SUB" | grep -q REPLACE_ME || [ -z "$SUB" ]; then
  fail "hub_subscription_id not set in terraform.tfvars"
elif [ "$ACTIVE" != "$SUB" ]; then
  fail "active az subscription ($ACTIVE) != hub_subscription_id ($SUB) — run: az account set --subscription $SUB"
else
  ok "subscription $(az account show --query name -o tsv) ($ACTIVE), region $LOCATION"
fi

# ---------------------------------------------------------------------------
echo ""
echo "[2/5] Resource provider registration (fresh subscriptions: up to ~30 min!)"
PROVIDERS="Microsoft.Network Microsoft.Compute Microsoft.Storage Microsoft.ManagedIdentity \
Microsoft.Authorization Microsoft.Cdn Microsoft.ContainerService Microsoft.KeyVault \
Microsoft.OperationalInsights Microsoft.Insights Microsoft.Resources"
for p in $PROVIDERS; do
  st=$(az provider show -n "$p" --query registrationState -o tsv 2>/dev/null || echo "Unknown")
  if [ "$st" != "Registered" ]; then
    az provider register -n "$p" --only-show-errors >/dev/null 2>&1 || true
  fi
done
MAX_WAIT=${PREFLIGHT_PROVIDER_WAIT_MIN:-45}
for i in $(seq 1 $((MAX_WAIT * 2))); do
  PENDING=""
  for p in $PROVIDERS; do
    st=$(az provider show -n "$p" --query registrationState -o tsv 2>/dev/null || echo "Unknown")
    [ "$st" = "Registered" ] || PENDING="$PENDING $p($st)"
  done
  if [ -z "$PENDING" ]; then ok "all required providers Registered"; break; fi
  if [ "$i" -eq $((MAX_WAIT * 2)) ]; then
    fail "still not Registered after ${MAX_WAIT} min:$PENDING"
  else
    echo "         waiting (30s):$PENDING"; sleep 30
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "[3/5] VM sizes available in $LOCATION for THIS subscription"
# One (slow) listing call, filtered locally for every size below. Only
# region-wide ('Location') restrictions count — 'Zone' restrictions just
# exclude some availability zones, and these VMs are not zonal.
SKU_CACHE=$(mktemp)
trap 'rm -f "$SKU_CACHE"' EXIT
az vm list-skus --location "$LOCATION" --resource-type virtualMachines --all \
  --query "[].{n:name,r:join(',',restrictions[?type=='Location'].reasonCode)}" -o tsv 2>/dev/null > "$SKU_CACHE" || true
check_size() {
  local label="$1" size="$2" level="${3:-fail}" out report
  report=fail; [ "$level" = "warn" ] && report=warn
  out=$(awk -F'\t' -v s="$size" '$1==s {print $1"\t"$2; exit}' "$SKU_CACHE")
  if [ -z "$out" ]; then
    $report "$label $size: not offered in $LOCATION"
  elif echo "$out" | awk '{print $2}' | grep -q .; then
    $report "$label $size: restricted in $LOCATION ($(echo "$out" | awk '{print $2}')) — pick another size/region"
  else
    ok "$label $size"
  fi
}
check_size "panorama_vm_size" "$PAN_SIZE"
check_size "fw_vm_size      " "$FW_SIZE"
check_size "app1_vm_size    " "$APP_SIZE"
check_size "dc_vm_size      " "$DC_SIZE"

# Optional AKS add-on (only a warning — the add-on is opt-in). Reads
# optional/aks-deploy/terraform.tfvars if present, else the module defaults.
AKS_TFVARS="$ROOT_DIR/optional/aks-deploy/terraform.tfvars"
opt_var() {
  local v
  v=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$AKS_TFVARS" 2>/dev/null | head -1 \
      | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | tr -d '[:space:]')
  echo "${v:-$2}"
}
check_size "aks edl_vm_size  " "$(opt_var edl_vm_size Standard_B2s_v2)" warn
check_size "aks node_vm_size " "$(opt_var aks_node_vm_size Standard_D2s_v5)" warn

# ---------------------------------------------------------------------------
echo ""
echo "[4/5] Marketplace terms (Panorama + VM-Series BYOL)"
for offer in panorama vmseries-flex; do
  acc=$(az vm image terms show --publisher paloaltonetworks --offer "$offer" --plan byol --query accepted -o tsv 2>/dev/null || echo "false")
  if [ "$acc" = "true" ]; then
    ok "paloaltonetworks/$offer/byol accepted"
  else
    warn "paloaltonetworks/$offer/byol NOT accepted — accepting now"
    az vm image terms accept --publisher paloaltonetworks --offer "$offer" --plan byol --only-show-errors >/dev/null 2>&1 \
      && ok "accepted $offer" || fail "could not accept terms for $offer (need Owner/Contributor)"
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "[5/5] PAN-OS version compatibility (FW must be <= Panorama)"
PAN_LATEST=$(az vm image list --publisher paloaltonetworks --offer panorama --sku byol --all \
             --query "[].version" -o tsv 2>/dev/null | sort -V | tail -1)
if [ -z "$PAN_LATEST" ]; then
  warn "could not list Panorama image versions"
else
  echo "         newest Panorama image: $PAN_LATEST   |   pan_os_version (FW): $PAN_OS"
  if [ "$PAN_OS" = "latest" ]; then
    fail "pan_os_version = \"latest\" is unsafe — the FW 'latest' image can be newer than Panorama. Set pan_os_version = \"$PAN_LATEST\" (or lower)."
  elif [ "$(printf '%s\n%s\n' "$PAN_LATEST" "$PAN_OS" | sort -V | tail -1)" != "$PAN_LATEST" ]; then
    # Caveat: Marketplace encodes hotfixes as a 3-digit patch (12.1.405 =
    # 12.1.4-h5), which compares numerically higher than e.g. 12.1.9. If you
    # deliberately pinned such a hotfix image, verify the real release manually.
    fail "pan_os_version $PAN_OS is NEWER than newest Panorama $PAN_LATEST — Panorama will refuse the FWs (hotfix image like 12.1.405 = 12.1.4-h5? verify manually)"
  else
    FWV=$(az vm image list --publisher paloaltonetworks --offer vmseries-flex --sku byol --all \
          --query "[?version=='$PAN_OS'] | [0].version" -o tsv 2>/dev/null)
    if [ -n "$FWV" ]; then ok "VM-Series image $PAN_OS exists and is <= Panorama $PAN_LATEST"
    else fail "no VM-Series (vmseries-flex/byol) image with version $PAN_OS"; fi
  fi
fi

echo ""
echo "Reminder: every FW (re)deployment consumes one VM-Series BYOL auth-code credit,"
echo "          and the registration PIN (CSP Portal) must be fresh — see README Prerequisites."
echo ""
if [ "$FAILS" -gt 0 ]; then
  echo "============================================================"
  echo "  Pre-flight FAILED ($FAILS problem(s)) — fix before 'terraform apply'"
  echo "============================================================"
  exit 1
fi
echo "============================================================"
echo "  Pre-flight OK — you can run Phase 1a"
echo "============================================================"
