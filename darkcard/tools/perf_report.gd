extends SceneTree

# 性能基线采集：跑真实战斗场景，按帧采样 FPS / DrawCall / 节点数 / 内存 / 脚本耗时，
# 输出分布（min/avg/max），用于和 03 文件里的预算线对照。
# 用法：godot --path . --script res://tools/perf_report.gd -- [秒数]

var _samples: Array[Dictionary] = []
var _elapsed := 0.0
var _duration := 12.0


func _initialize() -> void:
    for a in OS.get_cmdline_user_args():
        if a.is_valid_float():
            _duration = float(a)
    _run()


func _run() -> void:
    await process_frame
    var scene: PackedScene = load("res://scenes/Battle.tscn")
    var battle := scene.instantiate()
    root.add_child(battle)
    await process_frame
    await process_frame

    # 采样前先跑几秒让 JIT/纹理加载稳定
    var warmup := 2.0
    var t0 := Time.get_ticks_msec()
    while Time.get_ticks_msec() - t0 < warmup * 1000:
        await process_frame

    _elapsed = 0.0
    while _elapsed < _duration:
        var dt := root.get_process_delta_time()
        _elapsed += dt
        _samples.append({
            "fps": Performance.get_monitor(Performance.TIME_FPS),
            "draw": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
            "nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
            "objects": Performance.get_monitor(Performance.OBJECT_COUNT),
            "static_mem": Performance.get_monitor(Performance.MEMORY_STATIC),
            "proc": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
            "physics": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
            "card_tiles": _count_tiles(battle),
        })
        await process_frame

    _report()
    quit(0)


func _count_tiles(battle: Node) -> int:
    var n := 0
    var stack: Array[Node] = [battle]
    while not stack.is_empty():
        var cur: Node = stack.pop_back()
        if cur is CardTile:
            n += 1
        for c in cur.get_children():
            stack.append(c)
    return n


func _report() -> void:
    if _samples.is_empty():
        printerr("没有采样到数据")
        return
    var keys := ["fps", "draw", "nodes", "objects", "static_mem", "proc", "physics", "card_tiles"]
    var names := {
        "fps": "FPS", "draw": "DrawCall/帧", "nodes": "节点数", "objects": "对象数",
        "static_mem": "静态内存(MB)", "proc": "脚本耗时(ms)", "physics": "物理耗时(ms)",
        "card_tiles": "卡牌实例数",
    }
    print("=== 性能基线（窗口模式 · 战斗场景 · %.0f 秒 · %d 帧采样） ===" % [_duration, _samples.size()])
    print("  %-14s %10s %10s %10s" % ["指标", "min", "avg", "max"])
    for k in keys:
        var mn := 1e18
        var mx := -1e18
        var tot := 0.0
        for s in _samples:
            var v := float(s[k])
            mn = minf(mn, v)
            mx = maxf(mx, v)
            tot += v
        var avg := tot / float(_samples.size())
        if k == "static_mem":
            mn /= 1048576.0
            avg /= 1048576.0
            mx /= 1048576.0
        print("  %-14s %10.2f %10.2f %10.2f" % [names[k], mn, avg, mx])

    # 与 03 文件的预算线对照
    var fps_avg := 0.0
    var draw_max := 0.0
    var mem_max := 0.0
    for s in _samples:
        fps_avg += float(s["fps"])
        draw_max = maxf(draw_max, float(s["draw"]))
        mem_max = maxf(mem_max, float(s["static_mem"]))
    fps_avg /= float(_samples.size())
    print("--- 预算对照（03 文件：60 FPS / DrawCall ≤ 100 / 内存 ≤ 200MB） ---")
    print("  FPS        %s  (%.1f)" % ["PASS" if fps_avg >= 55.0 else "WARN", fps_avg])
    print("  DrawCall   %s  (%.0f)" % ["PASS" if draw_max <= 100.0 else "WARN", draw_max])
    print("  内存       %s  (%.1f MB)" % ["PASS" if mem_max / 1048576.0 <= 200.0 else "WARN", mem_max / 1048576.0])
    print("  注：以上为本机（RTX 4060 笔记本）数据，不等于低端真机；真机数据待补。")
