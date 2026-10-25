"""自博弈训练：折扣 regret matching + 单步前瞻值函数。

为什么不是纯 CFR 全枚举：
  50×50 的联合动作空间无法逐步枚举；这里每步只枚举"己方动作"，
  对手动作按当前策略采样一次，用 V(s') 给后续 bootstrap。
  这是 simultaneous-move 博弈里可落地的近似，配合平均策略收敛良好。

训练信号：
  r = 本步血差改善（归一化），终局 ±1
  Q(s,a) = r + γ V(s'_a)
  regret 更新用 Q，从而能感知"攒运→核弹"这类跨回合收益
"""

from __future__ import annotations

import math
import os
import pickle
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from abstract import abstract, payoff  # noqa: E402
from engine import DB, Game, PASS_ID  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(HERE, "..", "data", "cards.json")

MAX_TURNS = 30
TEMP = 1.0


class Trainer:
    def __init__(self, db: DB, gamma: float = 0.97, v_lr: float = 0.2,
                 seed: int = 0, pool_rate: float = 0.5):
        self.db = db
        self.gamma = gamma
        self.v_lr = v_lr
        self.rng = np.random.default_rng(seed)
        # league play：对手池。每隔一段时间把当前平均策略存一份快照，
        # 训练时有一定概率让某一席当"历史对手"，避免在非传递博弈里
        # 与自己的当前版本互相振荡（SPIRAL / league play 的做法）。
        self.pool_rate = pool_rate
        self.pool: list[dict] = []
        self.snapshot_every = 4000
        # 周期抽样自检：每训练 N 局抽 K 局用"平均策略"跑一遍，看策略是否正常
        self.sample_every = 5000
        self.sample_games = 24
        self.samples: list[dict] = []
        # —— 多样性塑形 ——
        # 目标不只是"赢"，还要"打得有花样"：玩家打几十局，应该能看到
        # AI 把 50 张技能都用过一遍。纯 regret matching 会收敛到少数几张牌。
        # diversity_beta : 冷门牌加权（按使用次数的 1/sqrt 递减）
        # combo_beta     : 能推进长连招前置的牌加权（龟派/葵花这类需要 3~4 步铺垫）
        self.diversity_beta = 0.0
        self.combo_beta = 0.0
        # 探索底噪强度：训练时 0.12 左右，既能撑开多样性又不至于太弱
        self.eps = 0.12
        self.card_uses: dict[str, int] = {}
        self.combo_steps: dict[str, list[tuple]] = {}
        for cid in db.order:
            c = db.cards[cid]
            combo = list(getattr(c, "combo", []) or [])
            if combo:
                self.combo_steps[cid] = [tuple(combo[:k]) for k in range(len(combo))]
        self.index = {cid: i for i, cid in enumerate(db.order)}
        self.n = len(db.order) + 1
        self.pass_idx = self.n - 1
        self.index[PASS_ID] = self.pass_idx
        self.R: dict[tuple, np.ndarray] = {}
        self.S: dict[tuple, np.ndarray] = {}
        self.V: dict[tuple, float] = {}
        self.visits = 0

    # ---------- 策略 ----------

    def _row(self, table: dict, key: tuple) -> np.ndarray:
        row = table.get(key)
        if row is None:
            row = np.zeros(self.n, dtype=np.float32)
            table[key] = row
        return row

    def policy(self, key: tuple, idx: list[int], eps: float = -1.0) -> np.ndarray:
        r = self.R.get(key)
        if r is None:
            return np.full(len(idx), 1.0 / len(idx), dtype=np.float64)
        pos = np.maximum(r[idx], 0.0)
        s = pos.sum()
        if s <= 0:
            return np.full(len(idx), 1.0 / len(idx), dtype=np.float64)
        p = pos / s
        # 探索底噪：保证每个合法动作都有非零概率。
        # 这是"AI 玩法多样性"的主要来源——平均策略会把这层均匀分布一起累积进去，
        # 玩家打几十局就能看到 AI 把各种牌都用过。
        e = self.eps if eps < 0 else eps
        return (1.0 - e) * p + e / len(idx)

    def snapshot(self) -> None:
        """把当前平均策略存入对手池（只保留最近 12 份）。"""
        snap = {k: v.copy() for k, v in self.S.items()}
        self.pool.append(snap)
        if len(self.pool) > 12:
            self.pool.pop(0)

    def pool_policy(self, key: tuple, idx: list[int]) -> np.ndarray:
        if not self.pool:
            return None
        snap = self.pool[int(self.rng.integers(len(self.pool)))]
        s_row = snap.get(key)
        if s_row is None:
            return None
        pos = np.maximum(s_row[idx], 0.0)
        total = pos.sum()
        if total <= 0:
            return None
        p = pos / total
        return (1.0 - 0.02) * p + 0.02 / len(idx)

    def average_policy(self, key: tuple, idx: list[int]) -> np.ndarray:
        s_row = self.S.get(key)
        if s_row is None:
            return np.full(len(idx), 1.0 / len(idx), dtype=np.float64)
        pos = np.maximum(s_row[idx], 0.0)
        total = pos.sum()
        if total <= 0:
            return np.full(len(idx), 1.0 / len(idx), dtype=np.float64)
        return pos / total

    # ---------- 单步推演 ----------

    def probe(self, g: Game, who: int, mine: str, theirs: str):
        """推演一步。返回 (即时+折扣价值, 下一状态 key 或 None=终局)。"""
        gg = g.clone()
        ok = gg.play_turn(mine, theirs) if who == 0 else gg.play_turn(theirs, mine)
        if not ok:
            return None
        me_before = g.player(who).hp
        op_before = g.player(1 - who).hp
        me_after = gg.player(who).hp
        op_after = gg.player(1 - who).hp
        delta = (op_before - op_after) - (me_before - me_after)
        value = delta / 100.0
        if gg.over:
            value += 1.0 if gg.winner == who else -1.0
            return value, None
        return value, abstract(gg, who)

    # ---------- 单局 ----------

    def train_episode(self) -> int:
        g = Game(self.db)
        traj = [[], []]
        guard = 0
        while not g.over and g.turn < MAX_TURNS and guard < 200:
            guard += 1
            keys = (abstract(g, 0), abstract(g, 1))
            legals = (g.legal_cards(0), g.legal_cards(1))
            if not legals[0] or not legals[1]:
                break
            idxs = ([self.index[c] for c in legals[0]],
                    [self.index[c] for c in legals[1]])
            # 每席独立：学习者用当前策略并更新 regret；对手席用池里的历史策略
            learner = [True, True]
            probs = [None, None]
            for who in (0, 1):
                if self.pool and self.rng.random() < self.pool_rate:
                    pp = self.pool_policy(keys[who], idxs[who])
                    if pp is not None:
                        learner[who] = False
                        probs[who] = pp
                if probs[who] is None:
                    probs[who] = self.policy(keys[who], idxs[who])
            pick = (self.rng.choice(len(idxs[0]), p=probs[0]),
                    self.rng.choice(len(idxs[1]), p=probs[1]))
            a, b = legals[0][pick[0]], legals[1][pick[1]]

            # 双方各自更新 regret：己方枚举，对手固定为采样动作
            for who in (0, 1):
                if not learner[who]:
                    continue
                key = keys[who]
                idx = idxs[who]
                mine, theirs = (a, b) if who == 0 else (b, a)
                q = np.empty(len(idx), dtype=np.float64)
                hist = g.player(who).history
                for j, card in enumerate(legals[who]):
                    res = self.probe(g, who, card, theirs)
                    if res is None:
                        q[j] = 0.0
                    else:
                        val, nk = res
                        q[j] = val if nk is None else val + self.gamma * self.V.get(nk, 0.0)
                    # 多样性塑形：冷门牌 + 能推进连招前置的牌，给一点额外价值
                    if self.diversity_beta > 0.0:
                        used = self.card_uses.get(card, 0)
                        q[j] += self.diversity_beta / math.sqrt(1.0 + used)
                    if self.combo_beta > 0.0:
                        prefixes = self.combo_steps.get(card, [])
                        for pre in prefixes:
                            if len(pre) == 0 or (
                                len(hist) >= len(pre)
                                and tuple(hist[-len(pre):]) == pre
                            ):
                                q[j] += self.combo_beta
                                break
                p = probs[who]
                ev = float((p * q).sum())
                row = self._row(self.R, key)
                row[idx] += (q - ev).astype(np.float32)
                srow = self._row(self.S, key)
                srow[idx] += p.astype(np.float32)

            # 实际执行采样动作
            self.card_uses[a] = self.card_uses.get(a, 0) + 1
            self.card_uses[b] = self.card_uses.get(b, 0) + 1
            h0, h1 = g.p0.hp, g.p1.hp
            g.play_turn(a, b)
            d0 = ((h1 - g.p1.hp) - (h0 - g.p0.hp)) / 100.0
            traj[0].append((keys[0], d0))
            traj[1].append((keys[1], -d0))
            self.visits += 1

        # 局末：从后往前用终局效用倒推（只更新学习者席的值函数）
        final = payoff(g)
        self._backup(g, traj, final, learner)
        self.v_lr = max(0.02, self.v_lr * 0.99995)
        return g.turn

    def _backup(self, g: Game, traj, final: float, learner=None) -> None:
        for who in (0, 1):
            if learner is not None and not learner[who]:
                continue
            sign = 1.0 if who == 0 else -1.0
            G = sign * final
            for key, r in reversed(traj[who]):
                G = r + self.gamma * G
                old = self.V.get(key, 0.0)
                self.V[key] = old + self.v_lr * (G - old)

    # ---------- 周期抽样自检 ----------

    def sample_check(self, games: int = 0, rng=None) -> dict:
        """用平均策略跑几局，检查策略是否退化（而非只看最终胜率）。"""
        games = games or self.sample_games
        rng = rng or self.rng
        played: dict[str, int] = {}
        turns: list[int] = []
        wins = [0, 0]
        unfinished = 0
        avg_len = 0.0
        for _ in range(games):
            g = Game(self.db)
            guard = 0
            while not g.over and g.turn < 40 and guard < 200:
                guard += 1
                legals = (g.legal_cards(0), g.legal_cards(1))
                if not legals[0] or not legals[1]:
                    break
                picks = []
                for who in (0, 1):
                    legal = legals[who]
                    idx = [self.index[c] for c in legal]
                    key = abstract(g, who)
                    row = self.S.get(key)
                    if row is None:
                        p = np.full(len(idx), 1.0 / len(idx))
                    else:
                        pos = np.maximum(row[idx], 0.0)
                        tot = pos.sum()
                        p = pos / tot if tot > 0 else np.full(len(idx), 1.0 / len(idx))
                    picks.append(legal[int(rng.choice(len(idx), p=p))])
                for c in picks:
                    played[c] = played.get(c, 0) + 1
                if not g.play_turn(picks[0], picks[1]):
                    break
            if g.over and g.winner is not None:
                wins[g.winner] += 1
                turns.append(g.turn)
                avg_len += g.turn
            else:
                unfinished += 1
        total = max(1, sum(played.values()))
        share = sorted((v / total for v in played.values()), reverse=True)
        top1 = share[0] if share else 0.0
        top3 = sum(share[:3])
        res = {
            "games": games,
            "unfinished": unfinished,
            "avg_turns": avg_len / max(1, len(turns)),
            "win0": wins[0] / max(1, games),
            "win1": wins[1] / max(1, games),
            "distinct": len(played),
            "top1": top1,
            "top3": top3,
        }
        return res

    def report_sample(self, res: dict, episode: int) -> list[str]:
        """返回告警列表；空列表表示正常。"""
        warns: list[str] = []
        if res["unfinished"] > 0:
            warns.append(f"有 {res['unfinished']} 局没跑完（疑似卡死/超时）")
        if res["avg_turns"] < 3.0 or res["avg_turns"] > 20.0:
            warns.append(f"平均回合数 {res['avg_turns']:.1f} 超出合理区间(3~20)")
        if res["win0"] < 0.35 or res["win0"] > 0.65:
            warns.append(f"先手胜率 {res['win0']*100:.0f}% 偏离 50% 过多（策略有偏或振荡）")
        if res["distinct"] < 12:
            warns.append(f"只用到 {res['distinct']} 张牌（策略退化）")
        if res["top1"] > 0.40:
            warns.append(f"单张牌出牌占比 {res['top1']*100:.0f}%（>40%，套路化）")
        if res["top3"] > 0.80:
            warns.append(f"前三张牌合计占比 {res['top3']*100:.0f}%（>80%，缺乏混合）")
        # 与上一次采样比：策略分布突变 = 非传递博弈里的振荡
        if self.samples:
            prev = self.samples[-1]
            if abs(res["top1"] - prev["top1"]) > 0.15:
                warns.append(f"出牌集中度较上次突变 {prev['top1']*100:.0f}% → {res['top1']*100:.0f}%（疑似振荡）")
        self.samples.append(res)
        return warns

    # ---------- 保存 ----------

    def save(self, path: str) -> None:
        with open(path, "wb") as f:
            pickle.dump({
                "R": self.R, "S": self.S, "V": self.V,
                "order": self.db.order, "visits": self.visits,
            }, f, protocol=4)


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--episodes", type=int, default=20000)
    ap.add_argument("--out", default=os.path.join(HERE, "policy.pkl"))
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--pool-rate", type=float, default=0.5,
                    help="每席当历史对手的概率（league play）")
    ap.add_argument("--init", default="", help="从已有 checkpoint 继续训练")
    ap.add_argument("--sample-every", type=int, default=5000,
                    help="每训练多少局抽样体检一次")
    ap.add_argument("--sample-games", type=int, default=24,
                    help="每次体检抽样多少局")
    ap.add_argument("--diversity-beta", type=float, default=0.0,
                    help="冷门牌多样性加成强度（0=关闭）")
    ap.add_argument("--combo-beta", type=float, default=0.0,
                    help="连招前置牌多样性加成强度（0=关闭）")
    ap.add_argument("--eps", type=float, default=0.12,
                    help="探索底噪：每个合法动作的最小概率权重")
    args = ap.parse_args()

    db = DB(DB_PATH)
    tr = Trainer(db, seed=args.seed, pool_rate=args.pool_rate)
    tr.sample_every = args.sample_every
    tr.sample_games = args.sample_games
    tr.diversity_beta = args.diversity_beta
    tr.combo_beta = args.combo_beta
    tr.eps = args.eps
    if args.init:
        with open(args.init, "rb") as f:
            ck = pickle.load(f)
        tr.R = ck["R"]
        tr.S = ck["S"]
        tr.V = ck["V"]
        tr.visits = ck.get("visits", 0)
        print(f"从 {os.path.basename(args.init)} 继续训练："
              f"states={len(tr.R)} visits={tr.visits}")
    t0 = time.time()
    turns = 0
    for ep in range(args.episodes):
        turns += tr.train_episode()
        if (ep + 1) % tr.snapshot_every == 0:
            tr.snapshot()
        if (ep + 1) % tr.sample_every == 0:
            res = tr.sample_check()
            warns = tr.report_sample(res, ep + 1)
            tag = "  ".join(warns) if warns else "正常"
            print(f"  [体检] ep {ep+1:6d}  未完成={res['unfinished']}  "
                  f"平均回合={res['avg_turns']:.1f}  先手胜率={res['win0']*100:.0f}%  "
                  f"用到的牌={res['distinct']}/50  单牌最高占比={res['top1']*100:.0f}%  -> {tag}",
                  flush=True)
        if (ep + 1) % 50000 == 0:
            tr.save(args.out + f".ep{ep+1}.pkl")
        if (ep + 1) % 2000 == 0:
            dt = time.time() - t0
            print(f"  ep {ep+1:6d}  states={len(tr.R):7d}  "
                  f"avg_turn={turns/(ep+1):.1f}  "
                  f"{ep+1/dt:.0f} ep/s  {dt:.0f}s", flush=True)
    tr.save(args.out)
    print(f"saved {args.out}  states={len(tr.R)}  visits={tr.visits}  "
          f"{time.time()-t0:.0f}s")


if __name__ == "__main__":
    main()
