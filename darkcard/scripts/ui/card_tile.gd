class_name CardTile
extends Button

signal card_picked(card_id: String)
signal card_long_pressed(card_id: String)

const HOLD_SEC := 0.42
const MOVE_TOL := 14.0
const DRAG_THRESHOLD := 6.0

var card_id: String = ""

var _def: SkillDef
var _desc: Label
var _cd: Label
var _accent: Color
var _sb_normal: StyleBoxFlat
var _sb_selected: StyleBoxFlat
var _sb_disabled: StyleBoxFlat
var _rim: Panel
var _rim_normal: StyleBoxFlat
var _rim_selected: StyleBoxFlat

var _holding := false
var _hold_t := 0.0
var _hold_from := Vector2.ZERO
var _long_fired := false

# —— 拖动接力 ——
# 卡牌是 Button，会吃掉拖动手势，事件到不了外层 ScrollContainer，
# 结果就是"按在卡牌上滑不动"。这里在位移超过阈值后自己接管拖动，
# 直接驱动祖先 ScrollContainer 滚动，并吞掉这次松手的点击。
var _press_pos := Vector2.ZERO
var _panning := false
var _suppress_click := false
var _last_drag_pos := Vector2.ZERO
var _scroll_cache: ScrollContainer = null


func setup(d: SkillDef) -> void:
    _def = d
    card_id = d.id
    text = ""
    focus_mode = Control.FOCUS_NONE
    clip_contents = true
    custom_minimum_size = Vector2(152, 108)
    mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
    _accent = UiPalette.category_color(d)

    _sb_normal = _metal_box(Color("#141B2B"), Color("#8A6B3A"), 2, 8)
    _sb_selected = _metal_box(Color("#1B2336"), UiPalette.GOLD, 2, 14)
    _sb_selected.shadow_color = Color(0.91, 0.75, 0.48, 0.32)
    _sb_disabled = _metal_box(Color("#0F1626"), Color("#2A3145"), 1, 0)

    add_theme_stylebox_override("normal", _sb_normal)
    add_theme_stylebox_override("hover", _sb_selected)
    add_theme_stylebox_override("pressed", _sb_selected)
    add_theme_stylebox_override("disabled", _sb_disabled)
    add_theme_stylebox_override("focus", StyleBoxEmpty.new())

    var art := TextureRect.new()
    var tex := _art_texture(d.id)
    if tex != null:
        art.texture = tex
        art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
        art.modulate = Color(1.18, 1.18, 1.18)
    else:
        art.texture = UiPalette.gradient(_accent.darkened(0.58), _accent.darkened(0.14))
        art.stretch_mode = TextureRect.STRETCH_SCALE
    art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    art.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(art)
    art.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
    art.offset_bottom = 68

    if tex == null:
        var glyph := Label.new()
        glyph.text = UiPalette.category_glyph(d)
        glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
        glyph.add_theme_font_size_override("font_size", 38)
        glyph.add_theme_color_override("font_color", Color(1, 1, 1, 0.22))
        glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
        add_child(glyph)
        glyph.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
        glyph.offset_bottom = 68

    var fade := TextureRect.new()
    fade.texture = UiPalette.gradient(Color(0.078, 0.106, 0.169, 0.0), Color("#141B2B"))
    fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    fade.stretch_mode = TextureRect.STRETCH_SCALE
    fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(fade)
    fade.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
    fade.offset_top = 48
    fade.offset_bottom = 68

    var inner := Panel.new()
    inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var isb := StyleBoxFlat.new()
    isb.bg_color = Color(0, 0, 0, 0)
    isb.border_color = Color(0.788, 0.643, 0.369, 0.35)
    isb.set_border_width_all(1)
    isb.set_corner_radius_all(8)
    inner.add_theme_stylebox_override("panel", isb)
    add_child(inner)
    _inset(inner, 6)

    var bevel := Panel.new()
    bevel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var bsb := StyleBoxFlat.new()
    bsb.bg_color = Color(0, 0, 0, 0)
    bsb.border_color = Color("#5A4526")
    bsb.set_border_width_all(2)
    bsb.set_corner_radius_all(10)
    bevel.add_theme_stylebox_override("panel", bsb)
    add_child(bevel)
    _inset(bevel, 3)

    _rim = Panel.new()
    _rim.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _rim_normal = _frame_style(Color(0.788, 0.643, 0.369, 0.5), 1, 12)
    _rim_selected = _frame_style(UiPalette.GOLD, 2, 12)
    _rim_selected.shadow_color = Color(0.91, 0.75, 0.48, 0.30)
    _rim_selected.shadow_size = 10
    _rim.add_theme_stylebox_override("panel", _rim_normal)
    add_child(_rim)
    _rim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

    var ring := Panel.new()
    ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var rsb := StyleBoxFlat.new()
    rsb.bg_color = Color("#6B5636")
    rsb.border_color = Color("#C9A45E")
    rsb.set_border_width_all(1)
    rsb.set_corner_radius_all(14)
    ring.add_theme_stylebox_override("panel", rsb)
    add_child(ring)
    ring.position = Vector2(7, 7)
    ring.size = Vector2(28, 28)

    var gem := Panel.new()
    gem.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var gsb := StyleBoxFlat.new()
    gsb.bg_color = _accent
    gsb.set_corner_radius_all(11)
    gem.add_theme_stylebox_override("panel", gsb)
    add_child(gem)
    gem.position = Vector2(10, 10)
    gem.size = Vector2(22, 22)

    var cost := Label.new()
    cost.text = _cost_text(d.cost)
    cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    cost.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    cost.add_theme_font_size_override("font_size", 12)
    cost.add_theme_color_override("font_color", Color("#0B1020"))
    cost.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(cost)
    cost.position = Vector2(7, 7)
    cost.size = Vector2(28, 28)

    var plate := ColorRect.new()
    plate.color = Color(0.788, 0.643, 0.369, 0.28)
    plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(plate)
    plate.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
    plate.offset_left = 8
    plate.offset_right = -8
    plate.offset_top = 68
    plate.offset_bottom = 69

    var title := Label.new()
    title.text = d.display_name
    title.add_theme_font_size_override("font_size", 15)
    title.add_theme_color_override("font_color", UiPalette.TEXT)
    title.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(title)
    title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
    title.offset_left = 9
    title.offset_right = -9
    title.offset_top = 71
    title.offset_bottom = 89

    _desc = Label.new()
    _desc.text = d.desc
    _desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _desc.add_theme_font_size_override("font_size", 10)
    _desc.add_theme_color_override("font_color", UiPalette.DIM)
    _desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_desc)
    _desc.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
    _desc.offset_left = 9
    _desc.offset_right = -9
    _desc.offset_top = 90
    _desc.offset_bottom = 106

    _cd = Label.new()
    _cd.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    _cd.add_theme_font_size_override("font_size", 9)
    _cd.add_theme_color_override("font_color", UiPalette.GOLD)
    _cd.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_cd)
    _cd.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
    _cd.offset_left = 86
    _cd.offset_right = -8
    _cd.offset_top = 11
    _cd.offset_bottom = 25

    pressed.connect(_on_pressed)


    set_process(true)


func _process(delta: float) -> void:
    if not _holding:
        return
    _hold_t += delta
    if _hold_t >= HOLD_SEC and not _long_fired:
        _long_fired = true
        _holding = false
        if OS.has_feature("mobile"):
            Input.vibrate_handheld(18)
        card_long_pressed.emit(card_id)


func _input(event: InputEvent) -> void:
    # 放在 _input 而不是 _gui_input，有两个原因：
    #  1) 覆写 _gui_input 会顶掉 Button 的原生按压逻辑（轻点选牌会失效）；
    #  2) Button 被 disable（不可出的牌）时不会发 button_down，
    #     用信号就没法在"不可出的牌"上识别按压，滑动会失效。
    # _input 能看到所有事件，这里用"按压点是否落在自己身上"来判定。
    if event is InputEventScreenTouch:
        var st := event as InputEventScreenTouch
        if st.pressed:
            if _hit(st.position):
                _begin_press(st.position)
        elif _holding:
            _end_press()
    elif event is InputEventMouseButton:
        var mb := event as InputEventMouseButton
        if mb.button_index == MOUSE_BUTTON_LEFT:
            if mb.pressed:
                if _hit(mb.position):
                    _begin_press(mb.position)
            elif _holding:
                _end_press()
    elif event is InputEventScreenDrag:
        if not _holding and not _panning:
            return
        var sd := event as InputEventScreenDrag
        _drag(sd.position, sd.relative)
    elif event is InputEventMouseMotion:
        if not _holding and not _panning:
            return
        var mm := event as InputEventMouseMotion
        if (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
            return
        # 触摸会被 Godot 模拟成鼠标事件，同一次拖动会来两次，按位置去重
        if _panning and mm.position.distance_to(_last_drag_pos) < 0.5:
            return
        _drag(mm.position, mm.relative)


func _hit(pos: Vector2) -> bool:
    return get_global_rect().has_point(pos)






func _begin_press(pos: Vector2) -> void:
    _holding = true
    _hold_t = 0.0
    _long_fired = false
    _hold_from = pos
    _press_pos = pos
    _last_drag_pos = pos
    _panning = false
    _suppress_click = false


func _end_press() -> void:
    _holding = false
    _panning = false


func _drag(pos: Vector2, rel: Vector2) -> void:
    if not _holding and not _panning:
        return
    if _press_pos.distance_to(pos) <= DRAG_THRESHOLD:
        return
    if not _panning:
        # 超过阈值即判定为滚动：取消长按，并吞掉本次松手的点击
        _panning = true
        _holding = false
        _long_fired = false
        _suppress_click = true
    var sc := _scroll_ancestor()
    if sc != null:
        sc.scroll_vertical -= rel.y
        sc.scroll_horizontal -= rel.x
    _last_drag_pos = pos
    # 吃掉这次事件，避免 ScrollContainer 再滚一次（双倍速度）
    get_viewport().set_input_as_handled()


func _scroll_ancestor() -> ScrollContainer:
    if _scroll_cache != null and is_instance_valid(_scroll_cache):
        return _scroll_cache
    var n := get_parent()
    while n != null:
        if n is ScrollContainer:
            _scroll_cache = n as ScrollContainer
            return _scroll_cache
        n = n.get_parent()
    return null


func cancel_hold() -> void:
    _holding = false
    _hold_t = 0.0


func set_state(legal: bool, reason: String, selected: bool, cd_text: String) -> void:
    disabled = not legal
    modulate = Color(1, 1, 1, 1.0) if legal else Color(1, 1, 1, 0.58)
    _cd.text = cd_text

    if selected and legal:
        add_theme_stylebox_override("normal", _sb_selected)
        add_theme_stylebox_override("hover", _sb_selected)
    else:
        add_theme_stylebox_override("normal", _sb_normal)
        add_theme_stylebox_override("hover", _sb_selected)

    _rim.add_theme_stylebox_override("panel", _rim_selected if (selected and legal) else _rim_normal)

    if reason != "":
        _desc.text = reason
        _desc.add_theme_color_override("font_color", UiPalette.RED)
    else:
        _desc.text = _def.desc
        _desc.add_theme_color_override("font_color", UiPalette.DIM)


func _on_pressed() -> void:
    if _suppress_click:
        # 刚刚是一次滑动，不算点击
        _suppress_click = false
        return
    if _long_fired:
        # 长按已经弹出详情，松手不再触发出牌
        _long_fired = false
        return
    card_picked.emit(card_id)


func _metal_box(bg: Color, border: Color, width: int, shadow: int) -> StyleBoxFlat:
    var sb := StyleBoxFlat.new()
    sb.bg_color = bg
    sb.border_color = border
    sb.set_border_width_all(width)
    sb.set_corner_radius_all(12)
    sb.shadow_color = Color(0, 0, 0, 0.38)
    sb.shadow_size = shadow
    sb.shadow_offset = Vector2(0, 3)
    sb.set_content_margin_all(0)
    return sb


func _inset(p: Control, px: float) -> void:
    p.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    p.offset_left = px
    p.offset_top = px
    p.offset_right = -px
    p.offset_bottom = -px


func _frame_style(c: Color, w: int, r: int) -> StyleBoxFlat:
    var sb := StyleBoxFlat.new()
    sb.bg_color = Color(0, 0, 0, 0)
    sb.border_color = c
    sb.set_border_width_all(w)
    sb.set_corner_radius_all(r)
    return sb


func _art_texture(id: String) -> Texture2D:
    var path := "res://assets/cards/%s.png" % id
    if ResourceLoader.exists(path):
        return load(path) as Texture2D
    return null


static func _cost_text(cost: int) -> String:
    if cost % 10 == 0:
        return str(cost / Units.YUN)
    return "%.1f" % (cost / float(Units.YUN))
