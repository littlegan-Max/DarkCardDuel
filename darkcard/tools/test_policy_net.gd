extends SceneTree

# 校验策略网络前向：用固定权重 + 固定输入，比对 Python 的参考输出。

func _initialize() -> void:
    var net := PolicyNet.new()
    if not net.load_file("res://tests/policy_net_ref.json"):
        printerr("load failed")
        quit(1)
        return
    var f := FileAccess.open("res://tests/policy_net_ref.json", FileAccess.READ)
    var ref = JSON.parse_string(f.get_as_text())
    f.close()

    var x: Array = []
    for v in ref["test_input"]:
        x.append(float(v))
    var want: Array = ref["expected"]

    var idx: Array[int] = []
    for i in want.size():
        idx.append(i)
    var got: Array = net.probs(x, idx)

    var max_diff := 0.0
    for i in want.size():
        max_diff = maxf(max_diff, absf(float(got[i]) - float(want[i])))
    print("actions=%d  max_abs_diff=%.6f" % [got.size(), max_diff])
    quit(0 if max_diff < 1e-4 else 1)
