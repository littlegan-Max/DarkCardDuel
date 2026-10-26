extends Control

# 联机大厅：连服务器、起昵称、匹配、开房间、好友、邀请好友。
#
# 版面自上而下四段：
#   1. 顶栏：标题 + 在线人数 + 「服务器」（连接设置收进弹层）+ 主菜单
#   2. 身份卡：头像 / 昵称 / 评分 + 本屏唯一的主操作「快速匹配」
#   3. 房间条：进了房间才出现，房号、成员、开始 / 邀请 / 离开都在这
#   4. 页签：房间 / 在线 / 好友 —— 三张列表共用同一块地方，
#      不再把四块面板竖着堆成一条长条
# 底部是一条状态条，所有回执都落在那里。
#
# 所有操作都通过 NetClient 发指令，结果由 command_result / event_received
# 两个信号回来刷新界面。

const TAB_ROOMS := 0
const TAB_PLAYERS := 1
const TAB_FRIENDS := 2
const TAB_NAMES := ["房间", "在线", "好友"]
## 屏幕逻辑宽度超过这个值就切桌面版面
const WIDE_MIN := 900.0

var client: NetClient
var db: CardDB

var _status: Label
var _status_dot: Panel
var _online_label: Label
var _room_code_edit: LineEdit
var _friend_name_edit: LineEdit
var _room_list: Container
var _friend_list: VBoxContainer
var _players_list: VBoxContainer
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
var _room_panel: Control    # 房间条（进房间才显示）
var _room_info: Label
var _room_code_label: Label
var _room_time_label: PanelContainer
var _room_time_text: Label
var _room_members: VBoxContainer   # 房间成员（房主能移除）
var _room_members_data: Array = [] # 当前房间的成员
var _start_btn: Button      # 房主的「开始」
var _leave_btn: Button      # 离开房间
var _hero_name: Label
var _hero_avatar: PanelContainer
var _avatar_letter: Label
var _conn_label: Label
var _conn_dot: Panel
var _rating_label: Label
var _tab_btns: Array = []
var _pages: Array = []
var _tab := TAB_ROOMS
var _refresh_timer := 0.0
var _roster_timer := 0.0    # 名单轮询的独立计时（见 _process）
var _pending_friend_invite := ""
var _disabled := false
var _connected := false   # 真的连上了（有存档 != 连着）
var _ui_root: Control
var _is_wide := false
var _last_rooms: Array = []
var _last_players: Array = []
var _last_friends: Array = []
var _last_status_text := "未连接"
var _last_status_color := UiPalette.DIM


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
	client.server_outdated.connect(_on_server_outdated)
	client.event_received.connect(_on_event)
	client.online_count_changed.connect(_on_online_count)
	client.disconnected.connect(func(r: String) -> void:
		_connected = false
		_sync_identity()
		_set_status("连接断开：" + r, UiPalette.RED))
	_build_ui()
	get_viewport().size_changed.connect(_on_viewport_resized)
	# HTTPRequest 要节点在场景树里，重连必须等 UI 建完再发
	_refresh_status.call_deferred()


# ---------------------------------------------------------------- 搭界面

func _build_ui() -> void:
	_is_wide = get_viewport_rect().size.x >= WIDE_MIN
	if _ui_root != null and is_instance_valid(_ui_root):
		_ui_root.queue_free()

	# 所有 UI 挂在 _ui_root 下：改窗口尺寸跨过断点时整块重建，
	# client 节点是 self 的直接子节点，不会跟着被清掉。
	_ui_root = Control.new()
	_ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui_root.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_ui_root)

	UiKit.backdrop(_ui_root)

	var margin := MarginContainer.new()
	_ui_root.add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var pad := 24 if _is_wide else 18
	var safe := UiKit.safe_insets(self)
	margin.add_theme_constant_override("margin_left", pad + int(safe.x))
	margin.add_theme_constant_override("margin_right", pad + int(safe.z))
	margin.add_theme_constant_override("margin_top", (16 if _is_wide else 14) + int(safe.y))
	margin.add_theme_constant_override("margin_bottom", (16 if _is_wide else 14) + int(safe.w))

	if _is_wide:
		_build_wide(margin)
	else:
		_build_narrow(margin)

	_restore_after_rebuild()


## 桌面版：左边是「我是谁 + 打一局」，右边是列表区。
## 竖列那套在 16:9 上会把每块面板拉成一条横幅，所以宽屏必须换版面。
func _build_wide(margin: MarginContainer) -> void:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 16)
	margin.add_child(outer)

	_build_header(outer)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 20)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(body)

	var rail := VBoxContainer.new()
	rail.add_theme_constant_override("separation", 14)
	rail.custom_minimum_size.x = 392
	body.add_child(rail)
	_build_hero(rail)
	_build_room_banner(rail)
	var filler := Control.new()
	filler.size_flags_vertical = Control.SIZE_EXPAND_FILL
	filler.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rail.add_child(filler)

	var main := VBoxContainer.new()
	main.add_theme_constant_override("separation", 10)
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(main)
	_build_tabs(main)
	_build_body(main)

	_build_statusbar(outer)


## 手机版：原样的一列
func _build_narrow(margin: MarginContainer) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 11)
	margin.add_child(col)

	_build_header(col)
	_build_hero(col)
	_build_room_banner(col)
	_build_tabs(col)
	_build_body(col)
	_build_statusbar(col)


## 重建后把当前状态填回去（页签、列表、状态条）
func _restore_after_rebuild() -> void:
	if _tab != TAB_ROOMS:
		_switch_tab(_tab)
	if _room_id != "":
		_show_room()
	_refresh_rooms(_last_rooms)
	_refresh_players(_last_players)
	_refresh_friends(_last_friends)
	_set_status(_last_status_text, _last_status_color)


func _on_viewport_resized() -> void:
	var wide := get_viewport_rect().size.x >= WIDE_MIN
	if wide != _is_wide:
		_build_ui()


func _build_header(col: Control) -> void:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	col.add_child(top)

	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", 0)
	top.add_child(titles)
	titles.add_child(UiKit.kicker("DARK CARD DUEL", UiPalette.GOLD_DEEP))
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 8)
	titles.add_child(line)
	line.add_child(UiKit.label("联机大厅", 21, UiPalette.GOLD))
	line.add_child(UiKit.chip("v" + str(ProjectSettings.get_setting(
		"application/config/version", "0")), UiPalette.DIM))

	top.add_child(UiKit.spacer())

	var online_chip := PanelContainer.new()
	var ob := StyleBoxFlat.new()
	ob.bg_color = Color(0.25, 0.75, 0.62, 0.10)
	ob.border_color = Color(0.25, 0.75, 0.62, 0.30)
	ob.set_border_width_all(1)
	ob.set_corner_radius_all(9)
	ob.content_margin_left = 9
	ob.content_margin_right = 9
	ob.content_margin_top = 5
	ob.content_margin_bottom = 5
	online_chip.add_theme_stylebox_override("panel", ob)
	online_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var orow := HBoxContainer.new()
	orow.add_theme_constant_override("separation", 5)
	online_chip.add_child(orow)
	orow.add_child(UiKit.dot(UiPalette.TEAL, 6))
	_online_label = UiKit.label("在线 0", 11, UiPalette.TEAL)
	orow.add_child(_online_label)
	top.add_child(online_chip)

	var home := UiKit.ghost("主菜单", 30, 9)
	home.custom_minimum_size.x = 58
	home.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	home.pressed.connect(_on_go_home)
	top.add_child(home)


func _build_hero(col: Control) -> void:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel",
		UiKit.card(Color("#161E30"), 18, Color("#2C3A58")))
	col.add_child(pc)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 11)
	pc.add_child(v)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 11)
	v.add_child(row)

	_hero_avatar = UiKit.avatar("我", UiPalette.TEAL, 46)
	_avatar_letter = _hero_avatar.get_child(0) as Label
	row.add_child(_hero_avatar)

	var who := VBoxContainer.new()
	who.add_theme_constant_override("separation", 3)
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(who)

	_hero_name = UiKit.label("未命名玩家", 16, UiPalette.TEXT)
	who.add_child(_hero_name)

	var sub := HBoxContainer.new()
	sub.add_theme_constant_override("separation", 6)
	who.add_child(sub)
	_conn_dot = UiKit.dot(UiPalette.DIM, 6)
	sub.add_child(_conn_dot)
	_conn_label = UiKit.label("未连接服务器", 11, UiPalette.DIM)
	sub.add_child(_conn_label)

	var rating := PanelContainer.new()
	var rb := StyleBoxFlat.new()
	rb.bg_color = Color(0.91, 0.75, 0.48, 0.10)
	rb.border_color = Color(0.91, 0.75, 0.48, 0.28)
	rb.set_border_width_all(1)
	rb.set_corner_radius_all(10)
	rb.content_margin_left = 11
	rb.content_margin_right = 11
	rb.content_margin_top = 7
	rb.content_margin_bottom = 7
	rating.add_theme_stylebox_override("panel", rb)
	rating.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_rating_label = UiKit.label("评分 —", 12, UiPalette.GOLD)
	rating.add_child(_rating_label)
	row.add_child(rating)

	# 主操作：整屏只此一个金按钮
	_match_btn = UiKit.primary("快速匹配", 50, 14)
	_match_btn.pressed.connect(_on_matchmake)
	v.add_child(_match_btn)

	_match_info = UiKit.label("", 11, UiPalette.GOLD)
	_match_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_match_info.visible = false
	v.add_child(_match_info)


func _build_room_banner(col: Control) -> void:
	_room_panel = PanelContainer.new()
	_room_panel.add_theme_stylebox_override("panel",
		UiKit.card(Color("#1C2438"), 16, UiPalette.GOLD_DEEP))
	_room_panel.visible = false
	col.add_child(_room_panel)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	_room_panel.add_child(v)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	v.add_child(top)
	_room_code_label = UiKit.label("房间 ——", 15, UiPalette.GOLD)
	top.add_child(_room_code_label)
	top.add_child(UiKit.spacer())
	_room_time_label = UiKit.chip("出牌 20 秒", UiPalette.DIM)
	_room_time_text = _room_time_label.get_child(0) as Label
	top.add_child(_room_time_label)

	_room_info = UiKit.label("", 11, UiPalette.DIM)
	_room_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_room_info)

	_room_members = VBoxContainer.new()
	_room_members.add_theme_constant_override("separation", 4)
	v.add_child(_room_members)

	var acts := HBoxContainer.new()
	acts.add_theme_constant_override("separation", 8)
	v.add_child(acts)
	_start_btn = UiKit.primary("开始这一局", 36, 10)
	_start_btn.add_theme_font_size_override("font_size", 13)
	_start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_btn.pressed.connect(_on_start_room)
	acts.add_child(_start_btn)

	_invite_btn = UiKit.ghost("邀请好友", 36, 10)
	_invite_btn.custom_minimum_size.x = 84
	_invite_btn.pressed.connect(_on_invite)
	acts.add_child(_invite_btn)

	_leave_btn = UiKit.danger("离开", 36, 10)
	_leave_btn.custom_minimum_size.x = 64
	_leave_btn.pressed.connect(_on_leave_room)
	acts.add_child(_leave_btn)


func _build_tabs(col: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	col.add_child(row)
	_tab_btns.clear()
	for i in TAB_NAMES.size():
		var b := UiKit.tab(TAB_NAMES[i], not _is_wide)
		b.pressed.connect(_switch_tab.bind(i))
		row.add_child(b)
		_tab_btns.append(b)
	if _is_wide:
		# 宽屏下页签靠左排，右边留空，别让下划线拉成一条横幅
		var pad := Control.new()
		pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(pad)


func _build_body(col: Control) -> void:
	# 三张列表共用一个「内容区」面板：列表没几条时，空白也落在面板里，
	# 不会看着像画面下半截漏风。
	var pc := PanelContainer.new()
	pc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pc.add_theme_stylebox_override("panel",
		UiKit.card(Color("#0F1626"), 16, Color("#1E2740"), 12))
	col.add_child(pc)

	var body := Control.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pc.add_child(body)


	_pages = [_build_page_rooms(), _build_page_players(), _build_page_friends()]
	for i in _pages.size():
		var p: Control = _pages[i]
		body.add_child(p)
		p.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		p.visible = i == TAB_ROOMS
	_switch_tab(TAB_ROOMS)


func _build_page_rooms() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)

	var r1 := _capped_row()
	v.add_child(r1)
	_room_code_edit = UiKit.input("输入 6 位房号加入")
	_room_code_edit.max_length = 6
	if _is_wide:
		_room_code_edit.custom_minimum_size.x = 300
	_room_code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_code_edit.text_changed.connect(func(t: String) -> void:
		var up := t.to_upper()
		if up != t:
			_room_code_edit.text = up
			_room_code_edit.caret_column = up.length())
	_room_code_edit.text_submitted.connect(func(_t: String) -> void: _on_join_room())
	r1.add_child(_room_code_edit)
	_join_btn = UiKit.ghost("加入", 38, 10)
	_join_btn.custom_minimum_size.x = 68
	_join_btn.pressed.connect(_on_join_room)
	r1.add_child(_join_btn)

	var r2 := _capped_row()
	v.add_child(r2)
	_create_btn = UiKit.ghost("创建房间", 38, 10)
	if _is_wide:
		_create_btn.custom_minimum_size.x = 226
	else:
		_create_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_create_btn.pressed.connect(_on_create_room)
	r2.add_child(_create_btn)

	var turn_l := UiKit.label("出牌", 10, UiPalette.DIM)
	turn_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r2.add_child(turn_l)

	_turn_opt = UiKit.option(["5 秒", "10 秒", "15 秒", "20 秒", "30 秒", "60 秒"],
		[5, 10, 15, 20, 30, 60], 3)
	_turn_opt.custom_minimum_size = Vector2(104, 38)
	_turn_opt.item_selected.connect(_on_turn_seconds_changed)
	r2.add_child(_turn_opt)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	if _is_wide:
		head.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	v.add_child(head)
	head.add_child(UiKit.section("公开房间"))
	if not _is_wide:
		head.add_child(UiKit.spacer())
	var refresh := UiKit.pill("刷新", 50)
	refresh.custom_minimum_size.y = 24
	refresh.add_theme_font_size_override("font_size", 10)
	refresh.pressed.connect(func() -> void:
		if client.has_identity():
			client.list_rooms())
	head.add_child(refresh)

	# 窄屏还是竖列（空态才好居中），宽屏用两列网格把宽度用起来
	if _is_wide:
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 10)
		grid.add_theme_constant_override("v_separation", 7)
		_room_list = grid
	else:
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 7)
		_room_list = box
	v.add_child(_wrap_scroll(_room_list))
	_refresh_rooms([])
	return v


func _build_page_players() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	if _is_wide:
		head.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	v.add_child(head)
	head.add_child(UiKit.section("在线玩家"))
	if not _is_wide:
		head.add_child(UiKit.spacer())
	var refresh := UiKit.pill("刷新", 50)
	refresh.custom_minimum_size.y = 24
	refresh.add_theme_font_size_override("font_size", 10)
	refresh.pressed.connect(func() -> void:
		if client.has_identity():
			client.list_players())
	head.add_child(refresh)

	_players_list = VBoxContainer.new()
	_players_list.add_theme_constant_override("separation", 7)
	v.add_child(_wrap_scroll(_players_list))
	_refresh_players([])
	return v


func _build_page_friends() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	_friend_name_edit = UiKit.input("输入对方昵称")
	_friend_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_friend_name_edit.text_submitted.connect(func(_t: String) -> void: _on_add_friend())
	row.add_child(_friend_name_edit)
	var add := UiKit.ghost("加好友", 38, 10)
	add.custom_minimum_size.x = 74
	add.pressed.connect(_on_add_friend)
	row.add_child(add)

	v.add_child(UiKit.section("好友"))

	_friend_list = VBoxContainer.new()
	_friend_list.add_theme_constant_override("separation", 7)
	v.add_child(_wrap_scroll(_friend_list))
	_refresh_friends([])
	return v


func _build_statusbar(col: Control) -> void:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#0D1424")
	sb.border_color = Color("#212B42")
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 11
	sb.content_margin_right = 11
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	pc.add_theme_stylebox_override("panel", sb)
	col.add_child(pc)

	_status_box = VBoxContainer.new()
	_status_box.add_theme_constant_override("separation", 2)
	pc.add_child(_status_box)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	_status_box.add_child(row)
	_status_dot = UiKit.dot(UiPalette.DIM, 6)
	row.add_child(_status_dot)
	_status = UiKit.label("未连接", 11, UiPalette.DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_status)


## 宽屏下把一行控件限制在 560 宽，别整条拉满。
func _capped_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	if _is_wide:
		# 宽屏下按内容宽度靠左，不跟着整列拉成一整条
		row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	return row


func _wrap_scroll(inner: Control) -> ScrollContainer:
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.add_child(inner)
	return sc


# ---------------------------------------------------------------- 页签

func _switch_tab(i: int) -> void:
	_tab = i
	for k in _tab_btns.size():
		UiKit.style_tab(_tab_btns[k], k == i)
	for k in _pages.size():
		(_pages[k] as Control).visible = k == i


## 身份卡跟随连接状态与昵称刷新
func _sync_identity() -> void:
	var nm := client.player_name.strip_edges()
	if nm == "":
		nm = "未命名玩家"
	_hero_name.text = nm
	_avatar_letter.text = nm.substr(0, 1)
	var on := _connected
	if not NetClient.TRANSPORT_READY:
		_conn_label.text = "联机服务待接入"
	elif on:
		_conn_label.text = "已连接服务器"
	else:
		_conn_label.text = "未连接服务器"
	(_conn_dot.get_theme_stylebox("panel") as StyleBoxFlat).bg_color = \
		UiPalette.TEAL if on else UiPalette.DIM
	_rating_label.text = ("评分 %d" % _my_mmr) if _my_mmr > 0 else "评分 —"


# ---------------------------------------------------------------- 操作

func _on_matchmake() -> void:
	if _queued:
		client.cancel_match()
		_queued = false
		_match_btn.text = "快速匹配"
		return
	if not _require_online():
		return
	client.matchmake()
	_queued = true
	_match_btn.text = "取消匹配"


## 联机没接上时，所有动作都走这里：说清原因，不要静默失败。
func _require_online() -> bool:
	if _connected:
		return true
	_set_status("联机服务尚未接入，等对接方把连接层接好", UiPalette.GOLD)
	return false


func _on_create_room() -> void:
	if not _require_online():
		return
	_turn_seconds = float(_turn_opt.get_item_id(_turn_opt.get_selected_id()))
	client.create_room(_turn_seconds)


func _on_join_room() -> void:
	if not _require_online():
		return
	var code := _room_code_edit.text.strip_edges().to_upper()
	if code.length() != 6:
		_set_status("房号是 6 位", UiPalette.RED)
		return
	client.join_room(code)


func _on_turn_seconds_changed(_idx: int) -> void:
	# 房主改出牌时间：先记下来，点了「开始」才生效
	_turn_seconds = float(_turn_opt.get_item_id(_turn_opt.get_selected_id()))
	if _room_id != "" and _room_time_label != null:
		_room_time_text.text = "出牌 %d 秒" % int(_turn_seconds)


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
	if not _require_online():
		return
	var nm := _friend_name_edit.text.strip_edges()
	if nm == "":
		return
	client.add_friend(nm)


func _on_invite() -> void:
	# 房间条上的「邀请好友」：跳到好友页，让玩家挑人
	if _room_id == "":
		_set_status("先创建或加入一个房间", UiPalette.RED)
		return
	_switch_tab(TAB_FRIENDS)
	_set_status("在好友右侧点「邀请」，把人拉进房间 " + _room_id, UiPalette.GOLD)


# ---------------------------------------------------------------- 回调

func _on_cmd_result(cmd: String, res: Dictionary) -> void:
	var ok := bool(res.get("ok", false))
	if not ok:
		_set_status(str(res.get("error", "操作失败")), UiPalette.RED)
		return
	match cmd:
		"register", "login":
			_connected = true
			_set_status("已连接 · 你是 " + client.player_name, UiPalette.TEAL)
			client.start_polling()
			client.api("online", {})
			client.api("friends", {})
			client.api("profile", {})
			# 名单列表下一拍就刷，别让玩家先盯 3 秒空列表
			_roster_timer = 3.0
			_sync_identity()
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
			_sync_identity()
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


## 显示房间条（房号、成员、房主、出牌时间）
func _show_room() -> void:
	if _room_id == "":
		_room_panel.visible = false
		return
	_room_panel.visible = true
	var is_host := _host_id == client.player_id or _host_id == ""
	_room_code_label.text = "房间 " + _room_id
	_room_time_text.text = "出牌 %d 秒" % int(_turn_seconds)
	_room_info.text = "你是房主，人齐了点「开始这一局」" if is_host else "等房主开始这一局"
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
		row.add_theme_constant_override("separation", 7)
		_room_members.add_child(row)
		var me := mid == client.player_id
		row.add_child(UiKit.dot(UiPalette.GOLD if me else UiPalette.TEAL, 5))
		var nm := str(m.get("name", "?"))
		if me:
			nm += "（你）"
		var l := UiKit.label(nm, 12, UiPalette.TEXT)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		if is_host and mid != client.player_id:
			var rm := UiKit.pill("移除", 50)
			rm.pressed.connect(func() -> void:
				client.remove_member(_room_id, mid)
				_set_status("已把 " + str(m.get("name", "")) + " 请出房间", UiPalette.GOLD))
			row.add_child(rm)


func _update_match_info(status: Dictionary) -> void:
	if status.is_empty():
		return
	_match_info.visible = true
	_match_info.text = "匹配中 · 已等 %.0f 秒 · 评分 %d · 范围 ±%d" % [
		float(status.get("waited", 0.0)),
		int(status.get("mmr", _my_mmr)),
		int(status.get("window", 0.0)),
	]


func _refresh_players(players: Array) -> void:
	_last_players = players
	for c in _players_list.get_children():
		_players_list.remove_child(c)
		c.queue_free()
	if players.is_empty():
		_players_list.add_child(_vfill())
		_players_list.add_child(_empty("（还没有别人在线）"))
		_players_list.add_child(_vfill())
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

		var card := UiKit.row_card()
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 9)
		card.add_child(row)
		row.add_child(UiKit.dot(color, 7))

		var who := VBoxContainer.new()
		who.add_theme_constant_override("separation", 1)
		who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		who.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(who)
		who.add_child(UiKit.label(str(p.get("name", "?")), 13, UiPalette.TEXT))
		who.add_child(UiKit.label(str(p.get("label", "空闲")), 10, color))

		# 在房间里的人可以点「加入」直接进他的房间
		var rid := str(p.get("room_id", ""))
		if rid != "" and st == "in_lobby":
			var join := UiKit.pill("加入", 54)
			join.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			join.pressed.connect(func() -> void:
				client.join_room(rid)
				_set_status("正在加入房间 " + rid, UiPalette.GOLD))
			row.add_child(join)
		_players_list.add_child(card)


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
	# 名单 3 秒一轮。以前这里写的是 int(_refresh_timer * 10) % 30，
	# 但 _refresh_timer 上一行就被清零了，条件永远成立 —— 实际每秒都在拉。
	_roster_timer += 1.0
	if _roster_timer >= 3.0:
		_roster_timer = 0.0
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


func _on_server_outdated(server_version: String) -> void:
	# 反过来：服务器比客户端旧。该更新的是服务器，而服务器会自动更新，
	# 所以等它自己升上来就行，不用玩家做什么。
	_set_status("服务器版本较旧（v%s），它会自动更新，稍等片刻即可" % server_version,
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
	_online_label.text = "在线 —"
	_sync_identity()
	if not NetClient.TRANSPORT_READY:
		_set_status("联机服务尚未接入，等对接方把连接层接好", UiPalette.GOLD)
	elif client.has_identity():
		_set_status("已有存档，正在重连…", UiPalette.DIM)


func _refresh_rooms(rooms: Array) -> void:
	_last_rooms = rooms
	for c in _room_list.get_children():
		_room_list.remove_child(c)
		c.queue_free()
	if rooms.is_empty():
		if _is_wide:
			_room_list.add_child(_empty("暂无公开房间 · 左边「创建房间」开一个，等人进来"))
		else:
			_room_list.add_child(_vfill())
			_room_list.add_child(_empty("（暂无公开房间，上面点「创建房间」等人来）"))
			_room_list.add_child(_vfill())
		return
	for r in rooms:
		if not (r is Dictionary):
			continue
		var code := str(r.get("room_id", ""))
		var names: Array = r.get("players", [])
		var card := UiKit.row_card()
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 9)
		card.add_child(row)

		var info := VBoxContainer.new()
		info.add_theme_constant_override("separation", 1)
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(info)
		info.add_child(UiKit.label(code, 15, UiPalette.TEXT))

		var sub := "%d/2 人 · %s" % [names.size(), ", ".join(PackedStringArray(names))]
		if names.is_empty():
			sub = "房主 %s" % str(r.get("owner", "?"))
		var sub_l := UiKit.label(sub, 10, UiPalette.DIM)
		sub_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.add_child(sub_l)

		var j := UiKit.pill("加入", 54)
		j.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		j.pressed.connect(func() -> void: client.join_room(code))
		row.add_child(j)
		_room_list.add_child(card)


func _refresh_friends(friends: Array) -> void:
	_last_friends = friends
	for c in _friend_list.get_children():
		_friend_list.remove_child(c)
		c.queue_free()
	if friends.is_empty():
		_friend_list.add_child(_vfill())
		_friend_list.add_child(_empty("（还没有好友，在上面输入昵称加一个）"))
		_friend_list.add_child(_vfill())
		return
	for f in friends:
		if not (f is Dictionary):
			continue
		var on := bool(f.get("online", false))
		var color := UiPalette.TEAL if on else UiPalette.DIM
		var card := UiKit.row_card()
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 9)
		card.add_child(row)
		row.add_child(UiKit.dot(color, 7))

		var who := VBoxContainer.new()
		who.add_theme_constant_override("separation", 1)
		who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		who.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(who)
		who.add_child(UiKit.label(str(f.get("name", "?")), 13, UiPalette.TEXT))
		var tail := str(f.get("label", "")) if on else "离线"
		who.add_child(UiKit.label(tail, 10, color))

		var fid := str(f.get("id", ""))
		var fname := str(f.get("name", ""))
		var inv := UiKit.pill("邀请", 54)
		inv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		inv.disabled = not on
		inv.pressed.connect(func() -> void: _invite_one(fid, fname))
		row.add_child(inv)
		_friend_list.add_child(card)


## 把某个好友拉进当前房间；还没进房间就先记下来，等开好房再点。
func _invite_one(fid: String, fname: String) -> void:
	_pending_friend_invite = fid
	if _room_id == "":
		_set_status("还没进房间：先在上面建一个房，再点「邀请」", UiPalette.GOLD)
		_switch_tab(TAB_ROOMS)
		return
	client.invite_friend(fid, _room_id)
	_set_status("已邀请 %s 进房间 %s" % [fname, _room_id], UiPalette.TEAL)


## 上下拉扯用的空占位：列表为空时把空态卡放在正中间。
func _vfill() -> Control:
	var c := Control.new()
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _empty(text: String) -> Control:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.02)
	sb.border_color = Color(1, 1, 1, 0.06)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(18)
	pc.add_theme_stylebox_override("panel", sb)
	var l := UiKit.label(text, 11, UiPalette.DIM)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pc.add_child(l)
	return pc


func _set_status(text: String, color: Color) -> void:
	_last_status_text = text
	_last_status_color = color
	if _status == null or not is_instance_valid(_status):
		return
	_status.text = text
	_status.add_theme_color_override("font_color", color)
	if _status_dot != null:
		(_status_dot.get_theme_stylebox("panel") as StyleBoxFlat).bg_color = color


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
