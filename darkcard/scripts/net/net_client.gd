class_name NetClient
extends Node

# 联机客户端 —— 接口壳（**待接入**）
#
# 这里只剩「接口」：信号、字段、方法签名。原来那套实现（HTTPRequest 长轮询、
# 指令队列、断线重连、版本握手、凭据存档）已经整段移除，由对接方重写。
#
# 为什么清空（给对接方看的背景）：
#   旧链路是明文 http + token 明文存在 user://net_profile.cfg + 服务端默认
#   --host 0.0.0.0，只凭一个 token 认人。同一局域网内抓包即可冒充玩家，
#   房主那台服务器也能看到所有人的 token 与出牌。隐私与安全需要统一设计，
#   所以不在这份旧实现上打补丁，直接交出去重写。
#
# ---------------------------------------------------------------- 对接契约
#
# 1) 登录：成功后发 command_result("register" 或 "login", {ok=true,...})，
#    并把 token / player_id / player_name 三个字段填好 —— 大厅、对战、
#    匹配（net_match.gd / match_controller.gd）都读这三个字段。
#
# 2) 事件：服务器推来的一切都走 event_received(evt)，evt.type 的取值见
#    server/server.py 顶部的协议表（room_joined / game_start / room_state /
#    turn / state / game_over / invite / friend_add / player_join / player_left /
#    host_changed / match_expired / match_cancelled ...）。
#
# 3) 大厅要用到的指令：matchmake / cancel_match / match_status / list_players /
#    list_rooms / create_room / join_room / leave_room / start_room /
#    remove_member / add_friend / remove_friend / list_friends / invite_friend /
#    set_presence，以及 api("online"|"friends"|"profile")。
#    回执统一走 command_result(cmd, res)，cmd 名与指令名一致。
#
# 4) 对战要用到的：play_card(room_id, card_id)，以及上面的 turn / state / game_over。
#
# 5) 连不上、被踢、协议或规则版本不一致，都要发对应信号，不要静默失败 ——
#    大厅的状态条和版本提示全靠这些信号。
#
# 6) 填完之后把下面的 TRANSPORT_READY 改成 true。端到端联机测试
#    （tools/test_online.gd）看这个开关决定「真跑」还是「明确跳过」。
#
# 协议与服务器的现成参考：server/server.py（Python 侧仍在仓库里，没有删）。

signal connected_ok
signal disconnected(reason: String)
signal event_received(evt: Dictionary)
signal command_result(cmd: String, res: Dictionary)
signal online_count_changed(count: int)
signal rooms_changed(rooms: Array)
signal version_error(message: String)
signal server_updated(rules_version: String)
signal client_update_available(server_version: String)
signal server_outdated(server_version: String)   # 服务器比客户端旧

## 传输层是否已实现。false 时端到端联机测试会显式跳过，不会假装通过。
const TRANSPORT_READY := false

## 协议版本：与服务器必须一致。改了消息格式就两边一起 +1。
const PROTOCOL_VERSION := 2

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 8737

var host := DEFAULT_HOST
var port := DEFAULT_PORT
var rules_version := ""       # 本地卡表的规则版本，握手时给服务器比对
var local_game_version := ""  # 本地客户端版本，用来判断该提示谁更新
var server_game_version := "" # 服务器报的客户端版本
var token := ""
var player_id := ""
var player_name := ""
var version_mismatch := ""    # 非空表示服务器与本地版本对不上

var _warned: Dictionary = {}


# ---------------------------------------------------------------- 连接与身份

func set_server(h: String, p: int) -> void:
	host = h.strip_edges()
	port = p


func server_url() -> String:
	# 协议由待接入方决定（建议 https）。这里不再替它拼明文地址。
	return ""


func has_identity() -> bool:
	return token != "" and player_id != ""


func clear_identity() -> void:
	token = ""
	player_id = ""


# ---------------------------------------------------------------- 传输（待接入）

func send(cmd: String, extra: Dictionary = {}) -> void:
	_todo("send(%s)" % cmd)


func api(cmd: String, extra: Dictionary = {}) -> void:
	_todo("api(%s)" % cmd)


func start_polling() -> void:
	_todo("start_polling()")


func stop_polling() -> void:
	pass


func shutdown() -> void:
	pass


## 场景切换时被 SceneRouter 调用：长连接要跟着转到新场景。
func on_scene_transferred() -> void:
	pass


func cmd_req_in_tree() -> bool:
	return false


# ---------------------------------------------------------------- 指令（待接入）

func register(name: String) -> void:
	_todo("register()")


func login() -> void:
	_todo("login()")


func rename_player(name: String) -> void:
	_todo("rename_player()")


func create_room(turn_seconds: float = 20.0) -> void:
	_todo("create_room()")


func start_room(room_id: String, turn_seconds: float = -1.0) -> void:
	_todo("start_room()")


func remove_member(room_id: String, target_id: String) -> void:
	_todo("remove_member()")


func match_status() -> void:
	_todo("match_status()")


func list_players() -> void:
	_todo("list_players()")


func set_presence(state: String) -> void:
	_todo("set_presence()")


func join_room(room_id: String) -> void:
	_todo("join_room()")


func list_rooms() -> void:
	_todo("list_rooms()")


func matchmake() -> void:
	_todo("matchmake()")


func cancel_match() -> void:
	_todo("cancel_match()")


func add_friend(name: String) -> void:
	_todo("add_friend()")


func remove_friend(friend_id: String) -> void:
	_todo("remove_friend()")


func list_friends() -> void:
	_todo("list_friends()")


func invite_friend(friend_id: String, room_id: String) -> void:
	_todo("invite_friend()")


func play_card(room_id: String, card: String) -> void:
	_todo("play_card()")


func leave_room() -> void:
	_todo("leave_room()")


# ---------------------------------------------------------------- 版本握手
# 纯逻辑，不碰网络，留着：大厅要靠这些信号决定「该提示谁更新」。
# 接传输的时候，登录回执里拿到 {rules_version, protocol_version, game_version}
# 后直接调 _check_version(res) 即可。

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
		return
	# 规则一致但游戏版本不同：看谁更旧，提示的方向不能反。
	var srv_game := str(res.get("game_version", ""))
	if srv_game != "":
		server_game_version = srv_game
	if srv_game != "" and local_game_version != "" and srv_game != local_game_version:
		if _ver_lt(srv_game, local_game_version):
			# 服务器比客户端旧：不是玩家要更新，是服务器该更新。
			emit_signal("server_outdated", srv_game)
		else:
			emit_signal("client_update_available", srv_game)


## 比两个点分版本号：a 比 b 旧则返回 true。
static func _ver_lt(a: String, b: String) -> bool:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in range(maxi(pa.size(), pb.size())):
		var x := int(pa[i]) if i < pa.size() else 0
		var y := int(pb[i]) if i < pb.size() else 0
		if x != y:
			return x < y
	return false


# ---------------------------------------------------------------- 内部

## 每个入口只警告一次，免得刷屏。
func _todo(what: String) -> void:
	if _warned.has(what):
		return
	_warned[what] = true
	push_warning("NetClient.%s 未实现：联机层待接入，见 scripts/net/net_client.gd" % what)
