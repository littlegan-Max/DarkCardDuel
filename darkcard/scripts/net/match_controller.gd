class_name MatchController
extends RefCounted

# 对局控制器：把「单机 AI 对手」和「联机服务器对手」统一成同一套接口。
#
# 单机：对手的牌由本地 LearnedAI 选，选完立刻本地结算。
# 联机：对手的牌由服务器给，收到 turn_resolve 事件后才本地重放结算。
#
# 上层（battle_screen）只跟这个控制器打交道，
# 不关心对面是 AI 还是真人。

signal turn_resolved(cards: Array, events: Array)   # [我的牌, 对手牌], 事件流
signal opponent_joined(name: String)
signal opponent_left
signal notice(text: String)
signal state_mismatch(detail: String)

const MODE_LOCAL := "local"
const MODE_ONLINE := "online"

var mode := MODE_LOCAL
var db: CardDB
var duel: Duel
var rng := RandomNumberGenerator.new()

# 联机相关
var net: NetClient
var net_match: NetMatch

# 本局状态
var my_card := ""          # 我已提交但还没结算的牌
var submitted := false     # 是否已提交本回合
var finished := false
var opponent_name := "影武者"


func setup_local(card_db: CardDB, seed_value: int) -> void:
	mode = MODE_LOCAL
	db = card_db
	duel = Duel.new(db)
	rng.seed = seed_value
	my_card = ""
	submitted = false
	finished = false
	opponent_name = "影武者"


func setup_online(card_db: CardDB, client: NetClient) -> void:
	mode = MODE_ONLINE
	db = card_db
	net = client
	net_match = NetMatch.new()
	net_match.setup(client, card_db)
	net_match.turn_resolved.connect(_on_net_turn)
	net_match.opponent_joined.connect(func(info: Dictionary) -> void:
		opponent_name = str(info.get("name", "对手"))
		emit_signal("opponent_joined", opponent_name))
	net_match.opponent_left.connect(func() -> void: emit_signal("opponent_left"))
	net_match.notice.connect(func(t: String) -> void: emit_signal("notice", t))
	net_match.state_synced.connect(func(bad: bool, detail: String) -> void:
		if bad:
			emit_signal("state_mismatch", detail))
	duel = net_match.duel
	my_card = ""
	submitted = false
	finished = false
	opponent_name = "对手"


func on_net_event(evt: Dictionary) -> void:
	if net_match != null:
		net_match.handle_event(evt)
		duel = net_match.duel
		opponent_name = net_match.opponent_name


func _on_net_turn(cards: Array, events: Array) -> void:
	submitted = false
	my_card = ""
	finished = net_match.finished
	emit_signal("turn_resolved", cards, events)


## 提交我这回合的牌。
## 单机：立刻与 AI 的牌一起结算。
## 联机：发给服务器，等服务器的 turn_resolve 事件回来。
func submit(card: String, debug_opponent_card: String = "") -> bool:
	if duel == null or finished or submitted:
		return false
	if not duel.can_play(0, card):
		return false

	if mode == MODE_LOCAL:
		var b := ""
		if debug_opponent_card != "":
			b = debug_opponent_card
		else:
			b = LearnedAI.choose(duel, 1, rng)
		if b == "":
			b = "yun"
		# 立刻结算（对局内只有这一条路径）
		var events := duel.play_turn(card, b)
		finished = duel.state.over
		emit_signal("turn_resolved", [card, b], events)
		return true

	# 联机：交给服务器
	my_card = card
	submitted = true
	net_match.play(card)
	return true


## 超时自动出牌（单机本地选；联机交给服务器的看门狗处理）
func auto_pick() -> String:
	if duel == null:
		return ""
	if duel.can_play(0, "yun"):
		return "yun"
	var legal := duel.legal_cards(0)
	if legal.is_empty():
		return ""
	return legal[0]


func can_play(card: String) -> bool:
	if duel == null or finished or submitted:
		return false
	return duel.can_play(0, card)


func legal_cards() -> Array[String]:
	if duel == null:
		return []
	return duel.legal_cards(0)
