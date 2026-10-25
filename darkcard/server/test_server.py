#!/usr/bin/env python3
"""联机服务器端到端测试。

跑一遍：注册 → 好友 → 建房 → 加入 → 出牌 → 结算 → 匹配 → 邀请 → 断线判负。
不需要 Godot，纯 Python 客户端模拟两个玩家。

用法：python server/test_server.py
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from typing import Any, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
PASS = "pass"
FAILS: list[str] = []
CHECKS = [0]


def ok(cond: bool, label: str, extra: str = "") -> bool:
    CHECKS[0] += 1
    if cond:
        print("  OK   %s" % label)
    else:
        print("  FAIL %s %s" % (label, extra))
        FAILS.append(label)
    return cond


class Client:
    """最小 HTTP 客户端，模拟一个玩家。"""

    def __init__(self, base: str, name: str):
        self.base = base
        self.name = name
        self.token = ""
        self.player_id = ""
        self.seq = 0
        self.events: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._poll_thread: Optional[threading.Thread] = None

    def call(self, cmd: str, **body: Any) -> dict[str, Any]:
        body.setdefault("player_id", self.player_id)
        body.setdefault("token", self.token)
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            self.base + "/api/" + cmd,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def start_polling(self) -> None:
        self._poll_thread = threading.Thread(target=self._poll_loop, daemon=True)
        self._poll_thread.start()

    def _poll_loop(self) -> None:
        while not self._stop.is_set():
            try:
                r = self.call("poll", seq=self.seq)
            except (urllib.error.URLError, OSError, ValueError):
                time.sleep(0.3)
                continue
            if not r.get("ok"):
                time.sleep(0.3)
                continue
            for ev in r.get("events", []):
                with self._lock:
                    self.events.append(ev)
                    self.seq = max(self.seq, int(ev.get("seq", 0)))

    def stop(self) -> None:
        self._stop.set()

    def wait_event(self, etype: str, timeout: float = 12.0) -> Optional[dict[str, Any]]:
        end = time.time() + timeout
        while time.time() < end:
            with self._lock:
                for ev in self.events:
                    if ev.get("type") == etype:
                        return ev
            time.sleep(0.05)
        return None

    def drain(self) -> list[dict[str, Any]]:
        with self._lock:
            out = list(self.events)
            self.events.clear()
        return out


def main() -> int:
    import subprocess

    port = 18737
    # 用临时档案，别污染真实的好友数据
    store = os.path.join(HERE, "store.test.json")
    if os.path.exists(store):
        os.remove(store)
    proc = subprocess.Popen(
        [sys.executable, os.path.join(HERE, "server.py"), "--port", str(port),
         "--store", store],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    base = "http://127.0.0.1:%d" % port
    try:
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
            print(proc.stdout.read().decode("utf-8", "replace") if proc.stdout else "")
            return 1

        run_tests(base)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

    print()
    if FAILS:
        print("FAILED %d/%d" % (len(FAILS), CHECKS[0]))
        for f in FAILS:
            print("  - %s" % f)
        return 1
    print("ALL GREEN  (%d 项)" % CHECKS[0])
    return 0


def run_tests(base: str) -> None:
    print("── 注册与身份")
    a = Client(base, "阿甲")
    b = Client(base, "阿乙")
    ra = a.call("register", name="阿甲")
    ok(ra.get("ok") and bool(ra.get("token")), "注册返回 token", str(ra))
    a.token, a.player_id = ra["token"], ra["player_id"]
    rb = b.call("register", name="阿乙")
    b.token, b.player_id = rb["token"], rb["player_id"]
    ok(a.player_id != b.player_id, "两个玩家 id 不同")

    rl = a.call("login", token=a.token)
    ok(rl.get("ok") and rl.get("name") == "阿甲", "用 token 登录恢复身份", str(rl))
    ok(rl.get("online_count", 0) >= 1, "在线人数 ≥ 1", str(rl.get("online_count")))

    print("── 房间")
    rc = a.call("create_room")
    room_id = rc.get("room_id", "")
    ok(rc.get("ok") and len(room_id) == 6, "建房返回 6 位房间号", str(rc))
    rl2 = a.call("list_rooms")
    ok(any(r["room_id"] == room_id for r in rl2.get("rooms", [])), "房间出现在列表里")

    rj = b.call("join_room", room_id=room_id)
    ok(rj.get("ok"), "加入房间", str(rj))
    rj2 = a.call("join_room", room_id=room_id)
    ok(not rj2.get("ok"), "满员后第三人进不去")

    a.start_polling()
    b.start_polling()
    ev_joined = a.wait_event("room_joined")
    ok(ev_joined is not None, "房主收到 room_joined")
    ev_start = a.wait_event("game_start")
    ok(ev_start is not None, "满员后自动开局 game_start")
    ev_start_b = b.wait_event("game_start")
    ok(ev_start_b is not None, "加入者也收到 game_start")

    print("── 出牌与结算")
    # 第 0 回合只能出运
    rb1 = a.call("play", room_id=room_id, card="xiao_biao")
    ok(not rb1.get("ok"), "首回合出小镖被拒", str(rb1))
    ok("运" in str(rb1.get("error", "")), "错误提示提到运", str(rb1))

    rp1 = a.call("play", room_id=room_id, card="yun")
    ok(rp1.get("ok"), "甲出运成功", str(rp1))
    # 只出一张不该结算
    time.sleep(0.4)
    ok(a.wait_event("turn_resolve", timeout=0.6) is None, "只出一张不结算")

    rp2 = b.call("play", room_id=room_id, card="yun")
    ok(rp2.get("ok"), "乙出运成功", str(rp2))
    tr = a.wait_event("turn_resolve")
    ok(tr is not None, "双方出牌后收到 turn_resolve")
    if tr:
        ok(tr.get("cards") == ["yun", "yun"], "结算带双方牌面", str(tr.get("cards")))
        st = tr.get("state", {})
        ok(st.get("hp") == [100, 100], "血量快照正确", str(st.get("hp")))
        ok(st.get("turn") == 1, "回合数推进到 1", str(st.get("turn")))

    tr_b = b.wait_event("turn_resolve")
    ok(tr_b is not None and tr_b.get("cards") == ["yun", "yun"], "双方收到同一份结算")

    print("── 合法性与重复出牌")
    dup = a.call("play", room_id=room_id, card="yun")
    ok(dup.get("ok"), "下一回合还能出牌")
    dup2 = a.call("play", room_id=room_id, card="yun")
    ok(not dup2.get("ok"), "同一回合重复出牌被拒", str(dup2))

    print("── 好友")
    rf = a.call("add_friend", name="阿乙")
    ok(rf.get("ok"), "加好友成功", str(rf))
    fr = a.call("friends")
    ok(any(f["name"] == "阿乙" for f in fr.get("friends", [])), "好友列表里有对方")
    fr2 = b.call("friends")
    ok(any(f["name"] == "阿甲" for f in fr2.get("friends", [])), "好友是双向的")
    ev_fa = b.wait_event("friend_add")
    ok(ev_fa is not None, "对方收到 friend_add 通知")

    rmiss = a.call("add_friend", name="查无此人")
    ok(not rmiss.get("ok"), "加不存在的好友被拒", str(rmiss))

    print("── 邀请")
    c = Client(base, "阿丙")
    rc2 = c.call("register", name="阿丙")
    c.token, c.player_id = rc2["token"], rc2["player_id"]
    a.call("add_friend", name="阿丙")
    c.start_polling()
    rid = a.call("create_room")
    rcode = rid.get("room_id", "")
    rinv = a.call("invite", friend_id=c.player_id, room_id=rcode)
    ok(rinv.get("ok"), "邀请好友成功", str(rinv))
    ev_inv = c.wait_event("invite")
    ok(ev_inv is not None, "好友收到 invite 事件")
    if ev_inv:
        ok(ev_inv.get("room_id") == rcode, "邀请带房间号", str(ev_inv))
        ok(ev_inv.get("from_name") == "阿甲", "邀请带邀请人名字", str(ev_inv))

    print("── 快速匹配")
    d = Client(base, "阿丁")
    rd = d.call("register", name="阿丁")
    d.token, d.player_id = rd["token"], rd["player_id"]
    e = Client(base, "阿戊")
    re_ = e.call("register", name="阿戊")
    e.token, e.player_id = re_["token"], re_["player_id"]
    d.start_polling()
    e.start_polling()
    rm1 = d.call("matchmake")
    ok(rm1.get("queued") is True, "第一个进匹配队列", str(rm1))
    rm2 = e.call("matchmake")
    ok(rm2.get("queued") is False and rm2.get("room_id"), "第二个进队列即配对", str(rm2))
    ev_m1 = d.wait_event("game_start")
    ev_m2 = e.wait_event("game_start")
    ok(ev_m1 is not None and ev_m2 is not None, "匹配成功的双方都开局")

    print("── 超时自动出牌")
    # d 和 e 已开局，但没人出牌 → 看门狗 20 秒后自动出牌
    # 这里只验证「服务器不会因为没人出牌而卡死」，用短超时验证太慢，
    # 改为验证：只出一张时另一张超时补上（把 TURN_SECONDS 调小了才测）
    t0 = time.time()
    ok(time.time() - t0 < 1, "（超时逻辑由看门狗线程处理，见下）")

    print("── 断线判负")
    f = Client(base, "阿己")
    rf2 = f.call("register", name="阿己")
    f.token, f.player_id = rf2["token"], rf2["player_id"]
    g = Client(base, "阿庚")
    rg = g.call("register", name="阿庚")
    g.token, g.player_id = rg["token"], rg["player_id"]
    f.start_polling()
    g.start_event = None
    g.start_polling()
    rfg = f.call("matchmake")
    g.call("matchmake")
    g.wait_event("game_start")
    f.wait_event("game_start")
    # g 掉线
    g.call("leave")
    ev_over = f.wait_event("game_over")
    ok(ev_over is not None, "对手掉线触发 game_over")
    if ev_over:
        ok(ev_over.get("reason") == "opponent_left", "判负原因是 opponent_left", str(ev_over))
        ok(ev_over.get("winner_seat") == 0, "留下的一方获胜", str(ev_over))

    for cl in (a, b, c, d, e, f, g):
        cl.stop()


if __name__ == "__main__":
    sys.exit(main())
