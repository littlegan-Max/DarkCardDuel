extends SceneTree

# 观感走查：随机跑一局，逐回合打印事件流（含 DAMAGE_RACE / DAMAGE_TIE 的双方总量）

func _initialize() -> void:
    var db := CardDB.load_all()
    var rng := RandomNumberGenerator.new()
    rng.seed = 4242
    var d := Duel.new(db)
    var guard := 0
    while not d.state.over and d.state.turn < 12 and guard < 60:
        guard += 1
        var la := d.legal_cards(0)
        var lb := d.legal_cards(1)
        if la.is_empty() or lb.is_empty():
            break
        var a: String = la[rng.randi_range(0, la.size() - 1)]
        var b: String = lb[rng.randi_range(0, lb.size() - 1)]
        var ev: Array = d.play_turn(a, b)
        if ev.is_empty():
            print("rejected %s vs %s" % [a, b])
            break
        var line := "T%d %s vs %s |" % [d.state.turn - 1, a, b]
        for e in ev:
            var t := str(e.get("t", ""))
            match t:
                "REVEAL", "SNAPSHOT", "SETTLE":
                    continue
                "DAMAGE":
                    line += " DMG(%d→%d %d)" % [0, int(e["target"]), int(e["amount"])]
                "DAMAGE_RACE":
                    line += " RACE%dx%d→low=%d" % [int(e["totals"][0]), int(e["totals"][1]), int(e["loser"])]
                "DAMAGE_TIE":
                    line += " TIE(%d=%d)" % [int(e["totals"][0]), int(e["totals"][1])]
                "DOT_END":
                    line += " dot_end"
                "TIME_SPREAD":
                    line += " 时间分散(%d×%d)" % [int(e["amount"]), int(e["turns"])]
                _:
                    line += " " + t
        print(line)
        print("     hp=%d/%d yun=%d/%d dots=%d/%d" % [
            d.state.players[0].hp, d.state.players[1].hp,
            d.state.players[0].yun, d.state.players[1].yun,
            d.state.players[0].dots.size(), d.state.players[1].dots.size()])
    print("over=%s winner=%d turn=%d" % [str(d.state.over), d.state.winner, d.state.turn])
    quit(0)
