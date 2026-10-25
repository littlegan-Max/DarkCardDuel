class_name Duel
extends RefCounted

var db: CardDB
var state: DuelState
var resolver: TurnResolver


func _init(card_db: CardDB) -> void:
    db = card_db
    state = DuelState.create()
    resolver = TurnResolver.new(card_db)


func effective_cost(player: int, d: SkillDef) -> int:
    var p := state.players[player]
    var base := d.cost
    if d.cost_rule == "shield_price":
        # 首次用牌价 = 卡表 cost，之后永久便宜 1 费（规则：首次 3，之后 2）
        base = d.cost - Units.YUN if p.shield_bought_once else d.cost
    elif d.cost_rule == "cannon_price":
        # 元首 buff 期固定 2 费，否则用卡表 cost（RFC-0008 后 5 费）
        base = 2 * Units.YUN if p.cannon_discounted(state.turn) else d.cost
    return base * p.cost_percent / Units.PERCENT


func can_play(player: int, cid: String) -> bool:
    if state.over:
        return false

    var p := state.players[player]
    if p.pending_card != "":
        return false

    # 鄙视：本回合只能空过（B15）
    if p.skip_turn == state.turn:
        return cid == "pass"
    if cid == "pass":
        return false

    var d := db.get_def(cid)
    if d == null:
        return false

    # 第一回合只能出运
    if state.turn == 0 and cid != "yun":
        return false

    # 连招门（降飞被运挡后有一次豁免；究掐可无连招使用）
    if not d.combo.is_empty() and not d.combo_optional:
        var bypass := cid == "jiang_fei" and p.flags.has("fly_dragon_ready")
        if not bypass:
            if not ComboMatcher.suffix_matches(p.history, d.combo):
                return false

    # 冷却 / 不可连用
    var pool := d.pool_id if d.pool_id != "" else d.id
    if not p.can_use(pool, d.cooldown, state.turn):
        return false

    # 费用（核弹 all_in 永不拦截；0 费牌在负运时也能出）
    if d.cost_kind == "all_in":
        return true
    var need := effective_cost(player, d)
    return need <= 0 or p.yun >= need


func legal_cards(player: int) -> Array[String]:
    var out: Array[String] = []
    for cid in db.order:
        if can_play(player, cid):
            out.append(cid)
    if can_play(player, "pass"):
        out.append("pass")
    return out


func submit(player: int, cid: String) -> bool:
    if not can_play(player, cid):
        return false

    var d := db.get_def(cid)
    var p := state.players[player]
    var pay := 0
    if d != null and d.cost_kind == "all_in":
        pay = clampi(p.yun, 0, d.cost)
    elif d != null:
        pay = effective_cost(player, d)

    p.yun -= pay
    p.pending_card = cid
    p.pending_paid = pay

    if cid == "jiang_fei" and p.flags.has("fly_dragon_ready"):
        p.flags.erase("fly_dragon_ready")

    return true


func ready() -> bool:
    return state.players[0].pending_card != "" and state.players[1].pending_card != ""


func resolve_turn() -> Array:
    if not ready():
        return []
    return resolver.resolve(state)


func play_turn(a: String, b: String) -> Array:
    if state.over:
        return []
    if not can_play(0, a) or not can_play(1, b):
        return []
    submit(0, a)
    submit(1, b)
    return resolve_turn()


func is_over() -> bool:
    return state.over


func hp_text(player: int) -> String:
    return "%.2f" % (state.players[player].hp / float(Units.HP))


func yun_text(player: int) -> String:
    return "%.1f" % (state.players[player].yun / float(Units.YUN))
