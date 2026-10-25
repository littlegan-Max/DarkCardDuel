extends Control

const RUN_SEED := 20261024

var _db: CardDB
var _duel: Duel
var _log: RichTextLabel
var _status: Label


func _ready() -> void:
    _apply_font()
    _build_ui()
    _db = CardDB.load_all()
    if _db.size() == 0:
        _status.text = "卡表加载失败：检查 data/cards.json"
        return
    _status.text = "卡表 %d 张 · rules %s · 点上方按钮跑一局" % [_db.size(), _db.rules_version]


func _apply_font() -> void:
    var sys := SystemFont.new()
    sys.font_names = PackedStringArray([
        "Microsoft YaHei", "Noto Sans CJK SC", "PingFang SC", "SimHei"
    ])
    var t := Theme.new()
    t.default_font = sys
    t.default_font_size = 18
    var ink := Color(0.161, 0.165, 0.157)
    t.set_color("font_color", "Label", ink)
    t.set_color("default_color", "RichTextLabel", ink)

    var btn := StyleBoxFlat.new()
    btn.bg_color = Color("#E6F1FB")
    btn.border_color = Color("#B5D4F4")
    btn.set_border_width_all(1)
    btn.set_corner_radius_all(10)
    btn.content_margin_left = 20
    btn.content_margin_right = 20
    btn.content_margin_top = 12
    btn.content_margin_bottom = 12
    t.set_stylebox("normal", "Button", btn)

    var btn_hover := btn.duplicate() as StyleBoxFlat
    btn_hover.bg_color = Color("#D6E8F9")
    t.set_stylebox("hover", "Button", btn_hover)

    var btn_pressed := btn.duplicate() as StyleBoxFlat
    btn_pressed.bg_color = Color("#C3DCF5")
    t.set_stylebox("pressed", "Button", btn_pressed)

    t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
    t.set_color("font_color", "Button", Color("#0C447C"))
    t.set_color("font_hover_color", "Button", Color("#0C447C"))
    t.set_color("font_pressed_color", "Button", Color("#0C447C"))

    theme = t


func _build_ui() -> void:
    var bg := ColorRect.new()
    bg.color = Color(0.961, 0.965, 0.973)
    bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(bg)
    bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

    var margin := MarginContainer.new()
    add_child(margin)
    margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    margin.add_theme_constant_override("margin_left", 48)
    margin.add_theme_constant_override("margin_right", 48)
    margin.add_theme_constant_override("margin_top", 56)
    margin.add_theme_constant_override("margin_bottom", 40)

    var vb := VBoxContainer.new()
    vb.add_theme_constant_override("separation", 14)
    margin.add_child(vb)

    var title := Label.new()
    title.text = "暗牌技能对战"
    title.add_theme_font_size_override("font_size", 34)
    title.add_theme_color_override("font_color", Color(0.047, 0.267, 0.486))
    vb.add_child(title)

    var sub := Label.new()
    sub.text = "规则内核垂直切片 · rules 2.1 · 15 张牌 · 甲=进攻型 / 乙=防守型"
    sub.add_theme_color_override("font_color", Color(0.373, 0.369, 0.353))
    sub.add_theme_font_size_override("font_size", 16)
    vb.add_child(sub)

    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 12)
    vb.add_child(row)

    var run_btn := Button.new()
    run_btn.text = "跑一局 AI 对局"
    run_btn.custom_minimum_size = Vector2(230, 58)
    run_btn.pressed.connect(_on_run)
    row.add_child(run_btn)

    var clear_btn := Button.new()
    clear_btn.text = "清空"
    clear_btn.custom_minimum_size = Vector2(120, 58)
    clear_btn.pressed.connect(_on_clear)
    row.add_child(clear_btn)

    _log = RichTextLabel.new()
    _log.bbcode_enabled = true
    _log.scroll_following = true
    _log.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _log.custom_minimum_size = Vector2(0, 420)
    _log.add_theme_font_size_override("normal_font_size", 18)
    _log.add_theme_constant_override("line_separation", 4)
    vb.add_child(_log)

    _status = Label.new()
    _status.text = "就绪"
    _status.add_theme_color_override("font_color", Color(0.373, 0.369, 0.353))
    _status.add_theme_font_size_override("font_size", 15)
    vb.add_child(_status)


func _on_clear() -> void:
    _log.clear()
    _status.text = "已清空"


func _on_run() -> void:
    if _db == null or _db.size() == 0:
        return

    _log.clear()
    _duel = Duel.new(_db)
    var rng := RandomNumberGenerator.new()
    rng.seed = RUN_SEED

    var lines: Array[String] = []
    lines.append("[color=#5F5E5A]双方同时暗牌 → 同翻 → 十步结算。这里只展示结果行，结算细节见 headless 用例。[/color]")
    lines.append("")

    var guard := 0
    while not _duel.state.over and _duel.state.turn < 40 and guard < 80:
        guard += 1
        var t := _duel.state.turn
        var a := SimpleAI.choose(_duel, 0, rng, "aggro")
        var b := SimpleAI.choose(_duel, 1, rng, "turtle")
        if a == "" or b == "":
            break
        _duel.play_turn(a, b)
        lines.append(_turn_line(t, a, b))

    lines.append("")
    if _duel.state.over:
        var w := "甲" if _duel.state.winner == 0 else "乙"
        lines.append("[b][color=#0C447C]%s 胜[/color][/b]   %d 回合   %s" % [
            w, _duel.state.turn, _reason_text(_duel.state.end_reason)
        ])
    else:
        lines.append("[b][color=#854F0B]达到 40 回合上限，未分胜负[/color][/b]")

    _log.text = "\n".join(lines)
    _status.text = "甲 %s 血 / 乙 %s 血 · 共 %d 回合" % [
        _hp(_duel.state.players[0].hp),
        _hp(_duel.state.players[1].hp),
        _duel.state.turn,
    ]


func _turn_line(t: int, a: String, b: String) -> String:
    var p0: PlayerState = _duel.state.players[0]
    var p1: PlayerState = _duel.state.players[1]
    return "[color=#5F5E5A]第 %2d 回合[/color]   [color=#185FA5]甲 · %s[/color]   vs   [color=#854F0B]乙 · %s[/color]\n      [color=#5F5E5A]血[/color] %s : %s    [color=#5F5E5A]运[/color] %s : %s" % [
        t + 1, _name(a), _name(b), _hp(p0.hp), _hp(p1.hp), _yun(p0.yun), _yun(p1.yun)
    ]

func _name(cid: String) -> String:
    var d := _db.get_def(cid)
    return d.display_name if d != null else cid


func _hp(v: int) -> String:
    return "%.2f" % (v / float(Units.HP))


func _yun(v: int) -> String:
    return "%.1f" % (v / float(Units.YUN))


func _reason_text(reason: String) -> String:
    match reason:
        "death":
            return "击杀"
        "more_negative":
            return "同死，负血更少者胜"
        "code_kill_priority":
            return "同死，代码杀优先"
        _:
            return reason
