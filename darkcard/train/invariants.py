"""不变量扫描：跑大量随机对局，每一步都检查"规则上不可能出现"的状态。

比单点用例更容易抓到"效果重复执行""状态没清理""计时器错位"这类问题。
"""

from __future__ import annotations

import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
from engine import DB, Game, PASS_ID  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(HERE, "..", "data", "cards.json")

MAX_TURNS = 80
violations: list[str] = []
db = DB(DB_PATH)


def v(msg: str) -> None:
    if len(violations) < 40:
        violations.append(msg)


def check_round(g: Game, a: str, b: str, before: dict) -> None:
    tag = f"[seed {before['seed']} turn {before['turn']}] {a} vs {b}: "

    # 1 回合数只 +1
    if not g.over and g.turn != before["turn"] + 1:
        v(tag + f"turn {before['turn']} -> {g.turn}")

    # 2 history 只会因为"本回合这张牌真的出了"而 +1（裁定 1：被龟派取走的不记）
    for k in (0, 1):
        my_card = a if k == 0 else b
        opp_card = b if k == 0 else a
        taken = opp_card in ("gui_pai", "shen_zhi_gui_pai") and my_card not in (
            "gui_pai", "shen_zhi_gui_pai")
        expect = before["hist"][k] + (0 if taken else 1)
        if len(g.player(k).history) != expect:
            v(tag + f"p{k} history={len(g.player(k).history)} expect={expect}")
            break

    # 3 盾只能因为盾牌增加
    for k in (0, 1):
        played = "dun" if (k == 0 and a == "dun") or (k == 1 and b == "dun") else ""
        cap = before["shields"][k] + (1 if played else 0)
        if g.player(k).shields > cap:
            v(tag + f"p{k} shields {before['shields'][k]} -> {g.player(k).shields}")
        if g.player(k).shields < 0:
            v(tag + f"p{k} negative shields {g.player(k).shields}")

    # 4 葵只可能变成 50，且不可逆
    for k in (0, 1):
        p = g.player(k)
        if p.cost_percent not in (100, 50):
            v(tag + f"p{k} cost_percent={p.cost_percent}")
        if before["cost"][k] == 50 and p.cost_percent != 50:
            v(tag + f"p{k} cost reverted {before['cost'][k]} -> {p.cost_percent}")

    # 5 dot 层数不增（除非本回合挂了 dot/C4）
    a_card = db.cards[a]
    b_card = db.cards[b]
    # dot/C4 是挂给"对方"的，所以看对手出了什么牌
    for k in (0, 1):
        opp_card = b_card if k == 0 else a_card
        adds = (any(op.get("op") in ("DOT", "DELAY_DMG") for op in opp_card.ops)
                or opp_card.time_spread > 0)   # 裁定 7：长攻分散被吸 → 时间分散
        delta = len(g.player(k).dots) - before["dots"][k]
        if delta > (2 if adds else 0):
            v(tag + f"p{k} dots {before['dots'][k]} -> {len(g.player(k).dots)}")
        for e in g.player(k).dots:
            if e[1] < 0:
                v(tag + f"p{k} dot left<0")

    # 6 单回合血量变化有上限（最大 3.0 伤害 + 0.5 真伤 + dot 若干）
    for k in (0, 1):
        drop = before["hp"][k] - g.player(k).hp
        if drop > 800:
            v(tag + f"p{k} hp drop {drop}")

    # 7 回合结束后不应残留 pending
    for k in (0, 1):
        if g.player(k).pending_card != "":
            v(tag + f"p{k} pending not cleared")

    # 8 结束态必须有一方胜者
    if g.over and g.winner not in (0, 1):
        v(tag + f"over but winner={g.winner}")


def run(seed: int) -> None:
    rng = random.Random(seed)
    g = Game(db)
    guard = 0
    while not g.over and g.turn < MAX_TURNS and guard < 300:
        guard += 1
        la, lb = g.legal_cards(0), g.legal_cards(1)
        if not la or not lb:
            break
        a = la[rng.randrange(len(la))]
        b = lb[rng.randrange(len(lb))]
        before = {
            "seed": seed, "turn": g.turn,
            "hist": [len(g.p0.history), len(g.p1.history)],
            "shields": [g.p0.shields, g.p1.shields],
            "dots": [len(g.p0.dots), len(g.p1.dots)],
            "cost": [g.p0.cost_percent, g.p1.cost_percent],
            "hp": [g.p0.hp, g.p1.hp],
        }
        if not g.play_turn(a, b):
            v(f"[seed {seed} turn {g.turn}] play_turn rejected {a} vs {b}")
            break
        check_round(g, a, b, before)


def main() -> None:
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
    for i in range(n):
        run(20000 + i)
    if violations:
        print(f"VIOLATIONS {len(violations)} (showing up to 40)")
        for x in violations[:40]:
            print("  " + x)
        sys.exit(1)
    print(f"invariants ok over {n} matches")


if __name__ == "__main__":
    main()
