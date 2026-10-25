"""导出 Python 侧的特征向量，供 GDScript 侧比对。

特征不一致 = 训练出来的策略进了游戏就是乱码，比"数值前向不一致"更隐蔽，
所以必须有一条跨语言的特征比对。
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from engine import DB, Game
from features import features, N_FEATURES

HERE = os.path.dirname(os.path.abspath(__file__))
db = DB(os.path.join(HERE, "..", "data", "cards.json"))
g = Game(db)
g.turn = 5
g.p0.yun, g.p1.yun = 30, 10
g.p0.hp, g.p0.hp_max_ever = 250, 250
g.p1.hp, g.p1.hp_max_ever = 200, 200
g.p0.history = ["zhong_fang", "xi", "yun"]
g.p1.history = ["yun"]
g.p0.shields, g.p1.shields = 1, 0
g.p0.last_played = {"zhong_fang": 1, "yun": 2}
g.p1.last_played = {"yun": 1}

f0 = features(g, 0)
f1 = features(g, 1)
out = {
    "n_features": N_FEATURES,
    "state": {
        "turn": 5, "yun0": 30, "yun1": 10, "hp0": 250, "hp1": 200,
        "shields0": 1, "shields1": 0,
        "history0": ["zhong_fang", "xi", "yun"], "history1": ["yun"],
    },
    "features_p0": [round(float(x), 6) for x in f0],
    "features_p1": [round(float(x), 6) for x in f1],
}
p = os.path.join(HERE, "..", "tests", "features_ref.json")
json.dump(out, open(p, "w", encoding="utf-8"), ensure_ascii=False)
print(f"wrote {p}  N_FEATURES={N_FEATURES}")
print("p0:", out["features_p0"])
print("p1:", out["features_p1"])
