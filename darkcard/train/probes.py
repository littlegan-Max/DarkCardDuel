"""6 个漏洞探针：直接检查策略在"规则自带的坑"上的表现。

每条探针同时报告"该状态是否被训练覆盖"——未覆盖时概率接近均匀，
看着"通过"其实是没学过，必须区分开。
"""

from __future__ import annotations

import os
import pickle
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from abstract import abstract  # noqa: E402
from engine import DB, Game, PASS_ID  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(HERE, "..", "data", "cards.json")

db_singleton = DB(DB_PATH)
results: list[tuple[str, bool, bool, str]] = []


class Policy:
    def __init__(self, db: DB, ckpt: dict):
        self.db = db
        self.S = ckpt["S"]
        self.index = {cid: i for i, cid in enumerate(db.order)}
        self.index[PASS_ID] = len(db.order)
        self.known = False

    def dist(self, g: Game, who: int) -> tuple[list[str], np.ndarray]:
        legal = g.legal_cards(who)
        if not legal:
            return [], np.array([])
        idx = [self.index[c] for c in legal]
        row = self.S.get(abstract(g, who))
        self.known = row is not None
        if row is None:
            return legal, np.full(len(legal), 1.0 / len(legal))
        pos = np.maximum(row[idx], 0.0)
        tot = pos.sum()
        if tot <= 0:
            return legal, np.full(len(legal), 1.0 / len(legal))
        return legal, pos / tot

    def p_of(self, g: Game, who: int, cid: str) -> float:
        legal, p = self.dist(g, who)
        return float(p[legal.index(cid)]) if cid in legal else 0.0


def new_game(turn: int = 5, yun0: int = 0, yun1: int = 0,
             hp0: int = 100, hp1: int = 100) -> Game:
    g = Game(db_singleton)
    g.turn = turn
    g.p0.yun, g.p1.yun = yun0, yun1
    g.p0.hp, g.p0.hp_max_ever = hp0, hp0
    g.p1.hp, g.p1.hp_max_ever = hp1, hp1
    return g


def run(pol: Policy) -> None:
    # 1 吸刷运：经济动作会不会被无脑吸吃干
    g = new_game(3, 10, 0)
    p = pol.p_of(g, 0, "yun") + pol.p_of(g, 0, "qiang_hua_yun")
    results.append(("吸刷运", p < 0.6, pol.known, f"经济动作合计 {p*100:.0f}%（>60% 会被吸克制）"))

    # 2 负运喂招：负运被吸自己扣 1 运
    g = new_game(4, 20, 0)
    p = pol.p_of(g, 0, "fu_yun")
    results.append(("负运喂招", p < 0.2, pol.known, f"出负运 {p*100:.0f}%（>20% 会被吸反打）"))

    # 3 三棱镜加伤：自己每出一张运，对手三棱镜 +0.3
    g = new_game(4, 30, 0)
    g.p1.history = ["yun", "yun"]
    p = pol.p_of(g, 0, "yun")
    results.append(("三棱镜加伤", p < 0.5, pol.known, f"对手已连出 2 运仍续运 {p*100:.0f}%"))

    # 4 连招暴露：核弹起手 4 手运，就绪却不补最后一手 = 白费
    g = new_game(7, 40, 0)
    g.p0.history = ["yun", "yun", "yun"]
    legal, _ = pol.dist(g, 0)
    p_yun = pol.p_of(g, 0, "yun")
    ok = ("zhan_shu_he_dan" not in legal) or p_yun > 0.35
    results.append(("连招暴露", ok, pol.known,
                    f"核弹就绪={('zhan_shu_he_dan' in legal)} 续运 {p_yun*100:.0f}%"))

    # 5 自杀送龟派：可预测的自杀会被龟派直接反杀
    g = new_game(5, 10, 0, hp0=30)
    p = pol.p_of(g, 0, "zi_sha")
    results.append(("自杀送龟派", p < 0.15, pol.known, f"残血时出自杀 {p*100:.0f}%"))

    # 6 盾幻觉：盾挡不住代码杀
    g = new_game(6, 40, 0, hp0=50)
    g.p0.shields = 3
    p = pol.p_of(g, 0, "dun")
    results.append(("盾幻觉", p < 0.3, pol.known, f"已 3 盾仍买盾 {p*100:.0f}%"))


def main() -> None:
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "policy.pkl")
    with open(path, "rb") as f:
        ckpt = pickle.load(f)
    db = DB(DB_PATH)
    pol = Policy(db, ckpt)
    run(pol)

    width = max(len(r[0]) for r in results)
    bad = 0
    unknown = 0
    for name, ok, known, detail in results:
        if not known:
            unknown += 1
            mark = "N/A "
        else:
            mark = "PASS" if ok else "FAIL"
        if not ok and known:
            bad += 1
        print(f"  [{mark}] {name.ljust(width)}  {detail}" + ("" if known else "  <- 状态未被训练覆盖"))

    print(f"\n{len(results)-bad-unknown}/{len(results)} passed, {unknown} uncovered")
    sys.exit(0 if bad == 0 else 1)


if __name__ == "__main__":
    main()
