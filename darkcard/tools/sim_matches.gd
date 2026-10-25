extends SceneTree

# 批量对局模拟：验证 26 张牌的覆盖、对局长度、死循环
# godot --headless --path <proj> --script res://tools/sim_matches.gd

const MATCHES := 400
const TURN_CAP := 40


func _initialize() -> void:
    var db := CardDB.load_all()
    var sum_turn := 0
    var cap_hit := 0
    var wins := [0, 0]
    var use := {}
    var longest := 0

    for s in MATCHES:
        var d := Duel.new(db)
        var rng := RandomNumberGenerator.new()
        rng.seed = 90000 + s
        var guard := 0
        while not d.state.over and d.state.turn < TURN_CAP and guard < 80:
            guard += 1
            var a := SimpleAI.choose(d, 0, rng, "aggro")
            var b := SimpleAI.choose(d, 1, rng, "turtle")
            if a == "" or b == "":
                break
            use[a] = int(use.get(a, 0)) + 1
            use[b] = int(use.get(b, 0)) + 1
            var ev := d.play_turn(a, b)
            if ev.is_empty():
                break
        sum_turn += d.state.turn
        longest = maxi(longest, d.state.turn)
        if d.state.over:
            wins[d.state.winner] += 1
        else:
            cap_hit += 1

    print("matches=%d  avg_turns=%.1f  longest=%d  cap_hit=%d  aggro=%d turtle=%d" % [
        MATCHES, float(sum_turn) / float(MATCHES), longest, cap_hit, wins[0], wins[1],
    ])

    var unused: Array[String] = []
    var rows: Array[Array] = []
    for cid in db.order:
        if not use.has(cid):
            unused.append(cid)
        else:
            rows.append([cid, int(use[cid])])
    rows.sort_custom(func(x, y): return int(x[1]) > int(y[1]))

    var top := ""
    for i in mini(5, rows.size()):
        top += "%s=%d  " % [db.get_def(str(rows[i][0])).display_name, int(rows[i][1])]
    print("top5> " + top)
    print("unused(%d)> %s" % [unused.size(), ", ".join(unused)])
    quit(0)
