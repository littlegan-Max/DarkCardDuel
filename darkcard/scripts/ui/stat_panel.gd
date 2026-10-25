class_name StatPanel
extends PanelContainer

var _title: Label
var _hp: Label
var _yun: Label
var _shield: Label
var _cd: Label
var _segs: Array[ColorRect] = []
var _side: Color


func _init(title: String = "甲", side: Color = UiPalette.TEAL) -> void:
    _side = side
    custom_minimum_size = Vector2(0, 104)

    var sb := UiPalette.panel_box(UiPalette.PANEL, 18)
    sb.set_content_margin_all(12)
    add_theme_stylebox_override("panel", sb)

    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 10)
    add_child(row)

    var avatar := Panel.new()
    avatar.custom_minimum_size = Vector2(46, 46)
    avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    var av := StyleBoxFlat.new()
    av.bg_color = side.darkened(0.55)
    av.border_color = side
    av.set_border_width_all(1)
    av.set_corner_radius_all(23)
    avatar.add_theme_stylebox_override("panel", av)
    row.add_child(avatar)

    var glyph := Label.new()
    glyph.text = title
    glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    glyph.add_theme_font_size_override("font_size", 20)
    glyph.add_theme_color_override("font_color", side.lightened(0.15))
    avatar.add_child(glyph)
    glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

    var mid := VBoxContainer.new()
    mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    mid.add_theme_constant_override("separation", 3)
    row.add_child(mid)

    var top := HBoxContainer.new()
    mid.add_child(top)

    _title = Label.new()
    _title.text = "影武者"
    _title.add_theme_font_size_override("font_size", 12)
    _title.add_theme_color_override("font_color", UiPalette.DIM)
    _title.size_flags_vertical = Control.SIZE_SHRINK_END
    top.add_child(_title)

    var sp := Control.new()
    sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    top.add_child(sp)

    _hp = Label.new()
    _hp.text = "1.00"
    _hp.add_theme_font_size_override("font_size", 26)
    _hp.add_theme_color_override("font_color", UiPalette.TEXT)
    top.add_child(_hp)

    var unit := Label.new()
    unit.text = "血"
    unit.add_theme_font_size_override("font_size", 10)
    unit.add_theme_color_override("font_color", UiPalette.DIM)
    unit.size_flags_vertical = Control.SIZE_SHRINK_END
    top.add_child(unit)

    var segs := HBoxContainer.new()
    segs.add_theme_constant_override("separation", 3)
    mid.add_child(segs)
    for i in 10:
        var s := ColorRect.new()
        s.custom_minimum_size = Vector2(0, 7)
        s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        s.color = Color("#243049")
        segs.add_child(s)
        _segs.append(s)

    _cd = Label.new()
    _cd.text = ""
    _cd.add_theme_font_size_override("font_size", 9)
    _cd.add_theme_color_override("font_color", UiPalette.GOLD)
    mid.add_child(_cd)

    var right := VBoxContainer.new()
    right.custom_minimum_size.x = 76
    right.alignment = BoxContainer.ALIGNMENT_CENTER
    right.add_theme_constant_override("separation", 4)
    row.add_child(right)

    _yun = Label.new()
    _yun.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    _yun.add_theme_font_size_override("font_size", 14)
    _yun.add_theme_color_override("font_color", UiPalette.GOLD)
    right.add_child(_yun)

    _shield = Label.new()
    _shield.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    _shield.add_theme_font_size_override("font_size", 12)
    _shield.add_theme_color_override("font_color", UiPalette.BLUE.lightened(0.2))
    right.add_child(_shield)


func update_view(p: PlayerState, title: String, turn: int, db: CardDB) -> void:
    _title.text = title
    _hp.text = "%.2f" % (p.hp / float(Units.HP))
    _hp.add_theme_color_override("font_color", UiPalette.RED if p.hp <= 50 else UiPalette.TEXT)

    var filled := clampi(ceili(p.hp / float(Units.HP)), 0, 10)
    for i in 10:
        _segs[i].color = _side if i < filled else Color("#243049")

    _yun.text = "运 %.1f" % (p.yun / float(Units.YUN))
    _shield.text = "盾 %d" % p.shields
    _cd.text = _cd_text(p, turn, db)


func flash(color: Color) -> void:
    var tw := create_tween()
    modulate = color
    tw.tween_property(self, "modulate", Color.WHITE, 0.35)


func _cd_text(p: PlayerState, turn: int, db: CardDB) -> String:
    var out := ""
    for cid in db.order:
        var d := db.get_def(cid)
        if d.cooldown <= 0:
            continue
        var pool := d.pool_id if d.pool_id != "" else d.id
        if not p.last_played.has(pool):
            continue
        var left := d.cooldown - (turn - int(p.last_played[pool])) + 1
        if left > 0:
            if out != "":
                out += "   "
            out += "%s CD%d" % [d.display_name, left]
    return out
