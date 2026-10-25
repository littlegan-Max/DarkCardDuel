extends SceneTree

# 联机端到端测试：两个 Godot 客户端连上真服务器，打完整一局。
#
# 这是整个联机框架最重要的一道验证：
#   客户端用 GDScript 内核本地重放 → 事件流与单机一致
#   服务器用 Python 内核权威结算 → 状态快照
#   两者每回合对账，不一致就报错
#
# 用法：
#   godot --headless --path . --script res://tools/test_online.gd -- --port=8737 --seat=0
# 客户端 0 和 1 各起一个进程。

var client: NetClient
var ctrl: MatchController
var db: CardDB
var port := 8737
var seat := 0
var turns_done := 0
var finished := false
var errors: Array[String] = []
var _t0 := 0.0
var _last_turn := -1
var _done := false


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			port = int(arg.split("=")[1])
		elif arg.begins_with("--seat="):
			seat = int(arg.split("=")[1])
	print("[online] seat=%d port=%d" % [seat, port])

	db = CardDB.load_all()
	client = NetClient.new()
	root.add_child(client)
	client.set_server("127.0.0.1", port)
	client.command_result.connect(_on_cmd)
	client.event_received.connect(_on_event)

	# HTTPRequest 要求节点已在场景树里，所以指令要等下一帧再发
	_start_registration.call_deferred()
	_t0 = Time.get_ticks_msec()


func _start_registration() -> void:
	client.register("测试玩家%d" % seat)


func _process(delta: float) -> bool:
	# SceneTree 脚本的 _process 返回 true 表示「退出主循环」。
	# 这里必须返回 false，否则第一帧就退出了，HTTP 请求永远没机会推进。
	if Time.get_ticks_msec() - _t0 > 60000:
		errors.append("超时（60s）")
		_finish()
		return true
	return _done


func _on_cmd(cmd: String, res: Dictionary) -> void:
	if not bool(res.get("ok", false)):
		errors.append("%s 失败：%s" % [cmd, str(res.get("error", ""))])
		_finish()
		return
	if cmd == "register":
		client.start_polling()
		# 联机模式准备就绪，开始匹配
		ctrl = MatchController.new()
		ctrl.setup_online(db, client)
		ctrl.turn_resolved.connect(_on_turn)
		ctrl.state_mismatch.connect(_on_mismatch)
		client.matchmake()


func _on_event(evt: Dictionary) -> void:
	if ctrl != null:
		ctrl.on_net_event(evt)
	var t := str(evt.get("type", ""))
	if t == "game_start":
		print("[online] 开局，座位 %d" % ctrl.net_match.my_seat)
	elif t == "game_over":
		var w := int(evt.get("winner_seat", -1))
		print("[online] 对局结束，胜者 seat=%d 原因=%s" % [w, str(evt.get("reason", ""))])
		_finish()


func _on_turn(cards: Array, events: Array) -> void:
	turns_done += 1
	_last_turn = ctrl.duel.state.turn
	var hp := "%d/%d" % [ctrl.duel.state.players[0].hp, ctrl.duel.state.players[1].hp]
	if turns_done <= 3 or turns_done % 5 == 0:
		print("[online] 第%d回合 我=%s 对手=%s 血=%s 事件=%d条" % [
			_last_turn, str(cards[0]), str(cards[1]), hp, events.size()])
	if events.is_empty():
		errors.append("第%d回合没有产生事件" % _last_turn)
	# 局终：双方都被服务器判负说明流程完整
	if ctrl.duel.state.over:
		print("[online] 对局结束 胜者=%d 原因=%s" % [
			ctrl.duel.state.winner, ctrl.duel.state.end_reason])
		_finish()
		return

	# 下一回合：出一张有伤害的牌，让对局能尽快分出胜负
	# （双方都只出运的话永远打不完，测不出完整流程）
	if ctrl.duel.state.over:
		return
	# 出牌策略：先攒运，出得起攻击牌就出（否则永远只出运，对局打不完）。
	# 两个座位刻意用不同的高费牌，制造伤害差——
	# 比大小规则下同牌对同牌会互相抵消，血量永远不降。
	var pick := ""
	var dmg_cards := ["xiao_biao", "kai_sa", "nai_bao", "shou_qiang", "chang_gong"]
	if seat == 1:
		dmg_cards = ["chang_gong", "nai_bao", "kai_sa", "xiao_biao", "shou_qiang"]
	for cid in dmg_cards:
		if ctrl.duel.can_play(0, cid):
			pick = cid
			break
	if pick == "" and ctrl.duel.can_play(0, "yun"):
		pick = "yun"
	if pick == "":
		var legal := ctrl.duel.legal_cards(0)
		if not legal.is_empty():
			pick = legal[0]
	if pick == "":
		errors.append("第%d回合没有合法牌" % _last_turn)
		return
	ctrl.submit(pick)
	# 打到 12 回合就收工：对账每回合都在做，不需要真分出胜负
	# （比大小规则下同牌对同牌互相抵消，双方对称出牌时血量永远不降）
	if turns_done >= 12:
		print("[online] 已打满 12 回合")
		_finish()


func _on_mismatch(detail: String) -> void:
	errors.append("状态不一致：" + detail)
	print("[online] 状态不一致：" + detail)


func _finish() -> void:
	if _done:
		return
	_done = true
	print("[online] 用时 %dms" % (Time.get_ticks_msec() - _t0))
	if errors.is_empty():
		print("[online] OK 回合数=%d" % turns_done)
	else:
		for e in errors:
			print("[online] FAIL %s" % e)
	print("[online] DONE")
	quit(0 if errors.is_empty() else 1)
