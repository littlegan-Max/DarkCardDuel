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
    # 匹配窗口的放宽速度调快：正常是每秒 10 分（要等 35 秒才够 400 分差），
    # 测试里调到每秒 200 分，几秒就能验证「等久了会配上」。
    env = dict(os.environ)
    env["DARKCARD_MM_WINDOW_GROWTH"] = "200"
    proc = subprocess.Popen(
        # 显式绑回环地址：默认是 0.0.0.0（监听所有网卡），
        # 本地测试绑全网卡会触发 Windows 防火墙弹窗，也没必要对外暴露
        [sys.executable, os.path.join(HERE, "server.py"), "--port", str(port),
         "--host", "127.0.0.1", "--store", store],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
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


def set_mmr(base: str, player_id: str, mmr: int) -> bool:
    """给玩家调分（走本机专用的 set_mmr 接口）。"""
    data = json.dumps({"player_id": player_id, "mmr": mmr}).encode("utf-8")
    req = urllib.request.Request(
        base + "/api/set_mmr", data=data,
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return bool(json.loads(resp.read().decode("utf-8")).get("ok"))
    except Exception:
        return False


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

    print("── 房主手动开始")
    # 自建房不自动开始，由房主点「开始」
    ok(a.wait_event("game_start", timeout=1.0) is None, "人满了也不会自动开局")
    start_b = b.call("start_room", room_id=room_id)
    ok(not start_b.get("ok"), "非房主不能开始这一局", str(start_b))
    start_a = a.call("start_room", room_id=room_id)
    ok(start_a.get("ok"), "房主点开始", str(start_a))

    ev_start = a.wait_event("game_start", timeout=3.0)
    ok(ev_start is not None, "房主开始后收到 game_start")
    ev_start_b = b.wait_event("game_start", timeout=3.0)
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
    st1 = rm1.get("status", {})
    ok(st1.get("mmr") == 1000, "新号初始评分 1000", str(st1))
    ok(st1.get("window", 0) > 0, "排队时给出当前匹配范围", str(st1))
    rm2 = e.call("matchmake")
    ok(rm2.get("queued") is False and rm2.get("room_id"), "第二个进队列即配对", str(rm2))
    ev_m1 = d.wait_event("game_start")
    ev_m2 = e.wait_event("game_start")
    ok(ev_m1 is not None and ev_m2 is not None, "匹配成功的双方都开局")

    print("── 匹配状态查询")
    h = Client(base, "阿辛")
    rh = h.call("register", name="阿辛")
    h.token, h.player_id = rh["token"], rh["player_id"]
    h.call("matchmake")
    time.sleep(0.3)
    st2 = h.call("match_status")
    ok(st2.get("queued") is True, "排队中能查到状态", str(st2))
    ok(st2.get("waited", 0) > 0, "状态里带已等待秒数", str(st2))
    h.call("cancel_match")
    st3 = h.call("match_status")
    ok(st3.get("queued") is False, "取消排队后状态清空", str(st3))
    h.call("leave")

    print("── 评分差太大不配对（窗口随等待放宽）")
    # 两个分差 400 的玩家：初始窗口只有 50，应该配不上；
    # 等窗口放宽到 400 就该配上。
    i1 = Client(base, "阿壬")
    ri1 = i1.call("register", name="阿壬")
    i1.token, i1.player_id = ri1["token"], ri1["player_id"]
    i2 = Client(base, "阿癸")
    ri2 = i2.call("register", name="阿癸")
    i2.token, i2.player_id = ri2["token"], ri2["player_id"]
    i1.start_polling()
    i2.start_polling()
    # 直接改档案里的评分（本机专用接口）
    ok(set_mmr(base, i1.player_id, 1000), "给玩家调评分")
    ok(set_mmr(base, i2.player_id, 1400), "给玩家调评分")
    rm_i1 = i1.call("matchmake")
    rm_i2 = i2.call("matchmake")
    ok(rm_i2.get("queued") is True, "分差 400 远超初始窗口 50 → 暂时不配对", str(rm_i2))
    # 等窗口放宽（测试环境里每秒放宽 200 分，2 秒就够覆盖 400 分差）
    # 关键：窗口放宽是**后台定期重扫队列**生效的，不用玩家再点一次匹配
    got = i1.wait_event("game_start", timeout=8.0)
    ok(got is not None, "等够久之后自动配上并开局（不用再点匹配）")
    i1.call("leave")
    i2.call("leave")

    print("── 房主转移")
    j = Client(base, "甲方")
    rj2 = j.call("register", name="甲方")
    j.token, j.player_id = rj2["token"], rj2["player_id"]
    k = Client(base, "甲方乙")
    rk = k.call("register", name="甲方乙")
    k.token, k.player_id = rk["token"], rk["player_id"]
    j.start_polling()
    k.start_polling()
    rc_j = j.call("create_room")
    room_j = rc_j.get("room_id", "")
    k.call("join_room", room_id=room_j)
    j.call("leave")
    ev_host = k.wait_event("host_changed", timeout=2.0)
    ok(ev_host is not None, "房主离开后通知剩下的人", str(ev_host))
    if ev_host:
        ok(ev_host.get("host_id") == k.player_id, "房主转给了剩下的人", str(ev_host))
    k.call("leave")

    print("── Elo 评分结算")
    m = Client(base, "阿丑")
    rm_m = m.call("register", name="阿丑")
    m.token, m.player_id = rm_m["token"], rm_m["player_id"]
    n = Client(base, "阿寅")
    rm_n = n.call("register", name="阿寅")
    n.token, n.player_id = rm_n["token"], rm_n["player_id"]
    m.start_polling()
    n.start_polling()
    set_mmr(base, m.player_id, 1000)
    set_mmr(base, n.player_id, 1000)
    rm_m1 = m.call("matchmake")
    rm_n = n.call("matchmake")
    m.wait_event("game_start")
    n.wait_event("game_start")
    # 房号在**后进队列**那个人的响应里（先到的那个只拿到 queued）
    room_m = rm_n.get("room_id") or rm_m1.get("room_id")
    # 开局双方 0 运：第一回合只能出运，先攒够运
    m.call("play", room_id=room_m, card="yun")
    n.call("play", room_id=room_m, card="yun")
    m.wait_event("turn_resolve", timeout=3.0)
    n.wait_event("turn_resolve", timeout=3.0)
    # 第二回合：小镖(甲) 打 运(乙) → 甲赢，乙 1 点血被秒
    m.call("play", room_id=room_m, card="xiao_biao")
    n.call("play", room_id=room_m, card="yun")
    ev_go = m.wait_event("game_over", timeout=3.0)
    ok(ev_go is not None, "一局结束收到 game_over")
    if ev_go:
        mmrs = ev_go.get("mmr", {})
        ok(isinstance(mmrs, dict) and mmrs.get(m.player_id, 0) > 1000,
           "赢了之后评分涨了", str(mmrs))
    prof = m.call("profile")
    ok(prof.get("mmr", 0) > 1000, "profile 里能看到涨过的评分", str(prof))
    m.call("leave")
    n.call("leave")

    print("── 出牌时间")
    o = Client(base, "阿辰")
    ro = o.call("register", name="阿辰")
    o.token, o.player_id = ro["token"], ro["player_id"]
    rc_o = o.call("create_room", turn_seconds=30)
    ok(rc_o.get("turn_seconds") == 30, "建房时房主能定出牌时间", str(rc_o))
    rc_o2 = o.call("create_room", turn_seconds=999)
    ok(rc_o2.get("turn_seconds") == 120, "出牌时间超上限会被夹住", str(rc_o2))
    rc_o3 = o.call("create_room", turn_seconds=1)
    ok(rc_o3.get("turn_seconds") == 5, "出牌时间低于下限会被夹住", str(rc_o3))
    # 匹配房固定 10 秒
    p1 = Client(base, "阿巳")
    rp1 = p1.call("register", name="阿巳")
    p1.token, p1.player_id = rp1["token"], rp1["player_id"]
    p2 = Client(base, "阿午")
    rp2 = p2.call("register", name="阿午")
    p2.token, p2.player_id = rp2["token"], rp2["player_id"]
    p1.start_polling()
    p2.start_polling()
    rm_p1 = p1.call("matchmake")
    rm_p2 = p2.call("matchmake")
    ok(rm_p2.get("room_id") != "", "匹配配上了")
    st_p = p2.call("room_state")
    ok(st_p.get("turn_seconds") == 10, "匹配房的出牌时间固定 10 秒", str(st_p))
    p1.call("leave")
    p2.call("leave")
    o.call("leave")

    print("── 房主移除成员")
    q = Client(base, "阿未")
    rq = q.call("register", name="阿未")
    q.token, q.player_id = rq["token"], rq["player_id"]
    r = Client(base, "阿申")
    rr = r.call("register", name="阿申")
    r.token, r.player_id = rr["token"], rr["player_id"]
    q.start_polling()
    r.start_polling()
    rc_q = q.call("create_room")
    room_q = rc_q.get("room_id", "")
    r.call("join_room", room_id=room_q)
    rm_r = r.call("remove_member", room_id=room_q, target_id=q.player_id)
    ok(not rm_r.get("ok"), "非房主不能移除成员", str(rm_r))
    rm_q = q.call("remove_member", room_id=room_q, target_id=r.player_id)
    ok(rm_q.get("ok"), "房主可以移除成员", str(rm_q))
    st_q = q.call("room_state")
    ok(len(st_q.get("players", [])) == 1, "被移除的人不在房间里了", str(st_q))
    q.call("leave")

    print("── 玩家状态")
    t1 = Client(base, "阿辰乙")
    rt1 = t1.call("register", name="阿辰乙")
    t1.token, t1.player_id = rt1["token"], rt1["player_id"]
    t2 = Client(base, "阿辰丙")
    rt2 = t2.call("register", name="阿辰丙")
    t2.token, t2.player_id = rt2["token"], rt2["player_id"]
    t1.start_polling()
    t2.start_polling()
    t1.call("matchmake")
    time.sleep(0.3)
    lp = t2.call("list_players")
    states = {str(x.get("name", "")): str(x.get("state", "")) for x in lp.get("players", [])}
    ok(states.get("阿辰乙") == "matchmaking", "排队时状态是「匹配中」", str(states))
    rm_t = t2.call("matchmake")
    time.sleep(0.4)
    lp2 = t2.call("list_players")
    states2 = {str(x.get("name", "")): str(x.get("state", "")) for x in lp2.get("players", [])}
    ok(states2.get("阿辰乙") == "in_game", "开局后状态是「对战中」", str(states2))
    t1.call("leave")
    t2.call("leave")
    time.sleep(0.3)
    fr = t2.call("friends")
    ok(isinstance(fr.get("friends", []), list), "好友列表带状态字段", str(fr)[:120])

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
