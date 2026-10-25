extends Control

const MATCH_SEED := 20261024

var db: CardDB
var duel: Duel
var controller: MatchController
var rng := RandomNumberGenerator.new()
var selected_id := ""
var filter := "all"
var search_text := ""
var busy := false
var time_left := 20.0
var debug_hold := false
var debug_ai_card := ""

# —— 调试开关（默认全关，正式包无副作用）——
# debug/force_card : 强制 AI 每次出某张牌（空=正常）
# debug/verbose_log: 结算日志输出更详细
# debug/show_fps    : 顶部显示实时 FPS
const DBG_FORCE_CARD := "debug/force_card"
const DBG_VERBOSE := "debug/verbose_log"
const DBG_SHOW_FPS := "debug/show_fps"

var _match_no := 0
var _last_sec := 20
var _reveal_turn := 0

var _turn_label: Label
var _timer_bar: ProgressBar
var _timer_label: Label
var _enemy_panel: StatPanel
var _self_panel: StatPanel
var _enemy_slot: CardSlot
var _self_slot: CardSlot
var _result: Label
var _combo_row: HBoxContainer
var _tiles: Array[CardTile] = []
var _tabs: Array[Button] = []
var _confirm: Button
var _selected_label: Label
var _log_panel: PanelContainer
var _log_text: RichTextLabel
var _log_lines: Array[String] = []
var _gameover: Control
var _gameover_title: Label
var _gameover_sub: Label
var _detail: CardDetail
var _hint: Label

# —— 对手习惯模型：app 开着就持续学习玩家的出牌习惯 ——
var opponent_model: OpponentModel
var _profile: OpponentProfile


func _ready() -> void:
    db = CardDB.load_all()
    opponent_model = OpponentStore.load_model()
    _build_ui()
    _start_match()


func _process(delta: float) -> void:
    if duel == null or busy or duel.state.over:
        return
    if _detail != null and _detail.visible:
        return
    time_left = maxf(0.0, time_left - delta)
    var s := ceili(time_left)
    if s != _last_sec:
        _last_sec = s
        _timer_label.text = "%ds" % s
        _timer_bar.value = time_left
    if time_left <= 0.0:
        _on_timeout()


func _build_ui() -> void:
    var bg := TextureRect.new()
    bg.texture = UiPalette.gradient(UiPalette.BG_TOP, UiPalette.BG_BOTTOM)
    bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    bg.stretch_mode = TextureRect.STRETCH_SCALE
    add_child(bg)
    bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

    _add_glow(Vector2(270, 300), 460, UiPalette.GOLD, 0.10)
    _add_glow(Vector2(270, 700), 420, UiPalette.TEAL, 0.07)

    var margin := MarginContainer.new()
    add_child(margin)
    margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    margin.add_theme_constant_override("margin_left", 14)
    margin.add_theme_constant_override("margin_right", 14)
    margin.add_theme_constant_override("margin_top", 10)
    margin.add_theme_constant_override("margin_bottom", 12)

    var col := VBoxContainer.new()
    col.add_theme_constant_override("separation", 6)
    margin.add_child(col)

    col.add_child(_build_top())
    _enemy_panel = StatPanel.new("乙", UiPalette.RED)
    col.add_child(_enemy_panel)
    col.add_child(_build_stage())
    _self_panel = StatPanel.new("甲", UiPalette.TEAL)
    col.add_child(_self_panel)
    col.add_child(_build_combo())
    col.add_child(_build_hand())
    col.add_child(_build_confirm())

    _build_log()
    _build_gameover()

    _profile = OpponentProfile.new()
    add_child(_profile)
    _profile.closed.connect(func() -> void: busy = false)

    _detail = CardDetail.new()
    add_child(_detail)
    _detail.z_index = 25


func _add_glow(center: Vector2, size: float, c: Color, alpha: float) -> void:
    var g := TextureRect.new()
    g.texture = UiPalette.radial(c, alpha)
    g.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    g.stretch_mode = TextureRect.STRETCH_SCALE
    g.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(g)
    g.position = center - Vector2(size, size) * 0.5
    g.size = Vector2(size, size)


func _build_top() -> Control:
    var top := HBoxContainer.new()
    top.custom_minimum_size.y = 32
    top.add_theme_constant_override("separation", 10)

    _turn_label = _lab("第 1 回合", 13, UiPalette.GOLD)
    _turn_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    top.add_child(_turn_label)

    var sp := Control.new()
    sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    top.add_child(sp)

    var tbox := VBoxContainer.new()
    tbox.add_theme_constant_override("separation", 2)
    tbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    top.add_child(tbox)

    _timer_bar = ProgressBar.new()
    _timer_bar.min_value = 0
    _timer_bar.max_value = 20
    _timer_bar.value = 20
    _timer_bar.show_percentage = false
    _timer_bar.custom_minimum_size = Vector2(94, 5)
    var tbg := StyleBoxFlat.new()
    tbg.bg_color = Color("#232E47")
    tbg.set_corner_radius_all(3)
    var tfill := StyleBoxFlat.new()
    tfill.bg_color = UiPalette.GOLD
    tfill.set_corner_radius_all(3)
    _timer_bar.add_theme_stylebox_override("background", tbg)
    _timer_bar.add_theme_stylebox_override("fill", tfill)
    tbox.add_child(_timer_bar)

    _timer_label = _lab("20s", 9, UiPalette.DIM)
    _timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    tbox.add_child(_timer_label)

    top.add_child(_pill_button("画像", _toggle_profile))
    top.add_child(_pill_button("日志", _toggle_log))
    top.add_child(_pill_button("重开", _on_restart))
    return top


func _build_stage() -> Control:
    var stage := Control.new()
    stage.custom_minimum_size.y = 226

    var cards := HBoxContainer.new()
    cards.alignment = BoxContainer.ALIGNMENT_CENTER
    cards.add_theme_constant_override("separation", 12)
    stage.add_child(cards)
    cards.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
    cards.offset_bottom = 190

    _enemy_slot = CardSlot.new()
    _enemy_slot.set_owner_text("乙 · " + _opponent_title())
    _enemy_slot.set_back()
    cards.add_child(_enemy_slot)

    var vs_box := PanelContainer.new()
    vs_box.custom_minimum_size = Vector2(26, 26)
    vs_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    var vsb := StyleBoxFlat.new()
    vsb.bg_color = Color(0.91, 0.75, 0.48, 0.10)
    vsb.border_color = Color(0.91, 0.75, 0.48, 0.45)
    vsb.set_border_width_all(1)
    vsb.set_corner_radius_all(13)
    vs_box.add_theme_stylebox_override("panel", vsb)
    var vs := _lab("VS", 8, UiPalette.GOLD)
    vs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    vs.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    vs_box.add_child(vs)
    cards.add_child(vs_box)

    _self_slot = CardSlot.new()
    _self_slot.set_owner_text("甲 · 你")
    _self_slot.set_back()
    cards.add_child(_self_slot)

    var cc := CenterContainer.new()
    stage.add_child(cc)
    cc.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
    cc.offset_top = -30
    cc.offset_bottom = -2

    var pill := PanelContainer.new()
    var rp := StyleBoxFlat.new()
    rp.bg_color = Color("#1A2338")
    rp.border_color = Color("#2A3550")
    rp.set_border_width_all(1)
    rp.set_corner_radius_all(12)
    rp.set_content_margin_all(6)
    pill.add_theme_stylebox_override("panel", rp)

    _result = _lab("选择一张牌，锁定后同时翻开", 11, UiPalette.DIM)
    pill.add_child(_result)
    cc.add_child(pill)
    return stage


func _build_combo() -> Control:
    var row := HBoxContainer.new()
    row.custom_minimum_size.y = 26
    row.add_theme_constant_override("separation", 8)

    var t := _lab("连招", 10, UiPalette.DIM)
    t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    row.add_child(t)

    var scroll := ScrollContainer.new()
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.custom_minimum_size.y = 26
    row.add_child(scroll)

    _combo_row = HBoxContainer.new()
    _combo_row.add_theme_constant_override("separation", 6)
    scroll.add_child(_combo_row)
    return row


func _build_hand() -> Control:
    var hand := PanelContainer.new()
    hand.size_flags_vertical = Control.SIZE_EXPAND_FILL
    var hsb := UiPalette.panel_box(UiPalette.PANEL_SOFT, 18, Color("#26314A"))
    hsb.set_content_margin_all(10)
    hsb.shadow_size = 8
    hand.add_theme_stylebox_override("panel", hsb)

    var hv := VBoxContainer.new()
    hv.add_theme_constant_override("separation", 6)
    hand.add_child(hv)

    var hair := ColorRect.new()
    hair.color = Color(0.91, 0.75, 0.48, 0.45)
    hair.custom_minimum_size.y = 1
    hv.add_child(hair)

    var tabs := HBoxContainer.new()
    tabs.add_theme_constant_override("separation", 4)
    hv.add_child(tabs)

    var group := ButtonGroup.new()
    var defs := [["all", "全部"], ["attack", "攻击"], ["defense", "防御"], ["yun", "运"], ["combo", "连招"], ["heal", "治疗"]]
    for item in defs:
        var b := Button.new()
        b.text = item[1]
        b.toggle_mode = true
        b.button_group = group
        b.focus_mode = Control.FOCUS_NONE
        b.custom_minimum_size.y = 26
        b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        b.add_theme_font_size_override("font_size", 12)
        _style_tab(b)
        b.pressed.connect(_set_filter.bind(item[0]))
        tabs.add_child(b)
        _tabs.append(b)
        if item[0] == "all":
            b.button_pressed = true

    var search := LineEdit.new()
    search.placeholder_text = "搜索卡牌名"
    search.add_theme_font_size_override("font_size", 12)
    search.custom_minimum_size.y = 28
    var lsb := StyleBoxFlat.new()
    lsb.bg_color = Color("#0E1524")
    lsb.border_color = Color("#232D44")
    lsb.set_border_width_all(1)
    lsb.set_corner_radius_all(10)
    lsb.set_content_margin_all(8)
    search.add_theme_stylebox_override("normal", lsb)
    search.add_theme_stylebox_override("focus", lsb)
    search.add_theme_color_override("font_color", UiPalette.TEXT)
    search.add_theme_color_override("font_placeholder_color", UiPalette.DIM)
    search.add_theme_color_override("caret_color", UiPalette.GOLD)
    search.text_changed.connect(_on_search)
    hv.add_child(search)

    var scroll := ScrollContainer.new()
    scroll.custom_minimum_size = Vector2(0, 224)
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    hv.add_child(scroll)

    var grid := GridContainer.new()
    grid.columns = 3
    grid.add_theme_constant_override("h_separation", 8)
    grid.add_theme_constant_override("v_separation", 8)
    grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(grid)

    var foot := HBoxContainer.new()
    foot.size_flags_vertical = Control.SIZE_EXPAND_FILL
    hv.add_child(foot)

    var hint := _lab("共 %d 张 · 上下滑动 · 长按看详情" % db.size(), 9, UiPalette.DIM)
    hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    foot.add_child(hint)
    _hint = hint

    var legend := _lab("▲攻击   ◆防御   ●运   ★连招   ✚治疗", 9, UiPalette.DIM)
    legend.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    foot.add_child(legend)

    for cid in db.order:
        var tile := CardTile.new()
        tile.setup(db.get_def(cid))
        tile.card_picked.connect(_on_tile_picked)
        tile.card_long_pressed.connect(_on_tile_long_pressed)
        grid.add_child(tile)
        _tiles.append(tile)

    return hand


func _build_confirm() -> Control:
    var bar := HBoxContainer.new()
    bar.custom_minimum_size.y = 48
    bar.add_theme_constant_override("separation", 10)

    _selected_label = _lab("未选择", 12, UiPalette.DIM)
    _selected_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _selected_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    bar.add_child(_selected_label)

    _confirm = Button.new()
    _confirm.text = "确认出牌"
    _confirm.custom_minimum_size = Vector2(168, 44)
    _confirm.focus_mode = Control.FOCUS_NONE
    _style_primary(_confirm)
    _confirm.pressed.connect(_on_confirm)
    bar.add_child(_confirm)
    return bar


func _build_log() -> void:
    _log_panel = PanelContainer.new()
    add_child(_log_panel)
    _log_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
    _log_panel.offset_left = 16
    _log_panel.offset_right = -16
    _log_panel.offset_top = -430
    _log_panel.offset_bottom = -16
    _log_panel.z_index = 20
    _log_panel.visible = false

    var sb := UiPalette.panel_box(Color("#0E1524"), 18, UiPalette.GOLD_DEEP)
    sb.set_content_margin_all(14)
    _log_panel.add_theme_stylebox_override("panel", sb)

    var v := VBoxContainer.new()
    v.add_theme_constant_override("separation", 8)
    _log_panel.add_child(v)

    var head := HBoxContainer.new()
    v.add_child(head)

    var ver := str(ProjectSettings.get_setting("application/config/version", "0.0.0"))
    var title := _lab("结算日志 · v%s" % ver, 14, UiPalette.GOLD)
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    head.add_child(title)
    head.add_child(_pill_button("收起", _toggle_log))

    _log_text = RichTextLabel.new()
    _log_text.bbcode_enabled = true
    _log_text.scroll_following = true
    _log_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _log_text.add_theme_font_size_override("normal_font_size", 12)
    _log_text.add_theme_constant_override("line_separation", 3)
    v.add_child(_log_text)


func _build_gameover() -> void:
    _gameover = Control.new()
    add_child(_gameover)
    _gameover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _gameover.z_index = 30
    _gameover.visible = false

    var dim := ColorRect.new()
    dim.color = Color(0.02, 0.03, 0.06, 0.82)
    _gameover.add_child(dim)
    dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

    var cc := CenterContainer.new()
    _gameover.add_child(cc)
    cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

    var panel := PanelContainer.new()
    panel.custom_minimum_size = Vector2(300, 250)
    var sb := UiPalette.panel_box(Color("#161E30"), 20, UiPalette.GOLD)
    sb.set_content_margin_all(24)
    panel.add_theme_stylebox_override("panel", sb)
    cc.add_child(panel)

    var v := VBoxContainer.new()
    v.alignment = BoxContainer.ALIGNMENT_CENTER
    v.add_theme_constant_override("separation", 10)
    panel.add_child(v)

    _gameover_title = _lab("胜", 60, UiPalette.GOLD)
    _gameover_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    v.add_child(_gameover_title)

    _gameover_sub = _lab("", 12, UiPalette.DIM)
    _gameover_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    v.add_child(_gameover_sub)

    var again := Button.new()
    again.text = "再来一局"
    again.custom_minimum_size = Vector2(180, 46)
    again.focus_mode = Control.FOCUS_NONE
    _style_primary(again)
    again.pressed.connect(_on_restart)
    v.add_child(again)


## 联机模式：由大厅在切场景前调用，把已建好的控制器交给对战界面
func setup_online(ctrl: MatchController) -> void:
    controller = ctrl
    duel = controller.duel
    controller.turn_resolved.connect(_on_turn_resolved)
    controller.opponent_joined.connect(func(n: String) -> void:
        if _enemy_panel != null:
            _enemy_panel.set_title(n))
    controller.opponent_left.connect(func() -> void:
        _result.text = "对手已离开"
        _result.add_theme_color_override("font_color", UiPalette.RED))
    controller.state_mismatch.connect(func(detail: String) -> void:
        push_warning("联机状态不一致: " + detail))
    _start_match()


func _start_match() -> void:
    # 单机：控制器内部建好对局；联机：控制器已由大厅接好，这里只重置界面
    if controller == null or controller.mode == MatchController.MODE_LOCAL:
        controller = MatchController.new()
        controller.setup_local(db, MATCH_SEED + _match_no)
        controller.turn_resolved.connect(_on_turn_resolved)
    duel = controller.duel
    _match_no += 1
    selected_id = ""
    busy = false
    debug_hold = false
    debug_ai_card = str(ProjectSettings.get_setting(DBG_FORCE_CARD, ""))
    _reveal_turn = 0
    _log_lines.clear()
    if _detail != null:
        _detail.visible = false
    if _log_text != null:
        _log_text.text = ""
    if _gameover != null:
        _gameover.visible = false
    _start_turn()


func _start_turn() -> void:
    selected_id = ""
    busy = false
    _reveal_turn = 0
    time_left = 20.0
    _last_sec = 20
    _timer_bar.value = 20
    _timer_label.text = "20s"
    _enemy_slot.set_back()
    _enemy_slot.set_owner_text("乙 · 对手")
    _self_slot.set_back()
    _self_slot.set_owner_text("甲 · 你")
    _result.text = "选择一张牌，锁定后同时翻开"
    _result.add_theme_color_override("font_color", UiPalette.DIM)
    _refresh()


func _refresh() -> void:
    if duel == null:
        return
    var st := duel.state
    var shown := _reveal_turn if _reveal_turn > 0 else st.turn + 1
    _turn_label.text = "第 %d 回合" % shown
    _enemy_panel.update_view(st.players[1], "对手 · " + _opponent_title(), st.turn, db)
    _self_panel.update_view(st.players[0], "你 · 甲", st.turn, db)
    _refresh_combo()
    _refresh_tiles()

    var skipped := st.players[0].skip_turn == st.turn
    if skipped:
        selected_id = "pass"

    _confirm.disabled = selected_id == "" or busy or st.over
    if skipped:
        _selected_label.text = "被鄙视 · 本回合只能空过"
        _selected_label.add_theme_color_override("font_color", UiPalette.RED.lightened(0.15))
        return

    var d := db.get_def(selected_id)
    if d != null:
        _selected_label.text = "已选 · %s   %s" % [d.display_name, d.desc]
        _selected_label.add_theme_color_override("font_color", UiPalette.TEXT)
    else:
        _selected_label.text = "未选择"
        _selected_label.add_theme_color_override("font_color", UiPalette.DIM)


func _can_play(cid: String) -> bool:
    if controller != null:
        return controller.can_play(cid)
    return duel != null and duel.can_play(0, cid)


func _opponent_title() -> String:
    if controller != null and controller.mode == MatchController.MODE_ONLINE:
        return controller.opponent_name
    return "影武者"


func _refresh_tiles() -> void:
    for tile in _tiles:
        var d := db.get_def(tile.card_id)
        var legal := _can_play(tile.card_id)
        var reason := "" if legal else _reason(tile.card_id)
        tile.set_state(legal, reason, tile.card_id == selected_id, _cd_text(tile.card_id))
        tile.visible = _matches(d)


func _refresh_combo() -> void:
    for ch in _combo_row.get_children():
        _combo_row.remove_child(ch)
        ch.queue_free()

    for cid in db.order:
        var d := db.get_def(cid)
        if d.combo.is_empty():
            continue
        var prog := ComboMatcher.progress(duel.state.players[0].history, d.combo)
        var full := prog >= d.combo.size()

        var pc := PanelContainer.new()
        var sb := StyleBoxFlat.new()
        sb.bg_color = Color(0.91, 0.75, 0.48, 0.14) if full else Color("#1A2338")
        sb.border_color = UiPalette.GOLD if full else Color("#2A3550")
        sb.set_border_width_all(1)
        sb.set_corner_radius_all(9)
        sb.set_content_margin_all(4)
        pc.add_theme_stylebox_override("panel", sb)
        pc.add_child(_lab("%s %d/%d" % [d.display_name, prog, d.combo.size()], 9,
            UiPalette.GOLD if full else UiPalette.DIM))
        _combo_row.add_child(pc)


func _matches(d: SkillDef) -> bool:
    if search_text != "" and not d.display_name.contains(search_text):
        return false
    match filter:
        "all":
            return true
        "attack":
            return d.tags.has("attack")
        "defense":
            return d.tags.has("defense")
        "yun":
            return d.tags.has("resource") or d.tags.has("counter")
        "combo":
            return d.tags.has("combo")
        "heal":
            return d.tags.has("heal")
    return true


func _reason(cid: String) -> String:
    var d := db.get_def(cid)
    if d == null:
        return ""
    var p := duel.state.players[0]
    if p.skip_turn == duel.state.turn:
        return "被鄙视"
    if duel.state.turn == 0 and cid != "yun":
        return "首回合只能出运"
    if not d.combo.is_empty() and not d.combo_optional:
        var bypass := cid == "jiang_fei" and p.flags.has("fly_dragon_ready")
        if not bypass and not ComboMatcher.suffix_matches(p.history, d.combo):
            return "连招未满足"
    var pool := d.pool_id if d.pool_id != "" else d.id
    if not p.can_use(pool, d.cooldown, duel.state.turn):
        return "冷却中"
    if d.cost_kind != "all_in":
        var need := duel.effective_cost(0, d)
        if need > 0 and p.yun < need:
            return "运不足"
    return ""


func _cd_text(cid: String) -> String:
    var d := db.get_def(cid)
    if d == null or d.cooldown <= 0:
        return ""
    var p := duel.state.players[0]
    var pool := d.pool_id if d.pool_id != "" else d.id
    if not p.last_played.has(pool):
        return ""
    var left := d.cooldown - (duel.state.turn - int(p.last_played[pool])) + 1
    return ("CD%d" % left) if left > 0 else ""


func _on_tile_picked(cid: String) -> void:
    if busy or duel == null or duel.state.over:
        return
    if _detail != null and _detail.visible:
        return
    if not _can_play(cid):
        return
    selected_id = cid
    _self_slot.set_card(cid, db, "")
    _refresh()


func _on_tile_long_pressed(cid: String) -> void:
    if duel == null or duel.state.over:
        return
    var ok := _can_play(cid)
    var s := "现在可以出" if ok else "不可出 · " + _reason(cid)
    _detail.open(cid, db, s, ok)



# —— 对手习惯模型相关 ——

# 情境键：回合阶段 | 血量区间 | 运区间 | 上一手性质
# 刻意做得很粗：模型要的是"可复现的粗分类"，太细就学不到东西。
func _context_for(player: int) -> String:
    if duel == null:
        return ""
    var p := duel.state.players[player]
    var t := duel.state.turn
    var tb := "t1" if t <= 0 else ("t2_3" if t <= 2 else "t4p")
    var hb := "hp_lo" if p.hp < 40 else ("hp_mid" if p.hp < 80 else "hp_hi")
    var yb := "y0" if p.yun <= 0 else ("y1_2" if p.yun < 30 else ("y3_4" if p.yun < 50 else "y5p"))
    var last := ""
    if p.history.size() > 0:
        last = str(p.history[p.history.size() - 1])
    return "%s|%s|%s|%s" % [tb, hb, yb, _tag_of(last)]


func _tag_of(card_id: String) -> String:
    if card_id == "" or db == null:
        return "-"
    var d := db.get_def(card_id)
    if d == null:
        return "-"
    if d.tags.has("attack"):
        return "atk"
    if d.tags.has("defense"):
        return "def"
    if d.tags.has("resource"):
        return "res"
    if d.tags.has("heal"):
        return "heal"
    return "-"


func _tags_of(card_id: String) -> Array:
    if card_id == "" or db == null:
        return []
    var d := db.get_def(card_id)
    return d.tags if d != null else []


# 这张牌是不是某张长连招牌的"前置步"（比如中防是龟派的前置）
func _is_combo_setup(card_id: String) -> bool:
    if db == null:
        return false
    for cid in db.order:
        var d := db.get_def(cid)
        if d == null or d.combo.is_empty():
            continue
        if d.combo.has(card_id):
            return true
    return false


# 这张牌自己是不是长连招的收尾牌
func _is_combo_finish(card_id: String) -> bool:
    if db == null:
        return false
    var d := db.get_def(card_id)
    return d != null and not d.combo.is_empty()


func _toggle_profile() -> void:
    if _profile == null:
        return
    if _profile.visible:
        _profile.close()
        return
    busy = true
    _profile.open(opponent_model, db)


func _save_opponent_model() -> void:
    if opponent_model != null:
        OpponentStore.save_model(opponent_model)


func _on_confirm() -> void:
    if busy or duel == null or selected_id == "":
        return
    if controller == null or not controller.can_play(selected_id):
        return
    # 联机：提交给服务器，等它的 turn_resolve 事件回来才结算
    # 单机：控制器内部选 AI 的牌并立刻结算，_on_turn_resolved 接手
    controller.submit(selected_id, debug_ai_card)
    if controller.mode == MatchController.MODE_ONLINE:
        busy = true
        _result.text = "已出牌，等待对手…"
        _result.add_theme_color_override("font_color", UiPalette.GOLD)
        _confirm.disabled = true


func _on_turn_resolved(cards: Array, events: Array) -> void:
    # 单机与联机共用同一条结算 / 表现路径
    if cards.size() < 2:
        return
    var a := str(cards[0])
    var b := str(cards[1])
    busy = true
    _enemy_slot.set_back()
    _result.text = "同时翻开…"
    _result.add_theme_color_override("font_color", UiPalette.GOLD)
    await get_tree().create_timer(0.18).timeout

    _reveal_turn = duel.state.turn + 1
    # 记录玩家在"这个情境"下出的牌 → 持续学习出牌习惯
    var human_ctx := _context_for(0)
    if opponent_model != null and a != "":
        opponent_model.observe(human_ctx, a, _tags_of(a),
            _is_combo_setup(a), _is_combo_finish(a))
    _self_slot.set_card(a, db, _badge_for(events, 0))
    _enemy_slot.set_card(b, db, _badge_for(events, 1))
    _result.text = _summary(events)
    _result.add_theme_color_override("font_color", _summary_color(events))
    _pulse(_self_slot)
    _pulse(_enemy_slot)
    _append_log(a, b, events)
    _refresh()

    if _took_damage(events, 0):
        _self_panel.flash(Color(1.0, 0.55, 0.45))
    if _took_damage(events, 1):
        _enemy_panel.flash(Color(1.0, 0.55, 0.45))

    await get_tree().create_timer(0.85).timeout

    if duel.state.over:
        _show_gameover()
    elif debug_hold:
        busy = false
        time_left = 20.0
        _timer_bar.value = 20
        _timer_label.text = "20s"
    else:
        _start_turn()


func _on_timeout() -> void:
    if busy or duel == null or duel.state.over:
        return
    # 联机：超时由服务器看门狗替我们出牌（服务器是权威，不能本地擅自改）
    if controller != null and controller.mode == MatchController.MODE_ONLINE:
        _result.text = "超时，等待服务器判定…"
        _result.add_theme_color_override("font_color", UiPalette.RED)
        return
    var pick := ""
    if duel.can_play(0, "yun"):
        pick = "yun"
    else:
        var legal := duel.legal_cards(0)
        if not legal.is_empty():
            pick = legal[0]
    if pick == "":
        return
    selected_id = pick
    _refresh()
    _on_confirm()


func _on_restart() -> void:
    # 中途重开也算一局结束：衰减历史倾向并落盘
    if opponent_model != null and duel != null and not duel.state.over:
        opponent_model.end_match()
        _save_opponent_model()
    _start_match()


func _toggle_log() -> void:
    _log_panel.visible = not _log_panel.visible


func _set_filter(f: String) -> void:
    filter = f
    _refresh_tiles()


func _on_search(t: String) -> void:
    search_text = t.strip_edges()
    _refresh_tiles()


func _show_gameover() -> void:
    busy = true
    # 一局结束：衰减历史倾向（习惯会变），并立刻落盘
    if opponent_model != null:
        opponent_model.end_match()
        _save_opponent_model()
    _gameover.visible = true
    var win := duel.state.winner == 0
    _gameover_title.text = "胜" if win else "负"
    _gameover_title.add_theme_color_override("font_color", UiPalette.GOLD if win else UiPalette.RED)
    _gameover_sub.text = "%d 回合 · %s" % [duel.state.turn, _reason_text(duel.state.end_reason)]


func _exit_tree() -> void:
    # app 关闭时也要落盘（手机上可能被系统直接杀掉进程）
    _save_opponent_model()


func _badge_for(events: Array, p: int) -> String:
    for ev in events:
        match str(ev.get("t", "")):
            "COUNTER":
                if int(ev.get("player", -1)) == p:
                    return "被 %s 挡下" % _name(str(ev.get("by", "")))
            "SHIELD_SAVE":
                if int(ev.get("player", -1)) == p:
                    return "盾保命"
            "IMMUNE":
                if int(ev.get("player", -1)) == p:
                    return "酒 · 免疫"
            "CODE_KILL":
                if int(ev.get("target", -1)) == p:
                    return "代码杀"
    return ""


func _summary(events: Array) -> String:
    var parts: Array[String] = []
    for ev in events:
        match str(ev.get("t", "")):
            "DAMAGE_VOIDED":
                return "同死 · 本回合伤害作废"
            "KUI_CANCEL":
                return "双方龟派 · 互相抵消"
            "KUI":
                return "%s 龟派 · %s 转为己用" % [_who(int(ev["player"])), _name(str(ev["card"]))]
            "TIME_STOP":
                return "%s 扭转时空 · 本回合无效" % _who(int(ev["player"]))
            "GAME_OVER":
                return "%s 胜" % _who(int(ev.get("winner", 0)))
            "DAMAGE":
                parts.append("%s -%s" % [_who(int(ev["target"])), _hp(int(ev["amount"]))])
            "COUNTER":
                parts.append("%s 被 %s 挡下" % [_who(int(ev["player"])), _name(str(ev["by"]))])
            "SHIELD_SAVE":
                parts.append("%s 盾保命" % _who(int(ev["player"])))
            "HEAL":
                parts.append("%s +%s" % [_who(int(ev["player"])), _hp(int(ev["amount"]))])
            "DOT_APPLY":
                parts.append("%s 中偷袭" % _who(int(ev["player"])))
            "IMMUNE":
                parts.append("%s 免疫" % _who(int(ev["player"])))
            "BLOCK_BACKLASH":
                parts.append("%s 反伤 -%s" % [_who(int(ev["player"])), _hp(int(ev["amount"]))])
    if parts.is_empty():
        return "本回合无变化"
    var out := ""
    for i in mini(2, parts.size()):
        if out != "":
            out += "   ·   "
        out += parts[i]
    return out


func _summary_color(events: Array) -> Color:
    var has_damage := false
    var has_heal := false
    var has_counter := false
    var has_immune := false
    for ev in events:
        match str(ev.get("t", "")):
            "DAMAGE_VOIDED", "GAME_OVER":
                return UiPalette.GOLD
            "DAMAGE":
                has_damage = true
            "HEAL":
                has_heal = true
            "COUNTER":
                has_counter = true
            "IMMUNE":
                has_immune = true
    if has_damage:
        return UiPalette.RED.lightened(0.15)
    if has_immune:
        return UiPalette.BLUE.lightened(0.2)
    if has_heal:
        return UiPalette.TEAL
    if has_counter:
        return UiPalette.BLUE.lightened(0.15)
    return UiPalette.DIM


func _took_damage(events: Array, p: int) -> bool:
    for ev in events:
        if str(ev.get("t", "")) == "DAMAGE" and int(ev.get("target", -1)) == p:
            return true
    return false


func _append_log(a: String, b: String, events: Array) -> void:
    var head := "[color=#E8C07A]第 %d 回合[/color]   [color=#5B8DEF]甲 %s[/color]  vs  [color=#E4572E]乙 %s[/color]" % [
        duel.state.turn, _name(a), _name(b)
    ]
    _log_lines.append(head)
    for ev in events:
        var t := _event_text(ev)
        if t != "":
            _log_lines.append("[color=#93A0B8]·[/color] " + t)
    while _log_lines.size() > 240:
        _log_lines.pop_front()
    _log_text.text = "\n".join(_log_lines)


func _event_text(ev: Dictionary) -> String:
    match str(ev.get("t", "")):
        "COUNTER":
            return "%s 的 %s 被 %s 挡下" % [_who(int(ev["player"])), _name(str(ev["card"])), _name(str(ev["by"]))]
        "STEAL_YUN":
            return "%s 吸走 %s 运" % [_who(int(ev["player"])), _yun(int(ev["amount"]))]
        "YUN":
            return "%s +%s 运" % [_who(int(ev["player"])), _yun(int(ev["amount"]))]
        "HEAL":
            return "%s +%s 血" % [_who(int(ev["player"])), _hp(int(ev["amount"]))]
        "SHIELD_ADD":
            return "%s +1 盾" % _who(int(ev["player"]))
        "DAMAGE":
            return "%s -%s 血（剩 %s）" % [_who(int(ev["target"])), _hp(int(ev["amount"])), _hp(int(ev["hp"]))]
        "SHIELD_SAVE":
            return "%s 消耗 %d 盾保命" % [_who(int(ev["player"])), int(ev["used"])]
        "SHIELD_FAIL":
            return "%s 盾不足（需 %d，有 %d）" % [_who(int(ev["player"])), int(ev["need"]), int(ev["have"])]
        "DAMAGE_VOIDED":
            return "[color=#E8C07A]同死，本回合伤害作废，继续对局[/color]"
        "FLY_DRAGON_KEPT":
            return "%s 的降飞保留，下回合可再出" % _who(int(ev["player"]))
        "GAME_OVER":
            return "[color=#E8C07A]对局结束：%s 胜[/color]" % _who(int(ev["winner"]))
        "BLOCK_BACKLASH":
            return "%s 挡下后被反伤 %s 血" % [_who(int(ev["player"])), _hp(int(ev["amount"]))]
        "DOT_APPLY":
            return "%s 中偷袭：每回合 -%s，共 %d 回合" % [
                _who(int(ev["player"])), _hp(int(ev["amount"])), int(ev["turns"])
            ]
        "DOT_END":
            return "%s 的偷袭结束" % _who(int(ev["player"]))
        "DOT_CLEARED":
            return "%s 用桃桃解除偷袭" % _who(int(ev["player"]))
        "IMMUNE":
            return "%s 的酒免疫了 %s 伤害" % [_who(int(ev["player"])), _hp(int(ev["amount"]))]
        "CODE_KILL":
            return "[color=#E4572E]%s 被代码杀[/color]" % _who(int(ev["target"]))
        "YUN_CONSUMED":
            return "%s 的运被抵消" % _who(int(ev["player"]))
        "PRISM":
            return "%s 三棱镜 k=%d" % [_who(int(ev["player"])), int(ev["k"])]
        "KUI":
            return "[color=#8E7BE8]%s 龟派：%s 转为己用[/color]" % [
                _who(int(ev["player"])), _name(str(ev["card"]))
            ]
        "KUI_CANCEL":
            return "[color=#8E7BE8]双方龟派互相抵消[/color]"
        "KUI_NOOP":
            return "%s 龟派了 %s，但无可转对象" % [_who(int(ev["player"])), _name(str(ev["card"]))]
        "TIME_STOP":
            return "[color=#5B8DEF]%s 扭转时空：本回合全部无效[/color]" % _who(int(ev["player"]))
        "REFLECT":
            return "%s 觉醒中防反弹 %s" % [_who(int(ev["player"])), _hp(int(ev["amount"]))]
        "C4_APPLY":
            return "%s 中 C4：%d 回合后 -%s" % [
                _who(int(ev["player"])), int(ev["fire_turn"]), _hp(int(ev["amount"]))
            ]
        "PURIFY":
            return "%s 净化：解除 %d 层，回血 %s" % [
                _who(int(ev["player"])), int(ev["cleared"]), _hp(int(ev["healed"]))
            ]
        "SKIP_NEXT":
            return "%s 被鄙视，下回合空过" % _who(int(ev["player"]))
        "COST_HALF":
            return "%s 葵花宝典：后续费用减半" % _who(int(ev["player"]))
        "CANNON_BUFF":
            return "%s 元首之怒：意大利炮降至 2 费" % _who(int(ev["player"]))
        "SCHEDULE_YUN":
            return "%s 向运葵：%d 回合各 +%s 运" % [
                _who(int(ev["player"])), int(ev["turns"]), _yun(int(ev["amount"]))
            ]
        "YUN_STOLEN":
            return "%s 究掐抢走 %s 运" % [_who(int(ev["player"])), _yun(int(ev["amount"]))]
    return ""


func _pulse(n: Control) -> void:
    n.pivot_offset = n.size * 0.5
    n.scale = Vector2(0.96, 0.96)
    var tw := create_tween()
    tw.tween_property(n, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _reason_text(reason: String) -> String:
    match reason:
        "death":
            return "击杀"
        "more_negative":
            return "同死，负血更少者胜"
        "code_kill_priority":
            return "同死，代码杀优先"
    return reason


func debug_autoplay_turn() -> void:
    if busy or duel == null or duel.state.over:
        return
    var priority := ["xiao_biao", "kai_sa", "chang_gong", "jiang_long", "jiang_fei", "gua_sha", "yun"]
    var pick := ""
    for cid in priority:
        if duel.can_play(0, cid):
            pick = cid
            break
    if pick == "":
        var legal := duel.legal_cards(0)
        if not legal.is_empty():
            pick = legal[0]
    if pick == "":
        return
    selected_id = pick
    _refresh()
    _on_confirm()


func _lab(t: String, size: int, c: Color) -> Label:
    var l := Label.new()
    l.text = t
    l.add_theme_font_size_override("font_size", size)
    l.add_theme_color_override("font_color", c)
    return l


func _who(i: int) -> String:
    return "甲" if i == 0 else "乙"


func _name(cid: String) -> String:
    var d := db.get_def(cid)
    return d.display_name if d != null else cid


func _hp(v: int) -> String:
    return "%.2f" % (v / float(Units.HP))


func _yun(v: int) -> String:
    return "%.1f" % (v / float(Units.YUN))


func _pill_button(t: String, cb: Callable) -> Button:
    var b := Button.new()
    b.text = t
    b.custom_minimum_size = Vector2(52, 28)
    b.focus_mode = Control.FOCUS_NONE
    b.add_theme_font_size_override("font_size", 11)

    var n := StyleBoxFlat.new()
    n.bg_color = Color("#1A2338")
    n.border_color = Color("#2A3550")
    n.set_border_width_all(1)
    n.set_corner_radius_all(9)
    b.add_theme_stylebox_override("normal", n)

    var h := n.duplicate() as StyleBoxFlat
    h.bg_color = Color("#22304A")
    b.add_theme_stylebox_override("hover", h)
    b.add_theme_stylebox_override("pressed", h)
    b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
    b.add_theme_color_override("font_color", UiPalette.DIM)
    b.add_theme_color_override("font_hover_color", UiPalette.TEXT)
    b.pressed.connect(cb)
    return b


func _style_tab(b: Button) -> void:
    var n := StyleBoxFlat.new()
    n.bg_color = Color(0, 0, 0, 0)
    n.set_corner_radius_all(8)
    n.set_content_margin_all(6)
    b.add_theme_stylebox_override("normal", n)
    b.add_theme_stylebox_override("hover", n)

    var p := StyleBoxFlat.new()
    p.bg_color = Color("#1F2940")
    p.border_color = UiPalette.GOLD
    p.set_border_width_all(0)
    p.set_border_width(SIDE_BOTTOM, 2)
    p.set_corner_radius_all(8)
    p.set_content_margin_all(6)
    b.add_theme_stylebox_override("pressed", p)
    b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
    b.add_theme_color_override("font_color", UiPalette.DIM)
    b.add_theme_color_override("font_pressed_color", UiPalette.GOLD)
    b.add_theme_color_override("font_hover_color", UiPalette.TEXT)


func _style_primary(b: Button) -> void:
    var n := StyleBoxFlat.new()
    n.bg_color = UiPalette.GOLD
    n.set_corner_radius_all(14)
    n.shadow_color = Color(0.91, 0.75, 0.48, 0.28)
    n.shadow_size = 12
    n.shadow_offset = Vector2(0, 4)
    b.add_theme_stylebox_override("normal", n)

    var h := n.duplicate() as StyleBoxFlat
    h.bg_color = UiPalette.GOLD.lightened(0.12)
    b.add_theme_stylebox_override("hover", h)

    var p := n.duplicate() as StyleBoxFlat
    p.bg_color = UiPalette.GOLD.darkened(0.12)
    b.add_theme_stylebox_override("pressed", p)

    var d := n.duplicate() as StyleBoxFlat
    d.bg_color = Color("#4A3C22")
    d.shadow_size = 0
    b.add_theme_stylebox_override("disabled", d)

    b.add_theme_color_override("font_color", Color("#17110A"))
    b.add_theme_color_override("font_hover_color", Color("#17110A"))
    b.add_theme_color_override("font_pressed_color", Color("#17110A"))
    b.add_theme_color_override("font_disabled_color", UiPalette.DIM)
    b.add_theme_font_size_override("font_size", 15)
