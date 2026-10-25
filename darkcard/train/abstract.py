"""状态抽象：把无界资源与历史折叠成有限信息集。

设计原则（对应 AI 建议的第 1 层）：
- 血量按"阈值"分桶：盾/酒≤1/护身符 2~3 都是阈值判定，关键档位不能糊
- 运按 1 点粒度分桶，保留负值（-3 锁、负运挡牌）
- 连招折叠成"最活跃链的进度"，8 条链各自编码
- dot/C4 只保留"层数 + 是否有 C4"
- 其余布尔量（葵、元首、封牌）直接编码
"""

from __future__ import annotations

from engine import DB, Game, Player, combo_progress

# 8 条连招链（与 cards.json 的 combo 字段一致）
CHAINS: tuple[tuple[str, ...], ...] = (
    ("zhong_fang",),
    ("zhong_fang", "xi", "yun"),
    ("zhong_fang", "xi", "yun", "chao_ji_xi"),
    ("zhong_fang", "zhong_fang", "xi", "zhong_fang"),
    ("yun", "yun", "yun", "yun"),
    ("jue_xing_zhong_fang",),
    ("jue_xing_zhong_fang", "chao_ji_xi", "qiang_hua_yun"),
    ("xiao_qia", "chao_qia"),
)


def hp_bucket(hp: int) -> int:
    """0.5 血一档，范围 -3.0 ~ +8.0（定点 ×100）。

    阈值密集区不合并：盾保命、酒 ≤1、护身符 2~3、2.2 斩杀线都在这个区间。
    """
    if hp <= -300:
        return 0
    if hp >= 800:
        return 23
    return (hp + 300) // 50 + 1


def yun_bucket(y: int) -> int:
    """1 运一档，范围 -5 ~ +10。"""
    if y <= -50:
        return 0
    if y >= 100:
        return 16
    return (y + 50) // 10 + 1


def combo_bucket(history: list[str]) -> tuple[int, int]:
    best_chain = -1
    best_prog = 0
    for idx, pat in enumerate(CHAINS):
        p = combo_progress(history, pat)
        if p > best_prog:
            best_prog = p
            best_chain = idx
    return (best_chain + 1, best_prog)


def effect_bucket(p: Player) -> int:
    """dot 层数（0-2）+ C4 是否存在（0/1），压成 0-5。"""
    dots = 0
    has_c4 = 0
    for e in p.dots:
        if e[4] == 1:
            has_c4 = 1
        else:
            dots += 1
    return min(dots, 2) * 2 + has_c4


def turn_phase(turn: int) -> int:
    if turn < 5:
        return 0
    if turn < 12:
        return 1
    return 2


def abstract(g: Game, who: int) -> tuple:
    me = g.player(who)
    opp = g.player(1 - who)
    return (
        hp_bucket(me.hp), hp_bucket(opp.hp),
        yun_bucket(me.yun), yun_bucket(opp.yun),
        min(me.shields, 3), min(opp.shields, 3),
        combo_bucket(me.history), combo_bucket(opp.history),
        effect_bucket(me), effect_bucket(opp),
        me.cost_percent // 50, opp.cost_percent // 50,
        1 if me.cannon_discounted(g.turn) else 0,
        1 if opp.cannon_discounted(g.turn) else 0,
        1 if me.skip_turn == g.turn else 0,
        1 if opp.skip_turn == g.turn else 0,
        turn_phase(g.turn),
    )


def payoff(g: Game) -> float:
    """终局效用（玩家 0 视角），零和。"""
    if g.over:
        return 1.0 if g.winner == 0 else -1.0
    diff = g.p0.hp - g.p1.hp
    return max(-1.0, min(1.0, diff / 300.0))
