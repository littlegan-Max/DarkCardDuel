extends SceneTree

# 截图：godot --path <proj> --script res://tools/screenshot.gd
# 不是 headless —— 需要真实渲染，用于检查字体、布局与视觉

func _initialize() -> void:
    _run()


func _run() -> void:
    var battle = load("res://scenes/Battle.tscn").instantiate()
    root.add_child(battle)
    await process_frame

    battle.debug_hold = false
    battle.debug_autoplay_turn()
    await create_timer(1.25).timeout

    battle.debug_hold = true
    battle.debug_ai_card = "zhong_fang"
    battle.debug_autoplay_turn()
    await create_timer(1.2).timeout

    await RenderingServer.frame_post_draw
    var img := root.get_texture().get_image()
    print("battle: %s" % str(img.save_png("res://screenshot.png")))

    # 长按详情层
    battle._on_tile_long_pressed("gui_pai")
    await create_timer(0.45).timeout
    await RenderingServer.frame_post_draw
    var img2 := root.get_texture().get_image()
    print("detail: %s" % str(img2.save_png("res://screenshot_detail.png")))

    # 对手画像面板：先灌入一些样本让它有内容
    var m = battle.opponent_model
    if m != null:
        for i in 9:
            m.observe("t1|hp_hi|y0|res", "yun", ["resource"], false, false)
        for i in 6:
            m.observe("t2_3|hp_mid|y1_2|atk", "xiao_biao", ["attack"], false, false)
        for i in 4:
            m.observe("t2_3|hp_mid|y1_2|atk", "zhong_fang", ["defense"], false, false)
        for i in 3:
            m.observe("t4p|hp_lo|y0|def", "tao_tao", ["heal"], false, false)
        m.matches = 7
        m.max_streak = 4
    battle._on_tile_long_pressed("gui_pai")
    await create_timer(0.3).timeout
    battle._detail.close()
    await create_timer(0.2).timeout
    battle._toggle_profile()
    await create_timer(0.45).timeout
    await RenderingServer.frame_post_draw
    var img3 := root.get_texture().get_image()
    print("profile: %s" % str(img3.save_png("res://screenshot_profile.png")))

    quit(0)
