extends Control

# 联机大厅：连服务器、起昵称、匹配、开房间、好友、邀请好友。
#
# 这是玩家进联机模式看到的第一个画面。所有操作都通过 NetClient 发指令，
# 结果由 command_result / event_received 两个信号回来刷新界面。

var client: NetClient
var db: CardDB

var _status: Label
var _online_label: Label
var _name_edit: LineEdit
var _host_edit: LineEdit
var _port_edit: LineEdit
var _room_code_edit: LineEdit
var _friend_name_edit: LineEdit
var _room_list: VBoxContainer
var _friend_list: VBoxContainer
var _status_box: VBoxContainer
var _match_btn: Button
var _create_btn: Button
var _join_btn: Button
var _invite_btn: Button
var _room_id := ""
var _queued := false
var _host_id := ""          # 当前房间的房主
var _turn_seconds := 20.0   # 当前房间的出牌时间
var _my_mmr := 0            # 我的评分
var _turn_opt: OptionButton # 出牌时间选择
var _match_info: Label      # 匹配中的等待信息
var _room_panel: VBoxContainer   # 房间信息面板（进房间才显示）
var _room_info: Label
var _room_members: VBoxContainer   # 房间成员（房主能移除）
var _room_members_data: Array = []   # 当前房间的成员
var _start_btn: Button      # 房主的「开始」
var _leave_btn: Button      # 离开房间
var _players_list: VBoxContainer   # 在线玩家（带状态）
var _refresh_timer := 0.0
var _pending_friend_invite := ""
var _disabled := false


func _ready() -> void:
	db = CardDB.load_all()
	client = NetClient.new()
	add_child(client)
	# 把本地卡表的规则版本告诉客户端，握手时跟服务器比对
	client.rules_version = db.rules_version
	# 本地客户端版本：跟服务器返回的比对，提示玩家该更新客户端了
	client.local_game_version = str(ProjectSettings.get_setting(
		"application/config/version", ""))
	client.command_result.connect(_on_cmd_result)
	client.version_error.connect(_on_version_error)
	client.server_updated.connect(_on_server_updated)
	client.client_update_available.connect(_on_client_update_available)
	client.event_received.connect(_on_event)
	client.online_count_changed.connect(_on_online_count)
	client.disconnected.connect(func(r: String) -> void: _set_status("连接断开：" + r, UiPalette.RED))
	_build_ui()
	# HTTPRequest 要节点在场景树里，重连必须等 UI 建完再发
	_refresh_status.call_deferred()


func _build_ui() -> void:
	var bg := TextureRect.new()
	bg.texture = UiPalette.gradient(UiPalette.BG_TOP, UiPalette.BG_BOTTOM)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	margin.add_child(col)

	# —— 顶栏：标题 + 在线人数 + 状态 ——
	var top := HBoxContainer.new()
	col.add_child(top)
	var title := _lab("暗牌 · 联机大厅", 18, UiPalette.GOLD)
	top.add_child(title)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(sp)
	_online_label = _lab("在线 0", 12, UiPalette.TEAL)
	top.add_child(_online_label)
	var home := _btn("主菜单", _on_go_home)
	home.custom_minimum_size = Vector2(56, 28)
	top.add_child(home)

	_status = _lab("未连接", 11, UiPalette.DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_status)

	# —— 服务器设置 ——
	col.add_child(_panel("服务器", _build_server()))

	# —— 匹配 / 房间 ——
	col.add_child(_panel("对战", _build_match()))

	# —— 房间列表 ——
	col.add_child(_panel("房间列表", _build_rooms()))

	# —— 在线玩家（带状态：空闲 / 匹配中 / 房间中 / 对战中 / 人机对战）——
	_players_list = VBoxContainer.new()
	_players_list.add_theme_constant_override("separation", 4)
	col.add_child(_panel("在线玩家", _players_list))

	# —— 好友 ——
	col.add_child(_panel("好友", _build_friends()))

	# —— 状态条 ——
	_status_box = VBoxContainer.new()
	col.add_child(_status_box)


func _panel(title: String, content: Control) -> Control:
	var pc := PanelContainer.new()
	var sb := UiPalette.panel_box(UiPalette.PANEL_SOFT, 14, UiPalette.LINE)
	sb.set_content_margin_all(10)
	pc.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	pc.add_child(v)
	v.add_child(_lab(title, 12, UiPalette.GOLD))
	v.add_child(content)
	return pc


func _build_server() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)

	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 6)
	v.add_child(row1)
	row1.add_child(_lab("昵称", 11, UiPalette.DIM))
	_name_edit = LineEdit.new()
	_name_edit.text = client.player_name
	_name_edit.placeholder_text = "给自己起个名字"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.custom_minimum_size.y = 30
	_name_edit.text_changed.connect(func(t: String) -> void: client.player_name = t)
	row1.add_child(_name_edit)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	v.add_child(row2)
	row2.add_child(_lab("地址", 11, UiPalette.DIM))
	_host_edit = LineEdit.new()
	_host_edit.text = client.host
	_host_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host_edit.custom_minimum_size.y = 30
	row2.add_child(_host_edit)
	_port_edit = LineEdit.new()
	_port_edit.text = str(client.port)
	_port_edit.custom_minimum_size = Vector2(70, 30)
	row2.add_child(_port_edit)

	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", 8)
	v.add_child(row3)
	var conn := _btn("连接服务器", _on_connect)
	conn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row3.add_child(conn)
	var re := _btn("重连", _on_reconnect)
	re.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row3.add_child(re)
	return v


func _build_match() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)

	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 8)
	v.add_child(row1)
	_match_btn = _btn("快速匹配", _on_matchmake)
	_match_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_child(_match_btn)
	_create_btn = _btn("创建房间", _on_create_room)
	_create_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_child(_create_btn)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	v.add_child(row2)
	row2.add_child(_lab("房号", 11, UiPalette.DIM))
	_room_code_edit = LineEdit.new()
	_room_code_edit.placeholder_text = "6 位房号"
	_room_code_edit.max_length = 6
	_room_code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_code_edit.custom_minimum_size.y = 30
	row2.add_child(_room_code_edit)
	_join_btn = _btn("加入", _on_join_room)
	row2.add_child(_join_btn)

	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", 6)
	v.add_child(row3)
	_invite_btn = _btn("邀请好友进本房间", _on_invite)
	_invite_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row3.add_child(_invite_btn)

	# 出牌时间：自建房由房主定，匹配固定 10 秒
	var row4 := HBoxContainer.new()
	row4.add_theme_constant_override("separation", 6)
	v.add_child(row4)
	row4.add_child(_lab("出牌时间", 11, UiPalette.DIM))
	_turn_opt = OptionButton.new()
	for sec in [5, 10, 15, 20, 30, 60]:
		_turn_opt.add_item("%d 秒" % sec, sec)
	_turn_opt.select(3)   # 默认 20 秒
	_turn_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_turn_opt.item_selected.connect(_on_turn_seconds_changed)
	row4.add_child(_turn_opt)

	# 匹配中的等待信息
	_match_info = _lab("", 11, UiPalette.GOLD)
	_match_info.visible = false
	v.add_child(_match_info)

	# 房间信息面板（进了房间才显示）
	_room_panel = VBoxContainer.new()
	_room_panel.add_theme_constant_override("separation", 6)
	_room_panel.visible = false
	v.add_child(_room_panel)
	_room_info = _lab("", 11, UiPalette.TEXT)
	_room_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_room_panel.add_child(_room_info)
	_room_members = VBoxContainer.new()
	_room_members.add_theme_constant_override("separation", 3)
	_room_panel.add_child(_room_members)
	var row5 := HBoxContainer.new()
	row5.add_theme_constant_override("separation", 6)
	_room_panel.add_child(row5)
	_start_btn = _btn("开始这一局", _on_start_room)
	_start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row5.add_child(_start_btn)
	_leave_btn = _btn("离开房间", _on_leave_room)
	row5.add_child(_leave_btn)
	return v


func _build_rooms() -> Control:
	_room_list = VBoxContainer.new()
	_room_list.add_theme_constant_override("separation", 4)
	_refresh_rooms([])
	return _room_list


func _build_friends() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	v.add_child(row)
	row.add_child(_lab("名字", 11, UiPalette.DIM))
	_friend_name_edit = LineEdit.new()
	_friend_name_edit.placeholder_text = "对方昵称"
	_friend_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_friend_name_edit.custom_minimum_size.y = 30
	row.add_child(_friend_name_edit)
	var add := _btn("加好友", _on_add_friend)
	row.add_child(add)

	_friend_list = VBoxContainer.new()
	_friend_list.add_theme_constant_override("separation", 4)
	v.add_child(_friend_list)
	return v


# ---------------------------------------------------------------- 操作

func _on_connect() -> void:
	if _disabled:
		_set_status("上次连接发现版本不一致，请先让服务器更新", UiPalette.RED)
		return
	client.set_server(_host_edit.text, int(_port_edit.text))
	var nm := _name_edit.text.strip_edges()
	if nm == "":
		nm = "玩家" + str(randi() % 900 + 100)
		_name_edit.text = nm
	client.player_name = nm
	if client.has_identity():
		client.login()
	else:
		client.register(nm)


func _on_reconnect() -> void:
	client.set_server(_host_edit.text, int(_port_edit.text))
	if client.has_identity():
		client.login()
	else:
		_on_connect()


func _on_matchmake() -> void:
	if _queued:
		client.cancel_match()
		_queued = false
		_match_btn.text = "快速匹配"
		return
	client.matchmake()
	_queued = true
	_match_btn.text = "取消匹配"


func _on_create_room() -> void:
	_turn_seconds = float(_turn_opt.get_item_id(_turn_opt.get_selected_id()))
	client.create_room(_turn_seconds)


func _on_join_room() -> void:
	var code := _room_code_edit.text.strip_edges().to_upper()
	if code.length() != 6:
		_set_status("房号是 6 位", UiPalette.RED)
		return
	client.join_room(code)


func _on_turn_seconds_changed(_idx: int) -> void:
	# 房主改出牌时间：先记下来，点了「开始」才生效
	_turn_seconds = float(_turn_opt.get_item_id(_turn_opt.get_selected_id()))


func _on_start_room() -> void:
	if _room_id == "":
		_set_status("还没进房间", UiPalette.RED)
		return
	client.start_room(_room_id, _turn_seconds)
	_set_status("已开始", UiPalette.TEAL)


func _on_leave_room() -> void:
	client.leave_room()
	_room_id = ""
	_host_id = ""
	_room_panel.visible = false
	_set_status("已离开房间", UiPalette.DIM)


func _on_add_friend() -> void:
	var nm := _friend_name_edit.text.strip_edges()
	if nm == "":
		return
	client.add_friend(nm)


func _on_invite() -> void:
	# 邀请：把当前选中的好友拉进当前房间
	if _room_id == "":
		_set_status("先创建或加入一个房间", UiPalette.RED)
		return
	if _pending_friend_invite == "":
		_set_status("先在好友列表里点一个「邀请」", UiPalette.RED)
		return
	client.invite_friend(_pending_friend_invite, _room_id)
	_set_status("已发出邀请", UiPalette.TEAL)


# ---------------------------------------------------------------- 回调

func _on_cmd_result(cmd: String, res: Dictionary) -> void:
	var ok := bool(res.get("ok", false))
	if not ok:
		_set_status(str(res.get("error", "操作失败")), UiPalette.RED)
		return
	match cmd:
		"register", "login":
			_set_status("已连接 · 你是 " + client.player_name, UiPalette.TEAL)
			client.start_polling()
			client.api("online", {})
			client.api("friends", {})
		"create_room":
			_room_id = str(res.get("room_id", ""))
			_host_id = client.player_id
			_turn_seconds = float(res.get("turn_seconds", _turn_seconds))
			_show_room()
			_set_status("房间已创建，房号 " + _room_id, UiPalette.GOLD)
		"join_room":
			_room_id = str(res.get("room_id", ""))
			_show_room()
			_set_status("已加入房间 " + _room_id, UiPalette.GOLD)
		"start_room":
			_set_status("已开始这一局", UiPalette.TEAL)
		"matchmake":
			if bool(res.get("queued", false)):
				_set_status("排队中…", UiPalette.GOLD)
				_match_info.visible = true
				_update_match_info(res.get("status", {}))
			else:
				_match_info.visible = false
				_set_status("匹配成功", UiPalette.TEAL)
		"cancel_match":
			_match_info.visible = false
			_set_status("已取消匹配", UiPalette.DIM)
		"match_status":
			if bool(res.get("queued", false)):
				_update_match_info(res)
			else:
				_match_info.visible = false
		"list_players":
			_refresh_players(res.get("players", []))
		"profile":
			_my_mmr = int(res.get("mmr", 0))
		"add_friend":
			_friend_name_edit.text = ""
			client.api("friends", {})
			_set_status("已加好友", UiPalette.TEAL)
		"friends":
			_refresh_friends(res.get("friends", []))
		"list_rooms", "online":
			_refresh_rooms(res.get("rooms", []))
			var c := int(res.get("online_count", 0))
			_online_label.text = "在线 %d" % c


func _on_event(evt: Dictionary) -> void:
	match str(evt.get("type", "")):
		"room_joined":
			_room_id = str(evt.get("room_id", ""))
			_host_id = str(evt.get("host_id", ""))
			_room_members_data = evt.get("players", [])
			_show_room()
			_set_status("已进入房间 " + _room_id, UiPalette.GOLD)
		"game_start":
			_enter_battle()
		"invite":
			var from := str(evt.get("from_name", "好友"))
			var rid := str(evt.get("room_id", ""))
			_set_status("%s 邀请你进房间 %s" % [from, rid], UiPalette.GOLD)
			_pending_friend_invite = ""
			# 直接接受邀请：加入对方的房间
			client.join_room(rid)
		"friend_add":
			_set_status("%s 加你为好友" % str(evt.get("friend", "")), UiPalette.TEAL)
			client.api("friends", {})
		"player_join":
			_set_status("%s 进了房间" % str(evt.get("player", {}).get("name", "")), UiPalette.GOLD)
		"player_left":
			_set_status("对手离开了", UiPalette.RED)
		"room_state":
			_host_id = str(evt.get("host_id", ""))
			_room_members_data = evt.get("players", [])
			_show_room()
		"host_changed":
			_host_id = str(evt.get("host_id", ""))
			_show_room()
			_set_status("%s 成了新房主" % str(evt.get("host_name", "")), UiPalette.GOLD)
		"match_expired":
			_match_info.visible = false
			_queued = false
			_match_btn.text = "快速匹配"
			_set_status(str(evt.get("message", "没找到对手")), UiPalette.RED)
		"match_cancelled":
			_match_info.visible = false


## 显示当前房间信息（房号、成员、房主、出牌时间）
func _show_room() -> void:
	if _room_id == "":
		_room_panel.visible = false
		return
	_room_panel.visible = true
	var is_host := _host_id == client.player_id or _host_id == ""
	_room_info.text = "房间 %s · 出牌 %d 秒\n%s" % [
		_room_id, int(_turn_seconds),
		"你是房主，可以点「开始这一局」" if is_host else "等房主开始这一局",
	]
	_start_btn.visible = is_host
	_turn_opt.disabled = not is_host
	_refresh_room_members(is_host)


## 房间成员列表。房主可以移除不活跃的成员（PlayFab 的大厅做法）。
func _refresh_room_members(is_host: bool) -> void:
	for c in _room_members.get_children():
		_room_members.remove_child(c)
		c.queue_free()
	for m in _room_members_data:
		if not (m is Dictionary):
			continue
		var mid := str(m.get("id", ""))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_room_members.add_child(row)
		var nm := str(m.get("name", "?"))
		if mid == client.player_id:
			nm += "（你）"
		var l := _lab(nm, 11, UiPalette.TEXT)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		if is_host and mid != client.player_id:
			var rm := _btn("移除", func() -> void:
				client.remove_member(_room_id, mid)
				_set_status("已把 " + str(m.get("name", "")) + " 请出房间", UiPalette.GOLD))
			rm.custom_minimum_size = Vector2(52, 24)
			row.add_child(rm)


func _update_match_info(status: Dictionary) -> void:
	if status.is_empty():
		return
	_match_info.visible = true
	_match_info.text = "匹配中 · 已等待 %.0f 秒 · 评分 %d · 当前范围 ±%d" % [
		float(status.get("waited", 0.0)),
		int(status.get("mmr", _my_mmr)),
		int(status.get("window", 0.0)),
	]


func _refresh_players(players: Array) -> void:
	for c in _players_list.get_children():
		_players_list.remove_child(c)
		c.queue_free()
	if players.is_empty():
		_players_list.add_child(_lab("（还没有别人在线）", 11, UiPalette.DIM))
		return
	for p in players:
		if not (p is Dictionary):
			continue
		var st := str(p.get("state", "idle"))
		var color := UiPalette.DIM
		match st:
			"idle":
				color = UiPalette.TEAL
			"matchmaking":
				color = UiPalette.GOLD
			"in_lobby":
				color = UiPalette.TEXT
			"in_game", "in_game_ai":
				color = UiPalette.RED
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_players_list.add_child(row)
		var l := _lab("%s %s" % [str(p.get("name", "?")), str(p.get("label", ""))],
			11, color)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		# 在房间里的人可以点「加入」直接进他的房间
		var rid := str(p.get("room_id", ""))
		if rid != "" and st == "in_lobby":
			var join := _btn("加入", func() -> void:
				client.join_room(rid)
				_set_status("正在加入房间 " + rid, UiPalette.GOLD))
			join.custom_minimum_size = Vector2(52, 24)
			row.add_child(join)


func _process(delta: float) -> void:
	# 定时刷新：匹配状态、在线玩家、好友在线状态
	_refresh_timer += delta
	if _refresh_timer < 1.0:
		return
	_refresh_timer = 0.0
	if not client.has_identity():
		return
	if _queued:
		client.match_status()
	if int(_refresh_timer * 10) % 30 == 0:
		client.list_players()
		client.list_friends()


func _on_version_error(message: String) -> void:
	# 服务器上的卡表/协议跟本地对不上：这局打了也是错的，明确挡住
	_set_status(message, UiPalette.RED)
	_disabled = true
	for b in _lock_buttons():
		b.disabled = true


func _on_client_update_available(server_version: String) -> void:
	# 服务器端已经是新版本了（服务器会自动更新），
	# 但客户端这份 APK/EXE 还旧着——得重新发一次包。
	_set_status("服务器已更新到 v%s，你的客户端版本较旧，建议更新后再来" % server_version,
		UiPalette.GOLD)


func _on_server_updated(new_rules: String) -> void:
	# 服务器换规则了（热重载，不用重启）。提示一下，正在打的局会按旧规则打完。
	_set_status("服务器已更新到规则 %s，当前这局仍按旧规则打完" % new_rules, UiPalette.GOLD)


func _lock_buttons() -> Array:
	var out: Array = []
	for b in [_match_btn, _create_btn, _join_btn, _invite_btn]:
		if b != null:
			out.append(b)
	return out


func _on_online_count(c: int) -> void:
	_online_label.text = "在线 %d" % c


# ---------------------------------------------------------------- 刷新

func _refresh_status() -> void:
	_online_label.text = "在线 ?"
	if client.has_identity():
		_set_status("已有存档，正在重连…", UiPalette.DIM)
		_on_reconnect()
	else:
		_set_status("填好昵称和地址，点「连接服务器」", UiPalette.DIM)


func _refresh_rooms(rooms: Array) -> void:
	for c in _room_list.get_children():
		_room_list.remove_child(c)
		c.queue_free()
	if rooms.is_empty():
		_room_list.add_child(_lab("（暂无公开房间）", 11, UiPalette.DIM))
		return
	for r in rooms:
		if not (r is Dictionary):
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var code := str(r.get("room_id", ""))
		var names: Array = r.get("players", [])
		var label := "%s   房主 %s" % [code, str(r.get("owner", "?"))]
		if not names.is_empty():
			label += "   %s" % ", ".join(PackedStringArray(names))
		var l := _lab(label, 11, UiPalette.TEXT)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var j := _btn("加入", func() -> void: client.join_room(code))
		j.custom_minimum_size = Vector2(56, 26)
		row.add_child(j)
		_room_list.add_child(row)


func _refresh_friends(friends: Array) -> void:
	for c in _friend_list.get_children():
		_friend_list.remove_child(c)
		c.queue_free()
	if friends.is_empty():
		_friend_list.add_child(_lab("（还没有好友）", 11, UiPalette.DIM))
		return
	for f in friends:
		if not (f is Dictionary):
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var on := bool(f.get("online", false))
		var st := str(f.get("state", "idle"))
		var dot := "●" if on else "○"
		var color := UiPalette.TEAL if on else UiPalette.DIM
		var tail := " · " + str(f.get("label", "")) if on else ""
		var l := _lab("%s %s%s" % [dot, str(f.get("name", "?")), tail], 11, color)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var fid := str(f.get("id", ""))
		var inv := _btn("邀请", func() -> void:
			_pending_friend_invite = fid
			_set_status("已选中 " + str(f.get("name", "")) + "，点上面「邀请好友进本房间」", UiPalette.GOLD))
		inv.custom_minimum_size = Vector2(56, 26)
		row.add_child(inv)
		_friend_list.add_child(row)


func _set_status(text: String, color: Color) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", color)


# ---------------------------------------------------------------- 进入对战

## 回主菜单。留在房间里的要先退出，否则服务器那边房间还挂着人。
func _on_go_home() -> void:
	if client != null and _room_id != "":
		client.leave_room()
	var main: Control = load("res://scenes/main/Main.tscn").instantiate()
	SceneRouter.swap(get_tree(), main)


func _enter_battle() -> void:
	if client == null or not client.has_identity():
		return
	var ctrl := MatchController.new()
	ctrl.setup_online(db, client)
	var battle: Control = load("res://scenes/Battle.tscn").instantiate()
	# 长连接客户端一起转到对战场景：大厅被释放时不能把连接一起带走，
	# 否则进了对战界面就是「连着但收不到任何消息」。
	SceneRouter.swap(get_tree(), battle, [client])
	battle.call("setup_online", ctrl)


# ---------------------------------------------------------------- 小工具

func _lab(t: String, size: int, c: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", c)
	return l


func _btn(t: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size.y = 30
	b.add_theme_font_size_override("font_size", 12)
	b.pressed.connect(cb)
	return b
