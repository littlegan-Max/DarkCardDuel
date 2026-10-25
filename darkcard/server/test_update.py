"""自动更新的专项测试：验证「不同形式的更新」都能被正确识别与应用。

要回答的问题是：以后我在本地改了任何东西，服务器那边到底能不能自己跟上？

测四种形式：
  A  只改卡表（cards.json）        → 规则层 → 热重载，不重启
  B  改服务器程序（server.py）     → 进程层 → 必须重启进程
  C  新增服务器模块文件            → 进程层 → 文件自动到位 + 重启
  D  改依赖（requirements.txt）    → 依赖层 → 自动 pip install
  E  包里混进了 store.json         → 必须被忽略，不能覆盖玩家数据
  F  内容完全没变                  → 什么都不该做
"""

import hashlib
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
ROOT = os.path.dirname(PROJ)

PASS = 0
FAIL = 0


def ok(cond: bool, label: str, detail: str = "") -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  OK   %s" % label)
    else:
        FAIL += 1
        print("  FAIL %s%s" % (label, ("  | " + detail) if detail else ""))


def _load_server_module(dirpath: str):
    """把 server.py 放到 dirpath 再导入——这样模块里的 HERE 就等于 dirpath。"""
    path = os.path.join(dirpath, "server.py")
    spec = importlib.util.spec_from_file_location("dc_server_%d" % abs(hash(dirpath)), path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


class FakeHub:
    """只提供 AutoUpdater 用到的那几个接口。"""

    def __init__(self):
        self.hot_reload_calls = 0
        self.hot_reload_ok = True
        self.notify_calls = 0
        self.active = False

    def hot_reload(self):
        self.hot_reload_calls += 1
        if self.hot_reload_ok:
            return True, ""
        return False, "假装失败"

    def notify_server_updated(self):
        self.notify_calls += 1

    def has_active_match(self):
        return self.active


def _base_files(dest: str) -> None:
    """铺一套「服务器安装目录」的基础文件。"""
    shutil.copy(os.path.join(PROJ, "server", "server.py"), os.path.join(dest, "server.py"))
    shutil.copy(os.path.join(PROJ, "train", "engine.py"), os.path.join(dest, "engine.py"))
    shutil.copy(os.path.join(PROJ, "data", "cards.json"), os.path.join(dest, "cards.json"))
    shutil.copy(os.path.join(PROJ, "server", "requirements.txt"),
                os.path.join(dest, "requirements.txt"))
    with open(os.path.join(dest, "版本.txt"), "w", encoding="utf-8") as f:
        f.write("游戏版本 0.3.0\n规则版本 2.1\n")


def _make_zip(zip_path: str, overrides: dict, extra: dict | None = None) -> None:
    """按基础文件打个 zip，overrides 里是「要改内容的文件」。"""
    base = tempfile.mkdtemp()
    try:
        _base_files(base)
        for name, content in overrides.items():
            with open(os.path.join(base, name), "w", encoding="utf-8") as f:
                f.write(content)
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
            for name in ("server.py", "engine.py", "cards.json", "requirements.txt",
                         "使用说明.txt", "版本.txt"):
                p = os.path.join(base, name)
                if os.path.exists(p):
                    z.write(p, name)
            for name, content in (extra or {}).items():
                z.writestr(name, content)
    finally:
        shutil.rmtree(base, ignore_errors=True)


def _stage(dest: str, zip_path: str):
    """在 dest 上跑一次「下载并解压」，返回 (模块, 变更分类)。"""
    mod = _load_server_module(dest)
    os.environ["DARKCARD_UPDATE_URL"] = _file_url(zip_path)
    updater = mod.AutoUpdater(FakeHub())
    changed = updater._download_and_stage()
    return mod, changed


def _file_url(path: str) -> str:
    """Windows 上的 file:// URL 要三个斜杠：file:///C:/path/to.zip"""
    p = path.replace("\\", "/")
    if not p.startswith("/"):
        p = "/" + p
    return "file://" + p


def test_rules_only(dest: str) -> None:
    print("\n[A] 只改卡表 → 规则层（热重载，不重启）")
    zip_path = os.path.join(dest, "rel_a.zip")
    d = json.load(open(os.path.join(PROJ, "data", "cards.json"), encoding="utf-8"))
    d["rules_version"] = "2.2"
    _make_zip(zip_path, {"cards.json": json.dumps(d, ensure_ascii=False, indent=2)})

    mod, changed = _stage(dest, zip_path)
    ok(changed is not None, "下载并解压成功")
    ok(changed["rule"] is True, "识别为规则层变更", str(changed))
    ok(changed["runtime"] is False, "不需要重启进程", str(changed))
    ok(changed["deps"] is False, "不涉及依赖", str(changed))
    # 磁盘上确实是新卡表
    on_disk = json.load(open(os.path.join(dest, "cards.json"), encoding="utf-8"))
    ok(on_disk["rules_version"] == "2.2", "磁盘上的卡表已更新")


def test_server_code(dest: str) -> None:
    print("\n[B] 改服务器程序 → 进程层（必须重启进程）")
    zip_path = os.path.join(dest, "rel_b.zip")
    src = open(os.path.join(PROJ, "server", "server.py"), encoding="utf-8").read()
    _make_zip(zip_path, {"server.py": src + "\n# 新加的功能\n"})

    mod, changed = _stage(dest, zip_path)
    ok(changed["runtime"] is True, "识别为进程层变更（要重启）", str(changed))
    ok(changed["rule"] is False, "不是规则层", str(changed))
    # 热重载只换 engine/cards，换不了 server.py —— 所以必须走重启
    hub = FakeHub()
    updater = mod.AutoUpdater(hub)
    updater._pending = {"rule": False, "runtime": True, "deps": False}
    updater._stop.set()   # 防止真的重启
    updater._tick()
    ok(hub.hot_reload_calls == 0,
       "进程层变更不会误走热重载（热重载换不了 server.py）",
       "hot_reload 调用了 %d 次" % hub.hot_reload_calls)


def test_new_file(dest: str) -> None:
    print("\n[C] 新增服务器模块文件 → 自动到位")
    zip_path = os.path.join(dest, "rel_c.zip")
    _make_zip(zip_path, {}, extra={
        "extra_mod.py": "# 新增的模块\nVALUE = 42\n",
        "sub/deep.txt": "嵌套文件\n",
    })

    mod, changed = _stage(dest, zip_path)
    ok(os.path.exists(os.path.join(dest, "extra_mod.py")), "新增模块文件已自动解压到位")
    ok(changed["runtime"] is True, "识别为进程层变更（要重启才生效）", str(changed))
    # 内容对不对
    got = open(os.path.join(dest, "extra_mod.py"), encoding="utf-8").read()
    ok("VALUE = 42" in got, "新增文件内容正确")


def test_dependencies(dest: str) -> None:
    print("\n[D] 改依赖 → 自动安装")
    zip_path = os.path.join(dest, "rel_d.zip")
    _make_zip(zip_path, {"requirements.txt": "# 注释行\n\n六库\n"})

    mod, changed = _stage(dest, zip_path)
    ok(changed["deps"] is True, "识别为依赖变更", str(changed))
    ok(changed["runtime"] is False, "依赖变更本身不触发重启", str(changed))

    # 装依赖的逻辑：注释和空行要被忽略
    req = os.path.join(dest, "requirements.txt")
    lines = [ln.strip() for ln in open(req, encoding="utf-8")
             if ln.strip() and not ln.strip().startswith("#")]
    ok(lines == ["六库"], "依赖解析正确（忽略注释与空行）", str(lines))


def test_store_preserved(dest: str) -> None:
    print("\n[E] 包里混进 store.json → 必须被忽略（玩家数据不能被覆盖）")
    zip_path = os.path.join(dest, "rel_e.zip")
    _make_zip(zip_path, {}, extra={"store.json": '{"players": {"x": {"name": "入侵者"}}}'})

    store = os.path.join(dest, "store.json")
    with open(store, "w", encoding="utf-8") as f:
        f.write('{"players": {"me": {"name": "原玩家"}}}')

    mod, changed = _stage(dest, zip_path)
    content = open(store, encoding="utf-8").read()
    ok("原玩家" in content and "入侵者" not in content,
       "store.json 未被覆盖", content[:60])
    ok(changed["runtime"] is False, "被忽略的文件不算变更", str(changed))


def test_no_change(dest: str) -> None:
    print("\n[F] 内容完全没变 → 什么都不该做")
    zip_path = os.path.join(dest, "rel_f.zip")
    _make_zip(zip_path, {})
    _stage(dest, zip_path)   # 先铺一次让它一致
    _make_zip(zip_path, {})
    mod, changed = _stage(dest, zip_path)
    ok(not any(changed.values()), "无变更时不做任何事", str(changed))


def test_hot_reload_applies_rules(dest: str) -> None:
    print("\n[G] 规则层变更 → 热重载真的换掉了引擎与卡表")
    zip_path = os.path.join(dest, "rel_g.zip")
    d = json.load(open(os.path.join(PROJ, "data", "cards.json"), encoding="utf-8"))
    d["rules_version"] = "2.3"
    _make_zip(zip_path, {"cards.json": json.dumps(d, ensure_ascii=False, indent=2)})

    mod = _load_server_module(dest)
    # Hub 要在覆盖之前建：它一上来就把磁盘上的卡表读进内存了
    hub = mod.Hub(mod.Store(os.path.join(dest, "store.json")))
    ok(hub.rules_version == "2.1", "热重载前规则版本是 2.1", hub.rules_version)
    os.environ["DARKCARD_UPDATE_URL"] = _file_url(zip_path)
    updater = mod.AutoUpdater(FakeHub())
    updater._download_and_stage()
    ok(hub.rules_version == "2.1",
       "磁盘上的卡表被覆盖了，但运行中的 Hub 还拿着旧版本（这正是我们要的）",
       hub.rules_version)
    hot_ok, hot_err = hub.hot_reload()
    ok(hot_ok, "热重载成功", hot_err)
    ok(hub.rules_version == "2.3", "热重载后规则版本变成 2.3", hub.rules_version)


def test_live_restart() -> None:
    """活体实测：改 server.py 后，服务器自己更新并且新代码真的在跑。

    前面几组是「分类对不对」，这组是「到底生效没有」——
    起一个真服务器，让自动更新器自己发现、自己下载、自己重启，
    然后从输出里确认新版本的标记出现了。
    """
    print("\n[H] 活体实测：改 server.py → 服务器自动重启且新代码生效")
    import subprocess
    import threading
    import time

    dest = tempfile.mkdtemp(prefix="dc_live_")
    rel = tempfile.mkdtemp(prefix="dc_rel_")
    try:
        _base_files(dest)
        # 新版 server.py：插一行模块级打印，方便确认新代码真的在跑
        src = open(os.path.join(PROJ, "server", "server.py"), encoding="utf-8").read()
        marker = "【新版已生效】"
        anchor = 'PASS_ID = "pass"'
        assert anchor in src, "找不到注入锚点，测试本身失效"
        new_src = src.replace(anchor, anchor + "\nprint(\"%s\")" % marker, 1)

        zip_path = os.path.join(rel, "release.zip")
        base = tempfile.mkdtemp()
        try:
            _base_files(base)
            with open(os.path.join(base, "server.py"), "w", encoding="utf-8") as f:
                f.write(new_src)
            with open(os.path.join(base, "版本.txt"), "w", encoding="utf-8") as f:
                f.write("游戏版本 9.9.9\n规则版本 2.1\n")
            with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
                for name in ("server.py", "engine.py", "cards.json", "requirements.txt",
                             "使用说明.txt", "版本.txt"):
                    p = os.path.join(base, name)
                    if os.path.exists(p):
                        z.write(p, name)
        finally:
            shutil.rmtree(base, ignore_errors=True)

        env = dict(os.environ)
        env["DARKCARD_UPDATE_URL"] = _file_url(zip_path)
        env["DARKCARD_UPDATE_TAG"] = "v9.9.9"
        env["DARKCARD_UPDATE_INTERVAL"] = "3"
        proc = subprocess.Popen(
            [sys.executable, os.path.join(dest, "server.py"), "--port", "19111",
             "--host", "127.0.0.1", "--store", os.path.join(dest, "store.json")],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)

        # 逐行读输出，直到看到新标记或超时
        buf = []
        seen = threading.Event()

        def reader():
            for raw in proc.stdout:
                line = raw.decode("utf-8", "replace")
                buf.append(line)
                if marker in line:
                    seen.set()

        t = threading.Thread(target=reader, daemon=True)
        t.start()
        seen.wait(timeout=60)
        time.sleep(0.5)
        try:
            proc.kill()
        except OSError:
            pass

        out = "".join(buf)
        ok(marker in out, "新版本的标记出现了（说明新 server.py 真的在跑）", out[-500:])
        ok("正在重启以应用新版本" in out, "日志里能看到重启动作", out[-500:])
        ok("进程层=True" in out, "日志里识别为进程层变更", out[-500:])
    finally:
        shutil.rmtree(dest, ignore_errors=True)
        shutil.rmtree(rel, ignore_errors=True)


def main() -> int:
    print("=" * 62)
    print("自动更新专项测试")
    print("=" * 62)
    made = []

    def fresh() -> str:
        # 每个用例一个干净目录：否则上一个用例改过的文件
        # 会让下一个用例误判「有变更」
        d = tempfile.mkdtemp(prefix="dc_update_")
        made.append(d)
        _base_files(d)
        return d

    try:
        test_rules_only(fresh())
        test_server_code(fresh())
        test_new_file(fresh())
        test_dependencies(fresh())
        test_store_preserved(fresh())
        test_no_change(fresh())
        test_hot_reload_applies_rules(fresh())
        test_live_restart()
    finally:
        for d in made:
            shutil.rmtree(d, ignore_errors=True)

    print("\n" + "=" * 62)
    print("通过 %d 项，失败 %d 项" % (PASS, FAIL))
    print("=" * 62)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
