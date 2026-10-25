"""把查表策略蒸馏成小型 MLP，导出为 Godot 可读的 JSON。

流程：
 1. 用训练好的平均策略跑 N 局，记录 (features, 目标分布)
 2. 训练 22 -> 64 -> 64 -> 51 的 MLP（KL 散度）
 3. 导出权重 + 动作顺序
"""

from __future__ import annotations

import json
import os
import pickle
import sys

import numpy as np
import torch
import torch.nn as nn

sys.path.insert(0, os.path.dirname(__file__))
from abstract import abstract  # noqa: E402
from engine import DB, Game, PASS_ID  # noqa: E402
from features import N_FEATURES, features  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(HERE, "..", "data", "cards.json")
MAX_TURNS = 40


class Net(nn.Module):
    def __init__(self, n_in: int, n_out: int, hidden: int = 64):
        super().__init__()
        self.fc1 = nn.Linear(n_in, hidden)
        self.fc2 = nn.Linear(hidden, hidden)
        self.fc3 = nn.Linear(hidden, n_out)

    def forward(self, x):
        x = torch.relu(self.fc1(x))
        x = torch.relu(self.fc2(x))
        return self.fc3(x)


def collect(db: DB, ckpt: dict, episodes: int, rng: np.random.Generator):
    S = ckpt["S"]
    index = {cid: i for i, cid in enumerate(db.order)}
    index[PASS_ID] = len(db.order)
    n_out = len(db.order) + 1
    xs, ys = [], []
    for _ in range(episodes):
        g = Game(db)
        guard = 0
        while not g.over and g.turn < MAX_TURNS and guard < 200:
            guard += 1
            for who in (0, 1):
                legal = g.legal_cards(who)
                if not legal:
                    break
                idx = [index[c] for c in legal]
                key = abstract(g, who)
                row = S.get(key)
                if row is None:
                    p = np.full(len(idx), 1.0 / len(idx))
                else:
                    pos = np.maximum(row[idx], 0.0)
                    tot = pos.sum()
                    p = pos / tot if tot > 0 else np.full(len(idx), 1.0 / len(idx))
                target = np.zeros(n_out, dtype=np.float32)
                target[idx] = p
                xs.append(features(g, who))
                ys.append(target)
            legals = (g.legal_cards(0), g.legal_cards(1))
            if not legals[0] or not legals[1]:
                break
            picks = []
            for who in (0, 1):
                legal = legals[who]
                idx = [index[c] for c in legal]
                key = abstract(g, who)
                row = S.get(key)
                if row is None:
                    p = np.full(len(idx), 1.0 / len(idx))
                else:
                    pos = np.maximum(row[idx], 0.0)
                    tot = pos.sum()
                    p = pos / tot if tot > 0 else np.full(len(idx), 1.0 / len(idx))
                picks.append(legal[int(rng.choice(len(idx), p=p))])
            if not g.play_turn(picks[0], picks[1]):
                break
    return np.array(xs, dtype=np.float32), np.array(ys, dtype=np.float32)


def main() -> None:
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "policy.pkl")
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "policy_net.json")
    episodes = int(sys.argv[3]) if len(sys.argv) > 3 else 12000

    db = DB(DB_PATH)
    with open(src, "rb") as f:
        ckpt = pickle.load(f)
    rng = np.random.default_rng(7)
    print(f"collecting {episodes} episodes from {os.path.basename(src)} ...")
    X, Y = collect(db, ckpt, episodes, rng)
    print(f"  samples={len(X)}")

    n_out = len(db.order) + 1
    net = Net(N_FEATURES, n_out)
    opt = torch.optim.Adam(net.parameters(), lr=2e-3)
    xt = torch.from_numpy(X)
    yt = torch.from_numpy(Y)
    bs = 2048
    n = len(X)
    for epoch in range(24):
        perm = torch.randperm(n)
        tot = 0.0
        for i in range(0, n, bs):
            b = perm[i:i + bs]
            logits = net(xt[b])
            logp = torch.log_softmax(logits, dim=1)
            # 目标分布可能为 0，用 mask 避免 log(0)
            mask = yt[b] > 0
            loss = -(yt[b] * logp * mask).sum(dim=1).mean()
            opt.zero_grad()
            loss.backward()
            opt.step()
            tot += float(loss) * len(b)
        if (epoch + 1) % 6 == 0:
            print(f"  epoch {epoch+1:2d}  loss={tot/n:.4f}")

    net.eval()
    with torch.no_grad():
        logits = net(xt)
        pred = torch.softmax(logits, dim=1)
        agree = float(((pred.argmax(1) == yt.argmax(1)).float()).mean())
    print(f"  top-1 agreement with tabular: {agree*100:.1f}%")

    payload = {
        "version": 1,
        "n_features": N_FEATURES,
        "hidden": 64,
        "actions": list(db.order) + [PASS_ID],
        "w1": net.fc1.weight.detach().numpy().round(6).tolist(),
        "b1": net.fc1.bias.detach().numpy().round(6).tolist(),
        "w2": net.fc2.weight.detach().numpy().round(6).tolist(),
        "b2": net.fc2.bias.detach().numpy().round(6).tolist(),
        "w3": net.fc3.weight.detach().numpy().round(6).tolist(),
        "b3": net.fc3.bias.detach().numpy().round(6).tolist(),
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    print(f"saved {out}  ({os.path.getsize(out)/1024:.0f} KB)")


if __name__ == "__main__":
    main()
