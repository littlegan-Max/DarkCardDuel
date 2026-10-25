extends SceneTree

# 观感走查：鄙视/核弹 vs 觉醒中防

func _initialize() -> void:
    var db := CardDB.load_all()
    var d := Duel.new(db)
    d.state.turn = 5
    for p in d.state.players:
        p.hp = 300
        p.hp_max_ever = 300
    d.state.players[0].yun = 40
    d.state.players[1].yun = 10
    for i in 4:
        d.state.players[0].history.append("yun")
    print("甲 鄙视 vs 乙 觉醒中防")
    for e in d.play_turn("bi_shi", "jue_xing_zhong_fang"):
        print("  ", JSON.stringify(e))
    print("甲下回合合法牌=", d.legal_cards(0))
    print("甲 空过 vs 乙 运:", "accepted" if not d.play_turn("pass", "yun").is_empty() else "rejected")
    print("甲再下回合合法数=", d.legal_cards(0).size())
    print("hp=%d/%d" % [d.state.players[0].hp, d.state.players[1].hp])

    var d2 := Duel.new(db)
    d2.state.turn = 5
    for p in d2.state.players:
        p.hp = 300
        p.hp_max_ever = 300
    d2.state.players[0].yun = 40
    d2.state.players[1].yun = 10
    for i in 4:
        d2.state.players[0].history.append("yun")
    print("甲 核弹 vs 乙 觉醒中防")
    for e in d2.play_turn("zhan_shu_he_dan", "jue_xing_zhong_fang"):
        print("  ", JSON.stringify(e))
    print("hp=%d/%d yun=%d/%d" % [d2.state.players[0].hp, d2.state.players[1].hp,
        d2.state.players[0].yun, d2.state.players[1].yun])
    quit(0)
