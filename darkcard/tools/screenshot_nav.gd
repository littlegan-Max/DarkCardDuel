extends SceneTree

# 导航实拍：走一遍玩家真实路径，每一步截屏并自动判断「是不是黑屏」。
#
#   godot --path <proj> --script res://tools/screenshot_nav.gd   （不是 headless，要真实渲染）
#
# 黑屏判定：把画面缩到很小后统计颜色种类。
# 正常界面（按钮、文字、面板）至少有几十种颜色；
# 真黑屏只有 1~2 种。

const OUT_DIR := "C:/Users/ghy/WorkBuddy/2026-10-25-10-37-36/shots"

var _fails := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	# —— 主菜单 ——
	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	await process_frame
	await process_frame
	await _shot("main", "主菜单")

	# —— 点「单机对战」——
	var btn := _find_btn(main, "单机对战")
	if btn == null:
		printerr("[FAIL] 主菜单上找不到「单机对战」按钮")
		_fails += 1
	else:
		btn.pressed.emit()
		await create_timer(0.8).timeout
		await _shot("battle", "点「单机对战」之后")

		# 对局中点「菜单」：退出确认层
		var battle: Node = current_scene
		var menu_btn := _find_btn(battle, "菜单")
		if menu_btn == null:
			printerr("[FAIL] 对局界面没有「菜单」按钮")
			_fails += 1
		else:
			# 量一下顶栏有没有挤出屏幕右边
			var vp := Vector2(540, 960)
			for lbl in ["画像", "日志", "重开", "菜单"]:
				var b := _find_btn(battle, lbl)
				if b != null:
					var r: Rect2 = b.get_global_rect()
					print("   顶栏 %s：x=%.0f..%.0f（屏幕宽 %.0f）" % [
						lbl, r.position.x, r.position.x + r.size.x, vp.x])
					if r.position.x + r.size.x > vp.x:
						printerr("[FAIL] 「%s」按钮超出屏幕右边缘（%.0f > %.0f）" % [
							lbl, r.position.x + r.size.x, vp.x])
						_fails += 1
			menu_btn.pressed.emit()
			await create_timer(0.4).timeout
			await _shot("exit_confirm", "对局中点「菜单」")

	# —— 回到主菜单，点「联机对战」——
	var main2: Node = load("res://scenes/main/Main.tscn").instantiate()
	root.add_child(main2)
	current_scene = main2
	await process_frame
	var btn2 := _find_btn(main2, "联机对战")
	if btn2 == null:
		printerr("[FAIL] 主菜单上找不到「联机对战」按钮")
		_fails += 1
	else:
		btn2.pressed.emit()
		await create_timer(0.8).timeout
		await _shot("lobby", "点「联机对战」之后")

	print("")
	print("[screenshot_nav] %d 项失败" % _fails)
	quit(1 if _fails > 0 else 0)


## 截屏 + 黑屏判定
func _shot(tag: String, desc: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, tag]
	print("%s → %s" % [desc, img.save_png(path)])

	var small := img.duplicate()
	small.resize(48, 80, Image.INTERPOLATE_BILINEAR)
	var colors := {}
	for y in range(small.get_height()):
		for x in range(small.get_width()):
			colors[small.get_pixel(x, y).to_rgba32()] = true
	var n := colors.size()
	if n <= 3:
		printerr("[FAIL] %s 是黑屏（只有 %d 种颜色）" % [desc, n])
		_fails += 1
	else:
		print("[OK]   %s 不是黑屏（%d 种颜色）" % [desc, n])


func _find_btn(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n as Button
	for c in n.get_children():
		var r := _find_btn(c, text)
		if r != null:
			return r
	return null
