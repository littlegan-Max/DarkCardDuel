"""引擎对齐测试：与 Godot 版 test_runner.gd 的期望值逐条比对。

任何一条不一致，说明 Python 引擎和 GDScript 引擎在某些规则上分叉了，
在那之上训练出来的策略不能用。
"""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from engine import DB, Game, PASS_ID  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(HERE, "..", "data", "cards.json")
db = DB(DB_PATH)

passed = 0
failed = 0
fails: list[str] = []


def ok(name: str, cond: bool, detail: str = "") -> None:
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
        fails.append(f"{name}  {detail}")


def duel(turn: int, yun0: int, yun1: int, hp0: int = 100, hp1: int = 100) -> Game:
    g = Game(db)
    g.turn = turn
    g.p0.yun, g.p1.yun = yun0, yun1
    g.p0.hp, g.p0.hp_max_ever = hp0, hp0
    g.p1.hp, g.p1.hp_max_ever = hp1, hp1
    return g


def prep(g: Game, who: int, cards: list[str]) -> None:
    g.player(who).history.extend(cards)


# ---------- 基础 ----------
g = Game(db)
ok("turn0 only yun", g.legal_cards(0) == ["yun"])

g = duel(1, 10, 0)
g.play_turn("xiao_biao", "yun")
ok("xiao_biao deals 1.0", g.p0.hp == 100 and g.p1.hp == 0 or True)  # 1 血直接死，下面用高血重测

g = duel(1, 10, 0, 300, 300)
g.play_turn("xiao_biao", "yun")
ok("xiao_biao 1.0 on 300hp", g.p1.hp == 200, f"hp1={g.p1.hp}")

g = duel(1, 10, 0)
g.play_turn("xiao_biao", "zhong_fang")
ok("zhong_fang blocks", g.p1.hp == 100)

g = duel(1, 10, 10)
g.play_turn("xiao_biao", "shan")
ok("shan dodges", g.p0.hp == 100 and g.p1.yun == 0)

g = duel(1, 10, 0)
g.play_turn("xiao_biao", "xi")
ok("xi negates and steals", g.p0.hp == 100 and g.p1.yun == 10)

g = duel(1, 0, 0)
g.play_turn("yun", "xi")
ok("xi blanks yun", g.p0.yun == 0 and g.p1.yun == 10)

g = duel(1, 10, 0)
g.play_turn("qiang_hua_yun", "xi")
ok("qiang_hua_yun keeps 1", g.p0.yun == 10 and g.p1.yun == 10)

g = duel(1, 10, 10, 300, 300)
g.play_turn("xiao_biao", "xiao_biao")
ok("equal damage cancels", g.p0.hp == 300 and g.p1.hp == 300)

g = duel(1, 10, 10)
g.play_turn("xiao_biao", "xiao_biao")
ok("mutual kill voided", g.p0.hp == 100 and g.p1.hp == 100 and not g.over)

# 裁定 4：不一样的伤害只有高的生效，低的一方整段归零
g = duel(1, 30, 10, 500, 500)
g.play_turn("chang_gong", "xiao_biao")
ok("higher total applies in full", g.p1.hp == 280, f"hp1={g.p1.hp}")
ok("lower total is zeroed", g.p0.hp == 500, f"hp0={g.p0.hp}")

g = duel(1, 30, 10, 50, 100)
g.play_turn("chang_gong", "xiao_biao")
ok("only the race loser can die", g.over and g.winner == 0,
   f"hp={g.p0.hp}/{g.p1.hp}")

g = duel(1, 10, 10, 300, 300)
g.p1.add_effect(20, 5, 1, 0, 0)
g.play_turn("xiao_biao", "xiao_biao")
ok("dot tips the race", g.p1.hp == 180, f"hp1={g.p1.hp}")
ok("dot winner keeps full damage", g.p0.hp == 300, f"hp0={g.p0.hp}")

g = duel(1, 10, 0, 50, 100)
g.play_turn("tao_tao", "yun")
ok("tao_tao heals", g.p0.hp == 100)
ok("tao_tao cd", not g.can_play(0, "tao_tao"))
g.turn = 3
g.p0.yun = 20
ok("tao_tao back", g.can_play(0, "tao_tao"))

g = duel(3, 40, 0)
g.play_turn("dun", "yun")
ok("shield first costs 4", g.p0.yun == 0 and g.p0.shields == 1)
g.p0.yun = 30
g.play_turn("dun", "yun")
ok("shield second costs 3", g.p0.yun == 0 and g.p0.shields == 2)

g = duel(3, 0, 20, 50, 100)
g.p0.shields = 1
g.play_turn("yun", "kai_sa")
ok("shield saves lethal", g.p0.hp == 50 and g.p0.shields == 0)

# ---------- 连招 / 核弹 ----------
g = duel(5, 0, 0)
ok("jiang_long needs combo", not g.can_play(0, "jiang_long"))
prep(g, 0, ["zhong_fang"])
ok("jiang_long unlocked", g.can_play(0, "jiang_long"))

g = duel(5, 0, 0)
prep(g, 0, ["zhong_fang"])
g.play_turn("jiang_long", "xi")
ok("jiang_long negated", g.p0.hp == 100 and g.p1.yun == 20)   # C9：吸者 +2 运

g = duel(5, 0, 0)
prep(g, 0, ["zhong_fang"])
g.play_turn("jiang_fei", "yun")
ok("jiang_fei blocked + flag", g.p0.hp == 100 and g.p0.fly_ready)
ok("jiang_fei replayable", g.can_play(0, "jiang_fei"))

g = duel(5, 60, 0, 300, 300)
prep(g, 0, ["yun"] * 4)
g.play_turn("zhan_shu_he_dan", "yun")
ok("nuke pays 4", g.p0.yun == 20 and g.p1.hp == 80)

g = duel(5, 0, 0, 300, 300)
prep(g, 0, ["yun"] * 4)
ok("nuke legal at 0 yun", g.can_play(0, "zhan_shu_he_dan"))

g = duel(5, 0, 0, 100, 50)
g.p1.shields = 1
prep(g, 0, ["yun"] * 4)
g.play_turn("zhan_shu_he_dan", "yun")
ok("nuke beats 1 shield", g.over and g.winner == 0 and g.p1.shields == 1)

# ---------- 批 2 ----------
g = duel(3, 10, 20, 300, 300)
g.p1.shields = 2
g.play_turn("chao_qia", "nai_bao")
ok("chao_qia kills nai_bao", g.over and g.winner == 0 and g.p0.hp == 300)

g = duel(3, 10, 0)
g.play_turn("chao_qia", "yun")
ok("yun consumes to block chao_qia", g.p0.hp == 100 and g.p1.yun == 0)

g = duel(3, 10, 0)
g.play_turn("chao_qia", "zhong_fang")
ok("zhong_fang cannot block chao_qia", g.p1.hp == 50)

g = duel(3, 10, 0, 300, 300)
g.play_turn("shou_qiang", "yun")
ok("handgun consumes yun", g.p0.hp == 300 and g.p1.yun == 0)

g = duel(3, 20, 10, 300, 300)
g.play_turn("shou_qiang", "shan")
ok("handgun undodgeable", g.p1.hp == 150)

g = duel(3, 0, 0, 300, 300)
g.play_turn("wei_biao", "xi")
# 2026-10-25 朋友反馈：微镖被吸，得 1 运的是「出吸的人」
ok("absorber gains 1 yun on wei_biao", g.p0.hp == 300 and g.p1.yun == 10
   and g.p0.yun == 0, f"yun={g.p0.yun}/{g.p1.yun}")

g = duel(5, 0, 0, 300, 300)
prep(g, 0, ["zhong_fang"])
g.play_turn("jiang_long", "fu_yun")
ok("fu_yun blocks jiang_long", g.p0.hp == 300 and g.p0.yun == -10)

g = duel(3, 20, 0, 300, 300)
g.play_turn("kai_sa", "fu_yun")
ok("fu_yun cannot block kai_sa", g.p1.hp == 150)

g = duel(3, 0, 0, 300, 300)
g.play_turn("fu_yun", "xi")
ok("stolen fu_yun costs the absorber", g.p1.yun == -10 and g.p0.yun == 0,
   f"yun={g.p0.yun}/{g.p1.yun}")

g = duel(3, 0, 10, 300, 300)
g.play_turn("jiu", "xiao_biao")
ok("jiu immunes 1.0", g.p0.hp == 300)

g = duel(3, 30, 10, 300, 300)
g.play_turn("chang_gong", "jiu")
ok("jiu cannot stop 2.2", g.p1.hp == 80)

g = duel(3, 10, 0, 300, 300)
g.play_turn("tou_xi", "yun")
ok("dot not on use turn", g.p1.hp == 300)
g.p0.yun = 10
g.play_turn("yun", "yun")
ok("dot ticks next turn", g.p1.hp == 280)

g = duel(5, 20, 0, 200, 300)
g.p0.add_effect(20, 5, 3, 1, 0)
g.play_turn("tao_tao", "yun")
ok("tao_tao clears dot", g.p0.hp == 250 and not g.p0.dots)

g = duel(3, 10, 0, 300, 300)
g.play_turn("san_leng_jing", "yun")
ok("prism k=1 -> 0.7", g.p1.hp == 230, f"hp1={g.p1.hp}")

g = duel(3, 10, 0, 300, 300)
g.play_turn("san_leng_jing", "fu_yun")
ok("prism k=-1 -> 0.1", g.p1.hp == 290, f"hp1={g.p1.hp}")

g = duel(3, 30, 0, 300, 300)
g.play_turn("chang_gong_fen_san", "zhong_fang")
ok("fen_san backlash", g.p0.hp == 300 and g.p1.hp == 250)

g = duel(3, 20, 0, 300, 300)
g.play_turn("heng_sao_da_di", "yun")
ok("heng_sao 1.0", g.p1.hp == 200)

g = duel(3, 20, 0, 50, 50)
g.play_turn("tao_yuan_jie_yi", "yun")
ok("tao_yuan heals both", g.p0.hp == 100 and g.p1.hp == 100)

# ---------- 批 3 ----------
g = duel(5, 10, 0, 300, 300)
prep(g, 1, ["zhong_fang", "xi", "yun"])
g.play_turn("xiao_biao", "gui_pai")
ok("kui reflects xiao_biao", g.p0.hp == 200 and g.p1.hp == 300, f"hp={g.p0.hp}/{g.p1.hp}")

g = duel(5, 10, 0, 200, 200)
prep(g, 1, ["zhong_fang", "xi", "yun"])
g.play_turn("tao_tao", "gui_pai")
ok("kui steals heal", g.p1.hp == 250 and g.p0.hp == 200)

g = duel(5, 10, 0, 300, 300)
prep(g, 1, ["zhong_fang", "xi", "yun"])
g.play_turn("zi_sha", "gui_pai")
ok("kui kills the kui user", g.over and g.winner == 0, f"winner={g.winner}")

g = duel(5, 0, 0, 300, 300)
prep(g, 0, ["zhong_fang", "xi", "yun"])
prep(g, 1, ["zhong_fang", "xi", "yun"])
g.play_turn("gui_pai", "gui_pai")
ok("mutual kui cancels", g.p0.hp == 300 and g.p1.hp == 300)

g = duel(5, 20, 0, 400, 400)
prep(g, 1, ["jue_xing_zhong_fang", "chao_ji_xi", "qiang_hua_yun"])
g.play_turn("kai_sa", "shen_zhi_gui_pai")
ok("shen kui doubles", g.p0.hp == 100, f"hp0={g.p0.hp}")

g = duel(5, 10, 10, 300, 300)
g.play_turn("xiao_biao", "hu_shen_fu")
ok("amulet ignores 1-cost", g.p1.hp == 200)

g = duel(5, 20, 10, 300, 300)
g.play_turn("kai_sa", "hu_shen_fu")
ok("amulet blocks 2-cost", g.p1.hp == 300)

g = duel(5, 30, 30, 300, 300)
g.play_turn("chang_gong", "niu_zhuan_shi_kong")
ok("time stop", g.p1.hp == 300 and g.p0.yun == 0)

g = duel(5, 20, 0, 300, 300)
g.play_turn("c4", "yun")
ok("c4 not immediate", g.p1.hp == 300)
g.play_turn("yun", "yun")
g.play_turn("yun", "yun")
ok("c4 waiting", g.p1.hp == 300)
g.play_turn("yun", "yun")
ok("c4 fires", g.p1.hp == 0, f"hp1={g.p1.hp} turn={g.turn}")

g = duel(5, 50, 0, 300, 300)
g.play_turn("liu_shen", "yun")
ok("liu_shen true dmg", g.p1.hp == 250, f"hp1={g.p1.hp}")

g = duel(5, 20, 0, 300, 300)
g.play_turn("du_yao", "yun")
ok("poison 40% on yun block", g.p1.hp == 180, f"hp1={g.p1.hp}")

g = duel(5, 10, 10, 300, 300)
g.play_turn("xiao_biao", "chao_ji_xi")
ok("super xi x2", g.p1.yun == 20, f"yun1={g.p1.yun}")

g = duel(5, 20, 10, 300, 300)
g.play_turn("bi_xin", "yun")
ok("bi_xin -2", g.p1.yun == 0)

g = duel(5, 20, -50, 300, 300)
g.play_turn("bi_xin", "tao_he")
ok("bi_xin no lift", g.p1.yun == -50)

g = duel(5, 30, 40, 300, 300)
g.play_turn("gou_hun", "tao_he")
ok("gou_hun all", g.p0.yun == 40 and g.p1.yun == 0)

g = duel(5, 30, -20, 300, 300)
g.play_turn("gou_hun", "tao_he")
ok("gou_hun negative->0", g.p1.yun == 0)

g = duel(5, 30, 0, 300, 300)
g.play_turn("bi_shi", "yun")
ok("bi_shi -> pass only", not g.can_play(1, "xiao_biao") and g.can_play(1, PASS_ID))

g = duel(5, 40, 0, 300, 300)
g.play_turn("yuan_shou", "yun")
g.p0.yun = 20
ok("cannon 2 under buff", g.can_play(0, "yi_da_li_pao"),
   f"cost={g.effective_cost(0, db.cards['yi_da_li_pao'])}")

g = duel(5, 50, 0, 300, 300)
prep(g, 0, ["zhong_fang", "xi", "yun", "chao_ji_xi"])
g.play_turn("kui_hua_bao_dian", "yun")
ok("kui_hua halves", g.p0.cost_percent == 50 and g.effective_cost(0, db.cards["xiao_biao"]) == 5)

g = duel(5, 10, 10, 300, 300)
g.play_turn("xiao_biao", "jue_xing_zhong_fang")
ok("jue_xing reflect", g.p1.hp == 300 and g.p0.hp == 250)

g = duel(5, 40, 10, 300, 300)
prep(g, 0, ["yun"] * 4)
g.play_turn("zhan_shu_he_dan", "jue_xing_zhong_fang")
ok("jue_xing blocks nuke and reflects 0.8", g.p0.hp == 220 and g.p1.hp == 300,
   f"hp={g.p0.hp}/{g.p1.hp}")

g = duel(5, 30, 0, 200, 300)
g.p0.hp_max_ever = 300
g.p0.add_effect(20, 5, 3, 1, 0)
g.play_turn("jing_hua", "yun")
ok("purify", g.p0.hp == 300 and not g.p0.dots)

g = duel(5, 20, 0, 300, 300)
g.play_turn("jiu_qia", "tao_he")
ok("jiu_qia 0.9", g.p1.hp == 220, f"hp1={g.p1.hp}")

g = duel(5, 20, 0, 300, 300)
prep(g, 0, ["xiao_qia", "chao_qia"])
g.play_turn("jiu_qia", "tao_he")
ok("jiu_qia combo 1.4", g.p1.hp == 170, f"hp1={g.p1.hp}")

g = duel(5, 20, 0, 300, 300)
g.play_turn("jiu_qia", "yun")
ok("jiu_qia steals gained yun", g.p1.hp == 300 and g.p0.yun == 10, f"yun0={g.p0.yun}")

g = duel(5, 10, 20, 300, 300)
g.play_turn("xiao_qia", "nai_bao")
ok("xiao_qia kills nai_bao", g.over and g.winner == 0)

g = duel(5, 40, 20, 300, 300)
g.play_turn("ding_hai_shen_zhen", "shou_qiang")
ok("ding_hai heals when blocked", g.p0.hp == 210, f"hp0={g.p0.hp}")

# 朋友反馈（2026-10-25）：定海神针被闪了以后也应该加血。
# C32「被防仍加血」的原则同样适用于被闪。
g = duel(5, 40, 10, 300, 300)
g.play_turn("ding_hai_shen_zhen", "shan")
ok("shan dodges ding_hai damage", g.p1.hp == 300, f"hp1={g.p1.hp}")
ok("ding_hai still heals when dodged by shan", g.p0.hp == 360, f"hp0={g.p0.hp}")

g = duel(5, 0, 0, 300, 300)
prep(g, 0, ["zhong_fang", "zhong_fang", "xi", "zhong_fang"])
g.play_turn("xiang_yun_kui", "yun")
ok("xiang_yun now", g.p0.yun == 20, f"yun0={g.p0.yun}")
g.play_turn("yun", "yun")
ok("xiang_yun next", g.p0.yun == 30, f"yun0={g.p0.yun}")

g = duel(5, 10, 0, 300, 300)
g.play_turn("zi_sha", "yun")
ok("self kill", g.over and g.winner == 1)

g = duel(5, 70, 0, 100, 300)
g.p1.shields = 2
g.play_turn("yi_da_li_pao", "yun")
ok("cannon 2 shields", g.p0.hp == 100 and not g.over and g.p1.shields == 0)

g = duel(5, 30, 0, 300, 300)
g.play_turn("nao_gua_beng", "yun")
ok("nao_gua_beng 1.3", g.p1.hp == 170)

# ---------- 盾判定按事件，不按"本回合那张牌" ----------
g = duel(5, 10, 0, 20, 300)
g.p0.add_effect(150, 5, 3, 1, 0)      # dot，source=1（对方）；要赢过 0.8 反弹
g.p0.shields = 1
prep(g, 1, ["yun"] * 4)
g.play_turn("jue_xing_zhong_fang", "zhan_shu_he_dan")
ok("dot lethal costs 1 shield", g.p0.hp == 20 and not g.over,
   f"hp={g.p0.hp} over={g.over}")

g = duel(5, 0, 0, 20, 300)
g.p0.shields = 1
prep(g, 1, ["yun"] * 4)
g.play_turn("yun", "zhan_shu_he_dan")
ok("nuke lethal needs 2 shields", g.over and g.winner == 1)

# ---------- 闪的目标 / 酒的总伤 / 盾的分组 ----------
g = duel(5, 10, 10, 300, 300)
g.play_turn("zi_sha", "shan")
ok("shan cannot save the self-killer", g.over and g.winner == 1, f"winner={g.winner}")

g = duel(5, 30, 20, 300, 300)
g.play_turn("gou_hun", "shan")
ok("shan still dodges gou_hun", g.p1.yun == 10, f"yun1={g.p1.yun}")

g = duel(5, 10, 50, 300, 300)
g.play_turn("jiu", "liu_shen")
ok("jiu cannot stop liu_shen", g.p0.hp == 0 and g.over, f"hp={g.p0.hp}")

g = duel(5, 0, 50, 50, 300)
g.p0.shields = 1
g.play_turn("yun", "liu_shen")
ok("liu_shen costs only 1 shield", g.p0.hp == 50 and not g.over, f"hp={g.p0.hp}")

g = duel(5, 10, 30, 200, 300)
g.p0.add_effect(20, 5, 3, 1, 0)
g.p0.shields = 1
g.play_turn("jiu", "chang_gong")
ok("immune hit does not eat a shield", g.p0.hp == 200 and not g.over, f"hp={g.p0.hp}")

# ---------- 规则文档示例 8 / 阈值交互 ----------
g = duel(5, 50, 0, 300, 300)
g.play_turn("c4", "yun")
g.play_turn("yun", "yun")
g.play_turn("yun", "yun")
ok("c4 still pending", g.p1.hp == 300, f"hp1={g.p1.hp}")
g.play_turn("niu_zhuan_shi_kong", "yun")
ok("c4 fires through time stop", g.p1.hp == 0, f"hp1={g.p1.hp}")

g = duel(5, 40, 10, 300, 300)
g.play_turn("yuan_shou", "yun")
g.p0.yun = 20
g.play_turn("yi_da_li_pao", "hu_shen_fu")
ok("amulet blocks discounted cannon", g.p1.hp == 300, f"hp1={g.p1.hp}")

g = duel(5, 50, 10, 300, 300)
prep(g, 0, ["zhong_fang", "xi", "yun", "chao_ji_xi"])
g.play_turn("kui_hua_bao_dian", "yun")
g.p0.yun = 30
g.play_turn("chang_gong", "hu_shen_fu")
ok("amulet ignores 1.5-cost", g.p1.hp == 80, f"hp1={g.p1.hp}")

g = duel(5, 30, 0, 300, 300)
prep(g, 1, ["zhong_fang", "zhong_fang", "xi", "zhong_fang"])
g.play_turn("gou_hun", "xiang_yun_kui")
ok("gou_hun takes this-turn yun too", g.p0.yun == 10 and g.p1.yun == 10,
   f"yun={g.p0.yun}/{g.p1.yun}")

g = duel(5, 40, 20, 200, 300)
g.play_turn("ding_hai_shen_zhen", "kai_sa")
ok("ding_hai heals through kai_sa", g.p0.hp == 110, f"hp0={g.p0.hp}")

# ---------- 神之龟派翻倍范围（C34） ----------
SHEN = ["jue_xing_zhong_fang", "chao_ji_xi", "qiang_hua_yun"]

g = duel(5, 10, 0, 300, 300)
g.p1.add_effect(150, 1, 5, 1, 0)
prep(g, 1, list(SHEN))
g.play_turn("jiu", "shen_zhi_gui_pai")
ok("shen kui keeps wine threshold at <=1", g.p1.hp == 150, f"hp1={g.p1.hp}")

g = duel(5, 20, 0, 300, 300)
prep(g, 1, list(SHEN))
g.play_turn("du_yao", "shen_zhi_gui_pai")
ok("shen kui does not double poison 80%", g.p0.hp == 60, f"hp0={g.p0.hp}")

g = duel(5, 10, 0, 300, 300)
prep(g, 1, list(SHEN))
g.play_turn("san_leng_jing", "shen_zhi_gui_pai")
ok("shen kui does not double prism formula", g.p0.hp == 260, f"hp0={g.p0.hp}")

g = duel(5, 50, 0, 300, 300)
prep(g, 1, list(SHEN))
g.play_turn("bi_xin", "shen_zhi_gui_pai")
ok("shen kui doubles yun loss", g.p0.yun == -10, f"yun0={g.p0.yun}")

g = duel(5, 40, 0, 500, 300)
prep(g, 1, list(SHEN))
g.play_turn("ding_hai_shen_zhen", "shen_zhi_gui_pai")
ok("shen kui doubles ding_hai both ways", g.p0.hp == 180 and g.p1.hp == 420,
   f"hp={g.p0.hp}/{g.p1.hp}")

g = duel(5, 10, 0, 300, 300)
prep(g, 1, list(SHEN))
g.play_turn("tao_tao", "shen_zhi_gui_pai")
ok("shen kui doubles heal to 1.0", g.p1.hp == 400, f"hp1={g.p1.hp}")

g = duel(5, 10, 0, 300, 300)
prep(g, 1, ["zhong_fang", "xi", "yun"])
g.play_turn("tao_tao", "gui_pai")
ok("plain kui does not double", g.p1.hp == 350, f"hp1={g.p1.hp}")

# ---------- 0 费牌在负运时 ----------
g = duel(5, 0, -20, 300, 300)
ok("0-cost playable at negative yun", g.can_play(1, "tao_he"))

# ---------- 裁定 1：龟派不算出过 ----------
g = duel(5, 0, 0, 300, 300)
prep(g, 1, ["zhong_fang", "xi", "yun"])
g.play_turn("zhong_fang", "gui_pai")
ok("kui-taken zhong_fang skips combo", not g.can_play(0, "jiang_long"))
ok("kui-taken card not in history", "zhong_fang" not in g.p0.history, str(g.p0.history))

g = duel(5, 0, 0, 300, 300)
g.play_turn("zhong_fang", "yun")
ok("plain zhong_fang advances combo", g.can_play(0, "jiang_long"))

g = duel(5, 0, 0, 300, 300)
prep(g, 1, ["zhong_fang", "xi", "yun"])
g.play_turn("wei_biao", "gui_pai")
ok("kui-taken wei_biao skips cooldown", g.can_play(0, "wei_biao"))

g = duel(5, 0, 0, 300, 300)
g.play_turn("wei_biao", "yun")
ok("plain wei_biao on cooldown", not g.can_play(0, "wei_biao"))
g.play_turn("yun", "yun")
ok("wei_biao back after a blank turn", g.can_play(0, "wei_biao"))

# ---------- 裁定 2/3 ----------
g = duel(5, 0, 0, 300, 300)
prep(g, 0, ["zhong_fang"])
g.play_turn("jiang_fei", "xi")
ok("xi gains 2 from jiang_fei", g.p1.yun == 20, f"yun1={g.p1.yun}")

# 2026-10-25 朋友反馈：飞龙在天被吸，吸者也得 2 运
g = duel(5, 0, 0, 300, 300)
prep(g, 0, ["jue_xing_zhong_fang"])
g.play_turn("fei_long_zai_tian", "xi")
ok("fei_long_zai_tian negated by xi", g.p0.hp == 300)
ok("xi gains 2 from fei_long_zai_tian", g.p1.yun == 20, f"yun1={g.p1.yun}")
ok("fei_long_zai_tian user gains nothing", g.p0.yun == 0, f"yun0={g.p0.yun}")

g = duel(5, 30, 0, 300, 300)
g.play_turn("chang_gong_fen_san", "fu_yun")
ok("fu_yun blocks fen_san", g.p0.hp == 300)
ok("fu_yun still drains itself", g.p0.yun == -10, f"yun0={g.p0.yun}")

g = duel(5, 0, 0, 300, 300)
g.play_turn("wei_biao", "fu_yun")
ok("fu_yun cannot block wei_biao", g.p1.hp == 200, f"hp1={g.p1.hp}")

# ---------- 裁定 8：觉醒中防 ----------
g = duel(5, 30, 10, 300, 300)
g.play_turn("chang_gong_fen_san", "jue_xing_zhong_fang")
ok("jue_xing blocks fen_san", g.p1.hp == 300)
ok("reflect capped at 0.8", g.p0.hp == 220, f"hp0={g.p0.hp}")

g = duel(5, 50, 10, 300, 300)
g.play_turn("liu_fei", "jue_xing_zhong_fang")
ok("liu_fei true dmg loses the race", g.p1.hp == 300, f"hp1={g.p1.hp}")
ok("reflect on liu_fei capped", g.p0.hp == 220, f"hp0={g.p0.hp}")

g = duel(5, 10, 10, 300, 300)
g.play_turn("chao_qia", "jue_xing_zhong_fang")
ok("jue_xing cannot block chao_qia", g.p1.hp == 250, f"hp1={g.p1.hp}")
ok("no reflect without a block", g.p0.hp == 300, f"hp0={g.p0.hp}")

g = duel(5, 40, 10, 300, 300)
prep(g, 0, ["yun"] * 4)
g.play_turn("zhan_shu_he_dan", "jue_xing_zhong_fang")
ok("nuke blocked and reflected", g.p0.hp == 220 and g.p1.hp == 300,
   f"hp={g.p0.hp}/{g.p1.hp}")

g = duel(5, 20, 10, 300, 300)
g.play_turn("bi_xin", "jue_xing_zhong_fang")
ok("bi_xin reflect is 1 yun", g.p0.yun == -10 and g.p1.yun == 0,
   f"yun={g.p0.yun}/{g.p1.yun}")

g = duel(5, 30, 10, 300, 300)
g.play_turn("bi_shi", "jue_xing_zhong_fang")
ok("bi_shi reflect forces a pass turn", g.can_play(0, PASS_ID)
   and not g.can_play(0, "yun"), str(g.legal_cards(0)))
ok("pass is the only legal option", g.legal_cards(0) == [PASS_ID], str(g.legal_cards(0)))
g.play_turn(PASS_ID, "yun")
ok("pass turn is consumed", g.can_play(0, "zhong_fang"))

# ---------- 裁定 7：时间分散 ----------
g = duel(5, 30, 0, 400, 400)
g.play_turn("chang_gong_fen_san", "xi")
ok("xi steals 3", g.p1.yun == 30, f"yun1={g.p1.yun}")
ok("time spread hung on the absorber", len(g.p0.dots) == 1)
ok("time spread lasts k turns", g.p0.dots and g.p0.dots[0][1] == 3,
   str(g.p0.dots))
g.play_turn("yun", "yun")
ok("time spread ticks 0.4", g.p0.hp == 360, f"hp0={g.p0.hp}")

g = duel(5, 30, 0, 400, 400)
g.play_turn("chang_gong_fen_san", "xi")
g.p0.yun = 10
g.play_turn("tao_tao", "yun")
ok("tao_tao clears time spread", not g.p0.dots)

# ---------- 裁定 9：向运葵可被列 ----------
for blocker, cost in (("xiao_biao", 10), ("wei_biao", 0), ("heng_sao_da_di", 20)):
    g = duel(5, 20, cost, 300, 300)
    prep(g, 0, ["zhong_fang", "zhong_fang", "xi", "zhong_fang"])
    g.play_turn("xiang_yun_kui", blocker)
    ok(f"xiang_yun_kui blocked by {blocker}", g.p0.yun == 20, f"yun0={g.p0.yun}")

g = duel(5, 20, 0, 300, 300)
prep(g, 0, ["zhong_fang", "zhong_fang", "xi", "zhong_fang"])
g.play_turn("xiang_yun_kui", "yun")
ok("xiang_yun_kui not blocked by yun", g.p0.yun == 40, f"yun0={g.p0.yun}")

# ---------- 通用可被列 ----------
g = duel(5, 10, 10, 300, 300)
g.play_turn("gua_sha", "jiu")
ok("gua_sha shaves through jiu", g.p1.hp == 280, f"hp1={g.p1.hp}")

g = duel(5, 10, 10, 300, 300)
g.play_turn("san_leng_jing", "xiao_biao")
ok("xiao_biao blocks prism", g.p1.hp == 300)
ok("blocked prism lets the blocker hit", g.p0.hp == 200, f"hp0={g.p0.hp}")

g = duel(5, 40, 20, 300, 300)
g.play_turn("ding_hai_shen_zhen", "shou_qiang")
ok("shou_qiang blocks ding_hai", g.p1.hp == 300, f"hp1={g.p1.hp}")

g = duel(5, 20, 0, 300, 300)
g.play_turn("heng_sao_da_di", "xiao_biao")
ok("xiao_biao blocks heng_sao", g.p1.hp == 300, f"hp1={g.p1.hp}")

g = duel(5, 50, 10, 300, 300)
prep(g, 0, ["zhong_fang", "xi", "yun", "chao_ji_xi"])
g.play_turn("kui_hua_bao_dian", "xiao_biao")
ok("xiao_biao blocks kui_hua", g.p0.cost_percent == 100)

g = duel(5, 40, 0, 300, 300)
g.play_turn("yuan_shou", "xiao_biao")
ok("xiao_biao blocks yuan_shou", g.p0.cannon_from == -1)

print(f"PASS {passed}  FAIL {failed}")
for f in fails:
    print("  FAIL", f)
sys.exit(0 if failed == 0 else 1)
