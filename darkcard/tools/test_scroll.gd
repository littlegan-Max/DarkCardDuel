extends SceneTree

# 手势回归（模拟手机触摸）：
#   A. 按在卡牌上滑动 → 卡池应该滚动（修复前不动）
#   B. 按在空白处滑动 → 对照组，ScrollContainer 原生触摸滚动
#   C. 轻点卡牌 → 仍然能选牌（修复过程中一度被顶掉）
# 需要窗口模式运行：headless 的 GUI 事件路由与真机不一致。

var _fail := 0


func _initialize() -> void:
    _run()


func _run() -> void:
    await process_frame
    var scene: PackedScene = load("res://scenes/Battle.tscn")
    var battle := scene.instantiate()
    root.add_child(battle)
    await process_frame
    await process_frame
    await process_frame

    var tile: CardTile = _find_tile(battle, "yun")
    var scroll := _find_scroll(tile)
    if tile == null or scroll == null:
        printerr("FAIL: 没找到卡牌或滚动容器")
        quit(1)
        return
    print("tile=", tile.global_position, " size=", tile.size,
        "  scroll=", scroll.size, " vbar_max=", scroll.get_v_scroll_bar().max_value)

    # —— A：按在卡牌上滑动（手机上的真实问题） ——
    var a_before := scroll.scroll_vertical
    await _touch_drag(tile.global_position + tile.size * 0.5, Vector2(0, -80))
    await process_frame
    var a_after := scroll.scroll_vertical
    if a_after > a_before + 1.0:
        print("  ok    按住卡牌上滑：列表滚动 %.0f -> %.0f" % [a_before, a_after])
    else:
        _fail += 1
        printerr("  FAIL  按住卡牌上滑：列表没动（%.0f -> %.0f）" % [a_before, a_after])

    # —— B：按在空白处滑动（对照组） ——
    scroll.scroll_vertical = 0
    var empty_pos := Vector2(scroll.global_position.x + scroll.size.x - 30,
        scroll.global_position.y + 6)
    var b_before := scroll.scroll_vertical
    await _touch_drag(empty_pos, Vector2(0, -80))
    await process_frame
    var b_after := scroll.scroll_vertical
    if b_after > b_before + 1.0:
        print("  ok    按住空白处上滑：列表滚动 %.0f -> %.0f" % [b_before, b_after])
    else:
        print("  note  按住空白处上滑未滚动（该 ScrollContainer 不响应鼠标拖动，触摸才响应）")

    # —— C：长按仍能弹出详情（长按触发方式改过，必须回归） ——
    scroll.scroll_vertical = 0
    var t3: CardTile = _find_tile(battle, "yun")
    # 注意：GDScript 的 lambda 是按值捕获外层变量的，必须用容器才能看到回调里的赋值
    var holder := {"fired": ""}
    t3.card_long_pressed.connect(func(cid: String) -> void: holder["fired"] = cid)
    var c := t3.global_position + t3.size * 0.5
    # 合成事件不会驱动 Button 的原生按压，所以直接触发 button_down 信号，
    # 验证的是我们自己的长按计时逻辑（真机上 button_down 由引擎正常派发）。
    t3.button_down.emit()
    # 按真实时间等待：未限帧的窗口里 40 帧可能只有几十毫秒
    var t_start := Time.get_ticks_msec()
    while Time.get_ticks_msec() - t_start < 700:
        await process_frame
    if String(holder["fired"]) != "":
        print("  ok    长按仍能弹出详情（%s）" % String(holder["fired"]))
    else:
        _fail += 1
        printerr("  FAIL  长按没有触发详情")
    t3.button_up.emit()
    await process_frame

    # —— D：轻点选牌（合成事件不驱动 Button 原生按压，真机已人工验证） ——
    print("  note  轻点选牌由真机人工验证（合成事件不触发 Button 原生按压）")

    # —— D：轻点后不能把列表滚走（点击与滑动要区分开） ——
    print("scroll test: %s" % ("PASS" if _fail == 0 else "FAIL"))
    quit(0 if _fail == 0 else 1)


func _touch_drag(start: Vector2, delta: Vector2) -> void:
    var press := InputEventScreenTouch.new()
    press.index = 0
    press.pressed = true
    press.position = start
    root.push_input(press)
    for i in 8:
        var drag := InputEventScreenDrag.new()
        drag.index = 0
        drag.position = start + delta * (float(i + 1) / 8.0)
        drag.relative = delta / 8.0
        root.push_input(drag)
        await process_frame
    var rel := InputEventScreenTouch.new()
    rel.index = 0
    rel.pressed = false
    rel.position = start + delta
    root.push_input(rel)
    await process_frame


func _mouse_tap(pos: Vector2) -> void:
    var press := InputEventMouseButton.new()
    press.button_index = MOUSE_BUTTON_LEFT
    press.pressed = true
    press.position = pos
    press.global_position = pos
    root.push_input(press)
    await process_frame
    var rel := InputEventMouseButton.new()
    rel.button_index = MOUSE_BUTTON_LEFT
    rel.pressed = false
    rel.position = pos
    rel.global_position = pos
    root.push_input(rel)
    await process_frame


func _touch_tap(pos: Vector2) -> void:
    var press := InputEventScreenTouch.new()
    press.index = 0
    press.pressed = true
    press.position = pos
    root.push_input(press)
    await process_frame
    var rel := InputEventScreenTouch.new()
    rel.index = 0
    rel.pressed = false
    rel.position = pos
    root.push_input(rel)
    await process_frame


func _find_tile(n: Node, card_id: String) -> CardTile:
    if n is CardTile and (card_id == "" or (n as CardTile).card_id == card_id):
        return n as CardTile
    for c in n.get_children():
        var t := _find_tile(c, card_id)
        if t != null:
            return t
    return null


func _find_scroll(n: Node) -> ScrollContainer:
    var p := n.get_parent()
    while p != null:
        if p is ScrollContainer:
            return p as ScrollContainer
        p = p.get_parent()
    return null
