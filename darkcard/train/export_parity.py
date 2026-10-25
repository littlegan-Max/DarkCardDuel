"""导出对拍用例：同一批随机动作序列，供 GDScript 引擎重放比对。

任何一步的 hp / yun / shields / dots / cost_percent / over / winner 不一致，
就说明两个引擎在某条规则上分叉了。
"""

from __future__ import annotations

import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
from engine import DB, Game, PASS_ID  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(HERE, "..", "data", "cards.json")
OUT = os.path.join(HERE, "..", "tests", "parity_cases.json")

N_CASES = 400
MAX_STEPS = 60


from abstract import CHAINS  # noqa: E402


def snapshot(g: Game) -> dict:
    return {
        "hp": [g.p0.hp, g.p1.hp],
        "yun": [g.p0.yun, g.p1.yun],
        "shields": [g.p0.shields, g.p1.shields],
        "dots": [len(g.p0.dots), len(g.p1.dots)],
        "cost": [g.p0.cost_percent, g.p1.cost_percent],
        "over": g.over,
        "winner": g.winner,
        "turn": g.turn,
    }


CHAIN_CARD = ["jiang_long", "gui_pai", "kui_hua_bao_dian", "xiang_yun_kui",
              "zhan_shu_he_dan", "fei_long_zai_tian", "shen_zhi_gui_pai", "jiu_qia"]

# 定向对拍对：光靠随机很难撞到的牌对（新裁定落点 + 历史坑点）。
# 每对 (a, b) 是 (p0 出牌, p1 出牌)；命中时用第 0 步强制打出，其余步继续随机。
FOCUS_PAIRS = [
    # 裁定 1：龟派取牌（含连招/冷却/k 的后果）
    ("zhong_fang", "gui_pai"), ("wei_biao", "gui_pai"), ("yun", "gui_pai"),
    ("gui_pai", "gui_pai"), ("san_leng_jing", "gui_pai"), ("tao_tao", "gui_pai"),
    ("xiao_biao", "shen_zhi_gui_pai"), ("yun", "shen_zhi_gui_pai"),
    # 裁定 2/3：负运被吸、降龙/降飞被吸
    ("fu_yun", "xi"), ("jiang_long", "xi"), ("jiang_fei", "xi"),
    ("fu_yun", "chao_ji_xi"), ("wei_biao", "xi"),
    # 裁定 4：伤害比大小（含 dot 参与）
    ("xiao_biao", "xiao_biao"), ("chang_gong", "xiao_biao"),
    ("du_yao", "xiao_biao"), ("liu_shen", "chang_gong"),
    # 裁定 6/8：觉醒中防的新阻挡集合与反弹
    ("kai_sa", "jue_xing_zhong_fang"), ("liu_fei", "jue_xing_zhong_fang"),
    ("san_leng_jing", "jue_xing_zhong_fang"), ("bi_xin", "jue_xing_zhong_fang"),
    ("bi_shi", "jue_xing_zhong_fang"), ("tou_xi", "jue_xing_zhong_fang"),
    ("zhan_shu_he_dan", "jue_xing_zhong_fang"), ("chao_qia", "jue_xing_zhong_fang"),
    ("chang_gong_fen_san", "jue_xing_zhong_fang"),
    # 裁定 7：长攻分散 时空分散
    ("chang_gong_fen_san", "xi"), ("chang_gong_fen_san", "zhong_fang"),
    ("chang_gong_fen_san", "fu_yun"), ("chang_gong_fen_san", "chao_ji_xi"),
    # 裁定 9：向运葵的新可被列
    ("xiang_yun_kui", "xiao_biao"), ("xiang_yun_kui", "wei_biao"),
    ("xiang_yun_kui", "heng_sao_da_di"), ("xiang_yun_kui", "yun"),
    # 通用可被列（原本硬编码缺口的牌对）
    ("gua_sha", "jiu"), ("san_leng_jing", "xiao_biao"), ("ding_hai_shen_zhen", "shou_qiang"),
    ("ding_hai_shen_zhen", "kai_sa"), ("nao_gua_beng", "kai_sa"),
    ("heng_sao_da_di", "xiao_biao"), ("kui_hua_bao_dian", "xiao_biao"),
    ("yuan_shou", "xiao_biao"), ("jiu", "liu_shen"), ("zi_sha", "shan"),
    ("gou_hun", "shan"), ("c4", "xiao_biao"),
]


def setup_chain_state(g: Game, rng: random.Random, seed: int):
    """预置连招进度 / 高运 / 盾 / dot，逼出长连招牌与跨回合状态。"""
    chain_idx = (seed // 2) % len(CHAINS)
    chain = CHAINS[chain_idx]
    # 一半给完整连招（逼出长连招牌），一半给随机前缀
    cut = len(chain) if rng.random() < 0.5 else rng.randint(0, len(chain))
    g.p0.history = list(chain[:cut])
    g.turn = rng.choice([4, 5, 6, 8])
    # 负运 / 高运 / 深血 / 濒死都压进来
    g.p0.yun = rng.choice([-50, -20, 0, 10, 20, 30, 40, 50, 70, 70])
    g.p1.yun = rng.choice([-30, 0, 10, 20, 30, 40, 70])
    hp0 = rng.choice([20, 50, 100, 150, 250, 400, 900])
    hp1 = rng.choice([20, 100, 200, 300, 400, 700])
    g.p0.hp = g.p0.hp_max_ever = hp0
    g.p1.hp = g.p1.hp_max_ever = hp1
    g.p0.shields = rng.choice([0, 0, 1, 2, 3])
    g.p1.shields = rng.choice([0, 1, 2])
    if rng.random() < 0.35:
        for _ in range(rng.randint(1, 3)):
            g.p1.dots.append([20, rng.randint(1, 4), g.turn, 0, 0])
    if rng.random() < 0.2:
        g.p0.dots.append([300, 1, g.turn + rng.randint(1, 3), 1, 1])
    if rng.random() < 0.2:
        g.p0.cost_percent = 50
    info = {
        "turn": g.turn,
        "hp": [hp0, hp1],
        "yun": [g.p0.yun, g.p1.yun],
        "shields": [g.p0.shields, g.p1.shields],
        "history0": list(g.p0.history),
        "dots0": [list(d) for d in g.p0.dots],
        "dots1": [list(d) for d in g.p1.dots],
        "cost0": g.p0.cost_percent,
    }
    forced = CHAIN_CARD[chain_idx] if cut == len(chain) else None
    return info, forced


def focus_case(seed: int, pair: tuple[str, str]):
    """定向对拍：把双方连招补到位、给足运与深血，第 0 步强制打这一对。"""
    g = Game(db)
    rng = random.Random(seed)
    g.turn = rng.choice([5, 6])
    for k, cid in ((0, pair[0]), (1, pair[1])):
        c = db.cards[cid]
        if c.combo:
            g.player(k).history = list(c.combo)
    g.p0.yun = g.p1.yun = 100
    g.p0.hp = g.p0.hp_max_ever = 500
    g.p1.hp = g.p1.hp_max_ever = 500
    info = {
        "turn": g.turn,
        "hp": [g.p0.hp, g.p1.hp],
        "yun": [g.p0.yun, g.p1.yun],
        "shields": [0, 0],
        "history0": list(g.p0.history),
        "history1": list(g.p1.history),
        "dots0": [],
        "dots1": [],
        "cost0": 100,
    }
    return g, info


def run_case(seed: int) -> dict:
    rng = random.Random(seed)
    g = Game(db)
    init = None
    forced = None
    focus = None
    if seed % 4 == 0:
        focus = FOCUS_PAIRS[(seed // 4) % len(FOCUS_PAIRS)]
        g, init = focus_case(seed, focus)
    elif seed % 4 == 2:
        init, forced = setup_chain_state(g, rng, seed)
    steps = []
    for step_i in range(MAX_STEPS):
        if g.over:
            break
        la, lb = g.legal_cards(0), g.legal_cards(1)
        if not la or not lb:
            break
        a = la[rng.randrange(len(la))]
        if step_i == 0 and focus is not None and focus[0] in la:
            a = focus[0]
        b = lb[rng.randrange(len(lb))]
        if step_i == 0 and focus is not None and focus[1] in lb:
            b = focus[1]
        if step_i == 0 and forced is not None and forced in la:
            a = forced
        if not g.play_turn(a, b):
            steps.append({"error": f"rejected {a} vs {b}"})
            break
        steps.append({"a": a, "b": b, "legal": [list(la), list(lb)], "after": snapshot(g)})
    return {"seed": seed, "init": init, "steps": steps}


def main() -> None:
    n = int(sys.argv[1]) if len(sys.argv) > 1 else N_CASES
    global db
    db = DB(DB_PATH)
    cases = [run_case(1000 + i) for i in range(n)]
    total = sum(len(c["steps"]) for c in cases)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump({"cases": cases}, f, ensure_ascii=False)
    print(f"cases={len(cases)} steps={total} -> {os.path.basename(OUT)}")


db = DB(DB_PATH)

if __name__ == "__main__":
    main()
