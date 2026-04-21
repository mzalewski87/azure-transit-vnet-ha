#!/usr/bin/env bash
###############################################################################
# Delete existing bootstrap files from Azure File Share (pre-cleanup)
#
# Runs BEFORE azurerm_storage_share_file to prevent "already exists" errors.
# Uses curl DELETE (empty body) which works through corporate SSL proxy.
# SAS token generated locally via Python (no network calls).
#
# Required environment variables (set by Terraform provisioner):
#   SA_NAME    - Storage Account name
#   SA_KEY     - Storage Account primary access key
#   SHARE      - File Share name
#   FILE_PATHS - Comma-separated list of file paths to delete
###############################################################################

SA_NAME="${SA_NAME:?Missing SA_NAME}"
SA_KEY="${SA_KEY:?Missing SA_KEY}"
SHARE="${SHARE:?Missing SHARE}"
FILE_PATHS="${FILE_PATHS:?Missing FILE_PATHS}"

API_VERSION="2022-11-02"

# Generate Account SAS token locally via Python (zero network calls)
SAS=$(python3 -c "
import hmac, hashlib, base64, datetime, urllib.parse, os
key = base64.b64decode(os.environ['SA_KEY'])
name = os.environ['SA_NAME']
ver = '2022-11-02'
start = (datetime.datetime.utcnow() - datetime.timedelta(minutes=5)).strftime('%Y-%m-%dT%H:%MZ')
expiry = (datetime.datetime.utcnow() + datetime.timedelta(hours=2)).strftime('%Y-%m-%dT%H:%MZ')
perms = 'rwdlc'
svc = 'f'
rt = 'sco'
sts = '\n'.join([name, perms, svc, rt, start, expiry, '', 'https', ver, '']) + '\n'
sig = base64.b64encode(hmac.new(key, sts.encode('utf-8'), hashlib.sha256).digest()).decode()
print(urllib.parse.urlencode({'sv':ver,'ss':svc,'srt':rt,'sp':perms,'se':expiry,'st':start,'spr':'https','sig':sig}))
") || { echo "[ERROR] SAS generation failed"; exit 0; }

BASE_URL="https://${SA_NAME}.file.core.windows.net/${SHARE}"

echo "=== Pre-cleanup: removing existing bootstrap files ==="
IFS=',' read -ra PATHS <<< "$FILE_PATHS"
for fpath in "${PATHS[@]}"; do
  fpath=$(echo "$fpath" | xargs)  # trim whitespace
  HTTP=$(curl -sk -X DELETE \
    "${BASE_URL}/${fpath}?${SAS}" \
    -H "x-ms-version: ${API_VERSION}" \
    -o /dev/null -w "%{http_code}" 2>/dev/null) || true
  
  case "$HTTP" in
    202) echo "  [OK] Deleted: $fpath" ;;
    404) echo "  [OK] Not found (skip): $fpath" ;;
    *)   echo "  [WARN] Delete $fpath: HTTP $HTTP (continuing anyway)" ;;
  esac
done
echo "=== Pre-cleanup complete ==="
