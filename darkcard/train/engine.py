"""暗牌技能对战 · Python 规则引擎

与 Godot 版 `darkcard/scripts/core/*` 语义逐条对齐：
  - 定点整数：hp 1 = 100，yun 1 = 10
  - 结算管线 B4：KUI → AMULET → TIME → COUNTER → RESOURCE → DAMAGE → SHIELD → DEATH → SETTLE
  - 龟派用 redirect 归属表，不为单卡写特例
  - 同死只回滚血量（C29）

用途：自博弈训练的数据源（比 GDScript 快两个数量级）。
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Optional

PASS_ID = "pass"

# 伤害事件用轻量 tuple 表示：(target, amount, source, kind)
# kind: 0=普通 1=真伤 2=dot 3=比例 4=反弹


@dataclass(slots=True)
class Card:
    id: str
    name: str
    desc: str
    cost: int
    cost_kind: str
    cost_rule: str
    countered_by: tuple[str, ...]
    tags: frozenset[str]
    ops: tuple[dict, ...]
    combo: tuple[str, ...]
    combo_optional: bool
    cooldown: int
    pool_id: str
    shield_cost: int
    target: str
    kill_tag: str
    yun_block: str
    dodgeable: bool
    on_blocked_hit: int
    stolen_self_yun: int
    steal_multiplier: int
    is_counter: bool
    # 作者裁定（2026-10-25）新增
    blocks: tuple[str, ...] = ()
    time_spread: int = 0
    reflect_percent: int = 0
    reflect_cap: int = 0

    @property
    def negative(self) -> bool:
        return "negative" in self.tags


@dataclass(slots=True)
class Player:
    hp: int = 100
    hp_max_ever: int = 100
    yun: int = 0
    shields: int = 0
    last_played: dict[str, int] = field(default_factory=dict)
    history: list[str] = field(default_factory=list)
    cost_percent: int = 100
    shield_bought_once: bool = False
    dots: list[list[int]] = field(default_factory=list)   # [amount, left, first, source, kind]
    immune_le: int = -1
    scheduled_yun: list[list[int]] = field(default_factory=list)  # [turn, amount]
    skip_turn: int = -1
    cannon_from: int = -1
    cannon_until: int = -1
    pending_card: str = ""
    pending_paid: int = 0
    fly_ready: bool = False

    def can_use(self, pool: str, cooldown: int, turn: int) -> bool:
        return turn - self.last_played.get(pool, -9999) > cooldown

    def add_effect(self, amount: int, left: int, first: int, source: int, kind: int) -> None:
        self.dots.append([amount, left, first, source, kind])

    def cannon_discounted(self, turn: int) -> bool:
        return self.cannon_from <= turn < self.cannon_until

    def clone(self) -> "Player":
        p = Player(
            hp=self.hp, hp_max_ever=self.hp_max_ever, yun=self.yun, shields=self.shields,
            cost_percent=self.cost_percent, shield_bought_once=self.shield_bought_once,
            immune_le=self.immune_le, skip_turn=self.skip_turn,
            cannon_from=self.cannon_from, cannon_until=self.cannon_until,
            pending_card=self.pending_card, pending_paid=self.pending_paid,
            fly_ready=self.fly_ready,
        )
        p.last_played = dict(self.last_played)
        p.history = list(self.history)
        p.dots = [list(d) for d in self.dots]
        p.scheduled_yun = [list(s) for s in self.scheduled_yun]
        return p


def _reflect_field(item: dict, key: str) -> int:
    """REFLECT op 的 percent / cap 提到牌级字段（与 GDScript SkillDef 一致）。"""
    for op in item.get("ops", []):
        if op.get("op") == "REFLECT":
            return int(op.get(key, 0))
    return 0


class DB:
    def __init__(self, path: str):
        with open(path, "r", encoding="utf-8") as f:
            raw = json.load(f)
        self.version = raw.get("rules_version", "")
        self.cards: dict[str, Card] = {}
        self.order: list[str] = []
        for item in raw["cards"]:
            c = Card(
                id=item["id"],
                name=item["name"],
                desc=item.get("desc", ""),
                cost=int(item.get("cost", 0)),
                cost_kind=item.get("cost_kind", "fixed"),
                cost_rule=item.get("cost_rule", ""),
                countered_by=tuple(item.get("countered_by", [])),
                tags=frozenset(item.get("tags", [])),
                ops=tuple(item.get("ops", [])),
                combo=tuple(item.get("combo", [])),
                combo_optional=bool(item.get("combo_optional", False)),
                cooldown=int(item.get("cooldown", 0)),
                pool_id=item.get("pool_id", ""),
                shield_cost=int(item.get("shield_cost", 1)),
                target=item.get("target", "self"),
                kill_tag=item.get("kill_tag", ""),
                yun_block=item.get("yun_block", ""),
                dodgeable=bool(item.get("dodgeable", True)),
                on_blocked_hit=int(item.get("on_blocked_hit", 0)),
                stolen_self_yun=int(item.get("stolen_self_yun", 0)),
                steal_multiplier=int(item.get("steal_multiplier", 1)),
                is_counter=bool(item.get("is_counter", False)),
                blocks=tuple(item.get("blocks", [])),
                time_spread=int(item.get("time_spread", 0)),
                reflect_percent=_reflect_field(item, "percent"),
                reflect_cap=_reflect_field(item, "cap"),
            )
            self.cards[c.id] = c
            self.order.append(c.id)
        self.cards[PASS_ID] = Card(
            id=PASS_ID, name="空过", desc="被鄙视", cost=0, cost_kind="fixed",
            cost_rule="", countered_by=(), tags=frozenset(), ops=(), combo=(),
            combo_optional=False, cooldown=0, pool_id="", shield_cost=1, target="self",
            kill_tag="", yun_block="", dodgeable=True, on_blocked_hit=0,
            stolen_self_yun=0, steal_multiplier=1, is_counter=False,
        )

# 神之龟派翻倍范围（C34）：只翻"牌面写死的 ±血量 / ±运"。
# 不翻：比例伤害（毒药）、公式伤害（三棱镜）、阈值（酒 ≤1、护身符 2~3）、计数与时长。
KUI_SCALABLE_OPS = frozenset({
    "DMG", "TRUE_DMG", "HEAL", "HEAL_ALL", "YUN_ADD", "YUN_ENEMY",
    "YUN_MINUS", "DOT", "DELAY_DMG", "SCHEDULE_YUN",
})


def kui_scalable(kind: str) -> bool:
    return kind in KUI_SCALABLE_OPS


def suffix_matches(history: list[str], pattern: tuple[str, ...]) -> bool:
    if not pattern:
        return True
    n = len(pattern)
    if len(history) < n:
        return False
    return tuple(history[-n:]) == pattern


def combo_progress(history: list[str], pattern: tuple[str, ...]) -> int:
    best = 0
    for n in range(1, len(pattern) + 1):
        if suffix_matches(history, pattern[:n]):
            best = n
    return best


class Game:
    """一局对战的完整状态机。"""

    __slots__ = ("db", "turn", "p0", "p1", "over", "winner", "end_reason",
                 "redirect", "kui_mult", "time_stopped")

    def __init__(self, db: DB):
        self.db = db
        self.turn = 0
        self.p0 = Player()
        self.p1 = Player()
        self.over = False
        self.winner = -1
        self.end_reason = ""
        self.redirect = [0, 1]
        self.kui_mult = 1
        self.time_stopped = False

    # ---------- 查询 ----------

    def player(self, i: int) -> Player:
        return self.p0 if i == 0 else self.p1

    def opponent(self, i: int) -> Player:
        return self.p1 if i == 0 else self.p0

    def effective_cost(self, i: int, c: Card) -> int:
        p = self.player(i)
        base = c.cost
        if c.cost_rule == "shield_price":
            # 首次用牌价 = 卡表 cost，之后永久便宜 1 费（RFC-0008：3/2 费）
            base = c.cost - 10 if p.shield_bought_once else c.cost
        elif c.cost_rule == "cannon_price":
            # 元首 buff 期固定 2 费，否则用卡表 cost（RFC-0008：5 费）
            base = 20 if p.cannon_discounted(self.turn) else c.cost
        return base * p.cost_percent // 100

    def can_play(self, i: int, cid: str) -> bool:
        if self.over:
            return False
        p = self.player(i)
        if p.pending_card != "":
            return False
        if p.skip_turn == self.turn:
            return cid == PASS_ID
        if cid == PASS_ID:
            return False
        c = self.db.cards.get(cid)
        if c is None:
            return False
        if self.turn == 0 and cid != "yun":
            return False
        if c.combo and not c.combo_optional:
            bypass = cid == "jiang_fei" and p.fly_ready
            if not bypass and not suffix_matches(p.history, c.combo):
                return False
        pool = c.pool_id or c.id
        if not p.can_use(pool, c.cooldown, self.turn):
            return False
        if c.cost_kind == "all_in":
            return True
        need = self.effective_cost(i, c)
        return need <= 0 or p.yun >= need

    def legal_cards(self, i: int) -> list[str]:
        out = [cid for cid in self.db.order if self.can_play(i, cid)]
        if self.can_play(i, PASS_ID):
            out.append(PASS_ID)
        return out

    # ---------- 提交与结算 ----------

    def submit(self, i: int, cid: str) -> bool:
        if not self.can_play(i, cid):
            return False
        c = self.db.cards[cid]
        p = self.player(i)
        if c.cost_kind == "all_in":
            pay = max(0, min(p.yun, c.cost))
        else:
            pay = self.effective_cost(i, c)
        p.yun -= pay
        p.pending_card = cid
        p.pending_paid = pay
        if cid == "jiang_fei":
            p.fly_ready = False
        return True

    def play_turn(self, a: str, b: str) -> bool:
        if self.over:
            return False
        if not self.can_play(0, a) or not self.can_play(1, b):
            return False
        self.submit(0, a)
        self.submit(1, b)
        self._resolve()
        return True

    def _resolve(self) -> None:
        ctx = _Ctx(self)
        ctx.run()

    def clone(self) -> "Game":
        g = Game.__new__(Game)
        g.db = self.db
        g.turn = self.turn
        g.p0 = self.p0.clone()
        g.p1 = self.p1.clone()
        g.over = self.over
        g.winner = self.winner
        g.end_reason = self.end_reason
        g.redirect = list(self.redirect)
        g.kui_mult = self.kui_mult
        g.time_stopped = self.time_stopped
        return g


class _Ctx:
    __slots__ = ("g", "turn", "cards", "defs", "paid", "negated", "blocked_by",
                 "dmg", "code_kill", "yun_consumed", "redirect", "kui_mult",
                 "kui_caster", "kui_taken", "time_stopped", "snap_hp", "hits")

    def __init__(self, g: Game):
        self.g = g
        self.turn = g.turn
        self.cards = [g.p0.pending_card, g.p1.pending_card]
        self.defs = [g.db.cards[self.cards[0]], g.db.cards[self.cards[1]]]
        self.paid = [g.p0.pending_paid, g.p1.pending_paid]
        self.negated = [False, False]
        self.blocked_by = ["", ""]
        self.dmg = []              # (target, amount, source, kind)
        self.code_kill = [False, False]
        self.yun_consumed = [False, False]
        self.redirect = [0, 1]
        self.kui_mult = 1
        self.kui_caster = -1
        self.kui_taken = [False, False]
        self.time_stopped = False
        self.snap_hp = (g.p0.hp, g.p1.hp)
        self.hits = []

    # ---------- helpers ----------

    def owner(self, i: int) -> int:
        return self.redirect[i]

    def target(self, i: int) -> int:
        d = self.defs[i]
        o = self.redirect[i]
        return 1 - o if d.target == "enemy" else o

    def pl(self, i: int) -> Player:
        return self.g.player(i)

    def negate(self, i: int, by: str) -> None:
        self.negated[i] = True
        self.blocked_by[i] = by

    # ---------- 主流程 ----------

    def run(self) -> None:
        self.phase_kui()
        self.phase_amulet()
        self.phase_time()
        if not self.time_stopped:
            self.phase_counter()
            self.phase_resource()
        self.phase_damage()
        result = self.phase_death()
        if result == "tie":
            self.code_kill = [False, False]
            self.g.p0.hp = self.snap_hp[0]
            self.g.p1.hp = self.snap_hp[1]
            # hp_max_ever 不回滚（C29）
            result = "continue"
        self.phase_settle()

    # ---------- 各阶段 ----------

    def phase_kui(self) -> None:
        kui = -1
        for i in (0, 1):
            d = self.defs[i]
            if d.id in ("gui_pai", "shen_zhi_gui_pai"):
                if kui >= 0:
                    self.negated = [True, True]
                    return
                kui = i
        if kui < 0:
            return
        other = 1 - kui
        self.kui_caster = kui
        for op in self.defs[kui].ops:
            if op.get("op") == "KUI":
                self.kui_mult = max(1, int(op.get("mult", 1)))
        self.redirect[other] = kui
        self.kui_taken[other] = True
        if self.defs[other].is_counter:
            self.negated[other] = True

    def phase_amulet(self) -> None:
        for i in (0, 1):
            d = self.defs[i]
            if d.id != "hu_shen_fu" or self.negated[i]:
                continue
            holder = self.owner(i)
            lo, hi = 20, 30
            for op in d.ops:
                if op.get("op") == "IMMUNE_COST_RANGE":
                    lo, hi = int(op.get("lo", 20)), int(op.get("hi", 30))
            for j in (0, 1):
                if j == i or self.negated[j]:
                    continue
                atk = self.defs[j]
                if not atk.negative or self.target(j) != holder:
                    continue
                spent = self.paid[j]
                if lo <= spent <= hi:
                    self.negate(j, "hu_shen_fu")

    def phase_time(self) -> None:
        for i in (0, 1):
            d = self.defs[i]
            if d.id == "niu_zhuan_shi_kong" and not self.negated[i]:
                self.time_stopped = True
                self.g.time_stopped = True

    def phase_counter(self) -> None:
        for i in (0, 1):
            if self.kui_taken[i]:
                continue
            j = 1 - i
            if self.kui_taken[j]:
                continue
            atk = self.defs[i]
            dfn = self.defs[j]
            if not self.negated[i]:
                self.try_block(i, j)
            if not self.negated[i] and atk.kill_tag and atk.kill_tag in dfn.tags:
                self.negated[j] = True
                self.blocked_by[j] = atk.id
                self.code_kill[j] = True

    def try_block(self, i: int, j: int) -> None:
        atk, dfn = self.defs[i], self.defs[j]
        gi, gj = self.g.player(i), self.g.player(j)

        # 1) 闪
        if (dfn.id == "shan" and atk.negative and atk.dodgeable
                and self.target(i) == j):
            self.negate(i, "shan")
            return

        # 2) 觉醒中防（裁定 8）：只挡中防挡得住的集合 + 核弹；除核弹外按比例反弹
        if dfn.id == "jue_xing_zhong_fang" and self.jue_xing_blocks(atk) and self.target(i) == j:
            self.negate(i, "jue_xing_zhong_fang")
            self.jue_xing_reflect(i, j)
            return

        # 3) 中防
        if dfn.id == "zhong_fang" and "zhong_fang" in atk.countered_by:
            self.negate(i, "zhong_fang")
            if atk.on_blocked_hit:
                self.dmg.append((j, atk.on_blocked_hit, i, 0, atk.shield_cost))
            return

        # 4) 负运：只挡自己的 blocks 清单
        if dfn.id == "fu_yun":
            if atk.id in dfn.blocks:
                self.negate(i, "fu_yun")
            return

        if dfn.is_counter:
            mult = max(1, dfn.steal_multiplier)
            if atk.id == "yun":
                self.negate(i, "xi")
                gj.yun += 10 * mult
                return
            if atk.id == "qiang_hua_yun":
                gj.yun += 10 * mult
                gi.yun -= 10
                return
            if "xi" in atk.countered_by:
                self.negate(i, "xi")
                gain = self.paid[i] * mult
                if atk.id in ("jiang_long", "jiang_fei"):
                    gain = 20 * mult            # C9：被吸伤害归 0，但吸者仍 +2 运
                if atk.id == "fu_yun":
                    gj.yun -= 10                    # 裁定 2：扣出吸的人
                    return
                if gain:
                    gj.yun += gain
                if atk.time_spread:                 # 裁定 7：时间分散
                    turns = max(1, gain // 10)
                    gi.add_effect(atk.time_spread, turns, self.turn + 1, j, 4)
                if atk.stolen_self_yun:
                    gi.yun += atk.stolen_self_yun
                return

        if dfn.id in ("yun", "qiang_hua_yun") and "yun" in atk.countered_by:
            self.negate(i, "yun")
            if atk.yun_block == "consume":
                self.yun_consumed[j] = True
            elif atk.yun_block == "steal_gain":
                gained = 10 if dfn.id == "yun" else 20
                self.yun_consumed[j] = True
                gi.yun += gained
            if atk.id == "jiang_fei":
                gi.fly_ready = True
            return

        # 7) 通用可被列
        if dfn.id in atk.countered_by:
            self.negate(i, dfn.id)

    # ---------- 觉醒中防 ----------

    @staticmethod
    def jue_xing_blocks(atk: Card) -> bool:
        return "zhong_fang" in atk.countered_by or "jue_xing_zhong_fang" in atk.countered_by

    def jue_xing_reflect(self, i: int, j: int) -> None:
        dfn, atk = self.defs[j], self.defs[i]
        p = self.g.player(i)

        if atk.id == "bi_xin":
            if p.yun > -30:
                p.yun = max(p.yun - 10, -30)
            return
        if atk.id == "bi_shi":
            p.skip_turn = self.turn + 1          # 反弹回去 = 对面下回合强制空过
            return

        base = self.card_damage_amount(atk)
        if base <= 0 or dfn.reflect_percent <= 0:
            return
        reflect = min(base * dfn.reflect_percent // 100, dfn.reflect_cap)
        if reflect <= 0:
            return
        self.dmg.append((i, reflect, j, 4, dfn.shield_cost))

    def card_damage_amount(self, atk: Card) -> int:
        if atk.id == "san_leng_jing":
            return max(0, 40 + 30 * self.prism_k())
        total = 0
        for op in atk.ops:
            kind = op.get("op", "")
            if kind in ("DMG", "TRUE_DMG"):
                amount = int(op.get("amount", 0))
                if self.kui_mult > 1:
                    amount *= self.kui_mult
                total += amount
        return total

    def prism_k(self) -> int:
        k = 0
        for i in (0, 1):
            if self.kui_taken[i]:            # 裁定 1：被龟派取走的不进 k
                continue
            c = self.cards[i]
            if c in ("yun", "qiang_hua_yun"):
                k += 1
            elif c == "fu_yun":
                k -= 1
        return k

    def phase_resource(self) -> None:
        g = self.g
        steal_all = []
        for i in (0, 1):
            d = self.defs[i]
            if d.id in ("gui_pai", "shen_zhi_gui_pai"):
                continue
            o = self.owner(i)
            tgt = self.target(i)
            po, pt = g.player(o), g.player(tgt)

            if self.negated[i] and d.id == "san_leng_jing":
                for c in (0, 1):
                    if self.kui_taken[c]:
                        continue
                    who = self.cards[c]
                    if who in ("yun", "qiang_hua_yun"):
                        self.dmg.append((c, 20, 1 - c, 0, 1))
                    elif who == "fu_yun":
                        pc = g.player(c)
                        pc.hp += 20
                        if pc.hp > pc.hp_max_ever:
                            pc.hp_max_ever = pc.hp
                continue

            if d.id == "tao_tao":
                po.dots.clear()

            combo_ok = suffix_matches(g.player(i).history, d.combo)

            for op in d.ops:
                kind = op.get("op", "")
                amount = int(op.get("amount", 0))
                if self.kui_mult > 1 and kui_scalable(kind):
                    amount *= self.kui_mult

                if self.negated[i]:
                    if self.blocked_by[i] == "shan":
                        continue
                    keep = (kind == "TRUE_DMG" or op.get("true_dmg") or op.get("on_blocked")
                            or (kind == "PRC_DMG" and self.blocked_by[i] == "yun"))
                    if not keep:
                        continue
                if op.get("combo_only") and not combo_ok:
                    continue
                if op.get("no_combo") and combo_ok:
                    continue

                if kind == "DMG":
                    self.dmg.append((tgt, amount, o, 0, d.shield_cost))
                elif kind == "TRUE_DMG":
                    self.dmg.append((tgt, amount, o, 1, d.shield_cost))
                elif kind == "PRC_DMG":
                    pct = int(op.get("percent", 80))
                    if self.negated[i] and self.blocked_by[i] == "yun":
                        pct = int(op.get("blocked_percent", 40))
                    base = max(0, pt.hp)
                    self.dmg.append((tgt, base * pct // 100, o, 3, d.shield_cost))
                elif kind == "HEAL":
                    po.hp += amount
                    if po.hp > po.hp_max_ever:
                        po.hp_max_ever = po.hp
                elif kind == "HEAL_ALL":
                    for k in (0, 1):
                        pk = g.player(k)
                        pk.hp += amount
                        if pk.hp > pk.hp_max_ever:
                            pk.hp_max_ever = pk.hp
                elif kind == "YUN_ADD":
                    if not (self.yun_consumed[i] and d.id in ("yun", "qiang_hua_yun")):
                        po.yun += amount
                elif kind == "YUN_ENEMY":
                    pt.yun += amount
                elif kind == "YUN_STEAL_ALL":
                    steal_all.append((o, tgt))
                elif kind == "YUN_MINUS":
                    floor_v = int(op.get("floor", -30))
                    if pt.yun > floor_v:
                        pt.yun = max(pt.yun + amount, floor_v)
                elif kind == "SHIELD_ADD":
                    po.shields += 1
                elif kind == "DOT":
                    pt.dots.append([amount, int(op.get("turns", 5)),
                                    self.turn + 1, o, 0])
                elif kind == "DELAY_DMG":
                    wait = int(op.get("turns", 3))
                    pt.dots.append([amount, 1, self.turn + wait, o, 1])
                elif kind == "IMMUNE_LE":
                    po.immune_le = amount
                elif kind == "PRISM":
                    self.dmg.append((tgt, 40 + 30 * self.prism_k(), o, 0, d.shield_cost))
                elif kind == "CODE_KILL":
                    self.code_kill[tgt] = True
                elif kind == "SELF_CODE_KILL":
                    self.code_kill[o] = True
                elif kind == "COST_HALF":
                    po.cost_percent = int(op.get("percent", 50))
                elif kind == "SCHEDULE_YUN":
                    po.yun += amount
                    for n in range(1, int(op.get("turns", 2))):
                        po.scheduled_yun.append([self.turn + n, amount])
                elif kind == "CANNON_DISCOUNT":
                    po.cannon_from = self.turn + 1
                    po.cannon_until = self.turn + 1 + int(op.get("turns", 3))
                elif kind == "SKIP_NEXT":
                    pt.skip_turn = self.turn + 1
                elif kind == "DOT_CLEAR_MAX_HP":
                    po.dots.clear()
                    po.hp = po.hp_max_ever

        # 勾魂晚于本回合的运结算，才能夺到"本回合获得的运"
        for so, st in steal_all:
            victim = g.player(st)
            stolen = max(victim.yun, 0)
            victim.yun = 0
            g.player(so).yun += stolen

    def phase_damage(self) -> None:
        g = self.g
        # dot / C4 当期跳伤：不经过反制，不受扭转时空影响
        for i in (0, 1):
            p = g.player(i)
            keep = []
            for e in p.dots:
                if self.turn < e[2]:
                    keep.append(e)
                    continue
                if e[1] > 0:
                    self.dmg.append((i, e[0], e[3], 2, 1))
                    e[1] -= 1
                if e[1] > 0:
                    keep.append(e)
            p.dots = keep

        # 裁定 4：比总量（含 dot 当期跳伤）。平 → 互抵；不平 → 只有高的生效。
        # 自己挂给自己的 dot（源=目标）不参与比较，永远照跳。
        totals = [0, 0]
        for tgt, amount, src, _k, _n in self.dmg:
            if src != tgt:
                totals[src] += amount

        if totals[0] == totals[1]:
            applied = [e for e in self.dmg if e[2] == e[0]]
        else:
            loser = 0 if totals[0] < totals[1] else 1
            applied = [e for e in self.dmg if not (e[2] == loser and e[0] != loser)]

        # 按"一次攻击"分组（C16）
        groups = []
        by_key = {}
        for tgt, amount, src, kind, need in applied:
            if kind == 2:
                key = ("dot", len(groups))
            else:
                key = (src, tgt)
            if key in by_key:
                gi = by_key[key]
                groups[gi][3] += abs(amount)
                groups[gi][4] = max(groups[gi][4], need)
                groups[gi][5].append((tgt, amount, src, kind, need))
            else:
                by_key[key] = len(groups)
                groups.append([tgt, src, 0, abs(amount), need, [(tgt, amount, src, kind, need)]])

        for tgt, src, _k, total, need, evs in groups:
            p = g.player(tgt)
            if not self.time_stopped and p.immune_le >= 0 and total <= p.immune_le:
                continue
            start_hp = p.hp
            for (t2, amount, _s2, _k2, _n2) in evs:
                if amount >= 0:
                    p.hp -= amount
                else:
                    p.hp -= amount
                    if p.hp > p.hp_max_ever:
                        p.hp_max_ever = p.hp
            if p.hp <= 0:
                if p.shields >= need:
                    p.shields -= need
                    p.hp = start_hp
                # 盾不足：保持死亡

    def phase_death(self) -> str:
        g = self.g
        d0 = g.p0.hp <= 0 or self.code_kill[0]
        d1 = g.p1.hp <= 0 or self.code_kill[1]
        if not d0 and not d1:
            return "continue"
        if d0 and d1:
            if self.code_kill[0] != self.code_kill[1]:
                w = 0 if self.code_kill[0] else 1
                g.over, g.winner, g.end_reason = True, w, "code_kill_priority"
                return "win"
            if g.p0.hp == g.p1.hp:
                return "tie"
            loser = 0 if g.p0.hp < g.p1.hp else 1
            g.over, g.winner, g.end_reason = True, 1 - loser, "more_negative"
            return "win"
        w = 1 if d0 else 0
        g.over, g.winner, g.end_reason = True, w, "death"
        return "win"

    def phase_settle(self) -> None:
        g = self.g
        for i in (0, 1):
            p = g.player(i)
            p.immune_le = -1
            d = self.defs[i]
            # 裁定 1：被龟派取走的牌不算出过（连招 / 冷却 / 三棱镜 k）
            if not self.kui_taken[i]:
                p.history.append(self.cards[i])
                pool = d.pool_id or d.id
                p.last_played[pool] = g.turn
            if self.cards[i] == "dun":
                p.shield_bought_once = True
            p.pending_card = ""
            p.pending_paid = 0

        g.turn += 1
        for i in (0, 1):
            p = g.player(i)
            keep = []
            for turn, amount in p.scheduled_yun:
                if turn == g.turn:
                    p.yun += amount
                else:
                    keep.append([turn, amount])
            p.scheduled_yun = keep
            if p.skip_turn >= 0 and p.skip_turn < g.turn:
                p.skip_turn = -1
