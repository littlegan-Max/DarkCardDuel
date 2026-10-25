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
var _refresh_timer := 0.0
var _pending_friend_invite := ""
var _disabled := false


func _ready() -> void:
	db = CardDB.load_all()
	client = NetClient.new()
	add_child(client)
	# 把本地卡表的规则版本告诉客户端，握手时跟服务器比对
	client.rules_version = db.rules_version
	client.command_result.connect(_on_cmd_result)
	client.version_error.connect(_on_version_error)
	client.server_updated.connect(_on_server_updated)
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

	_status = _lab("未连接", 11, UiPalette.DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_status)

	# —— 服务器设置 ——
	col.add_child(_panel("服务器", _build_server()))

	# —— 匹配 / 房间 ——
	col.add_child(_panel("对战", _build_match()))

	# —— 房间列表 ——
	col.add_child(_panel("房间列表", _build_rooms()))

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
	client.create_room()


func _on_join_room() -> void:
	var code := _room_code_edit.text.strip_edges().to_upper()
	if code.length() != 6:
		_set_status("房号是 6 位", UiPalette.RED)
		return
	client.join_room(code)


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
			_set_status("房间已创建，房号 " + _room_id, UiPalette.GOLD)
		"join_room":
			_room_id = str(res.get("room_id", ""))
			_set_status("已加入房间 " + _room_id, UiPalette.GOLD)
		"matchmake":
			if bool(res.get("queued", false)):
				_set_status("排队中…", UiPalette.GOLD)
			else:
				_set_status("匹配成功", UiPalette.TEAL)
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
			_set_status("已进入房间 " + _room_id, UiPalette.GOLD)
			_enter_battle()
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


func _on_version_error(message: String) -> void:
	# 服务器上的卡表/协议跟本地对不上：这局打了也是错的，明确挡住
	_set_status(message, UiPalette.RED)
	_disabled = true
	for b in _lock_buttons():
		b.disabled = true


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
		var dot := "●" if on else "○"
		var color := UiPalette.TEAL if on else UiPalette.DIM
		var l := _lab("%s %s" % [dot, str(f.get("name", "?"))], 11, color)
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

func _enter_battle() -> void:
	if client == null or not client.has_identity():
		return
	var ctrl := MatchController.new()
	ctrl.setup_online(db, client)
	var battle: Control = load("res://scenes/Battle.tscn").instantiate()
	add_child(battle)
	battle.call("setup_online", ctrl)
	get_tree().current_scene = battle
	queue_free()


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
