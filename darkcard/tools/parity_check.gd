extends SceneTree

# 双引擎对拍：重放 Python 引擎导出的随机动作序列，逐步比对状态。
# godot --headless --path . --script res://tools/parity_check.gd

const CASES := "res://tests/parity_cases.json"


func _initialize() -> void:
    var db := CardDB.load_all()
    if not FileAccess.file_exists(CASES):
        printerr("missing " + CASES)
        quit(1)
        return
    var txt := FileAccess.get_file_as_string(CASES)
    var data = JSON.parse_string(txt)
    if data == null or not (data is Dictionary):
        printerr("bad json")
        quit(1)
        return

    var cases: Array = data.get("cases", [])
    var mismatches := 0
    var steps_total := 0
    var rejected := 0
    var legal_mismatch := 0
    var first_report := true
    var first_legal := true

    for c in cases:
        var seed_i := int(c.get("seed", -1))
        var d := Duel.new(db)

        # 预置状态：连招进度 / 高运 / 盾 / dot / 葵
        var init = c.get("init", null)
        if init is Dictionary:
            d.state.turn = int(init.get("turn", 0))
            var ihp: Array = init.get("hp", [100, 100])
            var iyun: Array = init.get("yun", [0, 0])
            var ish: Array = init.get("shields", [0, 0])
            for k in 2:
                d.state.players[k].hp = int(ihp[k])
                d.state.players[k].hp_max_ever = int(ihp[k])
                d.state.players[k].yun = int(iyun[k])
                d.state.players[k].shields = int(ish[k])
            for h in init.get("history0", []):
                d.state.players[0].history.append(str(h))
            for h in init.get("history1", []):
                d.state.players[1].history.append(str(h))
            for k2 in 2:
                for dd in init.get("dots%d" % k2, []):
                    d.state.players[k2].dots.append({
                        "amount": int(dd[0]), "left": int(dd[1]), "first": int(dd[2]),
                        "source": int(dd[3]),
                        "kind": ("c4" if int(dd[4]) == 1 else "dot"),
                    })
            d.state.players[0].cost_percent = int(init.get("cost0", 100))

        var steps: Array = c.get("steps", [])
        for si in steps.size():
            var st: Dictionary = steps[si]
            if st.has("error"):
                break
            var a := str(st.get("a", ""))
            var b := str(st.get("b", ""))
            # 先比对合法性集合：连招/冷却/费用任何一处判定分叉都会在这里暴露
            if st.has("legal"):
                var want: Array = st["legal"]
                for side in 2:
                    var mine := d.legal_cards(side)
                    var theirs: Array = want[side]
                    if mine.size() != theirs.size():
                        legal_mismatch += 1
                        if first_legal:
                            printerr("  seed=%d step=%d side=%d: legal %d vs %d" % [
                                seed_i, si, side, mine.size(), theirs.size()])
                            first_legal = false
                    else:
                        for k in mine.size():
                            if str(mine[k]) != str(theirs[k]):
                                legal_mismatch += 1
                                if first_legal:
                                    printerr("  seed=%d step=%d side=%d: legal[%d] %s vs %s" % [
                                        seed_i, si, side, k, str(mine[k]), str(theirs[k])])
                                    first_legal = false
                                break
            var ev := d.play_turn(a, b)
            if ev.is_empty():
                rejected += 1
                if first_report:
                    printerr("  seed=%d step=%d: 本地拒绝 %s vs %s（turn=%d）" % [seed_i, si, a, b, d.state.turn])
                    first_report = false
                break
            steps_total += 1

            var aft: Dictionary = st.get("after", {})
            var s := d.state
            var want_hp: Array = aft.get("hp", [0, 0])
            var want_yun: Array = aft.get("yun", [0, 0])
            var want_sh: Array = aft.get("shields", [0, 0])
            var want_dots: Array = aft.get("dots", [0, 0])
            var want_cost: Array = aft.get("cost", [100, 100])

            var bad := ""
            for k in 2:
                if s.players[k].hp != int(want_hp[k]):
                    bad += " hp%d=%d(want %d)" % [k, s.players[k].hp, int(want_hp[k])]
                if s.players[k].yun != int(want_yun[k]):
                    bad += " yun%d=%d(want %d)" % [k, s.players[k].yun, int(want_yun[k])]
                if s.players[k].shields != int(want_sh[k]):
                    bad += " sh%d=%d(want %d)" % [k, s.players[k].shields, int(want_sh[k])]
                if s.players[k].dots.size() != int(want_dots[k]):
                    bad += " dots%d=%d(want %d)" % [k, s.players[k].dots.size(), int(want_dots[k])]
                if s.players[k].cost_percent != int(want_cost[k]):
                    bad += " cost%d=%d(want %d)" % [k, s.players[k].cost_percent, int(want_cost[k])]
            if s.over != bool(aft.get("over", false)):
                bad += " over=%s(want %s)" % [str(s.over), str(aft.get("over", false))]
            if s.winner != int(aft.get("winner", -1)):
                bad += " winner=%d(want %d)" % [s.winner, int(aft.get("winner", -1))]

            if bad != "":
                mismatches += 1
                if first_report:
                    printerr("  seed=%d step=%d: %s vs %s ->%s" % [seed_i, si, a, b, bad])
                    first_report = false
                break

    print("cases=%d  steps=%d  rejected=%d  state_mismatch=%d  legal_mismatch=%d" % [
        cases.size(), steps_total, rejected, mismatches, legal_mismatch])
    quit(0 if mismatches == 0 and rejected == 0 and legal_mismatch == 0 else 1)
