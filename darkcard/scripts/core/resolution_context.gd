class_name ResolutionContext
extends RefCounted

var state: DuelState
var turn: int = 0
var cards: Array[String] = []
var defs: Array[SkillDef] = []
var paid: Array[int] = []
var negated: Array[bool] = []
var blocked_by: Array[String] = []
var damage_events: Array[Dictionary] = []
var code_kill: Array[bool] = []
# 运挡为抵消（超掐/手枪，E4）：该玩家的运牌本回合不产生运
var yun_consumed: Array[bool] = []

# 龟派重定向：redirect[i] = 牌 i 的效果归属者（默认 i）
var redirect: Array[int] = []
var kui_mult: int = 1
var kui_caster: int = -1
var kui_taken: Array[bool] = []
var time_stopped: bool = false


func _init(st: DuelState, a: String, b: String, db: CardDB) -> void:
    state = st
    turn = st.turn

    cards.append(a)
    cards.append(b)

    defs.append(db.get_def(a))
    defs.append(db.get_def(b))

    paid.append(st.players[0].pending_paid)
    paid.append(st.players[1].pending_paid)

    for i in 2:
        negated.append(false)
        blocked_by.append("")
        code_kill.append(false)
        yun_consumed.append(false)
        redirect.append(i)
        kui_taken.append(false)


func owner_of(i: int) -> int:
    return redirect[i]


func target_of(i: int) -> int:
    var d: SkillDef = defs[i]
    var o := redirect[i]
    if d == null:
        return 1 - o
    if d.target == "enemy":
        return 1 - o
    return o


func is_kui_taken(i: int) -> bool:
    return redirect[i] != i
