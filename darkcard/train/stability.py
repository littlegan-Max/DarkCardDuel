"""稳定性/套路检测：同一个局面下，AI 是不是每次都出同一张牌。

用户反馈的现象："某 AI 第二回合一直都是出小镖，没变过"。
量化方式：跑 N 局，记录每个抽象状态（同一局面）下 AI 实际选了什么，
统计"该局面下最常出现的那张牌占多少比例"。比例越高 = 越套路。

温度（temperature）的作用：p ∝ q^(1/T)，
  T=1.0 用原始分布；T 越大分布越平、选择越随机。
"""

from __future__ import annotations

import os
import pickle
import random
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(__file__))
from abstract import abstract  # noqa: E402
from engine import DB, Game  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(HERE, "..", "data", "cards.json")


def soften(probs: list[float], temp: float) -> list[float]:
    if temp <= 1.0:
        return probs
    q = [max(p, 1e-6) ** (1.0 / temp) for p in probs]
    s = sum(q)
    return [x / s for x in q]


def run(db, S, index, games: int, temp: float, eps: float, seed: int = 99):
    rng = random.Random(seed)
    seen: dict[tuple, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for _ in range(games):
        g = Game(db)
        while not g.over and g.turn < 40:
            picks = []
            keys = []
            for who in (0, 1):
                legal = g.legal_cards(who)
                if not legal:
                    break
                idx = [index[c] for c in legal]
                key = abstract(g, who)
                keys.append(key)
                row = S.get(key)
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
                pick = legal[-1]
                for c, pp in zip(legal, p):
                    acc += pp
                    if x <= acc:
                        pick = c
                        break
                picks.append(pick)
            if len(picks) < 2:
                break
            for who in range(2):
                seen[keys[who]][picks[who]] += 1
            if not g.play_turn(picks[0], picks[1]):
                break
    return seen


def report(db, seen, label: str) -> float:
    shares = []
    worst = []
    for key, cnt in seen.items():
        total = sum(cnt.values())
        if total < 5:
            continue
        top_card, top_n = max(cnt.items(), key=lambda kv: kv[1])
        share = top_n / total
        shares.append(share)
        worst.append((share, db.cards[top_card].name, total, len(cnt)))
    if not shares:
        print(f"  {label}: 样本不足")
        return 0.0
    avg = sum(shares) / len(shares)
    worst.sort(reverse=True)
    print(f"  {label}: 重复局面数 {len(shares)}  平均'最常出牌占比' {avg*100:.1f}%"
          f"  （100% = 完全套路）")
    print("     最套路的几个局面：" + "，".join(
        f"{n}({s*100:.0f}%,出现{t}次,{k}种)" for s, n, t, k in worst[:4]))
    return avg


def opening_stats(db, S, index, games: int, temp: float, eps: float,
                  seed: int = 99) -> dict:
    """玩家能不能背出固定开局？统计前 N 回合出牌序列的去重情况。"""
    rng = random.Random(seed)
    seqs: dict[tuple, int] = defaultdict(int)
    for _ in range(games):
        g = Game(db)
        seq: list[str] = []
        for _turn in range(3):
            if g.over:
                break
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
                pick = legal[-1]
                for c, pp in zip(legal, p):
                    acc += pp
                    if x <= acc:
                        pick = c
                        break
                picks.append(pick)
            if len(picks) < 2:
                break
            seq.append(picks[0])
            seq.append(picks[1])
            if not g.play_turn(picks[0], picks[1]):
                break
        seqs[tuple(seq)] += 1
    total = sum(seqs.values())
    top = sorted(seqs.values(), reverse=True)
    return {
        "total": total,
        "distinct": len(seqs),
        "top_share": (top[0] / total) if top else 0.0,
        "top3_share": (sum(top[:3]) / total) if top else 0.0,
    }


def main() -> None:
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "policy_400k.pkl")
    games = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    db = DB(DB_PATH)
    with open(src, "rb") as f:
        ck = pickle.load(f)
    S = ck["S"]
    index = {c: i for i, c in enumerate(db.order)}
    print(f"=== 套路检测：{os.path.basename(src)} · {games} 局 ===")
    for temp, eps in ((1.0, 0.0), (1.0, 0.08), (1.4, 0.08), (1.8, 0.10)):
        seen = run(db, S, index, games, temp, eps)
        report(db, seen, f"T={temp} eps={eps}")
    print()
    print("=== 开局套路（前 3 回合出牌序列）===")
    for temp, eps in ((1.0, 0.0), (1.4, 0.08), (1.8, 0.10)):
        o = opening_stats(db, S, index, games, temp, eps)
        print(f"  T={temp} eps={eps}: {o['distinct']} 种不同开局 / {o['total']} 局   "
              f"最常见开局占 {o['top_share']*100:.0f}%   前三占 {o['top3_share']*100:.0f}%")


if __name__ == "__main__":
    main()
