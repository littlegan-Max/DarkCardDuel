extends Control

# 主菜单：选单机还是联机。
#
# 版面：抬头 + 标题 + 三个特征胶囊 + 两个入口卡（联机为金底主操作），
# 底部一行版本号。联机需要先在大厅里连上服务器，所以这里只放两个入口。

const LOBBY_SCENE := "res://scenes/lobby/Lobby.tscn"
const BATTLE_SCENE := "res://scenes/Battle.tscn"

## 逻辑宽度超过这个值就切桌面版面（和联机大厅用同一个断点）
const WIDE_MIN := 900.0

var _status: Label
var _ui_root: Control
var _is_wide := false


func _ready() -> void:
	_build_ui()
	get_viewport().size_changed.connect(_on_viewport_resized)


func _build_ui() -> void:
	_is_wide = get_viewport_rect().size.x >= WIDE_MIN
	if _ui_root != null and is_instance_valid(_ui_root):
		_ui_root.queue_free()
	_ui_root = Control.new()
	_ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui_root.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_ui_root)

	UiKit.backdrop(_ui_root)

	var cc := CenterContainer.new()
	_ui_root.add_child(cc)
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	if _is_wide:
		_build_wide(cc)
	else:
		_build_narrow(cc)

	# 版本号钉在屏幕底部
	var ver := UiKit.label("v" + str(ProjectSettings.get_setting(
		"application/config/version", "")), 10, UiPalette.DIM)
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ui_root.add_child(ver)
	ver.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	ver.offset_top = -34
	ver.offset_bottom = -16


## 桌面版：左边立标题，右边两个入口。手机那套居中一列直接放大只会显得空。
func _build_wide(cc: CenterContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 56)
	row.custom_minimum_size = Vector2(980, 0)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	cc.add_child(row)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 12)
	left.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(left)

	var emblem := _emblem()
	emblem.alignment = BoxContainer.ALIGNMENT_BEGIN
	left.add_child(emblem)
	left.add_child(UiKit.kicker("DARK CARD DUEL", UiPalette.GOLD_DEEP))

	var title := UiKit.label("暗牌技能对战", 52, UiPalette.GOLD)
	title.add_theme_constant_override("line_spacing", 0)
	left.add_child(title)

	var sub := UiKit.label("1v1 同时翻牌 · 读对方的手，藏自己的牌", 14, UiPalette.DIM)
	left.add_child(sub)

	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 8)
	left.add_child(chips)
	for t in ["读心", "1v1", "同时翻牌"]:
		chips.add_child(UiKit.chip(t, UiPalette.DIM))

	row.add_child(UiKit.spacer())

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 14)
	right.custom_minimum_size = Vector2(380, 0)
	row.add_child(right)

	right.add_child(_entry("联机对战", "匹配 · 开房间 · 好友", true,
		func() -> void: _go(LOBBY_SCENE)))
	right.add_child(_entry("单机对战", "对着 AI 打一局", false,
		func() -> void: _go(BATTLE_SCENE)))

	_status = UiKit.label("", 11, UiPalette.DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_status)


## 手机版：居中一列
func _build_narrow(cc: CenterContainer) -> void:
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 0)
	v.custom_minimum_size = Vector2(340, 0)
	cc.add_child(v)

	v.add_child(_emblem())

	var gap0 := Control.new()
	gap0.custom_minimum_size.y = 14
	v.add_child(gap0)

	v.add_child(UiKit.kicker("DARK CARD DUEL", UiPalette.GOLD_DEEP))

	var title := UiKit.label("暗牌技能对战", 36, UiPalette.GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_constant_override("line_spacing", 0)
	v.add_child(title)

	var chips := HBoxContainer.new()
	chips.alignment = BoxContainer.ALIGNMENT_CENTER
	chips.add_theme_constant_override("separation", 7)
	v.add_child(chips)
	for t in ["读心", "1v1", "同时翻牌"]:
		chips.add_child(UiKit.chip(t, UiPalette.DIM))

	var gap1 := Control.new()
	gap1.custom_minimum_size.y = 40
	v.add_child(gap1)

	v.add_child(_entry("联机对战", "匹配 · 开房间 · 好友", true,
		func() -> void: _go(LOBBY_SCENE)))

	var gap2 := Control.new()
	gap2.custom_minimum_size.y = 12
	v.add_child(gap2)

	v.add_child(_entry("单机对战", "对着 AI 打一局", false,
		func() -> void: _go(BATTLE_SCENE)))

	var gap3 := Control.new()
	gap3.custom_minimum_size.y = 26
	v.add_child(gap3)

	_status = UiKit.label("", 11, UiPalette.DIM)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_status)


func _on_viewport_resized() -> void:
	var wide := get_viewport_rect().size.x >= WIDE_MIN
	if wide != _is_wide:
		_build_ui()


## 标识：两张扣着的牌夹一个「VS」，一眼看出是同时翻牌的 1v1。
func _emblem() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)

	row.add_child(_card_back(-13.0))
	var vs := UiKit.label("VS", 11, UiPalette.GOLD_DEEP)
	vs.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(vs)
	row.add_child(_card_back(13.0))
	return row


func _card_back(tilt: float) -> Panel:
	var c := Panel.new()
	c.custom_minimum_size = Vector2(40, 56)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#141C2E")
	sb.border_color = Color(UiPalette.GOLD.r, UiPalette.GOLD.g, UiPalette.GOLD.b, 0.55)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	c.add_theme_stylebox_override("panel", sb)

	# 内嵌一圈细线，读起来像牌背的花纹，而不是一个空框
	var inner := Panel.new()
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.position = Vector2(5, 5)
	inner.size = Vector2(30, 46)
	var ib := StyleBoxFlat.new()
	ib.bg_color = Color(0, 0, 0, 0)
	ib.border_color = Color(UiPalette.GOLD.r, UiPalette.GOLD.g, UiPalette.GOLD.b, 0.22)
	ib.set_border_width_all(1)
	ib.set_corner_radius_all(4)
	inner.add_theme_stylebox_override("panel", ib)
	c.add_child(inner)

	# 中间一枚小菱形，像牌背的花纹
	var pip := Panel.new()
	pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pip.size = Vector2(9, 9)
	var pb := StyleBoxFlat.new()
	pb.bg_color = Color(UiPalette.GOLD.r, UiPalette.GOLD.g, UiPalette.GOLD.b, 0.5)
	pb.set_corner_radius_all(1)
	pip.add_theme_stylebox_override("panel", pb)
	c.add_child(pip)
	pip.pivot_offset = pip.size / 2.0
	pip.rotation = deg_to_rad(45.0)
	pip.position = (c.custom_minimum_size - pip.size) / 2.0

	c.pivot_offset = c.custom_minimum_size / 2.0
	c.rotation = deg_to_rad(tilt)
	return c


## 一个入口卡：标题 + 一行说明。金底是主入口，描边是次入口。
## 说明文字用子 Label 叠在按钮里，Button.text 只留标题（有测试按文本找按钮）。
func _entry(title: String, desc: String, primary: bool, cb: Callable) -> Button:
	var b: Button
	if primary:
		b = UiKit.primary(title, 74, 16)
	else:
		b = UiKit.ghost(title, 74, 16)

	b.custom_minimum_size = Vector2(380 if _is_wide else 340, 74)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override("font_size", 19)

	# 顶到上半区，把下半区留给说明文字
	for s in ["normal", "hover", "pressed", "disabled"]:
		if b.has_theme_stylebox_override(s):
			var sb: StyleBoxFlat = (b.get_theme_stylebox(s) as StyleBoxFlat).duplicate()
			sb.content_margin_left = 20
			sb.content_margin_right = 20
			sb.content_margin_top = 9
			sb.content_margin_bottom = 25
			b.add_theme_stylebox_override(s, sb)

	var sub := UiKit.label(desc, 11, Color("#2A2013") if primary else UiPalette.DIM)
	sub.position = Vector2(21, 45)
	sub.size = Vector2(290, 16)
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(sub)

	b.pressed.connect(cb)
	return b


func _go(path: String) -> void:
	if not ResourceLoader.exists(path):
		_status.text = "找不到场景：" + path
		_status.add_theme_color_override("font_color", UiPalette.RED)
		return
	# 切换必须走 SceneRouter：新场景要挂到 root 下，
	# 直接 add_child 到自己身上会跟着本节点一起被释放（黑屏）。
	var next: Control = load(path).instantiate()
	SceneRouter.swap(get_tree(), next)
