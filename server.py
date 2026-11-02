#!/usr/bin/env python3
"""公众号取关 · 本地服务。界面在浏览器里，真正点微信的是 bin/wxunf。"""
import json
import os
import socket
import subprocess
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import unquote

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(ROOT, "data")
SHOTS = os.path.join(DATA, "shots")
ENGINE = os.path.join(ROOT, "bin", "wxunf")
os.makedirs(SHOTS, exist_ok=True)


def read_json(name, default=None):
    try:
        with open(os.path.join(DATA, name), encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def write_json(name, obj):
    path = os.path.join(DATA, name)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


class Job:
    """同一时间只跑一个引擎进程（采集或取关）"""

    def __init__(self):
        self.lock = threading.Lock()
        self.proc = None
        self.kind = None
        self.events = []
        self.last = None

    @property
    def running(self):
        return self.proc is not None and self.proc.poll() is None

    def start(self, kind):
        with self.lock:
            if self.running:
                return False
            try:
                os.remove(os.path.join(DATA, "PAUSE"))
            except FileNotFoundError:
                pass
            self.kind = kind
            self.events = []
            self.last = {"type": "starting"}
            self.proc = subprocess.Popen([ENGINE, kind], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                         text=True, bufsize=1)
            # 跑的时候别让电脑睡眠、别锁屏，不然截图全黑
            subprocess.Popen(["/usr/bin/caffeinate", "-dimsu", "-w", str(self.proc.pid)])
            threading.Thread(target=self._pump, args=(self.proc,), daemon=True).start()
            return True

    def _pump(self, proc):
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                ev = {"type": "log", "msg": line}
            if ev.get("type") == "log":
                self.events.append(ev["msg"])
                self.events = self.events[-40:]
            else:
                self.last = ev
        proc.wait()
        if self.last and self.last.get("type") in ("starting", "progress", "pausing"):
            self.last = {"type": "error", "msg": "程序意外退出了，可以点继续再试一次"}

    def state(self):
        return {"kind": self.kind, "running": self.running, "last": self.last, "log": self.events[-12:]}


JOB = Job()


def check():
    out = subprocess.run([ENGINE, "check"], capture_output=True, text=True, timeout=60).stdout
    for line in out.splitlines():
        try:
            return json.loads(line)
        except Exception:
            pass
    return {"type": "check", "error": out.strip()}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n))
        except Exception:
            return {}

    def do_GET(self):
        path = unquote(self.path.split("?")[0])
        if path in ("/", "/index.html"):
            with open(os.path.join(ROOT, "ui.html"), "rb") as f:
                return self.send(200, f.read(), "text/html; charset=utf-8")
        if path == "/api/state":
            acc = read_json("accounts.json", {}) or {}
            return self.send(200, {
                "accounts": acc.get("accounts", []),
                "accountsUpdatedAt": acc.get("updatedAt"),
                "run": read_json("run.json"),
                "job": JOB.state(),
            })
        if path.startswith("/shots/"):
            name = os.path.basename(path)
            p = os.path.join(SHOTS, name)
            if os.path.isfile(p):
                with open(p, "rb") as f:
                    return self.send(200, f.read(), "image/png")
        return self.send(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?")[0]
        b = self.body()
        if path == "/api/check":
            return self.send(200, check())
        if JOB.running and path not in ("/api/pause",):
            return self.send(409, {"error": "还有任务在跑，先等它停下"})
        if path == "/api/harvest":
            return self.send(200, {"ok": JOB.start("harvest")})
        if path == "/api/run":
            names = [n for n in b.get("names", []) if isinstance(n, str) and n.strip()]
            if not names:
                return self.send(400, {"error": "取关清单是空的"})
            write_json("run.json", {"phase": "ready", "round": 1, "createdAt": time.strftime("%Y-%m-%d %H:%M:%S"),
                                    "targets": [{"name": n, "status": "pending", "reason": "", "shot": ""}
                                                for n in dict.fromkeys(names)]})
            return self.send(200, {"ok": JOB.start("run")})
        if path == "/api/resume":
            return self.send(200, {"ok": JOB.start("run")})
        if path == "/api/retry":
            run = read_json("run.json") or {}
            for t in run.get("targets", []):
                if t.get("status") != "gone":
                    t["status"] = "pending"
            run.update({"phase": "ready", "round": 1})
            run.pop("finishedAt", None)
            write_json("run.json", run)
            return self.send(200, {"ok": JOB.start("run")})
        if path == "/api/pause":
            open(os.path.join(DATA, "PAUSE"), "w").close()
            return self.send(200, {"ok": True})
        if path == "/api/clear-run":
            try:
                os.remove(os.path.join(DATA, "run.json"))
            except FileNotFoundError:
                pass
            return self.send(200, {"ok": True})
        return self.send(404, {"error": "not found"})


def free_port(start=47900):
    for p in range(start, start + 50):
        with socket.socket() as s:
            try:
                s.bind(("127.0.0.1", p))
                return p
            except OSError:
                continue
    return 0


if __name__ == "__main__":
    port = free_port()
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{port}/"
    print(f"  公众号取关已启动：{url}")
    print("  这个窗口别关，关了工具就停了。")
    if not os.environ.get("NO_BROWSER"):
        if subprocess.run(["open", "-a", "Firefox", url]).returncode != 0:
            subprocess.run(["open", url])
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
