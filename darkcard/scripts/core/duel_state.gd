class_name DuelState
extends RefCounted

var turn: int = 0
var players: Array[PlayerState] = []
var over: bool = false
var winner: int = -1          # -1 未结束，0/1 胜者
var end_reason: String = ""
var turn_logs: Array = []


static func create() -> DuelState:
    var s := DuelState.new()
    var a := PlayerState.new()
    var b := PlayerState.new()
    s.players.append(a)
    s.players.append(b)
    return s


func other(player: int) -> int:
    return 1 - player


func snapshot() -> Dictionary:
    var hp: Array[int] = []
    var yun: Array[int] = []
    var shields: Array[int] = []
    for p in players:
        hp.append(p.hp)
        yun.append(p.yun)
        shields.append(p.shields)
    return {"hp": hp, "yun": yun, "shields": shields}
