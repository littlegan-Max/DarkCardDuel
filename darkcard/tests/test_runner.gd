extends SceneTree

# headless 规则用例：godot --headless --path <proj> --script res://tests/test_runner.gd

var db: CardDB
var passed := 0
var failed := 0


func _initialize() -> void:
    db = CardDB.load_all()
    print("cards=%d  rules=%s" % [db.size(), db.rules_version])
    if db.size() != 50:
        printerr("expected 50 cards, got %d" % db.size())
        quit(1)
        return

    _test_card_data()
    _test_legality()
    _test_counter()
    _test_xi()
    _test_damage()
    _test_heal_cd()
    _test_shield()
    _test_combo()
    _test_nuke()
    _test_death()
    _test_batch2()
    _test_batch3()
    _test_batch4()
    _test_kui_table()
    _test_kui_scale()
    _test_ai()

    print("PASS %d  FAIL %d" % [passed, failed])
    quit(0 if failed == 0 else 1)


func _ok(name: String, cond: bool, detail: String = "") -> void:
    if cond:
        passed += 1
        print("  ok    " + name)
    else:
        failed += 1
        printerr("  FAIL  " + name + ("  " + detail if detail != "" else ""))


func _duel(turn_index: int, yun0: int, yun1: int, hp0: int = 100, hp1: int = 100) -> Duel:
    var d := Duel.new(db)
    d.state.turn = turn_index
    var p0 := d.state.players[0]
    var p1 := d.state.players[1]
    p0.yun = yun0
    p0.hp = hp0
    p0.hp_max_ever = hp0
    p1.yun = yun1
    p1.hp = hp1
    p1.hp_max_ever = hp1
    return d


func _test_card_data() -> void:
    print("[card data]")
    var known_ops := ["DMG", "TRUE_DMG", "PRC_DMG", "HEAL", "HEAL_ALL", "YUN_ADD",
        "YUN_ENEMY", "YUN_STEAL_ALL", "YUN_MINUS", "SHIELD_ADD", "CODE_KILL",
        "SELF_CODE_KILL", "DOT", "DELAY_DMG", "IMMUNE_LE", "IMMUNE_COST_RANGE",
        "PRISM", "COST_HALF", "SCHEDULE_YUN", "CANNON_DISCOUNT", "SKIP_NEXT",
        "NEGATE_ALL", "REFLECT", "DOT_CLEAR_MAX_HP", "KUI"]
    var refs_ok := true
    var ops_ok := true
    var cost_ok := true
    for cid in db.order:
        var d := db.get_def(cid)
        for c in d.countered_by:
            if not db.has_card(c):
                refs_ok = false
                printerr("    missing counter ref: %s -> %s" % [cid, c])
        for c in d.combo:
            if not db.has_card(c):
                refs_ok = false
                printerr("    missing combo ref: %s -> %s" % [cid, c])
        for op in d.ops:
            if not known_ops.has(str(op.get("op", ""))):
                ops_ok = false
                printerr("    unknown op: %s in %s" % [str(op.get("op", "")), cid])
        if d.cost % 5 != 0:
            cost_ok = false
            printerr("    cost not 0.5 step: %s = %d" % [cid, d.cost])
    _ok("all countered_by / combo refs resolve", refs_ok)
    _ok("all ops are known", ops_ok)
    _ok("all costs are 0.5 step", cost_ok)
    _ok("rules version is 2.1", db.rules_version == "2.1")


func _test_legality() -> void:
    print("[legality]")
    var d0 := Duel.new(db)
    var legal := d0.legal_cards(0)
    _ok("turn 0 offers only yun", legal.size() == 1 and legal[0] == "yun")
    _ok("turn 0 blocks xiao_biao", not d0.can_play(0, "xiao_biao"))

    var d1 := _duel(1, 10, 0)
    _ok("1.0 yun affords xiao_biao", d1.can_play(0, "xiao_biao"))
    _ok("1.0 yun cannot afford kai_sa", not d1.can_play(0, "kai_sa"))

    var d2 := _duel(1, 10, 0)
    d2.play_turn("xiao_biao", "yun")
    _ok("cost is actually paid", d2.state.players[0].yun == 0)


func _test_counter() -> void:
    print("[counter]")
    var d1 := _duel(1, 10, 0)
    d1.play_turn("xiao_biao", "zhong_fang")
    _ok("zhong_fang blocks xiao_biao", d1.state.players[0].hp == 100)

    var d2 := _duel(1, 10, 10)
    d2.play_turn("xiao_biao", "shan")
    _ok("shan dodges xiao_biao", d2.state.players[0].hp == 100)
    _ok("shan pays its cost", d2.state.players[1].yun == 0)

    var d3 := _duel(1, 20, 0)
    d3.play_turn("kai_sa", "zhong_fang")
    _ok("zhong_fang blocks kai_sa", d3.state.players[0].hp == 100)

    var d4 := _duel(1, 30, 0, 300, 300)
    d4.play_turn("chang_gong", "yun")
    _ok("chang_gong deals 2.2", d4.state.players[1].hp == 80,
        "hp1=%d" % d4.state.players[1].hp)


func _test_xi() -> void:
    print("[xi]")
    var d1 := _duel(1, 10, 0)
    d1.play_turn("xiao_biao", "xi")
    _ok("xi negates xiao_biao", d1.state.players[0].hp == 100)
    _ok("xi gains attacker's paid cost", d1.state.players[1].yun == 10)

    var d2 := _duel(1, 0, 0)
    d2.play_turn("yun", "xi")
    _ok("xi blanks yun gain", d2.state.players[0].yun == 0)
    _ok("xi takes the yun", d2.state.players[1].yun == 10)

    var d3 := _duel(1, 10, 0)
    d3.play_turn("qiang_hua_yun", "xi")
    _ok("qiang_hua_yun keeps 1 after absorb", d3.state.players[0].yun == 10)
    _ok("xi takes 1 from qiang_hua_yun", d3.state.players[1].yun == 10)


func _test_damage() -> void:
    print("[damage · 比大小]")
    # 裁定 4：两个一样的伤害互相抵消，谁都不掉血
    var d1 := _duel(1, 10, 10, 300, 300)
    d1.play_turn("xiao_biao", "xiao_biao")
    _ok("equal damage cancels out", d1.state.players[0].hp == 300 and d1.state.players[1].hp == 300)

    var d2 := _duel(1, 10, 10, 100, 100)
    d2.play_turn("xiao_biao", "xiao_biao")
    _ok("equal lethal mutual hit is voided", d2.state.players[0].hp == 100 and d2.state.players[1].hp == 100)
    _ok("match continues after void", not d2.state.over)

    # 不一样的伤害只有高的生效，低的一方整段归零（不按差额）
    var d3 := _duel(1, 30, 10, 500, 500)
    d3.play_turn("chang_gong", "xiao_biao")
    _ok("higher total applies in full", d3.state.players[1].hp == 280,
        "hp1=%d" % d3.state.players[1].hp)
    _ok("lower total is zeroed", d3.state.players[0].hp == 500,
        "hp0=%d" % d3.state.players[0].hp)

    var d3b := _duel(1, 30, 10, 50, 100)
    d3b.play_turn("chang_gong", "xiao_biao")
    _ok("only the loser of the race can die", d3b.state.over and d3b.state.winner == 0,
        "hp=%d/%d" % [d3b.state.players[0].hp, d3b.state.players[1].hp])

    # dot 参与比总量：1p 的 dot 当期跳伤把 1.0 vs 1.0 拉到 1.2 vs 1.0 → 1p 全生效（作者示例）
    var d4 := _duel(1, 10, 10, 300, 300)
    d4.state.players[1].add_dot(20, 5, 0, 0)
    d4.play_turn("xiao_biao", "xiao_biao")
    _ok("dot tips the race", d4.state.players[1].hp == 180,
        "hp1=%d" % d4.state.players[1].hp)
    _ok("dot winner keeps full damage", d4.state.players[0].hp == 300,
        "hp0=%d" % d4.state.players[0].hp)


func _test_heal_cd() -> void:
    print("[heal / cooldown]")
    var d := _duel(1, 10, 0, 50, 100)
    d.play_turn("tao_tao", "yun")
    _ok("tao_tao heals 0.5", d.state.players[0].hp == 100)
    _ok("tao_tao blocked next turn", not d.can_play(0, "tao_tao"))
    d.state.turn = 3
    d.state.players[0].yun = 20
    _ok("tao_tao back on turn+2", d.can_play(0, "tao_tao"))


func _test_shield() -> void:
    print("[shield]")
    var d1 := _duel(3, 40, 0)
    d1.play_turn("dun", "yun")
    _ok("first shield costs 4", d1.state.players[0].yun == 0)
    _ok("shield is banked", d1.state.players[0].shields == 1)
    _ok("first purchase flag set", d1.state.players[0].shield_bought_once)

    d1.state.players[0].yun = 30
    d1.play_turn("dun", "yun")
    _ok("second shield costs 3", d1.state.players[0].yun == 0)
    _ok("shields stack", d1.state.players[0].shields == 2)

    var d2 := _duel(3, 0, 20, 50, 100)
    d2.state.players[0].shields = 1
    d2.play_turn("yun", "kai_sa")
    _ok("shield saves lethal and keeps pre-hit hp", d2.state.players[0].hp == 50)
    _ok("shield consumed", d2.state.players[0].shields == 0)

    var d3 := _duel(5, 0, 0, 100, 50)
    d3.state.players[1].shields = 1
    for i in 4:
        d3.state.players[0].history.append("yun")
    d3.play_turn("zhan_shu_he_dan", "yun")
    _ok("one shield cannot block a 2-shield hit", d3.state.over and d3.state.winner == 0,
        "over=%s winner=%d" % [str(d3.state.over), d3.state.winner])
    _ok("insufficient shields are not consumed", d3.state.players[1].shields == 1)


func _test_combo() -> void:
    print("[combo]")
    var d1 := _duel(5, 0, 0)
    _ok("jiang_long needs zhong_fang", not d1.can_play(0, "jiang_long"))

    d1.state.players[0].history.append("zhong_fang")
    _ok("jiang_long unlocked after zhong_fang", d1.can_play(0, "jiang_long"))

    var d2 := _duel(5, 0, 0)
    d2.state.players[0].history.append("zhong_fang")
    d2.play_turn("jiang_long", "xi")
    _ok("jiang_long negated by xi", d2.state.players[0].hp == 100)
    # C9：降龙/降飞被吸，伤害归 0 但吸者照样 +2 运
    _ok("xi gains 2 from jiang_long (C9)", d2.state.players[1].yun == 20)

    var d3 := _duel(5, 0, 0)
    d3.state.players[0].history.append("zhong_fang")
    d3.play_turn("jiang_fei", "yun")
    _ok("yun block sets fly_dragon_ready", d3.state.players[0].flags.has("fly_dragon_ready"))
    _ok("jiang_fei still blocked", d3.state.players[0].hp == 100)
    _ok("jiang_fei replayable ignoring combo", d3.can_play(0, "jiang_fei"))

    var submitted := d3.submit(0, "jiang_fei")
    _ok("replay consumes the flag", submitted and not d3.state.players[0].flags.has("fly_dragon_ready"))


func _test_nuke() -> void:
    print("[nuke all-in]")
    var d1 := _duel(5, 60, 0, 300, 300)
    for i in 4:
        d1.state.players[0].history.append("yun")
    d1.play_turn("zhan_shu_he_dan", "yun")
    _ok("nuke pays 4 from 6", d1.state.players[0].yun == 20)
    _ok("nuke deals 2.2", d1.state.players[1].hp == 80)

    var d2 := _duel(5, 20, 0, 300, 300)
    for i in 4:
        d2.state.players[0].history.append("yun")
    d2.play_turn("zhan_shu_he_dan", "yun")
    _ok("nuke pays only what you have", d2.state.players[0].yun == 0)
    _ok("nuke still deals 2.2 when short", d2.state.players[1].hp == 80)

    var d3 := _duel(5, 0, 0, 300, 300)
    for i in 4:
        d3.state.players[0].history.append("yun")
    _ok("nuke is legal at 0 yun", d3.can_play(0, "zhan_shu_he_dan"))


func _test_death() -> void:
    print("[death]")
    var d := _duel(1, 10, 0, 100, 100)
    d.play_turn("xiao_biao", "yun")
    _ok("lethal damage ends the match", d.state.over and d.state.winner == 0)


func _test_batch2() -> void:
    print("[batch2 · qia]")
    # 超掐 vs 乃爆：乃爆伤害归 0 + 代码杀，盾救不了
    var d1 := _duel(3, 10, 20, 300, 300)
    d1.state.players[1].shields = 2
    d1.play_turn("chao_qia", "nai_bao")
    _ok("chao_qia blanks nai_bao damage", d1.state.players[0].hp == 300)
    _ok("chao_qia code-kills nai_bao despite shields", d1.state.over and d1.state.winner == 0)

    # 超掐 vs 运：运挡为抵消，运被消耗且不产生运
    var d2 := _duel(3, 10, 0)
    d2.play_turn("chao_qia", "yun")
    _ok("yun blocks chao_qia", d2.state.players[0].hp == 100)
    _ok("consume block yields no yun", d2.state.players[1].yun == 0)

    # 超掐 vs 普通运挡之外：中防挡不了超掐
    var d3 := _duel(3, 10, 0)
    d3.play_turn("chao_qia", "zhong_fang")
    _ok("zhong_fang cannot block chao_qia", d3.state.players[1].hp == 50)

    print("[batch2 · handgun]")
    var d4 := _duel(3, 10, 0, 300, 300)
    d4.play_turn("shou_qiang", "yun")
    _ok("yun blocks handgun", d4.state.players[0].hp == 300)
    _ok("handgun consumes the blocking yun", d4.state.players[1].yun == 0)

    var d5 := _duel(3, 20, 10, 300, 300)
    d5.play_turn("shou_qiang", "shan")
    _ok("handgun cannot be dodged", d5.state.players[1].hp == 150,
        "hp1=%d" % d5.state.players[1].hp)
    _ok("shan pays but whiffs", d5.state.players[1].yun == 0)

    var d6 := _duel(3, 20, 0, 300, 300)
    d6.play_turn("shou_qiang", "xi")
    _ok("xi still blocks handgun", d6.state.players[0].hp == 300)

    print("[batch2 · wei_biao / fu_yun]")
    var d7 := _duel(3, 0, 0, 300, 300)
    d7.play_turn("wei_biao", "xi")
    _ok("wei_biao negated by xi", d7.state.players[0].hp == 300)
    # 2026-10-25 朋友反馈：微镖被吸，得 1 运的是「出吸的人」，不是微镖使用者
    _ok("the absorber gains 1 yun when stealing wei_biao",
        d7.state.players[1].yun == 10 and d7.state.players[0].yun == 0,
        "yun=%d/%d" % [d7.state.players[0].yun, d7.state.players[1].yun])

    var d8 := _duel(5, 0, 0, 300, 300)
    d8.state.players[0].history.append("zhong_fang")
    d8.play_turn("jiang_long", "fu_yun")
    _ok("fu_yun blocks jiang_long", d8.state.players[0].hp == 300)
    _ok("fu_yun still drains 1 yun after blocking (C7)", d8.state.players[0].yun == -10)

    var d9 := _duel(3, 10, 0, 300, 300)
    d9.play_turn("xiao_biao", "fu_yun")
    _ok("fu_yun blocks xiao_biao", d9.state.players[0].hp == 300)

    var d10 := _duel(3, 20, 0, 300, 300)
    d10.play_turn("kai_sa", "fu_yun")
    _ok("fu_yun cannot block kai_sa", d10.state.players[1].hp == 150)

    var d11 := _duel(3, 0, 0, 300, 300)
    d11.play_turn("fu_yun", "xi")
    # 裁定 2：扣的是"出吸的人"，出负运的人不再自扣
    _ok("stolen fu_yun costs the absorber 1 yun",
        d11.state.players[1].yun == -10 and d11.state.players[0].yun == 0,
        "yun=%d/%d" % [d11.state.players[0].yun, d11.state.players[1].yun])

    print("[batch2 · jiu]")
    var d12 := _duel(3, 0, 10, 300, 300)
    d12.play_turn("jiu", "xiao_biao")
    _ok("jiu immunes a 1.0 hit", d12.state.players[0].hp == 300)

    var d13 := _duel(3, 30, 10, 300, 300)
    d13.play_turn("chang_gong", "jiu")
    _ok("jiu cannot stop 2.2", d13.state.players[1].hp == 80)

    print("[batch2 · dot]")
    var d14 := _duel(3, 10, 0, 300, 300)
    d14.play_turn("tou_xi", "yun")
    _ok("tou_xi does not tick on its own turn", d14.state.players[1].hp == 300)
    _ok("dot is banked", d14.state.players[1].dots.size() == 1)
    d14.state.players[0].yun = 10
    d14.play_turn("yun", "yun")
    _ok("dot ticks 0.2 next turn", d14.state.players[1].hp == 280)

    # 桃桃过程中解除 dot
    var d15 := _duel(5, 20, 0, 200, 300)
    d15.state.players[0].add_dot(20, 5, 1, 2)
    d15.play_turn("tao_tao", "yun")
    _ok("tao_tao clears dot before it ticks", d15.state.players[0].hp == 250)
    _ok("dot removed", d15.state.players[0].dots.is_empty())

    # 酒免疫 dot 单跳
    var d16 := _duel(5, 10, 10, 300, 300)
    d16.state.players[0].add_dot(20, 3, 1, 2)
    d16.play_turn("jiu", "yun")
    _ok("jiu immunes one dot tick", d16.state.players[0].hp == 300)

    print("[batch2 · prism]")
    var d17 := _duel(3, 10, 0, 300, 300)
    d17.play_turn("san_leng_jing", "yun")
    _ok("prism k=1 deals 0.7", d17.state.players[1].hp == 230,
        "hp=%d" % d17.state.players[1].hp)

    var d18 := _duel(3, 10, 0, 300, 300)
    d18.play_turn("san_leng_jing", "fu_yun")
    _ok("prism k=-1 deals only 0.1", d18.state.players[1].hp == 290,
        "hp=%d" % d18.state.players[1].hp)

    var d19 := _duel(3, 10, 0, 300, 300)
    d19.play_turn("san_leng_jing", "zhong_fang")
    _ok("prism blocked by zhong_fang", d19.state.players[1].hp == 300)

    print("[batch2 · slash / peach garden]")
    var d20 := _duel(3, 30, 0, 300, 300)
    d20.play_turn("chang_gong_fen_san", "zhong_fang")
    _ok("fen_san blocked by zhong_fang", d20.state.players[0].hp == 300)
    _ok("blocker takes 0.5 backlash", d20.state.players[1].hp == 250)

    var d21 := _duel(3, 20, 0, 300, 300)
    d21.play_turn("heng_sao_da_di", "yun")
    _ok("heng_sao deals 1.0", d21.state.players[1].hp == 200)

    var d22 := _duel(3, 20, 0, 50, 50)
    d22.play_turn("tao_yuan_jie_yi", "yun")
    _ok("tao_yuan heals both sides", d22.state.players[0].hp == 100 and d22.state.players[1].hp == 100)

    var d23 := _duel(3, 0, 0, 300, 300)
    d23.play_turn("wei_biao", "zhong_fang")
    _ok("zhong_fang blocks wei_biao", d23.state.players[0].hp == 300)


func _test_batch3() -> void:
    print("[batch3 · kui]")
    var d1 := _duel(5, 10, 0, 300, 300)
    _prep(d1, 1, ["zhong_fang", "xi", "yun"])
    d1.play_turn("xiao_biao", "gui_pai")
    _ok("kui turns xiao_biao back on its owner", d1.state.players[0].hp == 200,
        "hp0=%d" % d1.state.players[0].hp)
    _ok("kui user takes no damage", d1.state.players[1].hp == 300)
    _ok("kui is free", d1.state.players[1].yun == 0)

    var d2 := _duel(5, 10, 0, 200, 200)
    _prep(d2, 1, ["zhong_fang", "xi", "yun"])
    d2.play_turn("tao_tao", "gui_pai")
    _ok("kui steals self-heal", d2.state.players[1].hp == 250 and d2.state.players[0].hp == 200)

    var d3 := _duel(5, 10, 0, 300, 300)
    _prep(d3, 1, ["zhong_fang", "xi", "yun"])
    d3.play_turn("zi_sha", "gui_pai")
    _ok("kui redirects self-kill onto the kui user (C28)",
        d3.state.over and d3.state.winner == 0)

    var d4 := _duel(5, 0, 0, 300, 300)
    _prep(d4, 0, ["zhong_fang", "xi", "yun"])
    _prep(d4, 1, ["zhong_fang", "xi", "yun"])
    d4.play_turn("gui_pai", "gui_pai")
    _ok("mutual kui cancels both (C33)",
        d4.state.players[0].hp == 300 and d4.state.players[1].hp == 300)

    var d5 := _duel(5, 20, 0, 400, 400)
    _prep(d5, 1, ["jue_xing_zhong_fang", "chao_ji_xi", "qiang_hua_yun"])
    d5.play_turn("kai_sa", "shen_zhi_gui_pai")
    _ok("shen_zhi_gui_pai doubles damage", d5.state.players[0].hp == 100,
        "hp0=%d" % d5.state.players[0].hp)

    print("[batch3 · amulet / time]")
    var d6 := _duel(5, 10, 10, 300, 300)
    d6.play_turn("xiao_biao", "hu_shen_fu")
    _ok("amulet ignores a 1-cost card", d6.state.players[1].hp == 200)

    var d7 := _duel(5, 20, 10, 300, 300)
    d7.play_turn("kai_sa", "hu_shen_fu")
    _ok("amulet blocks a 2-cost card", d7.state.players[1].hp == 300)

    var d8 := _duel(5, 30, 30, 300, 300)
    d8.play_turn("chang_gong", "niu_zhuan_shi_kong")
    _ok("time stop cancels all effects", d8.state.players[1].hp == 300)
    _ok("time stop still charges the cost", d8.state.players[0].yun == 0)

    print("[batch3 · delayed / true damage]")
    var d9 := _duel(5, 20, 0, 300, 300)
    d9.play_turn("c4", "yun")
    _ok("c4 does not fire immediately", d9.state.players[1].hp == 300)
    d9.play_turn("yun", "yun")
    d9.play_turn("yun", "yun")
    _ok("c4 still waiting two turns later", d9.state.players[1].hp == 300)
    d9.play_turn("yun", "yun")
    _ok("c4 fires -3.0 on turn+3", d9.state.players[1].hp == 0,
        "hp1=%d turn=%d" % [d9.state.players[1].hp, d9.state.turn])

    var d10 := _duel(5, 50, 0, 300, 300)
    d10.play_turn("liu_shen", "yun")
    _ok("liu_shen true damage pierces yun block", d10.state.players[1].hp == 250,
        "hp1=%d" % d10.state.players[1].hp)

    var d11 := _duel(5, 20, 0, 300, 300)
    d11.play_turn("du_yao", "yun")
    _ok("poison halved by yun block", d11.state.players[1].hp == 180,
        "hp1=%d" % d11.state.players[1].hp)

    print("[batch3 · yun ops]")
    var d12 := _duel(5, 10, 10, 300, 300)
    d12.play_turn("xiao_biao", "chao_ji_xi")
    _ok("super xi doubles the steal", d12.state.players[1].yun == 20,
        "yun1=%d" % d12.state.players[1].yun)

    var d13 := _duel(5, 20, 10, 300, 300)
    d13.play_turn("bi_xin", "yun")
    _ok("bi_xin takes 2 yun", d13.state.players[1].yun == 0,
        "yun1=%d" % d13.state.players[1].yun)

    var d14 := _duel(5, 20, -50, 300, 300)
    d14.play_turn("bi_xin", "tao_he")
    _ok("bi_xin never lifts yun back up (Q9)", d14.state.players[1].yun == -50,
        "yun1=%d" % d14.state.players[1].yun)

    var d15 := _duel(5, 30, 40, 300, 300)
    d15.play_turn("gou_hun", "tao_he")
    _ok("gou_hun takes all positive yun", d15.state.players[0].yun == 40 and d15.state.players[1].yun == 0,
        "yun=%d/%d" % [d15.state.players[0].yun, d15.state.players[1].yun])

    var d16 := _duel(5, 30, -20, 300, 300)
    d16.play_turn("gou_hun", "tao_he")
    _ok("gou_hun zeroes negative yun without going negative", d16.state.players[1].yun == 0,
        "yun1=%d" % d16.state.players[1].yun)

    print("[batch3 · skip / cannon / kui_hua]")
    var d17 := _duel(5, 30, 0, 300, 300)
    d17.play_turn("bi_shi", "yun")
    _ok("bi_shi blocks every card next turn", not d17.can_play(1, "xiao_biao"))
    _ok("bi_shi leaves only pass", d17.can_play(1, "pass"))

    var d18 := _duel(5, 40, 0, 300, 300)
    d18.play_turn("yuan_shou", "yun")
    d18.state.players[0].yun = 20
    _ok("cannon drops to 2 under buff", d18.can_play(0, "yi_da_li_pao"),
        "cost=%d" % d18.effective_cost(0, db.get_def("yi_da_li_pao")))

    var d19 := _duel(5, 50, 0, 300, 300)
    _prep(d19, 0, ["zhong_fang", "xi", "yun", "chao_ji_xi"])
    d19.play_turn("kui_hua_bao_dian", "yun")
    _ok("kui_hua halves own cost", d19.state.players[0].cost_percent == 50)
    _ok("xiao_biao now costs 0.5", d19.effective_cost(0, db.get_def("xiao_biao")) == 5)

    print("[batch3 · reflect / purify / qia]")
    var d20 := _duel(5, 10, 10, 300, 300)
    d20.play_turn("xiao_biao", "jue_xing_zhong_fang")
    _ok("jue_xing blocks and reflects 0.5", d20.state.players[1].hp == 300 and d20.state.players[0].hp == 250)

    var d21 := _duel(5, 40, 10, 300, 300)
    _prep(d21, 0, ["yun", "yun", "yun", "yun"])
    d21.play_turn("zhan_shu_he_dan", "jue_xing_zhong_fang")
    _ok("jue_xing blocks nuke and still reflects 0.8",
        d21.state.players[0].hp == 220 and d21.state.players[1].hp == 300,
        "hp=%d/%d" % [d21.state.players[0].hp, d21.state.players[1].hp])

    var d22 := _duel(5, 30, 0, 200, 300)
    d22.state.players[0].hp_max_ever = 300
    d22.state.players[0].add_dot(20, 5, 1, 2)
    d22.play_turn("jing_hua", "yun")
    _ok("purify clears dots and restores max hp", d22.state.players[0].hp == 300)
    _ok("purify emptied dot list", d22.state.players[0].dots.is_empty())

    var d23 := _duel(5, 20, 0, 300, 300)
    d23.play_turn("jiu_qia", "tao_he")
    _ok("jiu_qia base damage 0.9", d23.state.players[1].hp == 220,
        "hp1=%d" % d23.state.players[1].hp)

    var d24 := _duel(5, 20, 0, 300, 300)
    _prep(d24, 0, ["xiao_qia", "chao_qia"])
    d24.play_turn("jiu_qia", "tao_he")
    _ok("jiu_qia combo damage 1.4", d24.state.players[1].hp == 170,
        "hp1=%d" % d24.state.players[1].hp)

    var d25 := _duel(5, 20, 0, 300, 300)
    d25.play_turn("jiu_qia", "yun")
    _ok("jiu_qia blocked by yun deals 0", d25.state.players[1].hp == 300)
    _ok("jiu_qia steals the gained yun (C23)", d25.state.players[0].yun == 10,
        "yun0=%d" % d25.state.players[0].yun)

    var d26 := _duel(5, 10, 20, 300, 300)
    d26.play_turn("xiao_qia", "nai_bao")
    _ok("xiao_qia code-kills nai_bao", d26.state.over and d26.state.winner == 0)

    print("[batch3 · misc]")
    var d27 := _duel(5, 40, 20, 300, 300)
    d27.play_turn("ding_hai_shen_zhen", "shou_qiang")
    _ok("ding_hai still heals when blocked", d27.state.players[0].hp == 210,
        "hp0=%d" % d27.state.players[0].hp)

    # 朋友反馈（2026-10-25）：定海神针被闪了以后也应该加血。
    # C32「被防仍加血」的原则：+0.6 加的是施术者自己，闪躲的是"指向对方"的部分，
    # 够不着施术者自己的收益。闪躲掉了伤害，但加血照旧。
    var d27b := _duel(5, 40, 10, 300, 300)
    d27b.play_turn("ding_hai_shen_zhen", "shan")
    _ok("shan dodges ding_hai damage", d27b.state.players[1].hp == 300,
        "hp1=%d" % d27b.state.players[1].hp)
    _ok("ding_hai still heals when dodged by shan", d27b.state.players[0].hp == 360,
        "hp0=%d" % d27b.state.players[0].hp)

    var d28 := _duel(5, 0, 0, 300, 300)
    _prep(d28, 0, ["zhong_fang", "zhong_fang", "xi", "zhong_fang"])
    d28.play_turn("xiang_yun_kui", "yun")
    _ok("xiang_yun pays 1 yun now and 1 next turn", d28.state.players[0].yun == 20,
        "yun0=%d" % d28.state.players[0].yun)
    d28.play_turn("yun", "yun")
    _ok("xiang_yun adds another yun on the following turn", d28.state.players[0].yun == 30,
        "yun0=%d" % d28.state.players[0].yun)

    var d29 := _duel(5, 10, 0, 300, 300)
    d29.play_turn("zi_sha", "yun")
    _ok("self-kill ends the match", d29.state.over and d29.state.winner == 1)

    var d30 := _duel(5, 70, 0, 100, 300)
    d30.state.players[1].shields = 2
    d30.play_turn("yi_da_li_pao", "yun")
    _ok("cannon needs 2 shields to survive", d30.state.players[0].hp == 100 and not d30.state.over)
    _ok("cannon consumes both shields", d30.state.players[1].shields == 0)

    var d31 := _duel(5, 30, 0, 300, 300)
    d31.play_turn("nao_gua_beng", "yun")
    _ok("nao_gua_beng deals 1.3", d31.state.players[1].hp == 170)

    print("[batch3 · shield need]")
    # dot 致死只该吃 1 张盾，不能按"本回合那张牌"的 shield_cost 算
    # B 出的是核弹（shield_cost=2），但被觉醒中防挡下；真正致死的是 dot
    # （dot 要大到赢过 0.8 反弹，否则会先被比大小零化）
    var d32 := _duel(5, 10, 0, 20, 300)
    d32.state.players[0].add_dot(150, 5, 1, 2)
    d32.state.players[0].shields = 1
    for i in 4:
        d32.state.players[1].history.append("yun")
    d32.play_turn("jue_xing_zhong_fang", "zhan_shu_he_dan")
    _ok("dot lethal costs 1 shield, not the card's 2",
        d32.state.players[0].hp == 20 and not d32.state.over,
        "hp=%d over=%s" % [d32.state.players[0].hp, str(d32.state.over)])

    # 核弹致死才该吃 2 张盾
    var d33 := _duel(5, 0, 0, 20, 300)
    d33.state.players[0].shields = 1
    for i in 4:
        d33.state.players[1].history.append("yun")
    d33.play_turn("yun", "zhan_shu_he_dan")
    _ok("nuke lethal needs 2 shields", d33.state.over and d33.state.winner == 1)

    print("[batch3 · flash target]")
    # 闪只能躲"指向自己"的牌：自杀是对自己使用，闪救不了
    var d34 := _duel(5, 10, 10, 300, 300)
    d34.play_turn("zi_sha", "shan")
    _ok("shan cannot save the self-killer", d34.state.over and d34.state.winner == 1,
        "over=%s winner=%d" % [str(d34.state.over), d34.state.winner])

    # 对照组：勾魂指向对方，闪正常生效
    # B 起始 2 运，付闪 1 运后应剩 1 运（若勾魂生效会是 0）
    var d35 := _duel(5, 30, 20, 300, 300)
    d35.play_turn("gou_hun", "shan")
    _ok("shan still dodges gou_hun", d35.state.players[1].yun == 10,
        "yun1=%d" % d35.state.players[1].yun)

    print("[batch3 · wine total damage]")
    # 酒按"该次攻击总伤害"判：六神 2.5+0.5=3.0 > 1，酒救不了
    var d36 := _duel(5, 10, 50, 300, 300)
    d36.play_turn("jiu", "liu_shen")
    _ok("jiu cannot stop liu_shen (3.0 total)",
        d36.state.players[0].hp == 0 and d36.state.over,
        "hp=%d" % d36.state.players[0].hp)

    print("[batch3 · shield grouping]")
    # 多段伤害算"一次攻击"（C16）：六神 2.5+0.5 只该吃 1 张盾
    var d37 := _duel(5, 0, 50, 50, 300)
    d37.state.players[0].shields = 1
    d37.play_turn("yun", "liu_shen")
    _ok("liu_shen costs only 1 shield",
        d37.state.players[0].hp == 50 and not d37.state.over,
        "hp=%d over=%s" % [d37.state.players[0].hp, str(d37.state.over)])

    # 被免疫的那一组不该消耗盾
    var d38 := _duel(5, 10, 30, 200, 300)
    d38.state.players[0].add_dot(20, 5, 1, 2)
    d38.state.players[0].shields = 1
    d38.play_turn("jiu", "chang_gong")
    _ok("immune hit does not eat a shield",
        d38.state.players[0].hp == 200 and d38.state.players[0].shields == 0 and not d38.state.over,
        "hp=%d shields=%d" % [d38.state.players[0].hp, d38.state.players[0].shields])

    print("[spec examples]")
    # 规则文档第七部分示例 8：C4 到期即便同回合扭转时空也照跳
    # A 需要留够 3 运出扭转时空：C4 付 2，两次运 +2，共 5 运起手
    var d39 := _duel(5, 50, 0, 300, 300)
    var e1: Array = d39.play_turn("c4", "yun")
    var e2: Array = d39.play_turn("yun", "yun")
    var e3: Array = d39.play_turn("yun", "yun")
    _ok("c4 setup accepted", not e1.is_empty() and not e2.is_empty() and not e3.is_empty())
    _ok("c4 still pending", d39.state.players[1].hp == 300,
        "turn=%d hp1=%d" % [d39.state.turn, d39.state.players[1].hp])
    var e4: Array = d39.play_turn("niu_zhuan_shi_kong", "yun")
    _ok("time stop accepted", not e4.is_empty(),
        "turn=%d yun0=%d" % [d39.state.turn, d39.state.players[0].yun])
    _ok("c4 fires through time stop", d39.state.players[1].hp == 0,
        "hp1=%d" % d39.state.players[1].hp)

    # C18：元首把炮削到 2 费，正落在护身符 2~3 区间
    var d40 := _duel(5, 40, 10, 300, 300)
    d40.play_turn("yuan_shou", "yun")
    d40.state.players[0].yun = 20
    d40.play_turn("yi_da_li_pao", "hu_shen_fu")
    _ok("amulet blocks discounted cannon", d40.state.players[1].hp == 300,
        "hp1=%d" % d40.state.players[1].hp)

    # C43：葵后 3 费变 1.5 费，不在 2~3 区间，护身符不免疫
    var d41 := _duel(5, 50, 10, 300, 300)
    _prep(d41, 0, ["zhong_fang", "xi", "yun", "chao_ji_xi"])
    d41.play_turn("kui_hua_bao_dian", "yun")
    d41.state.players[0].yun = 30
    d41.play_turn("chang_gong", "hu_shen_fu")
    _ok("amulet ignores 1.5-cost after kui_hua", d41.state.players[1].hp == 80,
        "hp1=%d" % d41.state.players[1].hp)

    # 勾魂要夺到"本回合获得的运"（向运葵当期 +1），B 剩下的 1 运是下回合预约运
    var d43 := _duel(5, 30, 0, 300, 300)
    _prep(d43, 1, ["zhong_fang", "zhong_fang", "xi", "zhong_fang"])
    d43.play_turn("gou_hun", "xiang_yun_kui")
    _ok("gou_hun takes this-turn yun too",
        d43.state.players[0].yun == 10 and d43.state.players[1].yun == 10,
        "yun=%d/%d" % [d43.state.players[0].yun, d43.state.players[1].yun])

    # C32：定海被凯撒挡，-1.6 归 0，但 +0.6 照加
    var d42 := _duel(5, 40, 20, 200, 300)
    d42.play_turn("ding_hai_shen_zhen", "kai_sa")
    _ok("ding_hai heals through kai_sa", d42.state.players[0].hp == 110,
        "hp0=%d" % d42.state.players[0].hp)


func _test_batch4() -> void:
    print("[batch4 · ruling 1: kui does not count as played]")
    # 被龟派取走的中防不推进连招 → 下一回合出了降龙
    var d1 := _duel(5, 0, 0, 300, 300)
    _prep(d1, 1, ["zhong_fang", "xi", "yun"])
    d1.play_turn("zhong_fang", "gui_pai")
    _ok("kui-taken zhong_fang does not advance combo", not d1.can_play(0, "jiang_long"))
    _ok("kui-taken card is not in history", not d1.state.players[0].history.has("zhong_fang"),
        str(d1.state.players[0].history))
    # 对照：正常出中防会推进连招
    var d1b := _duel(5, 0, 0, 300, 300)
    d1b.play_turn("zhong_fang", "yun")
    _ok("plain zhong_fang does advance combo", d1b.can_play(0, "jiang_long"))

    # 被龟派取走不记冷却 → 微镖下一回合能再出
    var d2 := _duel(5, 0, 0, 300, 300)
    _prep(d2, 1, ["zhong_fang", "xi", "yun"])
    d2.play_turn("wei_biao", "gui_pai")
    _ok("kui-taken wei_biao skips its cooldown", d2.can_play(0, "wei_biao"))
    var d2b := _duel(5, 0, 0, 300, 300)
    d2b.play_turn("wei_biao", "yun")
    _ok("plain wei_biao still goes on cooldown", not d2b.can_play(0, "wei_biao"))

    print("[batch4 · ruling 5: wei_biao cooldown]")
    var d3 := _duel(5, 0, 0, 300, 300)
    d3.play_turn("wei_biao", "yun")
    _ok("wei_biao locked the very next turn", not d3.can_play(0, "wei_biao"))
    d3.play_turn("yun", "yun")
    _ok("wei_biao back after one blank turn", d3.can_play(0, "wei_biao"))

    print("[batch4 · ruling 2/3: xi vs fu_yun / jiang_fei]")
    var d4 := _duel(5, 0, 0, 300, 300)
    d4.play_turn("fu_yun", "xi")
    _ok("fu_yun stolen drains the absorber", d4.state.players[1].yun == -10)
    _ok("fu_yun's own user is not drained", d4.state.players[0].yun == 0)
    var d5 := _duel(5, 0, 0, 300, 300)
    _prep(d5, 0, ["zhong_fang"])
    d5.play_turn("jiang_fei", "xi")
    _ok("xi gains 2 from jiang_fei (C9)", d5.state.players[1].yun == 20,
        "yun1=%d" % d5.state.players[1].yun)

    print("[batch5 · friend ruling: fei_long_zai_tian stolen gives 2 yun]")
    var d5b := _duel(5, 0, 0, 300, 300)
    _prep(d5b, 0, ["jue_xing_zhong_fang"])
    d5b.play_turn("fei_long_zai_tian", "xi")
    _ok("fei_long_zai_tian is negated by xi", d5b.state.players[0].hp == 300)
    _ok("xi gains 2 from fei_long_zai_tian (same as jiang_fei)",
        d5b.state.players[1].yun == 20, "yun1=%d" % d5b.state.players[1].yun)
    _ok("fei_long_zai_tian's user gains nothing",
        d5b.state.players[0].yun == 0, "yun0=%d" % d5b.state.players[0].yun)

    print("[batch4 · ruling 2/9: fu_yun blocks list]")
    var d6 := _duel(5, 30, 0, 300, 300)
    d6.play_turn("chang_gong_fen_san", "fu_yun")
    _ok("fu_yun now blocks chang_gong_fen_san", d6.state.players[0].hp == 300)
    _ok("fu_yun still drains itself", d6.state.players[0].yun == -10,
        "yun0=%d" % d6.state.players[0].yun)
    var d7 := _duel(5, 0, 0, 300, 300)
    d7.play_turn("wei_biao", "fu_yun")
    _ok("fu_yun cannot block wei_biao", d7.state.players[1].hp == 200,
        "hp1=%d" % d7.state.players[1].hp)

    print("[batch4 · ruling 8: jue_xing_zhong_fang]")
    # 能挡中防能挡的：长攻分散被挡，反弹 min(2.4×50%, 0.8) = 0.8
    var d8 := _duel(5, 30, 10, 300, 300)
    d8.play_turn("chang_gong_fen_san", "jue_xing_zhong_fang")
    _ok("jue_xing blocks chang_gong_fen_san", d8.state.players[1].hp == 300)
    _ok("reflect is capped at 0.8", d8.state.players[0].hp == 220,
        "hp0=%d" % d8.state.players[0].hp)
    # 六飞：普通伤害归 0，真伤照掉；但真伤 0.5 在比大小里输给 0.8 反弹 → 被零化
    var d9 := _duel(5, 50, 10, 300, 300)
    d9.play_turn("liu_fei", "jue_xing_zhong_fang")
    _ok("liu_fei true damage loses the race to the capped reflect",
        d9.state.players[1].hp == 300, "hp1=%d" % d9.state.players[1].hp)
    _ok("reflect on liu_fei is capped", d9.state.players[0].hp == 220)
    # 挡不了中防挡不住的：超掐
    var d10 := _duel(5, 10, 10, 300, 300)
    d10.play_turn("chao_qia", "jue_xing_zhong_fang")
    _ok("jue_xing cannot block chao_qia", d10.state.players[1].hp == 250)
    _ok("no reflect when it does not block", d10.state.players[0].hp == 300)
    # 核弹：挡下并反弹（2.2×50% = 1.1，封顶 0.8）
    var d11 := _duel(5, 40, 10, 300, 300)
    _prep(d11, 0, ["yun", "yun", "yun", "yun"])
    d11.play_turn("zhan_shu_he_dan", "jue_xing_zhong_fang")
    _ok("nuke is blocked", d11.state.players[1].hp == 300)
    _ok("nuke reflect is capped at 0.8", d11.state.players[0].hp == 220,
        "hp0=%d" % d11.state.players[0].hp)
    # 比心 → 对面扣 1 运（比心 2 费由施放者自付，被挡后 2 运的削减不生效）
    var d12 := _duel(5, 20, 10, 300, 300)
    d12.play_turn("bi_xin", "jue_xing_zhong_fang")
    _ok("bi_xin reflect is 1 yun", d12.state.players[0].yun == -10,
        "yun0=%d" % d12.state.players[0].yun)
    _ok("bi_xin's own yun loss is cancelled", d12.state.players[1].yun == 0)
    # 鄙视 → 反弹使对面下回合强制空过（与鄙视自身效果一致）
    var d13 := _duel(5, 30, 10, 300, 300)
    var ev13: Array = d13.play_turn("bi_shi", "jue_xing_zhong_fang")
    _ok("bi_shi turn resolved", not ev13.is_empty())
    _ok("bi_shi reflect forces a pass turn", d13.can_play(0, "pass"))
    _ok("forced turn allows nothing but pass", not d13.can_play(0, "zhong_fang"))
    _ok("pass is the only legal option", d13.legal_cards(0) == ["pass"],
        str(d13.legal_cards(0)))
    # 空过一回合后恢复正常
    d13.play_turn("pass", "yun")
    _ok("pass turn is consumed", d13.can_play(0, "zhong_fang"))

    print("[batch4 · ruling 7: time spread]")
    var d14 := _duel(5, 30, 0, 400, 400)
    d14.play_turn("chang_gong_fen_san", "xi")
    _ok("xi still steals the 3 paid yun", d14.state.players[1].yun == 30)
    _ok("time spread dot is hung on the absorber", d14.state.players[0].dots.size() == 1)
    _ok("time spread lasts k = stolen yun turns",
        int(d14.state.players[0].dots[0]["left"]) == 3,
        "left=%d" % int(d14.state.players[0].dots[0]["left"]))
    d14.play_turn("yun", "yun")
    _ok("time spread ticks 0.4 from the next turn", d14.state.players[0].hp == 360,
        "hp0=%d" % d14.state.players[0].hp)
    # 桃桃能解
    var d15 := _duel(5, 30, 0, 400, 400)
    d15.play_turn("chang_gong_fen_san", "xi")
    d15.state.players[0].yun = 10
    d15.play_turn("tao_tao", "yun")
    _ok("tao_tao clears time spread", d15.state.players[0].dots.is_empty())

    print("[batch4 · ruling 9: xiang_yun_kui countered_by]")
    var blocks := {"xiao_biao": 10, "wei_biao": 0, "heng_sao_da_di": 20}
    for blocker in blocks.keys():
        var d := _duel(5, 20, int(blocks[blocker]), 300, 300)
        _prep(d, 0, ["zhong_fang", "zhong_fang", "xi", "zhong_fang"])
        d.play_turn("xiang_yun_kui", blocker)
        _ok("xiang_yun_kui blocked by " + blocker, d.state.players[0].yun == 20,
            "yun0=%d" % d.state.players[0].yun)
    var d16 := _duel(5, 20, 0, 300, 300)
    _prep(d16, 0, ["zhong_fang", "zhong_fang", "xi", "zhong_fang"])
    var ev16: Array = d16.play_turn("xiang_yun_kui", "yun")
    _ok("xiang_yun_kui not blocked by yun",
        not ev16.is_empty() and d16.state.players[0].yun == 40,
        "yun0=%d" % d16.state.players[0].yun)

    print("[batch4 · generic countered_by now data driven]")
    var d17 := _duel(5, 10, 10, 300, 300)
    d17.play_turn("gua_sha", "jiu")
    _ok("gua_sha shaves through jiu", d17.state.players[1].hp == 280,
        "hp1=%d" % d17.state.players[1].hp)
    var d18 := _duel(5, 10, 10, 300, 300)
    d18.play_turn("san_leng_jing", "xiao_biao")
    _ok("xiao_biao blocks prism", d18.state.players[1].hp == 300)
    _ok("blocked prism leaves the blocker free to hit", d18.state.players[0].hp == 200,
        "hp0=%d" % d18.state.players[0].hp)
    var d19 := _duel(5, 40, 20, 300, 300)
    d19.play_turn("ding_hai_shen_zhen", "shou_qiang")
    _ok("shou_qiang blocks ding_hai", d19.state.players[1].hp == 300)
    var d20 := _duel(5, 20, 0, 300, 300)
    d20.play_turn("heng_sao_da_di", "xiao_biao")
    _ok("xiao_biao blocks heng_sao_da_di", d20.state.players[1].hp == 300)
    var d21 := _duel(5, 50, 10, 300, 300)
    _prep(d21, 0, ["zhong_fang", "xi", "yun", "chao_ji_xi"])
    d21.play_turn("kui_hua_bao_dian", "xiao_biao")
    _ok("xiao_biao blocks kui_hua", d21.state.players[0].cost_percent == 100)
    var d22 := _duel(5, 40, 0, 300, 300)
    d22.play_turn("yuan_shou", "xiao_biao")
    _ok("xiao_biao blocks yuan_shou", d22.state.players[0].cannon_from == -1)


func _prep(d: Duel, player: int, history: Array) -> void:
    for c in history:
        d.state.players[player].history.append(str(c))


func _test_kui_table() -> void:
    print("[kui redirect table]")
    # 攻击类被龟派后必须"反向"：原主受损、龟派者无损
    var atk := ["xiao_biao", "wei_biao", "chao_qia", "kai_sa", "nai_bao",
        "chang_gong", "chang_gong_fen_san", "shou_qiang", "du_yao", "liu_shen",
        "ding_hai_shen_zhen", "nao_gua_beng", "heng_sao_da_di", "gua_sha"]
    var bad := ""
    for cid in atk:
        var d := _duel(5, 70, 0, 500, 500)
        _prep(d, 1, ["zhong_fang", "xi", "yun"])
        var ev: Array = d.play_turn(cid, "gui_pai")
        if ev.is_empty():
            bad += " %s(非法)" % cid
            continue
        if d.state.players[0].hp >= 500:
            bad += " %s(未反噬)" % cid
        if d.state.players[1].hp < 500:
            bad += " %s(误伤龟派者)" % cid
    _ok("all attack cards redirect to their owner", bad == "", bad)

    # 自增益类：龟派者获得、原主只付费用，拿不到效果
    var self_cards := [
        ["tao_tao", 50, 300, 300, 350, 0],     # cid, A初始运, A初始血, A期望血, B期望血, A期望盾
        ["yun", 50, 300, 300, 300, 0],
        ["qiang_hua_yun", 50, 300, 300, 300, 0],
        ["dun", 50, 300, 300, 300, 0],
    ]
    var bad2 := ""
    for item in self_cards:
        var cid: String = item[0]
        var d := _duel(5, int(item[1]), 0, int(item[2]), 300)
        _prep(d, 1, ["zhong_fang", "xi", "yun"])
        var ev: Array = d.play_turn(cid, "gui_pai")
        if ev.is_empty():
            bad2 += " %s(非法)" % cid
            continue
        var p0: PlayerState = d.state.players[0]
        var p1: PlayerState = d.state.players[1]
        if p0.hp != int(item[3]) or p1.hp != int(item[4]):
            bad2 += " %s(hp %d/%d)" % [cid, p0.hp, p1.hp]
    _ok("self-buff cards transfer hp to the kui user", bad2 == "", bad2)

    # 运类与盾类单独核对（运会被费用影响，不能只看正负）
    var dy := _duel(5, 50, 0, 300, 300)
    _prep(dy, 1, ["zhong_fang", "xi", "yun"])
    dy.play_turn("yun", "gui_pai")
    _ok("kui steals yun", dy.state.players[0].yun == 50 and dy.state.players[1].yun == 10,
        "yun=%d/%d" % [dy.state.players[0].yun, dy.state.players[1].yun])

    var dq := _duel(5, 50, 0, 300, 300)
    _prep(dq, 1, ["zhong_fang", "xi", "yun"])
    dq.play_turn("qiang_hua_yun", "gui_pai")
    _ok("kui steals qiang_hua_yun",
        dq.state.players[0].yun == 40 and dq.state.players[1].yun == 20,
        "yun=%d/%d" % [dq.state.players[0].yun, dq.state.players[1].yun])

    var dd := _duel(5, 50, 0, 300, 300)
    _prep(dd, 1, ["zhong_fang", "xi", "yun"])
    dd.play_turn("dun", "gui_pai")
    _ok("kui steals shield",
        dd.state.players[0].shields == 0 and dd.state.players[1].shields == 1,
        "sh=%d/%d" % [dd.state.players[0].shields, dd.state.players[1].shields])

    # 神之龟派：攻击数值翻倍（对比普通龟派的掉血量）
    var d1 := _duel(5, 20, 0, 500, 500)
    _prep(d1, 1, ["zhong_fang", "xi", "yun"])
    d1.play_turn("kai_sa", "gui_pai")
    var normal_loss := 500 - d1.state.players[0].hp

    var d2 := _duel(5, 20, 0, 500, 500)
    _prep(d2, 1, ["jue_xing_zhong_fang", "chao_ji_xi", "qiang_hua_yun"])
    d2.play_turn("kai_sa", "shen_zhi_gui_pai")
    var double_loss := 500 - d2.state.players[0].hp
    _ok("shen zhi gui pai doubles the redirected damage",
        double_loss == normal_loss * 2,
        "normal=%d double=%d" % [normal_loss, double_loss])


func _test_kui_scale() -> void:
    print("[shen zhi gui pai scale scope]")
    var hist := ["jue_xing_zhong_fang", "chao_ji_xi", "qiang_hua_yun"]

    # 酒：免疫阈值不是 ±血量/±运，不翻倍 —— B 身上 1.5 的 dot 照挨
    var d1 := _duel(5, 10, 0, 300, 300)
    d1.state.players[1].add_dot(150, 1, 1, 1)
    _prep(d1, 1, hist)
    d1.play_turn("jiu", "shen_zhi_gui_pai")
    _ok("shen kui keeps wine threshold at <=1", d1.state.players[1].hp == 150,
        "hp1=%d" % d1.state.players[1].hp)

    # 毒药：比例伤害不翻倍，打回 A（3.0 血 → 剩 0.6）
    var d2 := _duel(5, 20, 0, 300, 300)
    _prep(d2, 1, hist)
    d2.play_turn("du_yao", "shen_zhi_gui_pai")
    _ok("shen kui does not double poison 80%", d2.state.players[0].hp == 60,
        "hp0=%d" % d2.state.players[0].hp)

    # 三棱镜：公式伤害不翻倍（k=0 → 0.4）
    var d3 := _duel(5, 10, 0, 300, 300)
    _prep(d3, 1, hist)
    d3.play_turn("san_leng_jing", "shen_zhi_gui_pai")
    _ok("shen kui does not double prism formula", d3.state.players[0].hp == 260,
        "hp0=%d" % d3.state.players[0].hp)

    # 比心：±运翻倍，-2 → -4（下限 -3 仍生效）；再扣 2 费
    var d4 := _duel(5, 50, 0, 300, 300)
    _prep(d4, 1, hist)
    d4.play_turn("bi_xin", "shen_zhi_gui_pai")
    _ok("shen kui doubles yun loss (-2 -> -4)", d4.state.players[0].yun == -10,
        "yun0=%d" % d4.state.players[0].yun)

    # 定海：-1.6 → -3.2，+0.6 → +1.2
    var d5 := _duel(5, 40, 0, 500, 300)
    _prep(d5, 1, hist)
    d5.play_turn("ding_hai_shen_zhen", "shen_zhi_gui_pai")
    _ok("shen kui doubles ding_hai both ways",
        d5.state.players[0].hp == 180 and d5.state.players[1].hp == 420,
        "hp=%d/%d" % [d5.state.players[0].hp, d5.state.players[1].hp])

    # 桃桃：+0.5 → +1.0，且加到龟派者身上
    var d6 := _duel(5, 10, 0, 300, 300)
    _prep(d6, 1, hist)
    d6.play_turn("tao_tao", "shen_zhi_gui_pai")
    _ok("shen kui doubles heal to 1.0", d6.state.players[1].hp == 400,
        "hp1=%d hp0=%d" % [d6.state.players[1].hp, d6.state.players[0].hp])

    # 对照：普通龟派不翻倍
    var d7 := _duel(5, 10, 0, 300, 300)
    _prep(d7, 1, ["zhong_fang", "xi", "yun"])
    d7.play_turn("tao_tao", "gui_pai")
    _ok("plain kui does not double", d7.state.players[1].hp == 350,
        "hp1=%d" % d7.state.players[1].hp)


func _test_ai() -> void:
    print("[ai match]")
    var r1 := _run_ai(12345)
    var r2 := _run_ai(12345)
    var same := int(r1["winner"]) == int(r2["winner"]) \
        and int(r1["turn"]) == int(r2["turn"]) \
        and int(r1["hp"][0]) == int(r2["hp"][0]) \
        and int(r1["hp"][1]) == int(r2["hp"][1])
    _ok("same seed produces same match", same)
    _ok("match terminates or hits cap", bool(r1["over"]) or int(r1["turn"]) >= 40,
        "turn=%d" % int(r1["turn"]))
    print("    ai result: winner=%d turn=%d hp=%s" % [int(r1["winner"]), int(r1["turn"]), str(r1["hp"])])


func _run_ai(seed_value: int) -> Dictionary:
    var d := Duel.new(db)
    var rng := RandomNumberGenerator.new()
    rng.seed = seed_value
    var guard := 0
    while not d.state.over and d.state.turn < 40 and guard < 100:
        guard += 1
        var a := SimpleAI.choose(d, 0, rng, "aggro")
        var b := SimpleAI.choose(d, 1, rng, "turtle")
        if a == "" or b == "":
            break
        var events := d.play_turn(a, b)
        if events.is_empty():
            break
    var hp: Array[int] = []
    hp.append(d.state.players[0].hp)
    hp.append(d.state.players[1].hp)
    return {
        "over": d.state.over,
        "winner": d.state.winner,
        "turn": d.state.turn,
        "hp": hp,
    }
