#!/usr/bin/env python3
"""
PAN-OS upgrade orchestrator — Panorama + managed VM-Series, driven through
the Panorama XML API (single Bastion tunnel to Panorama).

Invoked by scripts/upgrade-panos.sh (which opens the tunnel and reads the
target version from `terraform output -json panos_upgrade`). Stdlib only.

ORCHESTRATION (all calls go to Panorama; firewall commands are proxied with
the XML API `target=<serial>` parameter, so the FWs never need a tunnel):

  0. Pre-flight: both FWs connected, target offered by the update server,
     upgrade plan computed and printed (--plan-only stops here).
  1. Panorama first (it must run >= the FW target): one feature release per
     hop — download base image + hop version, install, reboot, wait for API.
  2. Each firewall, ONE AT A TIME (both are active behind the Azure LB; the
     LB health probe drains the one that reboots):
       a. content update (latest) — PAN-OS requires a minimum content version
          before a software install,
       b. download the FULL image chain for the whole upgrade and verify every
          image reports downloaded=yes BEFORE installing anything,
       c. install + reboot per hop, wait until Panorama sees the FW connected
          on the expected version,
       d. MGMT VF boot-race check (scripts/check-mgmt-vf-race.sh); RACE /
          NO-MGMT triggers deallocate + start recovery.
  3. Re-push Template Stack + Device Group (PANW: push full config after
     upgrading managed firewalls).

UPGRADE PATH RULES (PAN-OS "Skip Software Version Upgrade", PAN-OS >= 10.1):
  - A firewall may skip up to MAX_SKIP (3) feature releases in one install,
    but the BASE image of every skipped release AND of the target release
    must already be downloaded on the firewall (installation is not needed).
  - Feature releases are discovered from the update server list (e.g. there
    is no 12.0 — 11.2 is followed by 12.1). A release's base image is its
    lowest non-hotfix version (normally X.Y.0).
  - Larger jumps are split into hops that each skip at most MAX_SKIP.
  - Panorama itself is upgraded one feature release per hop (max_skip=0).
"""

import argparse
import functools
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

MAX_SKIP = 3


def _sleep(seconds):
    time.sleep(seconds)  # indirection so tests can run without real waits

# ─── Versions & upgrade path planning (pure, unit-tested) ───────────────────

_VER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-h(\d+))?$")


@functools.total_ordering
class Version:
    def __init__(self, text):
        m = _VER_RE.match(text.strip())
        if not m:
            raise ValueError("not a PAN-OS version: %r" % text)
        self.text = text.strip()
        self.major, self.minor, self.patch = (int(m.group(i)) for i in (1, 2, 3))
        self.hotfix = int(m.group(4) or 0)

    @property
    def train(self):
        return (self.major, self.minor)

    @property
    def key(self):
        return (self.major, self.minor, self.patch, self.hotfix)

    def __lt__(self, other):
        return self.key < other.key

    def __eq__(self, other):
        return self.key == other.key

    def __hash__(self):
        return hash(self.key)

    def __repr__(self):
        return self.text


def _parse_all(versions):
    out = []
    for v in versions:
        try:
            out.append(Version(v))
        except ValueError:
            pass  # ignore unparseable entries from the update server
    return out


def base_of(train, available):
    """Lowest non-hotfix version of a feature release (normally X.Y.0)."""
    in_train = sorted(v for v in available if v.train == train)
    if not in_train:
        raise ValueError("no images available for release %d.%d" % train)
    plain = [v for v in in_train if v.hotfix == 0]
    return (plain or in_train)[0]


def landing_of(train, available):
    """Version to land on for an intermediate hop: latest non-hotfix release."""
    in_train = sorted(v for v in available if v.train == train)
    plain = [v for v in in_train if v.hotfix == 0]
    return (plain or in_train)[-1]


def plan_upgrade(current, target, available, max_skip=MAX_SKIP):
    """Compute the upgrade plan.

    Returns {"downloads": [Version...], "hops": [Version...]}:
      downloads — every image that must be on the device before the first
                  install (whole chain, ordered, de-duplicated),
      hops      — versions to install in order (each followed by a reboot).
    Raises ValueError on downgrade / unavailable target.
    """
    cur, tgt = Version(current), Version(target)
    avail = set(_parse_all(available)) | {tgt}
    if tgt == cur:
        return {"downloads": [], "hops": []}
    if tgt < cur:
        raise ValueError("target %s is older than current %s (downgrade not supported)" % (tgt, cur))
    if Version(target) not in set(_parse_all(available)):
        raise ValueError("target %s is not offered by the update server" % tgt)
    if cur.key < (10, 1, 0, 0):
        max_skip = 0  # skip-upgrade needs PAN-OS 10.1+ on the device

    if tgt.train == cur.train:
        return {"downloads": [tgt], "hops": [tgt]}

    trains = sorted({v.train for v in avail if cur.train < v.train <= tgt.train})
    downloads, hops = [], []
    while trains:
        if len(trains) - 1 <= max_skip:
            hop_trains, landing = trains, tgt
            trains = []
        else:
            hop_trains = trains[: max_skip + 1]
            trains = trains[max_skip + 1:]
            landing = landing_of(hop_trains[-1], avail)
        for t in hop_trains:
            downloads.append(base_of(t, avail))
        downloads.append(landing)
        hops.append(landing)

    seen, ordered = set(), []
    for v in downloads:
        if v not in seen:
            seen.add(v)
            ordered.append(v)
    return {"downloads": ordered, "hops": hops}


# ─── Panorama XML API client ────────────────────────────────────────────────

class ApiError(Exception):
    pass


class Panorama:
    def __init__(self, url, user, password):
        self.url = url.rstrip("/") + "/api/"
        self.user, self.password = user, password
        self.ctx = ssl.create_default_context()
        self.ctx.check_hostname = False
        self.ctx.verify_mode = ssl.CERT_NONE  # self-signed mgmt cert via tunnel
        self.key = None

    def _post(self, params, timeout=120, retries=3):
        """POST to the XML API. Network failures (tunnel hiccup, TLS handshake
        timeout, device restarting) are retried, then raised as ApiError so
        callers never see a raw urllib traceback."""
        data = urllib.parse.urlencode(params).encode()
        for attempt in range(1, retries + 1):
            try:
                req = urllib.request.Request(self.url, data=data)
                with urllib.request.urlopen(req, context=self.ctx, timeout=timeout) as r:
                    body = r.read()
                break
            except (urllib.error.URLError, OSError) as e:  # incl. TimeoutError, ssl errors
                reason = getattr(e, "reason", e)
                if attempt == retries:
                    raise ApiError("cannot reach Panorama API at %s (%s)" % (self.url, reason))
                _sleep(10)
        try:
            root = ET.fromstring(body)
        except ET.ParseError:
            raise ApiError("non-XML response from %s: %r" % (self.url, body[:200]))
        if root.get("status") != "success":
            msg = " ".join(t.strip() for t in root.itertext() if t.strip())
            raise ApiError(msg or "API call failed")
        return root

    def login(self, retries=6):
        root = self._post({"type": "keygen", "user": self.user, "password": self.password},
                          30, retries)
        self.key = root.findtext(".//key")
        if not self.key:
            raise ApiError("keygen returned no key")

    def op(self, cmd, target=None, timeout=120):
        params = {"type": "op", "cmd": cmd, "key": self.key}
        if target:
            params["target"] = target
        return self._post(params, timeout)

    def commit_all(self, cmd):
        return self._post({"type": "commit", "action": "all", "cmd": cmd, "key": self.key}, 120)

    def reachable(self):
        try:
            self.login(retries=1)
            return True
        except Exception:
            return False


# ─── Operations ─────────────────────────────────────────────────────────────

def log(msg):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


def system_info(pan, target=None):
    root = pan.op("<show><system><info></info></system></show>", target)
    return {
        "serial": root.findtext(".//serial", ""),
        "sw_version": root.findtext(".//sw-version", ""),
        "hostname": root.findtext(".//hostname", ""),
    }


def connected_devices(pan):
    root = pan.op("<show><devices><connected></connected></devices></show>")
    devs = []
    for e in root.findall("./result/devices/entry"):
        devs.append({
            "serial": e.findtext("serial") or e.get("name", ""),
            "hostname": e.findtext("hostname", ""),
            "ip": e.findtext("ip-address", ""),
            "sw_version": e.findtext("sw-version", ""),
            "connected": e.findtext("connected", "") == "yes",
        })
    return devs


def software_check(pan, target=None):
    """Refresh the list from the update server; return (current, {ver: entry})."""
    root = pan.op("<request><system><software><check></check></software></system></request>",
                  target, timeout=300)
    versions, current = {}, None
    for e in root.findall(".//versions/entry"):
        v = e.findtext("version", "")
        versions[v] = {"downloaded": e.findtext("downloaded", "") == "yes"}
        if e.findtext("current", "") == "yes":
            current = v
    return current, versions


def downloaded_versions(pan, target=None):
    root = pan.op("<request><system><software><info></info></software></system></request>", target)
    return {e.findtext("version", "") for e in root.findall(".//versions/entry")
            if e.findtext("downloaded", "") == "yes"}


def wait_job(pan, job, target=None, what="job", timeout_s=3600):
    deadline, last = time.time() + timeout_s, None
    while time.time() < deadline:
        try:
            root = pan.op("<show><jobs><id>%s</id></jobs></show>" % job, target)
        except Exception as e:  # transient (tunnel / proxy hiccup)
            log("  %s: job %s poll error (%s), retrying" % (what, job, e))
            _sleep(20)
            continue
        status = root.findtext(".//job/status", "")
        result = root.findtext(".//job/result", "")
        progress = root.findtext(".//job/progress", "")
        if status == "FIN":
            if result == "OK":
                log("  %s: job %s OK" % (what, job))
                return
            details = " ".join(l.text or "" for l in root.findall(".//job/details/line"))
            raise ApiError("%s: job %s %s %s" % (what, job, result, details.strip()))
        if progress != last:
            log("  %s: job %s %s %s%%" % (what, job, status, progress))
            last = progress
        _sleep(20)
    raise ApiError("%s: job %s timed out" % (what, job))


def _job_id(root):
    job = root.findtext(".//job")
    if not job:
        raise ApiError("no job id in response: %s" % ET.tostring(root, "unicode")[:300])
    return job


def ensure_downloaded(pan, versions, target=None, label=""):
    have = downloaded_versions(pan, target)
    for v in versions:
        if v.text in have:
            log("  %s: image %s already downloaded" % (label, v))
            continue
        log("  %s: downloading image %s" % (label, v))
        root = pan.op("<request><system><software><download><version>%s</version>"
                      "</download></software></system></request>" % v.text, target)
        wait_job(pan, _job_id(root), target, "%s download %s" % (label, v))
    have = downloaded_versions(pan, target)
    missing = [v.text for v in versions if v.text not in have]
    if missing:
        raise ApiError("%s: images not on device after download: %s" % (label, ", ".join(missing)))
    log("  %s: full image chain present: %s" % (label, ", ".join(v.text for v in versions)))


def install_and_restart(pan, version, target=None, label=""):
    log("  %s: installing %s" % (label, version))
    root = pan.op("<request><system><software><install><version>%s</version>"
                  "</install></software></system></request>" % version.text, target)
    wait_job(pan, _job_id(root), target, "%s install %s" % (label, version))
    log("  %s: rebooting" % label)
    try:
        pan.op("<request><restart><system></system></restart></request>", target, timeout=30)
    except Exception:
        pass  # the device may drop the connection while restarting


def content_update(pan, target, label):
    try:
        pan.op("<request><content><upgrade><check></check></upgrade></content></request>",
               target, timeout=300)
        root = pan.op("<request><content><upgrade><download><latest></latest></download>"
                      "</upgrade></content></request>", target)
        wait_job(pan, _job_id(root), target, "%s content download" % label)
        root = pan.op("<request><content><upgrade><install><version>latest</version>"
                      "</install></upgrade></content></request>", target)
        wait_job(pan, _job_id(root), target, "%s content install" % label)
    except ApiError as e:
        log("  [WARN] %s: content update failed (%s) — continuing; the software install"
            " will refuse if the content is below the required minimum" % (label, e))


def vf_check(vm, args, recover):
    """Run check-mgmt-vf-race.sh; returns its exit code (0 ok, 2 bad, 3 unknown)."""
    if not args.vf_check or not vm:
        return 0
    cmd = [args.vf_check] + (["--recover", "--yes"] if recover else []) + [vm]
    log("  running: %s" % " ".join(cmd))
    return subprocess.call(cmd)


def wait_until(predicate, timeout_s, label, on_stall=None, stall_after_s=None):
    start = time.time()
    stalled = False
    while time.time() - start < timeout_s:
        if predicate():
            return True
        if on_stall and not stalled and stall_after_s and time.time() - start > stall_after_s:
            stalled = True
            on_stall()
        _sleep(30)
    return False


# ─── Phases ─────────────────────────────────────────────────────────────────

def upgrade_panorama(pan, target, args):
    info = system_info(pan)
    current = info["sw_version"]
    if Version(current) >= Version(target):
        log("Panorama %s >= %s — no Panorama upgrade needed" % (current, target))
        return
    if not args.upgrade_panorama:
        raise ApiError("Panorama runs %s < target %s; Panorama must be >= its firewalls. "
                       "Enable panos_upgrade_panorama or upgrade Panorama first." % (current, target))
    _, versions = software_check(pan)
    plan = plan_upgrade(current, target, versions.keys(), max_skip=0)
    log("Panorama plan: %s -> %s via %s (downloads: %s)" % (
        current, target, " -> ".join(map(str, plan["hops"])),
        ", ".join(map(str, plan["downloads"]))))
    if args.plan_only:
        return
    for hop in plan["hops"]:
        hop_downloads = [v for v in plan["downloads"] if v.train == hop.train and v <= hop]
        ensure_downloaded(pan, hop_downloads, None, "Panorama")
        install_and_restart(pan, hop, None, "Panorama")
        _sleep(120)

        def up():
            if not pan.reachable():
                return False
            try:
                return system_info(pan)["sw_version"] == hop.text
            except Exception:
                return False

        ok = wait_until(up, 45 * 60, "Panorama",
                        on_stall=lambda: vf_check(args.panorama_vm, args, recover=True),
                        stall_after_s=20 * 60)
        if not ok:
            raise ApiError("Panorama did not come back on %s within 45 min" % hop)
        log("Panorama is up on %s" % hop)
        vf_check(args.panorama_vm, args, recover=False)


def upgrade_firewall(pan, dev, target, args):
    serial, label = dev["serial"], "%s(%s)" % (dev["hostname"] or "fw", dev["serial"])
    vm = args.vm_map.get(dev["ip"])
    current, versions = software_check(pan, serial)
    current = current or dev["sw_version"]
    if Version(current) >= Version(target):
        log("%s already on %s — skipping" % (label, current))
        return
    plan = plan_upgrade(current, target, versions.keys())
    log("%s plan: %s -> %s, hops %s, image chain %s" % (
        label, current, target, " -> ".join(map(str, plan["hops"])),
        ", ".join(map(str, plan["downloads"]))))
    if args.plan_only:
        return

    content_update(pan, serial, label)
    ensure_downloaded(pan, plan["downloads"], serial, label)

    for hop in plan["hops"]:
        install_and_restart(pan, hop, serial, label)
        _sleep(120)

        def back():
            try:
                for d in connected_devices(pan):
                    if d["serial"] == serial:
                        return d["connected"] and d["sw_version"] == hop.text
            except Exception:
                pass
            return False

        ok = wait_until(back, 40 * 60, label,
                        on_stall=lambda: vf_check(vm, args, recover=True),
                        stall_after_s=20 * 60)
        if not ok:
            raise ApiError("%s did not reconnect to Panorama on %s within 40 min" % (label, hop))
        log("%s connected on %s" % (label, hop))
        if vf_check(vm, args, recover=False) == 2:
            raise ApiError("%s: MGMT VF race detected after reboot" % label)


def push_config(pan, args):
    log("Re-pushing Template Stack %s and Device Group %s" % (args.template_stack, args.device_group))
    for cmd in (
        "<commit-all><template-stack><name>%s</name></template-stack></commit-all>" % args.template_stack,
        "<commit-all><shared-policy><device-group><entry name='%s'/></device-group>"
        "</shared-policy></commit-all>" % args.device_group,
    ):
        root = pan.commit_all(cmd)
        job = root.findtext(".//job")
        if job:
            wait_job(pan, job, None, "push", timeout_s=900)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", required=True, help="Panorama base URL (e.g. https://127.0.0.1:44310)")
    p.add_argument("--user", default="panadmin")
    p.add_argument("--target", required=True, help="PAN-OS target version for the firewalls")
    p.add_argument("--no-upgrade-panorama", dest="upgrade_panorama", action="store_false")
    p.add_argument("--plan-only", action="store_true", help="print the plan, change nothing")
    p.add_argument("--vm-map", default="", help="mgmt-ip=vm-name,... for the VF race check")
    p.add_argument("--panorama-vm", default="vm-panorama")
    p.add_argument("--vf-check", default="", help="path to check-mgmt-vf-race.sh")
    p.add_argument("--device-group", default="Transit-VNet-DG")
    p.add_argument("--template-stack", default="Transit-VNet-Stack")
    p.add_argument("--expect-fws", type=int, default=2)
    args = p.parse_args()
    args.vm_map = dict(kv.split("=", 1) for kv in args.vm_map.split(",") if "=" in kv)
    Version(args.target)  # validate early

    password = os.environ.get("PAN_PASS")
    if not password:
        sys.exit("PAN_PASS is not set")
    pan = Panorama(args.url, args.user, password)

    try:
        pan.login()
        devs = [d for d in connected_devices(pan) if d["connected"]]
        log("Panorama %s; connected firewalls: %s" % (
            system_info(pan)["sw_version"],
            ", ".join("%s %s %s" % (d["hostname"], d["serial"], d["sw_version"]) for d in devs) or "none"))
        if len(devs) < args.expect_fws:
            sys.exit("[ERROR] expected %d connected firewalls, found %d — fix Phase 2b first"
                     % (args.expect_fws, len(devs)))

        upgrade_panorama(pan, args.target, args)
        for dev in sorted(devs, key=lambda d: d["hostname"]):
            upgrade_firewall(pan, dev, args.target, args)
        if not args.plan_only:
            push_config(pan, args)
    except (ApiError, ValueError) as e:
        sys.exit("[ERROR] %s" % e)
    log("Plan only — nothing changed" if args.plan_only else "Upgrade to %s completed" % args.target)


if __name__ == "__main__":
    main()
