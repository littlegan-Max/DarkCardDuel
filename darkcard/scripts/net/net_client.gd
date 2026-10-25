class_name NetClient
extends Node

# 联机客户端：与服务器的 HTTP 通道。
#
# 架构：服务器权威 + 客户端本地重放。
#   服务器只发「双方各出了什么牌」和权威状态快照；
#   客户端用与单机完全相同的 GDScript 内核重放，产出事件流驱动 UI。
#   这样事件流与单机 100% 一致，不必跨语言对齐事件格式。
#
# 并发模型：两条独立的 HTTP 通道
#   _poll_req  —— 长轮询（服务器 hold 住连接，有事件才返回）
#   _cmd_req   —— 指令通道（注册/出牌/加好友…）
# 两者都用 HTTPRequest，各占一个连接。

signal connected_ok
signal disconnected(reason: String)
signal event_received(evt: Dictionary)
signal command_result(cmd: String, res: Dictionary)
signal online_count_changed(count: int)
signal rooms_changed(rooms: Array)
signal version_error(message: String)

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 8737

# 协议版本：与服务器必须一致。改了消息格式就两边一起 +1。
const PROTOCOL_VERSION := 1

var host := DEFAULT_HOST
var port := DEFAULT_PORT
var rules_version := ""      # 本地卡表的规则版本
var token := ""
var player_id := ""
var player_name := ""

var _poll_req: HTTPRequest
var _cmd_req: HTTPRequest
var _seq := 0
var _polling := false
var _stopped := false
var _online_count := 0
var _rooms: Array = []
var _cfg_path := "user://net_profile.cfg"
var _pending_cmd := ""
var _cmd_queue: Array = []
var _cmd_inflight := false
var _host_locked := false   # 调用方显式设过地址后，存档不再覆盖
var version_mismatch := ""   # 非空表示服务器与本地版本对不上


func _ready() -> void:
	_ensure_requests()
	_load_profile()


## 显式设置服务器地址并落盘。
## 注意：_ready 里的 _load_profile 会用存档覆盖 host/port，
## 所以调用方必须在 add_child 之后再调一次本方法，
## 或者用 set_server_after_ready() 之外的顺序（见 lobby 的用法）。


## 惰性建好两条 HTTP 通道。
## 不能只依赖 _ready：调用方常常 add_child 之后同一帧就发指令，
## _ready 还没跑到，_cmd_req 会是 null。
## 注意 HTTPRequest.request() 要求节点已在场景树里，
## 所以调用方若在 _initialize() 这类时机 add_child，需要延迟一帧再发指令。
func _ensure_requests() -> void:
	if _poll_req == null:
		_poll_req = HTTPRequest.new()
		_poll_req.timeout = 40.0
		_poll_req.use_threads = true
		add_child(_poll_req)
		_poll_req.request_completed.connect(_on_poll_done)
	if _cmd_req == null:
		_cmd_req = HTTPRequest.new()
		_cmd_req.timeout = 20.0
		_cmd_req.use_threads = true
		add_child(_cmd_req)
		_cmd_req.request_completed.connect(_on_cmd_done)


# ---------------------------------------------------------------- 配置

func set_server(h: String, p: int) -> void:
	host = h.strip_edges()
	port = p
	_host_locked = true
	_save_profile()


func server_url() -> String:
	return "http://%s:%d" % [host, port]


func _load_profile() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_cfg_path) != OK:
		return
	token = str(cfg.get_value("net", "token", ""))
	player_id = str(cfg.get_value("net", "player_id", ""))
	player_name = str(cfg.get_value("net", "name", ""))
	# 地址只在调用方没显式设过时才从存档恢复
	if not _host_locked:
		host = str(cfg.get_value("net", "host", host))
		port = int(cfg.get_value("net", "port", port))


func _save_profile() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("net", "token", token)
	cfg.set_value("net", "player_id", player_id)
	cfg.set_value("net", "name", player_name)
	cfg.set_value("net", "host", host)
	cfg.set_value("net", "port", port)
	cfg.save(_cfg_path)


func has_identity() -> bool:
	return token != "" and player_id != ""


func clear_identity() -> void:
	token = ""
	player_id = ""
	_save_profile()


# ---------------------------------------------------------------- 指令

## 发一条指令。指令走单通道，必须排队：
## 连着发两条（比如 register 紧跟 matchmake）时，
## 第二条会在第一条还在飞的时候被丢掉，响应就错位了。
func send(cmd: String, extra: Dictionary = {}) -> void:
	if _stopped:
		return
	_ensure_requests()
	_cmd_queue.append({"cmd": cmd, "body": extra.duplicate()})
	_pump_cmd_queue()


func cmd_req_in_tree() -> bool:
	_ensure_requests()
	return _cmd_req != null and _cmd_req.is_inside_tree()


func _pump_cmd_queue() -> void:
	if _cmd_inflight:
		return
	if _cmd_queue.is_empty():
		return
	var job: Dictionary = _cmd_queue.pop_front()
	_cmd_inflight = true
	_pending_cmd = str(job["cmd"])
	var body: Dictionary = job["body"]
	body["player_id"] = player_id
	body["token"] = token
	# 带上本地规则版本，服务器会拿它跟自己的卡表比对：
	# 改了规则但服务器没更新时，两边算出来的结果必然对不上，必须挡住
	if rules_version != "":
		body["rules_version"] = rules_version
	var headers := PackedStringArray(["Content-Type: application/json"])
	var err := _cmd_req.request(server_url() + "/api/" + str(job["cmd"]), headers,
		HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_cmd_inflight = false
		_pending_cmd = ""
		emit_signal("command_result", str(job["cmd"]), {"ok": false, "error": "网络错误 %d" % err})
		_pump_cmd_queue()


func _on_cmd_done(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	var cmd := _pending_cmd
	_pending_cmd = ""
	_cmd_inflight = false
	if result != HTTPRequest.RESULT_SUCCESS:
		emit_signal("command_result", cmd, {"ok": false, "error": "连接失败（%d）" % code})
		_pump_cmd_queue()
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary):
		emit_signal("command_result", cmd, {"ok": false, "error": "服务器返回了非法数据"})
		_pump_cmd_queue()
		return
	var res: Dictionary = parsed
	# 版本握手：服务器上的卡表/协议跟本地不一致就别往下走了
	if res.get("ok") and res.has("rules_version"):
		_check_version(res)
	# 注册 / 登录成功后记住身份，下次启动直接续上
	if res.get("ok") and res.has("token"):
		token = str(res["token"])
		player_id = str(res.get("player_id", player_id))
		player_name = str(res.get("name", player_name))
		_save_profile()
	emit_signal("command_result", cmd, res)
	_pump_cmd_queue()


## 校验服务器版本。
## rules_version 不一致 = 改了规则但服务器没更新（两边规则不同，必须挡住）。
## protocol_version 不一致 = 消息格式变了（连不上，必须挡住）。
func _check_version(res: Dictionary) -> void:
	var srv_rules := str(res.get("rules_version", ""))
	var srv_proto := int(res.get("protocol_version", PROTOCOL_VERSION))
	if srv_proto != PROTOCOL_VERSION:
		version_mismatch = "协议版本不匹配（服务器 %d，本地 %d），服务器需要更新" % [
			srv_proto, PROTOCOL_VERSION]
		emit_signal("version_error", version_mismatch)
		return
	if rules_version != "" and srv_rules != "" and srv_rules != rules_version:
		version_mismatch = "规则版本不匹配（服务器 %s，本地 %s），服务器需要更新" % [
			srv_rules, rules_version]
		emit_signal("version_error", version_mismatch)


func api(cmd: String, extra: Dictionary = {}) -> void:
	_ensure_requests()
	send(cmd, extra)


# ---------------------------------------------------------------- 长轮询

func start_polling() -> void:
	_stopped = false
	_polling = false
	_poll_once()


func stop_polling() -> void:
	_stopped = true
	_polling = false


func _poll_once() -> void:
	_ensure_requests()
	if _stopped or _polling:
		return
	if token == "":
		return
	_polling = true
	var body := {"player_id": player_id, "token": token, "seq": _seq}
	var headers := PackedStringArray(["Content-Type: application/json"])
	var err := _poll_req.request(server_url() + "/api/poll", headers, HTTPClient.METHOD_POST,
		JSON.stringify(body))
	if err != OK:
		_polling = false
		# 服务器还没起来，退避重试
		_retry_poll.call_deferred(2.0)


func _retry_poll(delay: float) -> void:
	if _stopped:
		return
	var t := get_tree().create_timer(delay)
	t.timeout.connect(func() -> void: _poll_once())


func _on_poll_done(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_polling = false
	if _stopped:
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		# 服务器挂了或网络断了，退避后重连
		emit_signal("disconnected", "连接断开（%d）" % code)
		_retry_poll.call_deferred(3.0)
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary):
		_retry_poll.call_deferred(1.0)
		return
	var res: Dictionary = parsed
	if not res.get("ok"):
		# token 失效
		emit_signal("disconnected", str(res.get("error", "登录失效")))
		clear_identity()
		return
	_seq = int(res.get("seq", _seq))
	var count := int(res.get("online_count", _online_count))
	if count != _online_count:
		_online_count = count
		emit_signal("online_count_changed", count)
	for e in res.get("events", []):
		if e is Dictionary:
			emit_signal("event_received", e)
	_poll_once()


# ---------------------------------------------------------------- 便捷封装

func register(name: String) -> void:
	player_name = name
	api("register", {"name": name})


func login() -> void:
	api("login", {})


func rename_player(name: String) -> void:
	player_name = name
	api("rename", {"name": name})


func create_room() -> void:
	api("create_room", {})


func join_room(room_id: String) -> void:
	api("join_room", {"room_id": room_id.to_upper()})


func list_rooms() -> void:
	api("list_rooms", {})


func matchmake() -> void:
	api("matchmake", {})


func cancel_match() -> void:
	api("cancel_match", {})


func add_friend(name: String) -> void:
	api("add_friend", {"name": name})


func remove_friend(friend_id: String) -> void:
	api("remove_friend", {"friend_id": friend_id})


func list_friends() -> void:
	api("friends", {})


func invite_friend(friend_id: String, room_id: String) -> void:
	api("invite", {"friend_id": friend_id, "room_id": room_id})


func play_card(room_id: String, card: String) -> void:
	api("play", {"room_id": room_id, "card": card})


func leave_room() -> void:
	api("leave", {})
