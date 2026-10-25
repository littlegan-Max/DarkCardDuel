class_name OpponentProfile
extends Control

# 对手画像面板：把模型学到的东西显示出来。
# 这一层是"可见性"——玩家能看见 AI 到底学到了什么，
# 也能一键清空（画像属于玩家数据）。

signal closed

var _body: RichTextLabel
var _model: OpponentModel


func _init() -> void:
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    z_index = 40
    visible = false
    mouse_filter = Control.MOUSE_FILTER_STOP

    var dim := ColorRect.new()
    dim.color = Color(0.016, 0.024, 0.047, 0.9)
    dim.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(dim)
    dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

    var panel := PanelContainer.new()
    panel.custom_minimum_size = Vector2(420, 560)
    panel.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(panel)
    panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
    panel.position = Vector2(-210, -280)
    panel.size = Vector2(420, 560)

    var sb := StyleBoxFlat.new()
    sb.bg_color = Color("#131A2B")
    sb.border_color = UiPalette.GOLD
    sb.set_border_width_all(2)
    sb.set_corner_radius_all(14)
    sb.shadow_color = Color(0, 0, 0, 0.5)
    sb.shadow_size = 16
    panel.add_theme_stylebox_override("panel", sb)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 18)
    margin.add_theme_constant_override("margin_right", 18)
    margin.add_theme_constant_override("margin_top", 14)
    margin.add_theme_constant_override("margin_bottom", 14)
    panel.add_child(margin)

    var col := VBoxContainer.new()
    col.add_theme_constant_override("separation", 10)
    margin.add_child(col)

    var title := Label.new()
    title.text = "对手画像"
    title.add_theme_font_size_override("font_size", 20)
    title.add_theme_color_override("font_color", UiPalette.GOLD)
    col.add_child(title)

    var sub := Label.new()
    sub.text = "app 开着就会持续学习你的出牌习惯"
    sub.add_theme_font_size_override("font_size", 12)
    sub.add_theme_color_override("font_color", UiPalette.DIM)
    col.add_child(sub)

    _body = RichTextLabel.new()
    _body.bbcode_enabled = true
    _body.fit_content = true
    _body.scroll_active = true
    _body.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _body.add_theme_font_size_override("normal_font_size", 13)
    col.add_child(_body)

    var row := HBoxContainer.new()
    row.alignment = BoxContainer.ALIGNMENT_END
    row.add_theme_constant_override("separation", 10)
    col.add_child(row)

    var clear_btn := Button.new()
    clear_btn.text = "清空画像"
    clear_btn.custom_minimum_size = Vector2(96, 34)
    clear_btn.pressed.connect(_on_clear)
    row.add_child(clear_btn)

    var close_btn := Button.new()
    close_btn.text = "关闭"
    close_btn.custom_minimum_size = Vector2(96, 34)
    close_btn.pressed.connect(close)
    row.add_child(close_btn)


func open(model: OpponentModel, db: CardDB) -> void:
    _model = model
    _refresh(db)
    visible = true


func _refresh(db: CardDB) -> void:
    if _model == null or _body == null:
        return
    var m := _model
    var lines: Array[String] = []
    lines.append("[color=#8FA6C8]样本[/color]  对局 %d · 决策 %d" % [m.matches, m.decisions])
    lines.append("")

    lines.append("[color=#8FA6C8]最常用的技能[/color]")
    var tops := m.top_cards(6)
    if tops.is_empty():
        lines.append("  还没有足够样本")
    for e in tops:
        var cid := str(e[0])
        var name := cid
        if db != null and db.get_def(cid) != null:
            name = db.get_def(cid).display_name
        lines.append("  %s  %d 次" % [name, int(e[1])])

    lines.append("")
    lines.append("[color=#8FA6C8]攻防倾向[/color]")
    lines.append("  攻击 %.0f%%   防御 %.0f%%   资源 %.0f%%   治疗 %.0f%%" % [
        m.tag_share("attack") * 100.0,
        m.tag_share("defense") * 100.0,
        m.tag_share("resource") * 100.0,
        m.tag_share("heal") * 100.0,
    ])

    lines.append("")
    lines.append("[color=#8FA6C8]可预判程度[/color]")
    lines.append("  连续出同一张牌的比例 %.0f%%   最长连续 %d 次" % [
        m.predictability() * 100.0, m.max_streak])
    lines.append("  连招意图：铺垫 %d 次 / 完成 %d 次" % [int(m.combo_setup), int(m.combo_finish)])
    lines.append("")
    lines.append("[color=#6F7C93]AI 会在你形成习惯的情境里提前应对（越明显越准）。[/color]")
    lines.append("[color=#6F7C93]画像存在 user:// 里，换设备不会同步；清空后重新学习。[/color]")
    _body.text = "\n".join(lines)


func _on_clear() -> void:
    OpponentStore.clear()
    if _model != null:
        _model = OpponentModel.new()
    _body.text = "[color=#8FA6C8]样本[/color]\n\n[color=#6F7C93]画像已清空。[/color]"


func close() -> void:
    visible = false
    closed.emit()
