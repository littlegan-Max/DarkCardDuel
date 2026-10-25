extends SceneTree

# 随机出牌压测：不依赖 AI 智能，只验证 50 张牌的组合路径都能结算、不崩溃、不死循环
# godot --headless --path <proj> --script res://tools/sim_random.gd

const MATCHES := 3000
const TURN_CAP := 120


func _initialize() -> void:
    var db := CardDB.load_all()
    var rng := RandomNumberGenerator.new()
    rng.seed = 424242

    var stuck := 0
    var cap_hit := 0
    var total_turns := 0
    var use := {}
    var errors := 0

    for m in MATCHES:
        var d := Duel.new(db)
        var guard := 0
        while not d.state.over and d.state.turn < TURN_CAP and guard < 400:
            guard += 1
            var la := d.legal_cards(0)
            var lb := d.legal_cards(1)
            if la.is_empty() or lb.is_empty():
                stuck += 1
                break
            var a: String = la[rng.randi_range(0, la.size() - 1)]
            var b: String = lb[rng.randi_range(0, lb.size() - 1)]
            use[a] = int(use.get(a, 0)) + 1
            use[b] = int(use.get(b, 0)) + 1
            var ev := d.play_turn(a, b)
            if ev.is_empty():
                errors += 1
                print("  empty resolve at match %d turn %d: %s vs %s" % [m, d.state.turn, a, b])
                break
            if d.state.turn >= TURN_CAP:
                cap_hit += 1
        total_turns += d.state.turn

    print("matches=%d  avg_turns=%.1f  stuck=%d  cap_hit=%d  empty_resolve=%d" % [
        MATCHES, float(total_turns) / float(MATCHES), stuck, cap_hit, errors,
    ])

    var unused: Array[String] = []
    var rows: Array[Array] = []
    for cid in db.order:
        if not use.has(cid):
            unused.append(cid)
        else:
            rows.append([cid, int(use[cid])])
    rows.sort_custom(func(x, y): return int(x[1]) > int(y[1]))

    var low := ""
    for i in range(maxi(0, rows.size() - 5), rows.size()):
        low += "%s=%d  " % [db.get_def(str(rows[i][0])).display_name, int(rows[i][1])]
    print("least-used> " + low)
    print("unused(%d)> %s" % [unused.size(), ", ".join(unused)])
    quit(0)
