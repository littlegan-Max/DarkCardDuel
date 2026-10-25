"""多样化策略层：让 AI 打得有花样，但**不能变成另一套套路**。

看 30 局真实牌局发现的问题：
  1. 纯 regret matching 收敛到少数几张牌（运/微镖/吸/强化运/中防 占大半）；
  2. 3 费以上与长连招牌永远出不来（要攒运、要铺前置）；
  3. 187 个回合里 135 个回合双方毫无变化 —— 72% 的回合在空转。

设计原则（避免"AI 按套路出牌"）：
  · **没有任何固定优先级**。不是"总是打最冷门的牌"，而是每回合独立掷骰：
      - 10% 自发随机：在合法牌里纯随机挑一张（纯粹的无套路）
      - 25% 临时起意：随机领一个"冷门目标"（在用得最少的若干张里随机抽），
        能出就出；出不了就**随机**挑一种准备方式（攒运 / 铺前置 / 随便打一张），
        而且这个目标只维持 1~3 回合就作废
      - 其余 65% 按学到的策略出牌（策略仍是主力）
  · 目标、准备方式、维持时长全是随机的 → 玩家看到的是"有想法但不可预测"的 AI，
    而不是另一条固定流程。

强度代价要可控：随机干预占比小，且"攒运"最多连续 2 回合，避免为了凑牌而送命。
"""

from __future__ import annotations

import random
from typing import Optional


class VarietyPolicy:
    def __init__(self, db, rng: random.Random, spontaneous: float = 0.10,
                 whim: float = 0.25, quest_pool: int = 8, quest_life: int = 3,
                 max_prepare: int = 2):
        self.db = db
        self.rng = rng
        self.spontaneous = spontaneous
        self.whim = whim
        self.quest_pool = quest_pool
        self.quest_life = quest_life
        self.max_prepare = max_prepare
        self.used: dict[str, int] = {}
        self.quest: Optional[str] = None
        self.quest_left = 0
        self.prepare_streak = 0
        self.quests_done = 0
        self.quests_failed = 0

    # ---------- 内部 ----------

    def _random_rare(self) -> str:
        """在用得最少的若干张牌里随机抽一张（不是固定挑最冷门那张）。"""
        counts = sorted(self.used.get(c, 0) for c in self.db.order)
        lo = counts[0]
        band = [c for c in self.db.order if self.used.get(c, 0) <= lo + 1]
        pool = band if len(band) >= 3 else list(self.db.order)
        pool = pool[: max(3, self.quest_pool)]
        return self.rng.choice(pool)

    def _combo_step(self, card_id: str, history: list[str]) -> Optional[str]:
        combo = list(self.db.cards[card_id].combo or ())
        if not combo:
            return None
        for k in range(len(combo)):
            if k == 0:
                return combo[0]
            if len(history) >= k and list(history[-k:]) == list(combo[:k]):
                return combo[k]
        return None

    # ---------- 决策 ----------

    def choose(self, legal: list[str], history: list[str], yun: int,
               policy_pick) -> str:
        if not legal:
            return ""
        r = self.rng.random()

        # ① 自发随机：纯随机一张，不问理由
        if r < self.spontaneous:
            pick = self.rng.choice(legal)
            self._mark(pick)
            return pick

        # ② 临时起意：随机领一个冷门目标，随机准备
        if r < self.spontaneous + self.whim:
            if self.quest is None or self.quest_left <= 0:
                self.quest = self._random_rare()
                self.quest_left = self.rng.randint(1, self.quest_life)
                self.prepare_streak = 0
            q = self.quest
            self.quest_left -= 1
            if q in legal:
                self.quest = None
                self.quests_done += 1
                self._mark(q)
                return q
            # 出不了：随机挑一种准备方式
            options: list[str] = []
            step = self._combo_step(q, history)
            if step and step in legal:
                options.append(step)
            if "yun" in legal:
                options.append("yun")
            if "qiang_hua_yun" in legal and yun <= 1:
                options.append("qiang_hua_yun")
            if options and self.prepare_streak < self.max_prepare:
                self.prepare_streak += 1
                pick = self.rng.choice(options)
                self._mark(pick)
                return pick
            # 放弃目标，随便打一张（保持随机性）
            self.quest = None
            self.prepare_streak = 0
            self.quests_failed += 1
            pick = self.rng.choice(legal)
            self._mark(pick)
            return pick

        # ③ 主力：按学到的策略
        pick = policy_pick(legal)
        self._mark(pick)
        return pick

    def _mark(self, card_id: str) -> None:
        if card_id:
            self.used[card_id] = self.used.get(card_id, 0) + 1

    def coverage(self) -> int:
        return sum(1 for c in self.db.order if self.used.get(c, 0) > 0)
