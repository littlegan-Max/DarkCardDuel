extends SceneTree

# 特征向量跨语言比对：Python 训练时的特征，和 GDScript 游戏里算的特征必须一致。
# 不一致的后果很隐蔽：策略网络能正常前向，但输入是错的 → AI 表现得像随机。
#
# 用法：godot --headless --path . --script res://tools/test_policy_features.gd

func _initialize() -> void:
    var f := FileAccess.open("res://tests/features_ref.json", FileAccess.READ)
    if f == null:
        printerr("FAIL: 读不到参考文件")
        quit(1)
        return
    var ref = JSON.parse_string(f.get_as_text())
    f.close()

    var db := CardDB.load_all()
    var d := Duel.new(db)
    d.state.turn = int(ref["state"]["turn"])
    var p0 := d.state.players[0]
    var p1 := d.state.players[1]
    p0.yun = int(ref["state"]["yun0"])
    p1.yun = int(ref["state"]["yun1"])
    p0.hp = int(ref["state"]["hp0"])
    p0.hp_max_ever = int(ref["state"]["hp0"])
    p1.hp = int(ref["state"]["hp1"])
    p1.hp_max_ever = int(ref["state"]["hp1"])
    p0.shields = int(ref["state"]["shields0"])
    p1.shields = int(ref["state"]["shields1"])
    for c in ref["state"]["history0"]:
        p0.history.append(str(c))
    for c in ref["state"]["history1"]:
        p1.history.append(str(c))
    p0.last_played["zhong_fang"] = 1
    p0.last_played["yun"] = 2
    p1.last_played["yun"] = 1

    var net := PolicyNet.new()
    if not net.load_file("res://data/policy_net.json"):
        printerr("FAIL: 权重文件加载失败")
        quit(1)
        return

    var bad := 0
    bad += _compare(net.make_features(d, 0), ref["features_p0"], "p0")
    bad += _compare(net.make_features(d, 1), ref["features_p1"], "p1")
    if bad == 0:
        print("  ok    特征向量与 Python 训练侧完全一致")
        quit(0)
    else:
        printerr("  FAIL  特征向量有 %d 处不一致" % bad)
        quit(1)


func _compare(got: Array, want: Array, label: String) -> int:
    if got.size() != want.size():
        printerr("  FAIL  %s 维度不一致：gd=%d py=%d" % [label, got.size(), want.size()])
        return 1
    var bad := 0
    for i in got.size():
        var d := absf(float(got[i]) - float(want[i]))
        if d > 0.0001:
            bad += 1
            if bad <= 3:
                printerr("  FAIL  %s[%d] gd=%.6f py=%.6f" % [label, i, float(got[i]), float(want[i])])
    return bad
