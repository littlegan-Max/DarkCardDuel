#!/usr/bin/env python3
"""联机端到端测试驱动：起服务器 + 两个 Godot 客户端打一局。

验证的是整条链路：
  Godot 客户端 → HTTP → Python 服务器（Python 内核权威结算）
              → HTTP → Godot 客户端（GDScript 内核本地重放）
  每回合两边对账，不一致就报错。

两个客户端必须错开启动：
  同时启动时，先启动那个客户端的 stdout 在管道里被缓冲，
  进程退出时缓冲没刷出来，表现为「某个客户端莫名其妙静默」——
  是测试工具的问题，不是联机代码的问题。

用法：python tools/run_online_test.py
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GODOT = os.environ.get(
    "GODOT", "D:/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64.exe"
)
PORT = int(os.environ.get("DC_PORT", "18901"))
SERVER = os.path.join(ROOT, "server", "server.py")
USER_DIR = os.path.join(ROOT, ".godot_test_user")


def run_client(seat: int) -> str:
    env = dict(os.environ)
    env["GODOT_USER_HOME"] = os.path.join(USER_DIR, "seat%d" % seat)
    p = subprocess.Popen(
        [GODOT, "--headless", "--path", ROOT,
         "--script", "res://tools/test_online.gd",
         "--", "--port=%d" % PORT, "--seat=%d" % seat],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        env=env,
    )
    try:
        out = p.communicate(timeout=75)[0]
    except subprocess.TimeoutExpired:
        p.kill()
        out = p.communicate()[0]
    return out.decode("utf-8", "replace")


def main() -> int:
    store = os.path.join(ROOT, "server", "store.test.json")
    if os.path.exists(store):
        os.remove(store)
    os.makedirs(USER_DIR, exist_ok=True)

    print("── 起服务器")
    srv = subprocess.Popen(
        [sys.executable, SERVER, "--port", str(PORT), "--store", store],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    time.sleep(2.0)
    if srv.poll() is not None:
        print("服务器启动失败：")
        print(srv.stdout.read().decode("utf-8", "replace"))
        return 1

    outs = {}
    try:
        print("── 起客户端 seat=0")
        t0 = threading.Thread(target=lambda: outs.__setitem__(0, run_client(0)))
        t0.start()
        # 错开 4 秒：让 seat=0 先注册进匹配队列
        time.sleep(4.0)
        print("── 起客户端 seat=1")
        t1 = threading.Thread(target=lambda: outs.__setitem__(1, run_client(1)))
        t1.start()
        t0.join()
        t1.join()
    finally:
        srv.terminate()
        try:
            srv.wait(timeout=5)
        except subprocess.TimeoutExpired:
            srv.kill()

    for seat in (0, 1):
        print("── 客户端 seat=%d 输出" % seat)
        for line in outs.get(seat, "").splitlines():
            if "[online]" in line:
                print("   " + line.strip())

    print()
    ok = True
    for seat in (0, 1):
        if "[online] OK" not in outs.get(seat, ""):
            ok = False
            print("客户端 seat=%d 未通过" % seat)
    turns = []
    for seat in (0, 1):
        m = re.findall(r"回合数=(\d+)", outs.get(seat, ""))
        if m:
            turns.append(int(m[0]))
    if len(turns) == 2 and turns[0] != turns[1]:
        ok = False
        print("两边回合数不一致：%s" % turns)
    elif len(turns) == 2:
        print("两边回合数一致：%d" % turns[0])

    if ok:
        print("\nALL GREEN")
        return 0
    print("\nFAILED")
    return 1


if __name__ == "__main__":
    sys.exit(main())
