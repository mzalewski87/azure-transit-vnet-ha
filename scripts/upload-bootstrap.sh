#!/usr/bin/env bash
###############################################################################
# Upload bootstrap files to Azure File Share via curl + SAS token
#
# Bypasses corporate SSL proxy issues (az CLI Python SDK fails with
# SSL_CERTIFICATE_VERIFY_FAILED). curl -sk handles SSL interception.
#
# SAS token generated locally via Python (no network calls).
#
# Required environment variables (set by Terraform provisioner):
#   SA_NAME    - Storage Account name
#   SA_KEY     - Storage Account primary access key
#   SHARE      - File Share name (e.g., "bootstrap")
#   SRC_CFG    - Local path to init-cfg.txt
#   DEST_CFG   - Remote path (e.g., "fw1/config/init-cfg.txt")
#   SRC_AUTH   - Local path to authcodes file
#   DEST_AUTH  - Remote path (e.g., "fw1/license/authcodes")
#   FW_NAME    - FW identifier for logging (e.g., "FW1")
###############################################################################
set -euo pipefail

MAX_RETRIES=5
RETRY_DELAY=30
API_VERSION="2022-11-02"

# Validate required env vars
for var in SA_NAME SA_KEY SHARE SRC_CFG DEST_CFG SRC_AUTH DEST_AUTH; do
  if [ -z "${!var:-}" ]; then
    echo "[ERROR] Missing required env var: $var" >&2
    exit 1
  fi
done

FW_NAME="${FW_NAME:-FW}"

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
")

if [ -z "$SAS" ]; then
  echo "[ERROR] Failed to generate SAS token" >&2
  exit 1
fi

BASE_URL="https://${SA_NAME}.file.core.windows.net/${SHARE}"

upload_file() {
  local SRC="$1" DEST="$2"

  if [ ! -f "$SRC" ]; then
    echo "  [ERROR] Source file not found: $SRC" >&2
    return 1
  fi

  local FILE_SIZE
  FILE_SIZE=$(wc -c < "$SRC" | tr -d ' ')

  for i in $(seq 1 $MAX_RETRIES); do
    # Step 1: Create file (set size, overwrites existing)
    HTTP1=$(curl -sk -X PUT \
      "${BASE_URL}/${DEST}?${SAS}" \
      -H "x-ms-version: ${API_VERSION}" \
      -H "x-ms-type: file" \
      -H "x-ms-content-length: ${FILE_SIZE}" \
      -H "Content-Length: 0" \
      -o /dev/null -w "%{http_code}" 2>/dev/null)

    if [ "$HTTP1" != "201" ]; then
      echo "  [RETRY ${i}/${MAX_RETRIES}] Create ${DEST}: HTTP ${HTTP1}, waiting ${RETRY_DELAY}s..."
      sleep $RETRY_DELAY
      continue
    fi

    # Step 2: Upload content (Put Range)
    HTTP2=$(curl -sk -X PUT \
      "${BASE_URL}/${DEST}?comp=range&${SAS}" \
      -H "x-ms-version: ${API_VERSION}" \
      -H "x-ms-range: bytes=0-$((FILE_SIZE - 1))" \
      -H "x-ms-write: update" \
      -H "Content-Length: ${FILE_SIZE}" \
      --data-binary "@${SRC}" \
      -o /dev/null -w "%{http_code}" 2>/dev/null)

    if [ "$HTTP2" = "201" ]; then
      echo "  [OK] Uploaded ${DEST} (${FILE_SIZE} bytes)"
      return 0
    fi

    echo "  [RETRY ${i}/${MAX_RETRIES}] PutRange ${DEST}: HTTP ${HTTP2}, waiting ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
  done

  echo "  [ERROR] Failed to upload ${DEST} after ${MAX_RETRIES} retries" >&2
  return 1
}

echo "=== Uploading ${FW_NAME} bootstrap files ==="
upload_file "$SRC_CFG" "$DEST_CFG"
upload_file "$SRC_AUTH" "$DEST_AUTH"
echo "=== ${FW_NAME} bootstrap upload complete ==="
