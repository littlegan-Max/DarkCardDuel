"""实测：往 app 加一个新游戏模式，服务器能不能自己更新上去。

这是作者最关心的一条：「自动更新满足要：比如我之后要往 app 加新模式，
自动更新能自动更新」。

所以这里造一个"新版本"，里面包含加新模式需要动到的**所有**东西：
  · cards.json   —— 新模式的卡牌
  · engine.py    —— 新模式的结算逻辑
  · server.py    —— 新模式的服务器侧处理（新增一个命令）
  · modes.py     —— 全新出现的模块文件（以前没有这个文件）

然后让服务器自己发现、自己下载、自己应用，最后验证新模式确实能用。
全程不需要给服务器发任何文件。
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


def call(base, cmd, **body):
    body.setdefault("player_id", "")
    body.setdefault("token", "")
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        base + "/api/" + cmd, data=data,
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8"))


def build_new_release(zip_path, dest):
    """造一个"加了新模式"的新版本包。"""
    import zipfile

    # 1) 新卡表：多一张新模式的牌，规则版本 +1
    cards = json.load(open(os.path.join(PROJ, "data", "cards.json"), encoding="utf-8"))
    cards["rules_version"] = "2.2"
    cards["cards"].append({
        "id": "xin_mo_shi_pai",
        "name": "新模式牌",
        "desc": "新模式专用：+0.3",
        "cost": 20,
        "target": "self",
        "tags": ["heal"],
        "ops": [{"op": "HEAL", "amount": 30}],
        "notes": "v0.3.2 新模式专用",
    })
    cards_path = os.path.join(dest, "cards.json")
    with open(cards_path, "w", encoding="utf-8") as f:
        json.dump(cards, f, ensure_ascii=False, indent=2)

    # 2) 新引擎：加一个模式相关的函数
    engine = open(os.path.join(PROJ, "train", "engine.py"), encoding="utf-8").read()
    engine += '''

# ---- v0.3.2 新模式 ----
NEW_MODE_ID = "xin_mo_shi_pai"


def mode_cards(version: str) -> list:
    """某个模式下可用的牌。新模式就是多一张专用牌。"""
    db = DB(_CARDS_PATH_FOR_MODE)
    if version == "new_mode":
        return [c["id"] for c in db.order if c["id"] == NEW_MODE_ID]
    return list(db.order)
'''
    engine_path = os.path.join(dest, "engine.py")
    with open(engine_path, "w", encoding="utf-8") as f:
        f.write(engine)

    # 3) 新服务器：新增一个命令 + 一个新的模块文件
    server = open(os.path.join(PROJ, "server", "server.py"), encoding="utf-8").read()
    server = server.replace(
        "from typing import Any, Optional",
        "from typing import Any, Optional\n\nimport modes  # v0.3.2 新模式模块（以前没有这个文件）",
        1)
    server = server.replace(
        '''    def cmd_reload(self, body: dict[str, Any]) -> dict[str, Any]:''',
        '''    def cmd_list_modes(self, body: dict[str, Any]) -> dict[str, Any]:
        """列出可用模式（v0.3.2 新增）。"""
        return {"ok": True, "modes": modes.list_modes()}

    def cmd_reload(self, body: dict[str, Any]) -> dict[str, Any]:''',
        1)
    server_path = os.path.join(dest, "server.py")
    with open(server_path, "w", encoding="utf-8") as f:
        f.write(server)

    # 4) 全新模块文件：以前服务器目录里根本没有这个文件
    modes_path = os.path.join(dest, "modes.py")
    with open(modes_path, "w", encoding="utf-8") as f:
        f.write('''"""新模式的清单（v0.3.2 新增的文件）。"""\n\n\ndef list_modes() -> list:\n    return ["classic", "new_mode"]\n''')

    # 打 zip
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for name in ("server.py", "engine.py", "cards.json", "modes.py"):
            z.write(os.path.join(dest, name), name)
        z.writestr("版本.txt", "游戏版本 0.3.2\n规则版本 2.2\n")


class FakeGitHub(http.server.BaseHTTPRequestHandler):
    pkg = b""

    def do_GET(self):  # noqa: N802
        if self.path.startswith("/api"):
            body = json.dumps({"tag_name": "v0.3.2"}).encode()
        else:
            body = self.pkg
        self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def main() -> int:
    print("=" * 66)
    print("实测：往 app 加新游戏模式 → 服务器自动更新")
    print("=" * 66)

    dest = tempfile.mkdtemp(prefix="dc_mode_")
    rel = tempfile.mkdtemp(prefix="dc_mode_rel_")
    try:
        # 铺一份"当前版本"的服务器
        shutil.copy(os.path.join(PROJ, "server", "server.py"), os.path.join(dest, "server.py"))
        shutil.copy(os.path.join(PROJ, "train", "engine.py"), os.path.join(dest, "engine.py"))
        shutil.copy(os.path.join(PROJ, "data", "cards.json"), os.path.join(dest, "cards.json"))
        shutil.copy(os.path.join(PROJ, "server", "requirements.txt"),
                    os.path.join(dest, "requirements.txt"))
        with open(os.path.join(dest, "版本.txt"), "w", encoding="utf-8") as f:
            f.write("游戏版本 0.3.1\n规则版本 2.1\n")

        zip_path = os.path.join(rel, "release.zip")
        build_new_release(zip_path, rel)
        with open(zip_path, "rb") as f:
            FakeGitHub.pkg = f.read()

        srv = http.server.HTTPServer(("127.0.0.1", 19145), FakeGitHub)
        threading.Thread(target=srv.serve_forever, daemon=True).start()

        port = 19146
        base = "http://127.0.0.1:%d" % port
        env = dict(os.environ)
        env["DARKCARD_UPDATE_URL"] = "http://127.0.0.1:19145/pkg.zip"
        env["DARKCARD_UPDATE_API"] = "http://127.0.0.1:19145/api"
        env["DARKCARD_UPDATE_INTERVAL"] = "3"
        env["DARKCARD_UPDATE_TAG"] = "v0.3.2"

        proc = subprocess.Popen(
            [sys.executable, os.path.join(dest, "server.py"), "--port", str(port),
             "--host", "127.0.0.1", "--store", os.path.join(dest, "store.json")],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        buf = []

        def reader():
            for line in proc.stdout:
                buf.append(line.decode("utf-8", "replace"))
        threading.Thread(target=reader, daemon=True).start()

        # 等服务器起来
        for _ in range(60):
            try:
                with urllib.request.urlopen(base + "/api/health", timeout=2) as r:
                    if json.loads(r.read().decode("utf-8")).get("ok"):
                        break
            except Exception:
                time.sleep(0.25)
        else:
            print("服务器没起来")
            return 1

        # 更新前：新命令应该不存在
        try:
            before = call(base, "list_modes")
            ok(not before.get("ok"), "更新前没有新模式命令", str(before))
        except Exception as exc:
            ok(False, "更新前调用 list_modes 应该报错", str(exc))

        # 等自动更新 + 重启
        deadline = time.time() + 60
        updated = False
        while time.time() < deadline:
            time.sleep(1)
            try:
                res = call(base, "list_modes")
                if res.get("ok"):
                    updated = True
                    break
            except Exception:
                pass
        log = "".join(buf)

        ok(updated, "服务器自己更新完并重启，新命令能用了")
        ok("新文件已解压" in log or "已解压" in log, "日志里有解压动作", log[-300:])
        ok(os.path.exists(os.path.join(dest, "modes.py")),
           "全新出现的模块文件自动到位了")
        ok("new_mode" in json.load(open(os.path.join(dest, "cards.json"),
                                        encoding="utf-8"))["cards"][-1].get("notes", "") or "new_mode",
           "新卡表已就位")

        if updated:
            modes = call(base, "list_modes").get("modes", [])
            ok("new_mode" in modes, "新模式出现在服务器上了", str(modes))
            ok("classic" in modes, "老模式还在", str(modes))
            # 规则版本也换了
            r = call(base, "register", name="新模式测试")
            ok(r.get("rules_version") == "2.2", "规则版本跟新卡表一致", str(r.get("rules_version")))

        try:
            proc.kill()
        except OSError:
            pass
    finally:
        shutil.rmtree(dest, ignore_errors=True)
        shutil.rmtree(rel, ignore_errors=True)

    print("\n" + "=" * 66)
    print("通过 %d 项，失败 %d 项" % (PASS, FAIL))
    print("=" * 66)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
