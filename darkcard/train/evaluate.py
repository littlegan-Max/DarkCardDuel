"""策略评估：胜率矩阵 + 行为画像 + 可利用度上界。"""

from __future__ import annotations

import os
import pickle
import sys
from collections import Counter

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from abstract import abstract, payoff  # noqa: E402
from engine import DB, Game, PASS_ID  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(HERE, "..", "data", "cards.json")
MAX_TURNS = 40


class TrainedAgent:
    def __init__(self, db: DB, ckpt: dict, sample: bool = True, seed: int = 0):
        self.db = db
        self.S = ckpt["S"]
        self.V = ckpt["V"]
        self.order = ckpt["order"]
        self.index = {cid: i for i, cid in enumerate(db.order)}
        self.index[PASS_ID] = len(db.order)
        self.sample = sample
        self.rng = np.random.default_rng(seed)
        self.picks = Counter()

    def act(self, g: Game, who: int) -> str:
        legal = g.legal_cards(who)
        if len(legal) == 1:
            return legal[0]
        key = abstract(g, who)
        idx = [self.index[c] for c in legal]
        row = self.S.get(key)
        if row is None:
            p = np.full(len(idx), 1.0 / len(idx))
        else:
            pos = np.maximum(row[idx], 0.0)
            total = pos.sum()
            p = pos / total if total > 0 else np.full(len(idx), 1.0 / len(idx))
        if self.sample:
            k = int(self.rng.choice(len(idx), p=p))
        else:
            k = int(np.argmax(p))
        cid = legal[k]
        self.picks[cid] += 1
        return cid


class RandomAgent:
    def __init__(self, seed: int = 0):
        self.rng = np.random.default_rng(seed)

    def act(self, g: Game, who: int) -> str:
        legal = g.legal_cards(who)
        return legal[int(self.rng.integers(len(legal)))]


class GreedyAgent:
    """每回合选"纸面伤害最高"的牌，不看对手。"""

    def __init__(self, db: DB, seed: int = 0):
        self.db = db
        self.rng = np.random.default_rng(seed)

    def act(self, g: Game, who: int) -> str:
        legal = g.legal_cards(who)
        best, best_v = legal[0], -1e9
        for cid in legal:
            c = self.db.cards[cid]
            v = 0.0
            for op in c.ops:
                k = op.get("op")
                if k == "DMG":
                    v += int(op.get("amount", 0)) / 100.0
                elif k == "TRUE_DMG":
                    v += int(op.get("amount", 0)) / 100.0
                elif k == "HEAL":
                    v += 0.3
                elif k == "YUN_ADD":
                    v += 0.4
                elif k == "SHIELD_ADD":
                    v += 0.5
            v -= c.cost / 100.0 * 0.05
            if v > best_v:
                best_v, best = v, cid
        return best


def play(db: DB, a, b, seed: int = 0) -> tuple[int, int]:
    g = Game(db)
    guard = 0
    while not g.over and g.turn < MAX_TURNS and guard < 200:
        guard += 1
        ca, cb = a.act(g, 0), b.act(g, 1)
        if not g.play_turn(ca, cb):
            break
    if g.over:
        return g.winner, g.turn
    return (-1 if g.p0.hp < g.p1.hp else (0 if g.p0.hp > g.p1.hp else -1)), g.turn


def match(db: DB, a, b, n: int = 200) -> tuple[float, float]:
    wins = 0
    turns = 0
    for i in range(n):
        w, t = play(db, a, b, i)
        if w == 0:
            wins += 1
        turns += t
    return wins / n, turns / n


def main() -> None:
    db = DB(DB_PATH)
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "policy.pkl")
    with open(path, "rb") as f:
        ckpt = pickle.load(f)
    print(f"checkpoint: {os.path.basename(path)}  states={len(ckpt['S'])}  visits={ckpt.get('visits')}")

    trained = TrainedAgent(db, ckpt, sample=True, seed=1)
    trained_arg = TrainedAgent(db, ckpt, sample=False, seed=2)
    rand = RandomAgent(seed=3)
    greedy = GreedyAgent(db, seed=4)

    n = 300
    w1, t1 = match(db, trained, rand, n)
    print(f"vs random   : {w1*100:5.1f}%   avg_turn={t1:.1f}")
    w2, t2 = match(db, trained, greedy, n)
    print(f"vs greedy   : {w2*100:5.1f}%   avg_turn={t2:.1f}")
    w3, t3 = match(db, trained, trained_arg, n)
    print(f"self (samp vs argmax): {w3*100:5.1f}%   avg_turn={t3:.1f}")

    top = trained.picks.most_common(12)
    total = sum(trained.picks.values())
    print("action mix:")
    for cid, cnt in top:
        print(f"   {db.cards[cid].name:8s} {cnt/total*100:5.1f}%")


if __name__ == "__main__":
    main()
