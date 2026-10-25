class_name NetMatch
extends RefCounted

# 联机对局会话：把服务器事件翻译成本地 GDScript 内核的重放。
#
# 核心思路（服务器权威 + 客户端本地重放）：
#   服务器发来「甲出了 A、乙出了 B」，客户端用与单机完全相同的
#   turn_resolver 在本地重放这一手，得到的事件流与单机一模一样，
#   UI 的日志 / 动画 / 判定文案完全不用改。
#   服务器同时发一份权威状态快照；本地重放后与之比对，
#   不一致立刻报警（说明两个内核漂移了，必须马上发现）。
#
# 座位映射：服务器用 seat 0/1，本地固定用「自己=0、对手=1」，
# 所以从对手视角收到的事件要把 player 字段对调。

signal turn_resolved(cards: Array, events: Array)
signal state_synced(mismatch: bool, detail: String)
signal game_finished(winner_seat: int, reason: String)
signal opponent_joined(info: Dictionary)
signal opponent_left
signal notice(text: String)

var client: NetClient
var db: CardDB
var duel: Duel
var room_id := ""
var my_seat := 0
var opponent_name := ""
var opponent_id := ""
var finished := false

# 上一次结算的权威快照（服务器视角），用于对账
var _last_auth: Dictionary = {}


func setup(c: NetClient, card_db: CardDB) -> void:
	client = c
	db = card_db
	duel = Duel.new(db)
	room_id = ""
	my_seat = 0
	opponent_name = ""
	opponent_id = ""
	finished = false
	_last_auth = {}


func my_view() -> int:
	# 本地视角：0=自己，1=对手
	return 0


func opponent_view() -> int:
	return 1


## 把服务器视角的玩家号转成本地视角
func _to_local(seat: int) -> int:
	return 0 if seat == my_seat else 1


func handle_event(evt: Dictionary) -> void:
	var t := str(evt.get("type", ""))
	match t:
		"room_joined":
			room_id = str(evt.get("room_id", ""))
			my_seat = int(evt.get("seat", 0))
			var players: Array = evt.get("players", [])
			for p in players:
				if p is Dictionary and str(p.get("id", "")) != client.player_id:
					opponent_id = str(p.get("id", ""))
					opponent_name = str(p.get("name", "对手"))
			duel = Duel.new(db)
		"player_join":
			var p: Dictionary = evt.get("player", {})
			opponent_id = str(p.get("id", ""))
			opponent_name = str(p.get("name", "对手"))
			emit_signal("opponent_joined", p)
		"player_left":
			emit_signal("opponent_left")
		"game_start":
			room_id = str(evt.get("room_id", room_id))
			duel = Duel.new(db)
			finished = false
		"turn_resolve":
			_resolve_turn(evt)
		"game_over":
			var w := int(evt.get("winner_seat", -1))
			finished = true
			emit_signal("game_finished", _to_local(w) if w >= 0 else -1,
				str(evt.get("reason", "")))


func _resolve_turn(evt: Dictionary) -> void:
	var cards: Array = evt.get("cards", [])
	if cards.size() < 2:
		return
	# 服务器视角 → 本地视角（自己是 0）
	var a := str(cards[my_seat])
	var b := str(cards[1 - my_seat])

	# 本地重放：与单机完全相同的结算管线
	var events: Array = []
	if duel.can_play(0, a) and duel.can_play(1, b):
		events = duel.play_turn(a, b)
	else:
		# 理论上不会发生（服务器已经校验过）。真发生了说明状态漂移，
		# 硬着头皮结算，至少让对局能继续下去
		events = duel.play_turn(a, b)

	# 与服务器权威快照对账
	_check_against_authority(evt.get("state", {}))

	emit_signal("turn_resolved", [a, b], events)


func _check_against_authority(auth: Dictionary) -> void:
	if auth.is_empty():
		return
	_last_auth = auth
	var st := duel.state
	# 服务器的 seat 0/1 → 本地 0/1
	var auth_hp: Array = auth.get("hp", [])
	var auth_yun: Array = auth.get("yun", [])
	var auth_sh: Array = auth.get("shields", [])
	if auth_hp.size() < 2 or auth_yun.size() < 2:
		return
	var idx := my_seat
	var oidx := 1 - my_seat
	var my_hp := int(auth_hp[idx])
	var op_hp := int(auth_hp[oidx])
	var my_yun := int(auth_yun[idx])
	var op_yun := int(auth_yun[oidx])
	var my_sh := int(auth_sh[idx])
	var op_sh := int(auth_sh[oidx])

	var mine_ok := (st.players[0].hp == my_hp and st.players[0].yun == my_yun
		and st.players[0].shields == my_sh)
	var op_ok := (st.players[1].hp == op_hp and st.players[1].yun == op_yun
		and st.players[1].shields == op_sh)
	if mine_ok and op_ok:
		emit_signal("state_synced", false, "")
	else:
		var detail := "本地 %d/%d血 %d/%d运 vs 服务器 %d/%d血 %d/%d运" % [
			st.players[0].hp, st.players[1].hp, st.players[0].yun, st.players[1].yun,
			my_hp, op_hp, my_yun, op_yun]
		emit_signal("state_synced", true, detail)


## 提交出牌（服务器校验合法性）
func play(card: String) -> void:
	if room_id == "" or finished:
		return
	client.play_card(room_id, card)
