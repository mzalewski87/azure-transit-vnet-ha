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
# NOTE: intentionally NO 'set -e' — we handle curl errors in retry loop
set -uo pipefail

MAX_RETRIES=5
RETRY_DELAY=30
API_VERSION="2022-11-02"

# Validate required env vars
missing=""
for var in SA_NAME SA_KEY SHARE SRC_CFG DEST_CFG SRC_AUTH DEST_AUTH; do
  if [ -z "${!var:-}" ]; then
    missing="$missing $var"
  fi
done
if [ -n "$missing" ]; then
  echo "[ERROR] Missing required env vars:$missing" >&2
  exit 1
fi

FW_NAME="${FW_NAME:-FW}"

echo "  [DEBUG] SA_NAME=${SA_NAME}"
echo "  [DEBUG] SHARE=${SHARE}"
echo "  [DEBUG] SRC_CFG=${SRC_CFG} exists=$(test -f "${SRC_CFG}" && echo YES || echo NO)"
echo "  [DEBUG] SRC_AUTH=${SRC_AUTH} exists=$(test -f "${SRC_AUTH}" && echo YES || echo NO)"

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
echo "  [DEBUG] SAS token generated (length=${#SAS})"

BASE_URL="https://${SA_NAME}.file.core.windows.net/${SHARE}"

upload_file() {
  local SRC="$1" DEST="$2"

  if [ ! -f "$SRC" ]; then
    echo "  [ERROR] Source file not found: $SRC (pwd=$(pwd))" >&2
    return 1
  fi

  local FILE_SIZE
  FILE_SIZE=$(wc -c < "$SRC" | tr -d ' ')
  echo "  [INFO] Uploading $SRC -> $DEST ($FILE_SIZE bytes)"

  for i in $(seq 1 $MAX_RETRIES); do
    # Step 1: Create file (set size, overwrites existing)
    # || true prevents set -e from killing on curl connection errors
    local RESP1
    RESP1=$(curl -sk -X PUT \
      "${BASE_URL}/${DEST}?${SAS}" \
      -H "x-ms-version: ${API_VERSION}" \
      -H "x-ms-type: file" \
      -H "x-ms-content-length: ${FILE_SIZE}" \
      -H "Content-Length: 0" \
      -w "\n%{http_code}" 2>&1) || true

    local HTTP1
    HTTP1=$(echo "$RESP1" | tail -1)
    local BODY1
    BODY1=$(echo "$RESP1" | head -n -1)

    if [ "$HTTP1" != "201" ]; then
      echo "  [RETRY ${i}/${MAX_RETRIES}] Create ${DEST}: HTTP=${HTTP1}, waiting ${RETRY_DELAY}s..."
      echo "  [RETRY] Response: $(echo "$BODY1" | head -3)"
      sleep $RETRY_DELAY
      continue
    fi

    # Step 2: Upload content (Put Range)
    local RESP2
    RESP2=$(curl -sk -X PUT \
      "${BASE_URL}/${DEST}?comp=range&${SAS}" \
      -H "x-ms-version: ${API_VERSION}" \
      -H "x-ms-range: bytes=0-$((FILE_SIZE - 1))" \
      -H "x-ms-write: update" \
      -H "Content-Length: ${FILE_SIZE}" \
      --data-binary "@${SRC}" \
      -w "\n%{http_code}" 2>&1) || true

    local HTTP2
    HTTP2=$(echo "$RESP2" | tail -1)
    local BODY2
    BODY2=$(echo "$RESP2" | head -n -1)

    if [ "$HTTP2" = "201" ]; then
      echo "  [OK] Uploaded ${DEST} (${FILE_SIZE} bytes)"
      return 0
    fi

    echo "  [RETRY ${i}/${MAX_RETRIES}] PutRange ${DEST}: HTTP=${HTTP2}, waiting ${RETRY_DELAY}s..."
    echo "  [RETRY] Response: $(echo "$BODY2" | head -3)"
    sleep $RETRY_DELAY
  done

  echo "  [ERROR] Failed to upload ${DEST} after ${MAX_RETRIES} retries" >&2
  return 1
}

echo "=== Uploading ${FW_NAME} bootstrap files ==="
upload_file "$SRC_CFG" "$DEST_CFG"
rc1=$?
upload_file "$SRC_AUTH" "$DEST_AUTH"
rc2=$?

if [ $rc1 -ne 0 ] || [ $rc2 -ne 0 ]; then
  echo "=== ${FW_NAME} bootstrap upload FAILED ===" >&2
  exit 1
fi
echo "=== ${FW_NAME} bootstrap upload complete ==="
