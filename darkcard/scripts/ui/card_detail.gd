class_name CardDetail
extends Control

# 长按详情层：大插画 + 完整效果 + 可被列 + 当前可出状态

signal closed

var _db: CardDB
var _art: TextureRect
var _glyph: Label
var _name: Label
var _cost: Label
var _kind_chip: PanelContainer
var _kind: Label
var _desc: Label
var _stat_row: GridContainer
var _counter: Label
var _status: Label
var _note: Label
var _built := false


func _ready() -> void:
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    mouse_filter = Control.MOUSE_FILTER_STOP
    visible = false


func _build() -> void:
    if _built:
        return
    _built = true

    var dim := ColorRect.new()
    dim.color = Color(0.016, 0.024, 0.047, 0.88)
    dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(dim)
    dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

    var cc := CenterContainer.new()
    cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(cc)
    cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

    var panel := PanelContainer.new()
    panel.custom_minimum_size = Vector2(348, 0)
    var psb := StyleBoxFlat.new()
    psb.bg_color = Color("#101725")
    psb.border_color = Color("#C9A45E")
    psb.set_border_width_all(1)
    psb.set_corner_radius_all(20)
    psb.shadow_color = Color(0, 0, 0, 0.6)
    psb.shadow_size = 28
    psb.shadow_offset = Vector2(0, 10)
    psb.set_content_margin_all(0)
    panel.add_theme_stylebox_override("panel", psb)
    cc.add_child(panel)

    var col := VBoxContainer.new()
    col.add_theme_constant_override("separation", 0)
    panel.add_child(col)

    # —— 插画（内嵌圆角卡面）——
    var art_pad := MarginContainer.new()
    art_pad.add_theme_constant_override("margin_left", 16)
    art_pad.add_theme_constant_override("margin_right", 16)
    art_pad.add_theme_constant_override("margin_top", 16)
    col.add_child(art_pad)

    var art_frame := PanelContainer.new()
    art_frame.custom_minimum_size = Vector2(0, 188)
    var fsb := StyleBoxFlat.new()
    fsb.bg_color = Color("#0A101C")
    fsb.border_color = Color("#8A6B3A")
    fsb.set_border_width_all(2)
    fsb.set_corner_radius_all(14)
    fsb.set_content_margin_all(0)
    art_frame.add_theme_stylebox_override("panel", fsb)
    art_pad.add_child(art_frame)

    var art_holder := Control.new()
    art_holder.clip_contents = true
    art_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
    art_frame.add_child(art_holder)

    _art = TextureRect.new()
    _art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    _art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
    _art.mouse_filter = Control.MOUSE_FILTER_IGNORE
    art_holder.add_child(_art)
    _art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

    _glyph = Label.new()
    _glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _glyph.add_theme_font_size_override("font_size", 72)
    _glyph.add_theme_color_override("font_color", Color(0.91, 0.75, 0.48, 0.6))
    _glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
    art_holder.add_child(_glyph)
    _glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

    var fade := TextureRect.new()
    fade.texture = UiPalette.gradient(Color(0.063, 0.09, 0.145, 0.0), Color("#101725"))
    fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    fade.stretch_mode = TextureRect.STRETCH_SCALE
    fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
    art_holder.add_child(fade)
    fade.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
    fade.offset_top = -48

    # 费用宝珠（左上角）
    var orb := PanelContainer.new()
    orb.custom_minimum_size = Vector2(34, 34)
    orb.position = Vector2(12, 12)
    orb.size = Vector2(34, 34)
    var osb := StyleBoxFlat.new()
    osb.bg_color = UiPalette.GOLD
    osb.border_color = Color("#7A5C28")
    osb.set_border_width_all(2)
    osb.set_corner_radius_all(17)
    orb.add_theme_stylebox_override("panel", osb)
    art_holder.add_child(orb)
    _cost = Label.new()
    _cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _cost.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _cost.add_theme_font_size_override("font_size", 15)
    _cost.add_theme_color_override("font_color", Color("#17110A"))
    orb.add_child(_cost)

    # —— 正文 ——
    var body := MarginContainer.new()
    body.add_theme_constant_override("margin_left", 20)
    body.add_theme_constant_override("margin_right", 20)
    body.add_theme_constant_override("margin_top", 14)
    body.add_theme_constant_override("margin_bottom", 18)
    col.add_child(body)

    var v := VBoxContainer.new()
    v.add_theme_constant_override("separation", 10)
    body.add_child(v)

    var head := HBoxContainer.new()
    head.add_theme_constant_override("separation", 10)
    v.add_child(head)

    _name = Label.new()
    _name.add_theme_font_size_override("font_size", 24)
    _name.add_theme_color_override("font_color", UiPalette.TEXT)
    _name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    head.add_child(_name)

    _kind_chip = PanelContainer.new()
    _kind_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    var ksb := StyleBoxFlat.new()
    ksb.bg_color = Color(1, 1, 1, 0.04)
    ksb.border_color = UiPalette.LINE
    ksb.set_border_width_all(1)
    ksb.set_corner_radius_all(9)
    ksb.set_content_margin_all(0)
    ksb.content_margin_left = 9
    ksb.content_margin_right = 9
    ksb.content_margin_top = 3
    ksb.content_margin_bottom = 3
    _kind_chip.add_theme_stylebox_override("panel", ksb)
    head.add_child(_kind_chip)

    _kind = Label.new()
    _kind.add_theme_font_size_override("font_size", 11)
    _kind_chip.add_child(_kind)

    _desc = Label.new()
    _desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _desc.add_theme_font_size_override("font_size", 14)
    _desc.add_theme_color_override("font_color", Color("#C8D2E6"))
    _desc.add_theme_constant_override("line_spacing", 4)
    v.add_child(_desc)

    var hair := ColorRect.new()
    hair.color = Color(0.91, 0.75, 0.48, 0.22)
    hair.custom_minimum_size.y = 1
    v.add_child(hair)

    _stat_row = GridContainer.new()
    _stat_row.columns = 2
    _stat_row.add_theme_constant_override("h_separation", 14)
    _stat_row.add_theme_constant_override("v_separation", 8)
    v.add_child(_stat_row)

    _counter = Label.new()
    _counter.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _counter.add_theme_font_size_override("font_size", 12)
    _counter.add_theme_color_override("font_color", UiPalette.DIM)
    v.add_child(_counter)

    _status = Label.new()
    _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _status.add_theme_font_size_override("font_size", 13)
    v.add_child(_status)

    _note = Label.new()
    _note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _note.add_theme_font_size_override("font_size", 10)
    _note.add_theme_color_override("font_color", Color("#6F7C93"))
    v.add_child(_note)


func open(cid: String, db: CardDB, status_text: String, status_ok: bool) -> void:
    _db = db
    _build()
    var d := db.get_def(cid)
    if d == null:
        return

    var tex := _art_texture(cid)
    if tex != null:
        _art.texture = tex
        _art.modulate = Color(1.16, 1.16, 1.16)
        _glyph.visible = false
    else:
        var c := UiPalette.category_color(d)
        _art.texture = UiPalette.gradient(c.darkened(0.55), c.darkened(0.1))
        _glyph.visible = true
        _glyph.text = UiPalette.category_glyph(d)

    _cost.text = _cost_text(d.cost)
    _name.text = d.display_name
    _kind.text = _kind_text(d)
    _kind.add_theme_color_override("font_color", UiPalette.category_color(d))
    _desc.text = d.desc

    _fill_stats(d)
    _counter.text = _counter_text(d)
    _status.text = status_text
    _status.add_theme_color_override(
        "font_color", UiPalette.TEAL if status_ok else UiPalette.RED.lightened(0.1)
    )
    _note.text = "长按查看 · 点击任意处关闭"

    visible = true
    modulate = Color(1, 1, 1, 0)
    create_tween().tween_property(self, "modulate", Color(1, 1, 1, 1), 0.12)


func close() -> void:
    if not visible:
        return
    var tw := create_tween()
    tw.tween_property(self, "modulate", Color(1, 1, 1, 0), 0.1)
    tw.tween_callback(_hide)


func _hide() -> void:
    visible = false
    closed.emit()


func _gui_input(event: InputEvent) -> void:
    if event is InputEventMouseButton and event.pressed:
        close()
    elif event is InputEventScreenTouch and event.pressed:
        close()


func _fill_stats(d: SkillDef) -> void:
    for ch in _stat_row.get_children():
        _stat_row.remove_child(ch)
        ch.queue_free()

    var cells: Array[Array] = []
    cells.append(["费用", _cost_text(d.cost)])
    var effect := _effect_text(d)
    if effect != "":
        cells.append(["效果", effect])
    cells.append(["冷却", "无" if d.cooldown <= 0 else "隔 %d 回合" % d.cooldown])
    if not d.combo.is_empty():
        cells.append(["连招", _combo_text(d)])

    for cell in cells:
        var box := VBoxContainer.new()
        box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        box.add_theme_constant_override("separation", 2)

        var k := Label.new()
        k.text = cell[0]
        k.add_theme_font_size_override("font_size", 10)
        k.add_theme_color_override("font_color", Color("#6F7C93"))
        box.add_child(k)

        var val := Label.new()
        val.text = cell[1]
        val.add_theme_font_size_override("font_size", 14)
        val.add_theme_color_override("font_color", UiPalette.GOLD)
        val.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        box.add_child(val)

        _stat_row.add_child(box)


func _effect_text(d: SkillDef) -> String:
    for op in d.ops:
        var kind := str(op.get("op", ""))
        var amount := int(op.get("amount", 0))
        match kind:
            "DMG":
                return "%.1f 伤害" % (amount / float(Units.HP))
            "TRUE_DMG":
                return "%.1f 真伤" % (amount / float(Units.HP))
            "PRC_DMG":
                return "当前血量 %d%%" % int(op.get("percent", 80))
            "HEAL":
                return "+%.1f 血" % (amount / float(Units.HP))
            "HEAL_ALL":
                return "双方 +%.1f" % (amount / float(Units.HP))
            "YUN_ADD":
                return "+%.1f 运" % (amount / float(Units.YUN))
            "YUN_ENEMY":
                return "对方 %.1f 运" % (amount / float(Units.YUN))
            "YUN_STEAL_ALL":
                return "夺全部运"
            "YUN_MINUS":
                return "对方 %.1f 运" % (amount / float(Units.YUN))
            "SHIELD_ADD":
                return "+1 盾"
            "IMMUNE_LE":
                return "免疫 ≤%.1f" % (amount / float(Units.HP))
            "IMMUNE_COST_RANGE":
                return "免疫 %d~%d 费" % [int(op.get("lo", 20)) / Units.YUN, int(op.get("hi", 30)) / Units.YUN]
            "DOT":
                return "%.1f×%d 回合" % [amount / float(Units.HP), int(op.get("turns", 5))]
            "DELAY_DMG":
                return "%d 回合后 -%.1f" % [int(op.get("turns", 3)), amount / float(Units.HP)]
            "PRISM":
                return "0.4 + 0.3k"
            "CODE_KILL":
                return "代码杀"
            "SELF_CODE_KILL":
                return "杀死自己"
            "KUI":
                return "转化对方技能" if int(op.get("mult", 1)) == 1 else "转化并翻倍"
            "COST_HALF":
                return "后续费用 ×0.5"
            "SCHEDULE_YUN":
                return "%.1f 运 × %d 回合" % [amount / float(Units.YUN), int(op.get("turns", 2))]
            "CANNON_DISCOUNT":
                return "炮降至 2 费"
            "SKIP_NEXT":
                return "对方下回合空过"
            "NEGATE_ALL":
                return "本回合全部无效"
            "DOT_CLEAR_MAX_HP":
                return "解 dot · 回最高血"
            "REFLECT":
                return "反弹 %d%%（上限 %.1f）" % [
                    int(op.get("percent", 0)), int(op.get("cap", 0)) / float(Units.HP),
                ]
    return ""


func _counter_text(d: SkillDef) -> String:
    if d.countered_by.is_empty():
        return "可被：无（只能靠盾 / 闪 / 酒 处理）"
    var names: Array[String] = []
    for cid in d.countered_by:
        var cd := _db.get_def(cid)
        names.append(cd.display_name if cd != null else cid)
    return "可被：" + " · ".join(names)


func _combo_text(d: SkillDef) -> String:
    var names: Array[String] = []
    for cid in d.combo:
        var cd := _db.get_def(cid)
        names.append(cd.display_name if cd != null else cid)
    return " → ".join(names)


func _kind_text(d: SkillDef) -> String:
    if d.tags.has("combo"):
        return "连招"
    if d.tags.has("attack"):
        return "攻击"
    if d.tags.has("defense"):
        return "防御"
    if d.tags.has("heal"):
        return "治疗"
    if d.tags.has("counter"):
        return "反制"
    return "运"


func _art_texture(id: String) -> Texture2D:
    var path := "res://assets/cards/%s.png" % id
    if ResourceLoader.exists(path):
        return load(path) as Texture2D
    return null


static func _cost_text(cost: int) -> String:
    if cost % 10 == 0:
        return str(cost / Units.YUN)
    return "%.1f" % (cost / float(Units.YUN))
