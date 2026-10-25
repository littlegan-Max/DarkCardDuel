extends Control

# 主菜单：选单机还是联机。
#
# 联机需要先在大厅里连上服务器，所以主菜单只放两个入口。

const LOBBY_SCENE := "res://scenes/lobby/Lobby.tscn"
const BATTLE_SCENE := "res://scenes/Battle.tscn"

var _status: Label


func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	var bg := TextureRect.new()
	bg.texture = UiPalette.gradient(UiPalette.BG_TOP, UiPalette.BG_BOTTOM)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var cc := CenterContainer.new()
	add_child(cc)
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 14)
	v.custom_minimum_size = Vector2(300, 0)
	cc.add_child(v)

	var title := Label.new()
	title.text = "暗牌技能对战"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", UiPalette.GOLD)
	v.add_child(title)

	var sub := Label.new()
	sub.text = "读心 · 1v1 同时翻牌"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 13)
	sub.add_theme_color_override("font_color", UiPalette.DIM)
	v.add_child(sub)

	var local_btn := _big_btn("单机对战", "对着 AI 打一局", func() -> void: _go(BATTLE_SCENE))
	v.add_child(local_btn)

	var online_btn := _big_btn("联机对战", "匹配 / 开房间 / 好友", func() -> void: _go(LOBBY_SCENE))
	v.add_child(online_btn)

	_status = Label.new()
	_status.text = ""
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", 11)
	_status.add_theme_color_override("font_color", UiPalette.DIM)
	v.add_child(_status)


func _go(path: String) -> void:
	if not ResourceLoader.exists(path):
		_status.text = "找不到场景：" + path
		_status.add_theme_color_override("font_color", UiPalette.RED)
		return
	# 切换必须走 SceneRouter：新场景要挂到 root 下，
	# 直接 add_child 到自己身上会跟着本节点一起被释放（黑屏）。
	var next: Control = load(path).instantiate()
	SceneRouter.swap(get_tree(), next)


func _big_btn(t: String, sub: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.custom_minimum_size = Vector2(280, 56)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 17)
	b.pressed.connect(cb)
	return b
