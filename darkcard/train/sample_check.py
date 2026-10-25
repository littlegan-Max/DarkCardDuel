"""抽样体检：拿一个 checkpoint 跑几局，看策略是否正常。

与 trainer 内置的周期体检同一套判据，但可以对着**任意 checkpoint**
（包括训练中途保存的）单独跑，用于"训练过程中随时抽查"。

用法：
    python sample_check.py policy_400k.pkl [局数]
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


def check(db: DB, ckpt: dict, games: int, seed: int = 11) -> dict:
    S = ckpt["S"]
    index = {cid: i for i, cid in enumerate(db.order)}
    rng = random.Random(seed)
    played: dict[str, int] = {}
    wins = [0, 0]
    turns: list[int] = []
    unfinished = 0

    for _ in range(games):
        g = Game(db)
        guard = 0
        while not g.over and g.turn < 40 and guard < 200:
            guard += 1
            legals = (g.legal_cards(0), g.legal_cards(1))
            if not legals[0] or not legals[1]:
                break
            picks = []
            for who in (0, 1):
                legal = legals[who]
                idx = [index[c] for c in legal]
                row = S.get(abstract(g, who))
                if row is None:
                    p = [1.0 / len(idx)] * len(idx)
                else:
                    pos = [max(0.0, float(row[i])) for i in idx]
                    tot = sum(pos)
                    p = [x / tot for x in pos] if tot > 0 else [1.0 / len(idx)] * len(idx)
                x = rng.random()
                acc = 0.0
                pick = legal[-1]
                for c, pp in zip(legal, p):
                    acc += pp
                    if x <= acc:
                        pick = c
                        break
                picks.append(pick)
            for c in picks:
                played[c] = played.get(c, 0) + 1
            if not g.play_turn(picks[0], picks[1]):
                break
        if g.over and g.winner is not None:
            wins[g.winner] += 1
            turns.append(g.turn)
        else:
            unfinished += 1

    total = max(1, sum(played.values()))
    share = sorted((v / total for v in played.values()), reverse=True)
    return {
        "games": games,
        "unfinished": unfinished,
        "avg_turns": sum(turns) / max(1, len(turns)),
        "win0": wins[0] / max(1, games),
        "distinct": len(played),
        "top1": share[0] if share else 0.0,
        "top3": sum(share[:3]),
        "top_cards": sorted(played.items(), key=lambda kv: -kv[1])[:5],
    }


def verdict(r: dict) -> list[str]:
    warns: list[str] = []
    if r["unfinished"] > 0:
        warns.append(f"有 {r['unfinished']} 局没跑完")
    if r["avg_turns"] < 3.0 or r["avg_turns"] > 20.0:
        warns.append(f"平均回合数 {r['avg_turns']:.1f} 超出(3~20)")
    if r["win0"] < 0.35 or r["win0"] > 0.65:
        warns.append(f"先手胜率 {r['win0']*100:.0f}% 偏离 50% 过多")
    if r["distinct"] < 12:
        warns.append(f"只用到 {r['distinct']} 张牌")
    if r["top1"] > 0.40:
        warns.append(f"单张牌占比 {r['top1']*100:.0f}% > 40%")
    if r["top3"] > 0.80:
        warns.append(f"前三张合计 {r['top3']*100:.0f}% > 80%")
    return warns


def main() -> None:
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "policy_400k.pkl")
    games = int(sys.argv[2]) if len(sys.argv) > 2 else 120
    db = DB(DB_PATH)
    with open(src, "rb") as f:
        ckpt = pickle.load(f)
    r = check(db, ckpt, games)
    print(f"=== 抽样体检：{os.path.basename(src)} · {games} 局 ===")
    print(f"  未完成对局   {r['unfinished']}")
    print(f"  平均回合数   {r['avg_turns']:.1f}")
    print(f"  先手胜率     {r['win0']*100:.0f}%")
    print(f"  用到的牌     {r['distinct']}/50")
    print(f"  单牌最高占比 {r['top1']*100:.0f}%   前三合计 {r['top3']*100:.0f}%")
    print("  出牌最多的牌：" + ", ".join(f"{c}({n})" for c, n in r["top_cards"]))
    warns = verdict(r)
    print("  判定：" + ("正常" if not warns else " | ".join(warns)))


if __name__ == "__main__":
    main()
