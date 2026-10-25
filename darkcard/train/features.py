"""特征定义：Python 与 GDScript 必须逐位一致。

刻意不用分桶，用连续值 —— 网络有泛化能力，也避免两端分桶边界不一致。
顺序即列序，改顺序要同步改 `policy_net.gd`。
"""

from __future__ import annotations

from engine import Game

N_FEATURES = 21


def clamp(v: float, lo: float, hi: float) -> float:
    return lo if v < lo else (hi if v > hi else v)


def combo_feat(g: Game, who: int) -> tuple[float, float]:
    from abstract import CHAINS, combo_progress
    me = g.player(who)
    best_chain = -1.0
    best_prog = 0.0
    for idx, pat in enumerate(CHAINS):
        p = combo_progress(me.history, pat)
        if p > best_prog:
            best_prog = p
            best_chain = idx
    return (best_chain + 1.0) / 8.0, best_prog / 4.0


def dot_feats(p) -> tuple[float, float]:
    dots = 0
    c4 = 0.0
    for e in p.dots:
        if e[4] == 1:
            c4 = 1.0
        else:
            dots += 1
    return min(dots, 3) / 3.0, c4


def features(g: Game, who: int):
    me = g.player(who)
    opp = g.player(1 - who)
    mc, mp = combo_feat(g, who)
    oc, op = combo_feat(g, 1 - who)
    md, mc4 = dot_feats(me)
    od, oc4 = dot_feats(opp)
    return [
        clamp(me.hp / 400.0, -1.0, 2.0),
        clamp(opp.hp / 400.0, -1.0, 2.0),
        clamp(me.yun / 60.0, -1.0, 2.0),
        clamp(opp.yun / 60.0, -1.0, 2.0),
        min(me.shields, 3) / 3.0,
        min(opp.shields, 3) / 3.0,
        mc, mp,
        oc, op,
        md, mc4,
        od, oc4,
        me.cost_percent / 100.0,
        opp.cost_percent / 100.0,
        1.0 if me.cannon_discounted(g.turn) else 0.0,
        1.0 if opp.cannon_discounted(g.turn) else 0.0,
        1.0 if me.skip_turn == g.turn else 0.0,
        1.0 if opp.skip_turn == g.turn else 0.0,
        clamp(g.turn / 30.0, 0.0, 1.0),
    ]
