"""对比实验：纯学到的策略 vs 加了多样化层的策略。

指标：
  · 技能覆盖（用了多少张牌 / 50）
  · 空转回合占比（双方都没掉血也没回血）
  · 胜率（多样化层会不会把 AI 变笨）
"""

from __future__ import annotations

import os
import pickle
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
from abstract import abstract  # noqa: E402
from engine import DB, Game  # noqa: E402
from variety_ai import VarietyPolicy  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(HERE, "..", "data", "cards.json")


def soften(probs, temp):
    if temp <= 1.0:
        return probs
    q = [max(p, 1e-6) ** (1.0 / temp) for p in probs]
    s = sum(q)
    return [x / s for x in q]


def run(db, S, index, games: int, seed: int, use_variety: bool,
        spontaneous: float = 0.10, whim: float = 0.25, quest_prob: float = 0.35,
        temp: float = 1.0, eps: float = 0.0):
    rng = random.Random(seed)
    used: dict[str, int] = {}
    win = [0, 0]
    noop = 0
    total_turns = 0
    turn_counts = []

    for _ in range(games):
        g = Game(db)
        vp = VarietyPolicy(db, rng, spontaneous=spontaneous, whim=whim) if use_variety else None
        while not g.over and g.turn < 40:
            picks = []
            for who in (0, 1):
                legal = g.legal_cards(who)
                if not legal:
                    break
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
                p = soften(p, temp)
                x = rng.random()
                acc = 0.0
                sample = legal[-1]
                for c, pp in zip(legal, p):
                    acc += pp
                    if x <= acc:
                        sample = c
                        break

                if vp is None:
                    picks.append(sample)
                else:
                    hist = list(g.player(who).history)
                    yun = g.player(who).yun
                    picks.append(vp.choose(legal, hist, yun, lambda _l, s=sample: s))
            if len(picks) < 2:
                break
            a, b = picks
            used[a] = used.get(a, 0) + 1
            used[b] = used.get(b, 0) + 1
            h0a, h0b = g.p0.hp, g.p1.hp
            if not g.play_turn(a, b):
                break
            if g.p0.hp == h0a and g.p1.hp == h0b:
                noop += 1
        total_turns += g.turn
        turn_counts.append(g.turn)
        if g.over and g.winner is not None:
            win[g.winner] += 1

    return {
        "used": used,
        "coverage": sum(1 for c in db.order if used.get(c, 0) > 0),
        "noop": noop,
        "total_turns": total_turns,
        "avg_turns": total_turns / max(1, games),
        "win": win,
    }


def main() -> None:
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "policy_400k.pkl")
    games = int(sys.argv[2]) if len(sys.argv) > 2 else 30
    db = DB(DB_PATH)
    with open(src, "rb") as f:
        ck = pickle.load(f)
    S = ck["S"]
    index = {c: i for i, c in enumerate(db.order)}

    print(f"=== 对比：{os.path.basename(src)} · 每组 {games} 局 ===")
    for temp, eps in ((1.4, 0.08), (1.6, 0.10)):
        t = run(db, S, index, games, 4242, use_variety=False, temp=temp, eps=eps)
        print(f"  温度{temp}+噪{eps}   覆盖 {t['coverage']}/50   平均 {t['avg_turns']:.1f} 回合   "
              f"空转 {t['noop']}/{t['total_turns']} ({t['noop']/max(1,t['total_turns'])*100:.0f}%)")
    base = run(db, S, index, games, 4242, use_variety=False)
    print(f"  纯策略      覆盖 {base['coverage']}/50   平均 {base['avg_turns']:.1f} 回合   "
          f"空转 {base['noop']}/{base['total_turns']} ({base['noop']/max(1,base['total_turns'])*100:.0f}%)   "
          f"先手胜 {base['win'][0]}/{games}")

    for sp, wh in ((0.10, 0.25), (0.15, 0.35)):
        v = run(db, S, index, games, 4242, use_variety=True, spontaneous=sp, whim=wh)
        print(f"  +多样(随机{sp}/起意{wh}) 覆盖 {v['coverage']}/50   平均 {v['avg_turns']:.1f} 回合   "
              f"空转 {v['noop']}/{v['total_turns']} ({v['noop']/max(1,v['total_turns'])*100:.0f}%)   "
              f"先手胜 {v['win'][0]}/{games}")

    v = run(db, S, index, games, 4242, use_variety=True, spontaneous=0.15, whim=0.35)
    missing = [db.cards[c].name for c in db.order if v["used"].get(c, 0) == 0]
    print("  多样化后仍未出现：" + ("、".join(missing) if missing else "无（50 张全覆盖）"))


if __name__ == "__main__":
    main()
