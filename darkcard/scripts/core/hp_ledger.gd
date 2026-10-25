class_name HpLedger
extends RefCounted

# 血量事务：同死"伤害作废"只回滚血量，其余账目（运/费用/连招/冷却）照常（C29）

var _state: DuelState
var _snap: Array[int] = []


func _init(state: DuelState) -> void:
    _state = state
    _snap.append(0)
    _snap.append(0)


func begin() -> void:
    _snap[0] = _state.players[0].hp
    _snap[1] = _state.players[1].hp


func apply(player: int, delta: int) -> void:
    var p := _state.players[player]
    p.hp += delta
    if p.hp > p.hp_max_ever:
        p.hp_max_ever = p.hp


func rollback_hp_only() -> void:
    _state.players[0].hp = _snap[0]
    _state.players[1].hp = _snap[1]
