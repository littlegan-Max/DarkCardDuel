extends Node

# 桌面端的窗口与全屏。
#
# 这是个竖屏 540x960 的游戏。电脑是宽屏，两者比例对不上，只有三种做法：
#   a) 横向拉伸铺满 —— 按钮变成 1600px 长条、字号缩到 10px，难看且难用（原来的做法，已废弃）
#   b) 保持比例居中 —— 画面不变形，宽出来的部分留边（现在的做法）
#   c) 为宽屏重做一套横排布局 —— 战斗界面要整体重排，是另一个工程量的活
#
# 这里做 b：
#   · 项目里 stretch/aspect 设成 keep，任何窗口尺寸下画面都不变形、不拉伸
#   · 启动时把窗口按屏幕高度放大到合适的竖屏尺寸（大屏上不至于只有一小条）
#   · F11 / Alt+Enter 切全屏
#
# 注意：全屏时左右留边是纯黑，这是引擎 letterbox 的窗口区，clear color 管不到。
# 想让留边有颜色，只有改成 c 那条路。

const BASE := Vector2(540, 960)


func _ready() -> void:
	set_process_unhandled_input(true)
	if OS.has_feature("pc"):
		_fit_window_to_screen()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	var hit := key.keycode == KEY_F11
	if key.keycode == KEY_ENTER and key.alt_pressed:
		hit = true
	if not hit:
		return
	toggle_fullscreen()
	get_viewport().set_input_as_handled()


## 全屏 ↔ 窗口
func toggle_fullscreen() -> void:
	var win := get_window()
	if win == null:
		return
	win.mode = Window.MODE_WINDOWED if win.mode == Window.MODE_FULLSCREEN \
		else Window.MODE_FULLSCREEN


## 把窗口调成「屏幕放得下的最大竖屏」，并居中。
## 只在大屏上放大；屏幕本来就和设计尺寸差不多时不动它。
func _fit_window_to_screen() -> void:
	var win := get_window()
	if win == null or DisplayServer.get_name() == "headless":
		return
	if win.mode != Window.MODE_WINDOWED:
		return

	# 启动时窗口尺寸已经被别人定过（命令行 --resolution、或用户上次的记忆），
	# 就别再插手，否则会把外部指定的尺寸覆盖掉。
	var base := Vector2i(int(BASE.x), int(BASE.y))
	if win.size != base:
		return

	var usable := DisplayServer.screen_get_usable_rect(win.current_screen)
	if usable.size.x <= 0 or usable.size.y <= 0:
		return

	# 高度吃到屏幕的 90%，宽度按 9:16 反推；上限 1400 是防止 4K 屏上窗口过大
	var h := int(min(float(usable.size.y) * 0.9, 1400.0))
	var w := int(round(float(h) * BASE.x / BASE.y))
	if w <= 0 or h <= 0:
		return
	w = mini(w, usable.size.x)
	h = mini(h, usable.size.y)

	# 跟当前尺寸差得不多就别动，免得每次启动窗口大小乱跳
	var cur := win.size
	if absi(cur.x - w) < 24 and absi(cur.y - h) < 24:
		return

	win.size = Vector2i(w, h)
	win.position = usable.position + (usable.size - win.size) / 2
