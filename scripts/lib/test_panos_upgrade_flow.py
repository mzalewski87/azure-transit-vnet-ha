#!/usr/bin/env python3
"""End-to-end flow test of the orchestrator against a fake Panorama XML API.

The fake models Panorama + 2 managed FWs: per-device software lists,
downloaded images, jobs, installs that take effect on restart, and the
`target=<serial>` proxy. It asserts the safety properties of the flow:
  - Panorama is upgraded before any firewall,
  - every FW has the FULL image chain downloaded before its first install,
  - content is updated before software is installed,
  - FWs are upgraded one at a time (FW2 starts only after FW1 is back).

Run: python3 scripts/lib/test_panos_upgrade_flow.py
"""

import http.server
import os
import sys
import threading
import unittest
import urllib.parse
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import panos_upgrade as pu  # noqa: E402

AVAILABLE = ["12.1.0", "12.1.9", "12.2.0", "12.2.2", "12.2.4"]


class Device:
    def __init__(self, serial, hostname, ip, version):
        self.serial, self.hostname, self.ip = serial, hostname, ip
        self.version, self.pending = version, None
        self.downloaded = {version}
        self.content_installed = False


class FakePanorama:
    def __init__(self):
        self.pan = Device("PAN001", "panorama", "10.255.0.4", "12.1.9")
        self.fws = {
            "FW001": Device("FW001", "fw1-transit-hub", "10.110.255.4", "12.1.9"),
            "FW002": Device("FW002", "fw2-transit-hub", "10.110.255.5", "12.1.9"),
        }
        self.events = []  # (device, action, detail)
        self.jobs = 0

    def dev(self, target):
        return self.fws[target] if target else self.pan

    def handle(self, p):
        t = p.get("type")
        if t == "keygen":
            self.keygen_calls = getattr(self, "keygen_calls", 0) + 1
            if p.get("password") != "x":
                raise PermissionError("Invalid Credential")
            return "<result><key>K</key></result>"
        if t == "commit":
            self.events.append(("PAN001", "push", p["cmd"][:40]))
            return "<result><job>%d</job></result>" % self._job()
        cmd, target = p.get("cmd", ""), p.get("target")
        d = self.dev(target)
        if cmd.startswith("<show><system><info>"):
            return ("<result><system><serial>%s</serial><hostname>%s</hostname>"
                    "<sw-version>%s</sw-version></system></result>" % (d.serial, d.hostname, d.version))
        if cmd.startswith("<show><devices><connected>"):
            entries = "".join(
                "<entry name='%s'><serial>%s</serial><hostname>%s</hostname><ip-address>%s</ip-address>"
                "<sw-version>%s</sw-version><connected>yes</connected></entry>"
                % (f.serial, f.serial, f.hostname, f.ip, f.version) for f in self.fws.values())
            return "<result><devices>%s</devices></result>" % entries
        if cmd.startswith("<request><system><software><check>") or cmd.startswith("<request><system><software><info>"):
            entries = "".join(
                "<entry><version>%s</version><downloaded>%s</downloaded><current>%s</current></entry>"
                % (v, "yes" if v in d.downloaded else "no", "yes" if v == d.version else "no")
                for v in AVAILABLE)
            return "<result><sw-updates><versions>%s</versions></sw-updates></result>" % entries
        if cmd.startswith("<request><system><software><download>"):
            v = ET.fromstring(cmd).findtext(".//version")
            d.downloaded.add(v)
            self.events.append((d.serial, "download", v))
            return "<result><job>%d</job></result>" % self._job()
        if cmd.startswith("<request><system><software><install>"):
            v = ET.fromstring(cmd).findtext(".//version")
            if v not in d.downloaded:
                raise RuntimeError("install of %s without image" % v)
            d.pending = v
            self.events.append((d.serial, "install", v))
            return "<result><job>%d</job></result>" % self._job()
        if cmd.startswith("<request><restart>"):
            d.version, d.pending = d.pending or d.version, None
            self.events.append((d.serial, "restart", d.version))
            return "<result>restarting</result>"
        if cmd.startswith("<request><content>"):
            if "<install>" in cmd:
                d.content_installed = True
                self.events.append((d.serial, "content", "install"))
            if "<check>" in cmd:
                return "<result/>"
            return "<result><job>%d</job></result>" % self._job()
        if cmd.startswith("<show><jobs>"):
            return ("<result><job><status>FIN</status><result>OK</result>"
                    "<progress>100</progress></job></result>")
        raise RuntimeError("unexpected cmd %s" % cmd)

    def _job(self):
        self.jobs += 1
        return self.jobs


def serve(fake):
    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"])).decode()
            p = {k: v[0] for k, v in urllib.parse.parse_qs(body).items()}
            code = 200
            try:
                out = '<response status="success">%s</response>' % fake.handle(p)
            except PermissionError as e:  # real Panorama: HTTP 403 + XML body
                code = 403
                out = '<response status="error"><result><msg>%s</msg></result></response>' % e
            except Exception as e:
                out = '<response status="error"><msg>%s</msg></response>' % e
            self.send_response(code)
            self.end_headers()
            self.wfile.write(out.encode())

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


class FlowTest(unittest.TestCase):
    def setUp(self):
        pu._sleep = lambda s: None
        self.fake = FakePanorama()
        self.srv = serve(self.fake)
        self.url = "http://127.0.0.1:%d" % self.srv.server_address[1]
        os.environ["PAN_PASS"] = "x"

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()

    def run_main(self, *extra):
        sys.argv = ["panos_upgrade.py", "--url", self.url, "--target", "12.2.4"] + list(extra)
        pu.main()

    def test_full_upgrade_order_and_chain(self):
        self.run_main()
        ev = self.fake.events
        idx = lambda pred: next(i for i, e in enumerate(ev) if pred(e))

        # Panorama upgraded first, one release per hop (base 12.2.0 + target).
        pan_restart = idx(lambda e: e[0] == "PAN001" and e[1] == "restart")
        first_fw = idx(lambda e: e[0].startswith("FW"))
        self.assertLess(pan_restart, first_fw)
        self.assertEqual(self.fake.pan.version, "12.2.4")

        for fw in ("FW001", "FW002"):
            fev = [e for e in ev if e[0] == fw]
            first_install = next(i for i, e in enumerate(fev) if e[1] == "install")
            # full chain (base + target) downloaded before the first install
            self.assertEqual({e[2] for e in fev[:first_install] if e[1] == "download"},
                             {"12.2.0", "12.2.4"})
            # content before software
            self.assertLess(next(i for i, e in enumerate(fev) if e[1] == "content"), first_install)
            self.assertEqual(self.fake.fws[fw].version, "12.2.4")

        # one at a time: FW2 does nothing until FW1 has restarted on target
        fw1_restart = idx(lambda e: e[0] == "FW001" and e[1] == "restart")
        fw2_first = idx(lambda e: e[0] == "FW002")
        self.assertLess(fw1_restart, fw2_first)

        # config re-pushed at the end
        self.assertEqual(ev[-1][1], "push")

    def test_plan_only_changes_nothing(self):
        self.run_main("--plan-only")
        self.assertEqual([e for e in self.fake.events if e[1] != "push"], [])
        self.assertEqual(self.fake.pan.version, "12.1.9")

    def test_panorama_too_old_without_permission_aborts(self):
        with self.assertRaises(SystemExit):
            self.run_main("--no-upgrade-panorama")
        self.assertEqual([e for e in self.fake.events if e[0].startswith("FW")], [])

    def test_unreachable_panorama_exits_cleanly(self):
        # Regression: a dead tunnel used to surface as a raw urllib traceback.
        import socket
        hang = socket.socket()
        hang.bind(("127.0.0.1", 0))
        hang.listen(1)  # accepts TCP, never speaks TLS -> handshake timeout
        port = hang.getsockname()[1]
        orig = pu.Panorama._post
        pu.Panorama._post = lambda self, params, timeout=120, retries=3: orig(self, params, 1, 2)
        try:
            sys.argv = ["panos_upgrade.py", "--url", "https://127.0.0.1:%d" % port,
                        "--target", "12.2.4", "--plan-only"]
            with self.assertRaises(SystemExit) as cm:
                pu.main()
            self.assertIn("cannot reach Panorama API", str(cm.exception.code))
        finally:
            pu.Panorama._post = orig
            hang.close()

    def test_bad_password_single_attempt_clear_error(self):
        # Regression: HTTP 403 was treated as a network error and retried 6x.
        os.environ["PAN_PASS"] = "wrong"
        with self.assertRaises(SystemExit) as cm:
            self.run_main("--plan-only")
        self.assertIn("rejected the credentials", str(cm.exception.code))
        self.assertEqual(self.fake.keygen_calls, 1)

    def test_already_on_target_is_noop(self):
        self.fake.pan.version = "12.2.4"
        for f in self.fake.fws.values():
            f.version = "12.2.4"
        self.run_main()
        self.assertEqual([e[1] for e in self.fake.events], ["push", "push"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
