class_name UiKit
extends RefCounted

# 大厅 / 主菜单共用的一套控件工厂。
#
# 只负责「长什么样」，不接业务：点下去做什么由调用方自己连信号。
# 视觉口径与对战界面保持一致：深蓝底 + 金色主操作 + 细描边次要操作。
#
# 用法：
#   var b := UiKit.primary("快速匹配")
#   b.pressed.connect(_on_matchmake)


const H_PRIMARY := 52
const H_GHOST := 38


# ---------------------------------------------------------------- 背景

## 全屏背景：竖向渐变 + 一团金色散光，给纯色底一点纵深。
##
## 散光贴图必须比屏幕大得多、四边都落在屏幕外 —— 径向渐变在贴图边缘
## 仍有约 3% 的透明度，贴图边缘一旦进画面，就会露出一条笔直的边，
## 看着像误放的灰板。
static func backdrop(parent: Control) -> void:
	var bg := TextureRect.new()
	bg.texture = UiPalette.gradient(UiPalette.BG_TOP, UiPalette.BG_BOTTOM)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# 用实际可见区算，别用项目里写的 540x960：
	# 拉伸模式一改（比如宽屏下 expand），写死的尺寸会让散光贴图露边、跑偏。
	var vp := parent.get_viewport_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		vp = Vector2(540, 960)
	var side := vp.length() * 1.6

	var glow := TextureRect.new()
	glow.texture = UiPalette.radial(UiPalette.GOLD, 0.13)
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(glow)
	glow.size = Vector2(side, side)
	glow.position = Vector2(vp.x * 0.5, vp.y * 0.2) - glow.size * 0.5


# ---------------------------------------------------------------- 文字

static func label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


## 装饰性抬头（英文小标）：字距拉开，靠上对齐一行。
## Godot 的 Label 没有 letter-spacing，用小空格模拟。
static func kicker(text: String, color: Color) -> Label:
	var spaced := ""
	for i in text.length():
		if i > 0:
			spaced += " "
		spaced += text.substr(i, 1)
	return label(spaced, 9, color)


## 分区小标题：左侧一条金色短竖线 + 文字。
static func section(text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	var tick := Panel.new()
	tick.custom_minimum_size = Vector2(3, 12)
	tick.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var tb := StyleBoxFlat.new()
	tb.bg_color = UiPalette.GOLD
	tb.set_corner_radius_all(2)
	tick.add_theme_stylebox_override("panel", tb)
	row.add_child(tick)
	var l := label(text, 11, UiPalette.DIM)
	row.add_child(l)
	return row


static func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func hsep(color: Color = Color("#222C42")) -> Panel:
	var p := Panel.new()
	p.custom_minimum_size.y = 1
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	p.add_theme_stylebox_override("panel", sb)
	return p


# ---------------------------------------------------------------- 容器

## 一块面板的底：半透明深蓝 + 细描边 + 一点投影。
static func card(bg: Color = Color("#161E30"), radius: int = 16,
		border: Color = UiPalette.LINE, pad: int = 14) -> StyleBoxFlat:
	var sb := _fill(bg, radius)
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_content_margin_all(pad)
	sb.shadow_color = Color(0, 0, 0, 0.28)
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0, 4)
	return sb


## 纯色圆角底，不带描边投影（蒙层、色块用）。
static func flat(bg: Color, radius: int = 0) -> StyleBoxFlat:
	return _fill(bg, radius)


## 列表里一行一个的小卡片。
static func row_card() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := _fill(Color("#111828"), 12)
	sb.border_color = Color("#212B42")
	sb.set_border_width_all(1)
	sb.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", sb)
	return p


## 圆角胶囊底（在线人数、评分这类小标签用）。
static func chip(text: String, color: Color) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := _fill(Color(color.r, color.g, color.b, 0.12), 9)
	sb.border_color = Color(color.r, color.g, color.b, 0.35)
	sb.set_border_width_all(1)
	sb.content_margin_left = 9
	sb.content_margin_right = 9
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	p.add_theme_stylebox_override("panel", sb)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.add_child(label(text, 11, color))
	return p


## 头像：一枚描边圆 + 首字。
static func avatar(letter: String, color: Color, size: int = 46) -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(size, size)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(color.r, color.g, color.b, 0.16)
	sb.border_color = Color(color.r, color.g, color.b, 0.8)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(int(size / 2.0))
	p.add_theme_stylebox_override("panel", sb)
	var l := label(letter, int(size * 0.44), color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	p.add_child(l)
	return p


## 状态圆点。
static func dot(color: Color, size: int = 7) -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(size, size)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(int(size / 2.0))
	p.add_theme_stylebox_override("panel", sb)
	return p


# ---------------------------------------------------------------- 按钮

## 主操作：金底深字，整屏只该有一个。
static func primary(text: String, height: int = H_PRIMARY, radius: int = 14) -> Button:
	var b := _shell(text, height, 16)
	var base := _fill(UiPalette.GOLD, radius)
	base.shadow_color = Color(0.91, 0.75, 0.48, 0.24)
	base.shadow_size = 14
	base.shadow_offset = Vector2(0, 5)
	b.add_theme_stylebox_override("normal", base)

	var h := base.duplicate() as StyleBoxFlat
	h.bg_color = UiPalette.GOLD.lightened(0.10)
	b.add_theme_stylebox_override("hover", h)

	var p := base.duplicate() as StyleBoxFlat
	p.bg_color = UiPalette.GOLD.darkened(0.14)
	p.shadow_size = 4
	p.shadow_offset = Vector2(0, 2)
	b.add_theme_stylebox_override("pressed", p)

	var d := base.duplicate() as StyleBoxFlat
	d.bg_color = Color("#3A3020")
	d.shadow_size = 0
	b.add_theme_stylebox_override("disabled", d)

	b.add_theme_color_override("font_color", Color("#17110A"))
	b.add_theme_color_override("font_hover_color", Color("#17110A"))
	b.add_theme_color_override("font_pressed_color", Color("#2A2013"))
	b.add_theme_color_override("font_disabled_color", Color("#7A6A4C"))
	return b


## 次要操作：描边款。
static func ghost(text: String, height: int = H_GHOST, radius: int = 12) -> Button:
	var b := _shell(text, height, 13)
	var base := _fill(Color("#1A2338"), radius)
	base.border_color = Color("#2A3550")
	base.set_border_width_all(1)
	b.add_theme_stylebox_override("normal", base)

	var h := base.duplicate() as StyleBoxFlat
	h.bg_color = Color("#222C44")
	h.border_color = Color("#3A4868")
	b.add_theme_stylebox_override("hover", h)

	var p := base.duplicate() as StyleBoxFlat
	p.bg_color = Color("#151C2C")
	b.add_theme_stylebox_override("pressed", p)

	var d := base.duplicate() as StyleBoxFlat
	d.bg_color = Color("#141A28")
	b.add_theme_stylebox_override("disabled", d)

	b.add_theme_color_override("font_color", UiPalette.TEXT)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", UiPalette.DIM)
	b.add_theme_color_override("font_disabled_color", Color("#4E5A72"))
	return b


## 行内小动作（加入 / 邀请 / 移除）。
static func pill(text: String, width: int = 54) -> Button:
	var b := ghost(text, 26, 8)
	b.custom_minimum_size.x = width
	b.add_theme_font_size_override("font_size", 11)
	return b


## 危险动作（离开房间 / 移除成员）：描边偏红。
static func danger(text: String, height: int = H_GHOST, radius: int = 12) -> Button:
	var b := ghost(text, height, radius)
	var base := _fill(Color("#2A1C1E"), radius)
	base.border_color = Color(0.89, 0.34, 0.18, 0.55)
	base.set_border_width_all(1)
	b.add_theme_stylebox_override("normal", base)
	var h := base.duplicate() as StyleBoxFlat
	h.bg_color = Color("#332024")
	b.add_theme_stylebox_override("hover", h)
	b.add_theme_color_override("font_color", Color("#F09B82"))
	b.add_theme_color_override("font_hover_color", Color("#FFC0AC"))
	return b


## 页签：选中时底部一条金线。
static func tab(text: String, expand: bool = true) -> Button:
	var b := _shell(text, 34, 13)
	if expand:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		b.custom_minimum_size.x = 104
		b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	style_tab(b, false)
	return b


static func style_tab(b: Button, active: bool) -> void:
	var n := _fill(Color(0, 0, 0, 0), 0)
	if active:
		n.border_color = UiPalette.GOLD
		n.border_width_bottom = 2
	n.content_margin_top = 6
	n.content_margin_bottom = 6
	for s in ["normal", "hover", "pressed"]:
		b.add_theme_stylebox_override(s, n)
	b.add_theme_color_override("font_color", UiPalette.GOLD if active else UiPalette.DIM)
	b.add_theme_color_override("font_hover_color", UiPalette.TEXT)
	b.add_theme_color_override("font_pressed_color", UiPalette.GOLD if active else UiPalette.TEXT)


# ---------------------------------------------------------------- 输入

static func input(placeholder: String, height: int = 38) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.custom_minimum_size.y = height
	e.add_theme_font_size_override("font_size", 13)
	e.add_theme_color_override("font_color", UiPalette.TEXT)
	e.add_theme_color_override("font_placeholder_color", Color(0.58, 0.63, 0.72, 0.5))
	e.add_theme_color_override("caret_color", UiPalette.GOLD)
	e.add_theme_color_override("selection_color", Color(0.91, 0.75, 0.48, 0.25))

	var n := _fill(Color("#0D1424"), 10)
	n.border_color = Color("#26314A")
	n.set_border_width_all(1)
	n.content_margin_left = 12
	n.content_margin_right = 12
	e.add_theme_stylebox_override("normal", n)

	var f := n.duplicate() as StyleBoxFlat
	f.border_color = UiPalette.GOLD_DEEP
	e.add_theme_stylebox_override("focus", f)
	e.add_theme_stylebox_override("read_only", n)
	return e


## 选项下拉：按钮部分自绘，弹层也跟着统一底色。
## ids 要给：调用方通常靠 get_item_id() 取真实值（比如「20 秒」= 20），
## 不传 id 的话拿到的是下标，会把 20 秒变成 3。
static func option(texts: Array, ids: Array = [], selected_index: int = 0) -> OptionButton:
	var o := OptionButton.new()
	o.add_theme_font_size_override("font_size", 13)
	for i in texts.size():
		if i < ids.size():
			o.add_item(str(texts[i]), int(ids[i]))
		else:
			o.add_item(str(texts[i]))
	o.select(selected_index)

	var n := _fill(Color("#0D1424"), 10)
	n.border_color = Color("#26314A")
	n.set_border_width_all(1)
	n.content_margin_left = 12
	n.content_margin_right = 8
	o.add_theme_stylebox_override("normal", n)

	var h := n.duplicate() as StyleBoxFlat
	h.border_color = Color("#3A4868")
	o.add_theme_stylebox_override("hover", h)
	o.add_theme_stylebox_override("pressed", h)
	var f := n.duplicate() as StyleBoxFlat
	f.border_color = UiPalette.GOLD_DEEP
	o.add_theme_stylebox_override("focus", f)
	var d := n.duplicate() as StyleBoxFlat
	d.bg_color = Color("#141A28")
	o.add_theme_stylebox_override("disabled", d)

	o.add_theme_color_override("font_color", UiPalette.TEXT)
	o.add_theme_color_override("font_hover_color", UiPalette.TEXT)
	o.add_theme_color_override("font_pressed_color", UiPalette.TEXT)
	o.add_theme_color_override("font_disabled_color", Color("#4E5A72"))

	var pop := o.get_popup()
	pop.add_theme_font_size_override("font_size", 13)
	pop.add_theme_color_override("font_color", UiPalette.TEXT)
	pop.add_theme_color_override("font_hover_color", Color("#17110A"))
	var pb := _fill(Color("#121A2C"), 8)
	pb.border_color = UiPalette.LINE
	pb.set_border_width_all(1)
	pb.set_content_margin_all(4)
	pop.add_theme_stylebox_override("panel", pb)
	var hb := _fill(Color(UiPalette.GOLD.r, UiPalette.GOLD.g, UiPalette.GOLD.b, 0.16), 6)
	pop.add_theme_stylebox_override("hover", hb)
	pop.add_theme_stylebox_override("separator", _fill(Color("#222C42"), 0))
	return o


# ---------------------------------------------------------------- 内部

static func _fill(color: Color, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(6)
	return sb


static func _shell(text: String, height: int, font_size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size.y = height
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b
