#!/usr/bin/env python3
"""
Generate AKS egress External Dynamic Lists for PAN-OS / Panorama.

Reads:
  - /opt/aks-edl/fqdn_base_list.txt   (hardcoded FQDN baseline)
  - /opt/aks-edl/settings.json        (region, output dir, refresh policy)

Writes (atomically — temp file then rename):
  - /var/www/html/edl/aks-egress-fqdn.txt   (URL list — wildcards permitted)
  - /var/www/html/edl/aks-egress-ips.txt    (IP list — CIDRs from Azure Service
                                              Tags JSON, AzureCloud.<region>)

PAN-OS quirks honoured:
  - URL list entries are written with a trailing slash so wildcards match.
    Without the slash, `*.example.com` silently fails.
  - Lines starting with # or ; in the source list are preserved as comments
    in the output (PAN-OS treats both as comments).

If the Azure Service Tags JSON cannot be fetched, the IP list is regenerated
from the previous version on disk (best-effort: stale list is preferable to
an empty list — empty would block legitimate UDP 1194 / TCP 9000 traffic).

Logs to /var/log/aks-edl-update.log with a diff vs the previous version.

Invoked by aks-edl-update.service (one-shot, triggered by aks-edl-update.timer).
"""

import datetime
import json
import logging
import os
import re
import shutil
import sys
import tempfile
import urllib.error
import urllib.request

LOG_PATH = "/var/log/aks-edl-update.log"
BASE_LIST_PATH = "/opt/aks-edl/fqdn_base_list.txt"
SETTINGS_PATH = "/opt/aks-edl/settings.json"
OUTPUT_DIR = "/var/www/html/edl"
FQDN_OUT = os.path.join(OUTPUT_DIR, "aks-egress-fqdn.txt")
IPS_OUT = os.path.join(OUTPUT_DIR, "aks-egress-ips.txt")

# Microsoft updates the JSON weekly. The download URL on the confirmation page
# changes each release, so scrape the confirmation page for the current link.
SERVICE_TAGS_CONFIRM_URL = (
    "https://www.microsoft.com/en-us/download/confirmation.aspx?id=56519"
)
SERVICE_TAGS_URL_RE = re.compile(
    r'https://download\.microsoft\.com/download/[^"\s]+/ServiceTags_Public_[0-9]+\.json'
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_PATH),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("aks-edl")


def load_settings():
    with open(SETTINGS_PATH, "r", encoding="utf-8") as f:
        s = json.load(f)
    if not s.get("region"):
        raise RuntimeError("settings.json missing 'region'")
    return s


def render_fqdn_list(region):
    out = [
        f"# AKS Egress FQDN List",
        f"# Generated: {datetime.datetime.utcnow().isoformat()}Z",
        f"# Region: {region}",
        "",
    ]
    with open(BASE_LIST_PATH, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            stripped = line.strip()
            if not stripped or stripped.startswith(("#", ";")):
                out.append(line)
                continue
            entry = stripped.replace("${REGION}", region)
            out.append(entry + "/")
    return "\n".join(out) + "\n"


def fetch_service_tags_json():
    """Discover current Service Tags JSON URL then download it."""
    req = urllib.request.Request(
        SERVICE_TAGS_CONFIRM_URL,
        headers={"User-Agent": "aks-edl-generator/1.0"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        html = resp.read().decode("utf-8", errors="replace")
    matches = SERVICE_TAGS_URL_RE.findall(html)
    if not matches:
        raise RuntimeError("Could not find Service Tags JSON URL on confirmation page")
    json_url = matches[0]
    log.info("Discovered Service Tags JSON URL: %s", json_url)
    req = urllib.request.Request(json_url, headers={"User-Agent": "aks-edl-generator/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read())


def extract_azurecloud_cidrs(svc_tags_doc, region):
    """Return CIDRs for AzureCloud.<region> (case-insensitive region match)."""
    target = f"azurecloud.{region.lower()}"
    for v in svc_tags_doc.get("values", []):
        if v.get("name", "").lower() == target:
            prefixes = v.get("properties", {}).get("addressPrefixes", []) or []
            # IPv4 only — PAN-OS IP EDL handles both but our security rules are v4
            return [p for p in prefixes if ":" not in p]
    raise RuntimeError(f"AzureCloud.{region} not present in Service Tags JSON")


def render_ip_list(region, cidrs):
    out = [
        f"# AKS Egress IP List (AzureCloud.{region})",
        f"# Generated: {datetime.datetime.utcnow().isoformat()}Z",
        f"# Count: {len(cidrs)}",
        "",
    ]
    out.extend(sorted(cidrs))
    return "\n".join(out) + "\n"


def write_atomic(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-", suffix=".txt")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def diff_summary(path, new_content):
    if not os.path.exists(path):
        return "new file (was absent)"
    with open(path, "r", encoding="utf-8") as f:
        old = f.read()
    if old == new_content:
        return "unchanged"
    old_lines = {l for l in old.splitlines() if l and not l.startswith("#")}
    new_lines = {l for l in new_content.splitlines() if l and not l.startswith("#")}
    added = new_lines - old_lines
    removed = old_lines - new_lines
    return f"changed (+{len(added)} -{len(removed)})"


def main():
    log.info("=== aks-edl generation starting ===")
    settings = load_settings()
    region = settings["region"]

    # FQDN list — never fails; baseline file is always present
    fqdn_content = render_fqdn_list(region)
    log.info("FQDN list: %s", diff_summary(FQDN_OUT, fqdn_content))
    write_atomic(FQDN_OUT, fqdn_content)

    # IP list — best-effort fetch; keep old file on failure
    try:
        svc_tags = fetch_service_tags_json()
        cidrs = extract_azurecloud_cidrs(svc_tags, region)
        ip_content = render_ip_list(region, cidrs)
        log.info("IP list: %s (CIDRs: %d)", diff_summary(IPS_OUT, ip_content), len(cidrs))
        write_atomic(IPS_OUT, ip_content)
    except Exception as e:
        log.warning("IP list fetch FAILED: %s", e)
        if os.path.exists(IPS_OUT):
            log.warning("Keeping previous IP list at %s", IPS_OUT)
        else:
            # Emit a minimal stub so nginx serves something & PAN-OS doesn't 404.
            stub = (
                f"# AKS Egress IP List (AzureCloud.{region})\n"
                f"# Generated: {datetime.datetime.utcnow().isoformat()}Z\n"
                f"# FETCH FAILED — empty stub written so PAN-OS gets a 200 response\n"
                f"# Re-run /opt/aks-edl/generate_aks_edl.py once network access is restored\n"
            )
            write_atomic(IPS_OUT, stub)
            log.warning("Wrote empty stub IP list (no previous version on disk)")

    log.info("=== aks-edl generation finished ===")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log.exception("aks-edl generation crashed: %s", e)
        sys.exit(1)
