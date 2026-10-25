"""随机看几局：把对局逐回合打印出来，用来人工检查 AI 的打法是否正常。

用法：python watch_games.py <checkpoint> [局数] [随机种子]
"""

from __future__ import annotations

import os
import pickle
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
from abstract import abstract  # noqa: E402
from engine import DB, Game  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(HERE, "..", "data", "cards.json")

NAMES = ["甲", "乙"]


def pick_action(g: Game, who: int, S, index, rng: random.Random,
                eps: float = 0.0) -> str:
    legal = g.legal_cards(who)
    if not legal:
        return ""
    idx = [index[c] for c in legal]
    row = S.get(abstract(g, who))
    if row is None:
        p = [1.0 / len(idx)] * len(idx)
    else:
        pos = [max(0.0, float(row[i])) for i in idx]
        tot = sum(pos)
        p = [x / tot for x in pos] if tot > 0 else [1.0 / len(idx)] * len(idx)
    if eps > 0:
        p = [(1 - eps) * x + eps / len(idx) for x in p]
    x = rng.random()
    acc = 0.0
    for c, pp in zip(legal, p):
        acc += pp
        if x <= acc:
            return c
    return legal[-1]


def fmt_hp(v: int) -> str:
    return "%.2f" % (v / 100.0)


def fmt_yun(v: int) -> str:
    return "%.1f" % (v / 10.0)


def describe(db: DB, cid: str) -> str:
    if not cid:
        return "(空过)"
    c = db.cards[cid]
    return f"{c.name}({c.cost/10:.0f}费)"


def play_and_print(db: DB, S, index, seed: int, eps: float) -> set:
    rng = random.Random(seed)
    g = Game(db)
    used: set = set()
    print(f"\n===== 第 {seed} 号局 =====")
    while not g.over and g.turn < 40:
        a = pick_action(g, 0, S, index, rng, eps)
        b = pick_action(g, 1, S, index, rng, eps)
        if not a or not b:
            break
        used.add(a)
        used.add(b)
        h0a, h0b = g.p0.hp, g.p1.hp
        y0a, y0b = g.p0.yun, g.p1.yun
        sh0, sh1 = g.p0.shields, g.p1.shields
        print(f"  第{g.turn}回合  甲 {describe(db, a):<12}  乙 {describe(db, b):<12}", end="")
        ok = g.play_turn(a, b)
        if not ok:
            break
        print(f"        血 {fmt_hp(h0a)}→{fmt_hp(g.p0.hp)} : {fmt_hp(h0b)}→{fmt_hp(g.p1.hp)}"
              f"   盾 {sh0}→{g.p0.shields} : {sh1}→{g.p1.shields}"
              f"   运 {fmt_yun(y0a)}→{fmt_yun(g.p0.yun)} : {fmt_yun(y0b)}→{fmt_yun(g.p1.yun)}")
        notes = []
        d0 = h0a - g.p0.hp
        d1 = h0b - g.p1.hp
        if d0 > 0:
            notes.append(f"甲掉 {fmt_hp(d0)} 血")
        elif d0 < 0:
            notes.append(f"甲回复 {fmt_hp(-d0)} 血")
        if d1 > 0:
            notes.append(f"乙掉 {fmt_hp(d1)} 血")
        elif d1 < 0:
            notes.append(f"乙回复 {fmt_hp(-d1)} 血")
        if g.p0.shields < sh0:
            notes.append("甲用掉 1 张盾")
        if g.p1.shields < sh1:
            notes.append("乙用掉 1 张盾")
        if len(g.p0.dots) > 0 and len(g.p1.dots) == 0:
            notes.append("甲被挂了持续伤害")
        if len(g.p1.dots) > 0 and len(g.p0.dots) == 0:
            notes.append("乙被挂了持续伤害")
        if notes:
            print("        " + " | ".join(notes))
    if g.over and g.winner is not None:
        print(f"  结算：{NAMES[g.winner]} 胜（第 {g.turn} 回合）"
              f"  最终血量 {fmt_hp(g.p0.hp)} : {fmt_hp(g.p1.hp)}")
    else:
        print(f"  结算：未分胜负（第 {g.turn} 回合封顶）")
    return used


def compact_run(db: DB, S, index, games: int, seed0: int, eps: float,
                verbose: bool) -> dict:
    """跑多局并做汇总；verbose=True 时打印逐回合明细。"""
    used: dict[str, int] = {}
    rows = []
    turn_hist: list[int] = []
    win = [0, 0]
    noop_turns = 0
    total_turns = 0
    for k in range(games):
        rng = random.Random(seed0 + k * 7)
        g = Game(db)
        cards_in_game: list[str] = []
        while not g.over and g.turn < 40:
            a = pick_action(g, 0, S, index, rng, eps)
            b = pick_action(g, 1, S, index, rng, eps)
            if not a or not b:
                break
            used[a] = used.get(a, 0) + 1
            used[b] = used.get(b, 0) + 1
            cards_in_game += [a, b]
            h0a, h0b = g.p0.hp, g.p1.hp
            if verbose:
                print(f"  第{g.turn}回合  甲 {describe(db, a):<12}  乙 {describe(db, b):<12}")
            if not g.play_turn(a, b):
                break
            if g.p0.hp == h0a and g.p1.hp == h0b:
                noop_turns += 1
        total_turns += g.turn
        turn_hist.append(g.turn)
        if g.over and g.winner is not None:
            win[g.winner] += 1
        rows.append((g.turn, g.winner, len(set(cards_in_game)), cards_in_game))
        if verbose:
            print(f"  → 第{g.turn}回合结束，{'甲' if g.winner==0 else '乙' if g.winner==1 else '未结束'}胜")
    if verbose:
        print()
    print("=== 逐局一览（回合数 / 胜方 / 用到的不同牌数）===")
    for i, (t, w, d, _cards) in enumerate(rows):
        wname = "甲" if w == 0 else ("乙" if w == 1 else "未分")
        print(f"  局 {i+1:2d}: {t:2d} 回合  {wname}  不同牌 {d:2d}")
    return {
        "used": used, "rows": rows, "win": win, "turn_hist": turn_hist,
        "noop": noop_turns, "total_turns": total_turns,
    }


def main() -> None:
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "policy_400k.pkl")
    games = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    seed0 = int(sys.argv[3]) if len(sys.argv) > 3 else 100
    eps = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
    verbose = True
    db = DB(DB_PATH)
    with open(src, "rb") as f:
        ck = pickle.load(f)
    S = ck["S"]
    index = {c: i for i, c in enumerate(db.order)}
    r = compact_run(db, S, index, games, seed0, eps, verbose)
    used = r["used"]
    total = max(1, sum(used.values()))
    print("=== 汇总 ===")
    print(f"  对局 {games} 局，平均 {r['total_turns']/max(1,games):.1f} 回合，"
          f"先手胜 {r['win'][0]} / 后手胜 {r['win'][1]}")
    print(f"  无效果回合（双方都没掉血也没回血）：{r['noop']} / {r['total_turns']}")
    print(f"  用到的牌：{len(used)}/50")
    print("=== 每张牌使用次数（按次数降序）===")
    for c, n in sorted(used.items(), key=lambda kv: -kv[1]):
        print(f"  {db.cards[c].name:<8} {n:5d}  {n/total*100:5.1f}%")
    missing = [db.cards[c].name for c in db.order if c not in used]
    print("未出现：" + ("、".join(missing) if missing else "无（50 张全覆盖）"))


if __name__ == "__main__":
    main()
