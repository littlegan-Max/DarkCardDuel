class_name CardSlot
extends PanelContainer

var _owner: Label
var _art: TextureRect
var _glyph: Label
var _name: Label
var _desc: Label
var _badge: PanelContainer
var _badge_label: Label


func _init() -> void:
    custom_minimum_size = Vector2(148, 190)

    var sb := StyleBoxFlat.new()
    sb.bg_color = Color("#121A2A")
    sb.border_color = Color("#8A6B3A")
    sb.set_border_width_all(2)
    sb.set_corner_radius_all(14)
    sb.shadow_color = Color(0, 0, 0, 0.45)
    sb.shadow_size = 16
    sb.shadow_offset = Vector2(0, 6)
    sb.set_content_margin_all(0)
    add_theme_stylebox_override("panel", sb)

    var col := VBoxContainer.new()
    col.add_theme_constant_override("separation", 0)
    add_child(col)

    _owner = Label.new()
    _owner.text = "甲"
    _owner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _owner.add_theme_font_size_override("font_size", 9)
    _owner.add_theme_color_override("font_color", UiPalette.DIM)
    _owner.custom_minimum_size.y = 16
    col.add_child(_owner)

    _art = TextureRect.new()
    _art.custom_minimum_size = Vector2(148, 98)
    _art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    _art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
    _art.modulate = Color(1.15, 1.15, 1.15)
    col.add_child(_art)

    _glyph = Label.new()
    _glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _glyph.add_theme_font_size_override("font_size", 46)
    _glyph.add_theme_color_override("font_color", Color(0.91, 0.75, 0.48, 0.55))
    _art.add_child(_glyph)
    _glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

    var fade := TextureRect.new()
    fade.texture = UiPalette.gradient(Color(0.071, 0.09, 0.14, 0.0), Color("#121A2A"))
    fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    fade.stretch_mode = TextureRect.STRETCH_SCALE
    fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _art.add_child(fade)
    fade.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
    fade.offset_top = -30

    var plate := ColorRect.new()
    plate.color = Color(0.788, 0.643, 0.369, 0.35)
    plate.custom_minimum_size.y = 1
    col.add_child(plate)

    _name = Label.new()
    _name.text = "未知"
    _name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _name.add_theme_font_size_override("font_size", 17)
    _name.add_theme_color_override("font_color", UiPalette.TEXT)
    _name.custom_minimum_size.y = 26
    col.add_child(_name)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 10)
    margin.add_theme_constant_override("margin_right", 10)
    col.add_child(margin)

    _desc = Label.new()
    _desc.text = "等待翻开"
    _desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _desc.add_theme_font_size_override("font_size", 10)
    _desc.add_theme_color_override("font_color", UiPalette.DIM)
    _desc.custom_minimum_size.y = 28
    margin.add_child(_desc)

    _badge = PanelContainer.new()
    _badge.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
    var bsb := StyleBoxFlat.new()
    bsb.bg_color = Color(0.894, 0.341, 0.18, 0.16)
    bsb.border_color = UiPalette.RED
    bsb.set_border_width_all(1)
    bsb.set_corner_radius_all(8)
    bsb.set_content_margin_all(3)
    _badge.add_theme_stylebox_override("panel", bsb)
    _badge.visible = false
    col.add_child(_badge)

    _badge_label = Label.new()
    _badge_label.text = ""
    _badge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _badge_label.add_theme_font_size_override("font_size", 9)
    _badge_label.add_theme_color_override("font_color", UiPalette.RED.lightened(0.25))
    _badge.add_child(_badge_label)

    var overlay := Control.new()
    overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(overlay)

    for pos in [Vector2(4, 4), Vector2(140, 4), Vector2(4, 182), Vector2(140, 182)]:
        var stud := Panel.new()
        stud.mouse_filter = Control.MOUSE_FILTER_IGNORE
        var ssb := StyleBoxFlat.new()
        ssb.bg_color = Color("#C9A45E")
        ssb.set_corner_radius_all(2)
        stud.add_theme_stylebox_override("panel", ssb)
        overlay.add_child(stud)
        stud.position = pos
        stud.size = Vector2(4, 4)


func set_owner_text(text: String) -> void:
    _owner.text = text


func set_back() -> void:
    _art.texture = UiPalette.gradient(Color("#151B2E"), Color("#241F3D"))
    _glyph.visible = true
    _glyph.text = "?"
    _name.text = "未知"
    _name.add_theme_color_override("font_color", UiPalette.DIM)
    _desc.text = "等待翻开"
    _desc.add_theme_color_override("font_color", UiPalette.DIM)
    _badge.visible = false


func set_card(cid: String, db: CardDB, badge: String) -> void:
    var d := db.get_def(cid)
    if d == null:
        return

    var tex := _art_texture(cid)
    if tex != null:
        _art.texture = tex
        _glyph.visible = false
    else:
        var c := UiPalette.category_color(d)
        _art.texture = UiPalette.gradient(c.darkened(0.55), c.darkened(0.12))
        _glyph.visible = true
        _glyph.text = UiPalette.category_glyph(d)

    _name.text = d.display_name
    _name.add_theme_color_override("font_color", UiPalette.TEXT)
    _desc.text = d.desc
    _desc.add_theme_color_override("font_color", UiPalette.DIM)

    _badge.visible = badge != ""
    _badge_label.text = badge


func _art_texture(id: String) -> Texture2D:
    var path := "res://assets/cards/%s.png" % id
    if ResourceLoader.exists(path):
        return load(path) as Texture2D
    return null
