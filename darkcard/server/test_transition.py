"""过渡期实测：从 v0.3.0 升到 v0.3.1 的完整链路。

场景：对方的服务器上装的是 v0.3.0（旧的自动更新器，只认规则层）。
要验证的是：
  1. 旧服务器能把新版本的文件下载并铺到磁盘上
  2. 但跑着的进程还是旧代码（这正是过渡期的状态）
  3. 跑一次 update.sh 之后，新代码真的在运行

为了不受 GitHub 网络波动影响，这里本地起一个"假 GitHub"：
  /api   → {"tag_name": "v0.3.1"}
  /pkg.zip → 新版服务器包
然后把旧服务器副本里的两个 GitHub 地址指向本地。

注意：v0.3.0 的 server.py 不认识环境变量，所以是直接把文本地址替换掉的
（只改这个临时测试副本，发布产物不受影响）。
"""

import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
ROOT = os.path.dirname(PROJ)
GODOT = "D:/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64.exe"

# 旧包里这两个地址带 %s 占位符，替换的是整段表达式
OLD_URL_API = '"https://api.github.com/repos/%s/releases/latest" % UPDATE_REPO'
OLD_URL_PKG = '"https://github.com/%s/releases/latest/download/darkcard-server.zip" % UPDATE_REPO'

PASS = 0
FAIL = 0


def ok(cond, label, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  OK   %s" % label)
    else:
        FAIL += 1
        print("  FAIL %s%s" % (label, ("  | " + detail) if detail else ""))


class FakeGitHub(http.server.BaseHTTPRequestHandler):
    pkg = b""

    def do_GET(self):  # noqa: N802
        if self.path.startswith("/api"):
            body = json.dumps({"tag_name": "v0.3.1"}).encode()
            ctype = "application/json"
        else:
            body = self.pkg
            ctype = "application/zip"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def main():
    print("=" * 64)
    print("过渡期实测：v0.3.0 → v0.3.1")
    print("=" * 64)

    # 新版服务器包：用仓库里打好的
    pkg_path = os.path.join(PROJ, "build", "darkcard-server-v0.3.1.zip")
    if not os.path.exists(pkg_path):
        print("找不到 %s，先跑 pack_server.py" % pkg_path)
        return 1
    with open(pkg_path, "rb") as f:
        FakeGitHub.pkg = f.read()

    srv = http.server.HTTPServer(("127.0.0.1", 19140), FakeGitHub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    local_api = "http://127.0.0.1:19140/api"
    local_pkg = "http://127.0.0.1:19140/pkg.zip"
    print("假 GitHub 已起：%s" % local_api)

    dest = tempfile.mkdtemp(prefix="dc_trans_")
    try:
        # 铺一份 v0.3.0 的服务器（旧代码）
        # 旧版服务器包固定放在仓库里，这个测试才能一直复现
        old_pkg = os.path.join(HERE, "fixtures", "v030_server.zip")
        if not os.path.exists(old_pkg):
            print("缺少 v0.3.0 的包：%s" % old_pkg)
            return 1
        with zipfile_zip(old_pkg) as z:
            z.extractall(dest)
        # 把 GitHub 地址换成本地的（模拟"GitHub 可达"）
        sp = os.path.join(dest, "server.py")
        s = open(sp, encoding="utf-8").read()
        assert OLD_URL_API in s, "旧包里的 API 地址没找到"
        s = s.replace(OLD_URL_API, '"' + local_api + '"')
        s = s.replace(OLD_URL_PKG, '"' + local_pkg + '"')
        # 检查间隔改短，不然要等十分钟
        s = s.replace("CHECK_INTERVAL = 600.0", "CHECK_INTERVAL = 5.0", 1)
        s = s.replace("if self._stop.wait(60.0)", "if self._stop.wait(5.0)", 1)
        open(sp, "w", encoding="utf-8").write(s)
        print("v0.3.0 旧服务器已装到 %s" % dest)

        # 起旧服务器
        proc = subprocess.Popen(
            [sys.executable, sp, "--port", "19141", "--host", "127.0.0.1",
             "--store", os.path.join(dest, "store.json")],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        buf = []

        def reader():
            for line in proc.stdout:
                buf.append(line.decode("utf-8", "replace"))
        threading.Thread(target=reader, daemon=True).start()

        # 等它自动更新
        deadline = time.time() + 40
        while time.time() < deadline:
            time.sleep(1)
            if "新文件已解压" in "".join(buf):
                break
        time.sleep(2)
        log = "".join(buf)
        print("\n--- 旧服务器的日志 ---")
        print(log.strip())
        print()

        ok("新文件已解压" in log, "旧服务器自动把新版本下载并铺到磁盘上")
        ver = open(os.path.join(dest, "版本.txt"), encoding="utf-8").read()
        ok("0.3.1" in ver, "磁盘上的版本已是 0.3.1", ver.strip())
        src = open(sp, encoding="utf-8").read()
        ok("RULE_FILES" in src, "磁盘上的 server.py 已是新版代码")

        # 现在跑的是旧代码：health 不报 game_version
        h = json.loads(urllib.request.urlopen(
            "http://127.0.0.1:19141/api/health", timeout=5).read().decode())
        ok("game_version" not in h,
           "跑着的仍是旧代码（旧版 health 不报 game_version）", str(h))

        # 真实 Linux 上 update.sh 靠 fuser/lsof 按端口找旧进程；
        # 这里（Windows 测试环境）没有那些工具，所以补一个 server.pid，
        # 模拟"新版本服务器会写 pid 文件"这条路。
        with open(os.path.join(dest, "server.pid"), "w", encoding="utf-8") as f:
            f.write(str(proc.pid))

        # Linux 上这一步是 systemctl restart darkcard 干的活（把旧进程停掉）。
        # 这里 Windows 测试环境没法用 kill 停掉另一个 shell 起的进程，
        # 所以由测试代劳，效果等价。
        logtxt = open(os.path.join(dest, "server.log"), encoding="utf-8",
                      errors="replace").read() if os.path.exists(
                          os.path.join(dest, "server.log")) else ""
        print("\n--- 跑 update.sh ---")
        env = dict(os.environ)
        env["DARKCARD_UPDATE_API"] = local_api
        env["DARKCARD_UPDATE_URL"] = local_pkg
        env["DC_PORT"] = "19141"
        env["PATH"] = env["PATH"]
        # 让脚本里的 python3 指到当前解释器
        bindir = os.path.dirname(sys.executable)
        shutil.copy(sys.executable, os.path.join(bindir, "python3.exe")) \
            if not os.path.exists(os.path.join(bindir, "python3.exe")) else None
        # 先把旧进程停掉（等价于 Linux 上 systemctl restart 的前半步）
        try:
            proc.kill()
            proc.wait(timeout=5)
        except Exception:
            pass
        time.sleep(1)

        r = subprocess.run(["bash", "update.sh"], cwd=dest, env=env,
                           capture_output=True, timeout=180)
        out = r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")
        print(out.strip())
        print()

        ok("文件已是最新" in out, "update.sh 认出文件已是最新")
        ok("继续执行重启" in out, "update.sh 决定继续重启（而不是直接退出）")
        ok("已启动新进程" in out, "新进程被拉起", out[-300:])

        time.sleep(2)
        h2 = json.loads(urllib.request.urlopen(
            "http://127.0.0.1:19141/api/health", timeout=5).read().decode())
        ok(h2.get("game_version") == "0.3.1",
           "现在跑的是 v0.3.1 的新代码", str(h2))
        ok(h2.get("rules_version") == "2.1", "规则版本正常", str(h2))

        try:
            proc.kill()
        except OSError:
            pass
    finally:
        shutil.rmtree(dest, ignore_errors=True)
        srv.shutdown()

    print("\n" + "=" * 64)
    print("通过 %d 项，失败 %d 项" % (PASS, FAIL))
    print("=" * 64)
    return 1 if FAIL else 0


def zipfile_zip(path):
    import zipfile
    return zipfile.ZipFile(path)


if __name__ == "__main__":
    sys.exit(main())
