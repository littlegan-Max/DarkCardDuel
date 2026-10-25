extends SceneTree

# 场景切换冒烟测试。
#
# 主菜单点按钮 → 新场景必须能活过帧末。
# 旧实现是「把新场景 add_child 到自己身上，然后 queue_free 自己」，
# 新场景作为子节点被连带释放 → 点进去一片黑。
# Godot 引擎自己也会报：Condition "p_scene && p_scene->get_parent() != root" is true.
#
#   godot --headless --path <proj> --script res://tools/test_scene_nav.gd

const MAIN_SCENE := "res://scenes/main/Main.tscn"

var _fails := 0
var _checks := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	await _check_button("单机对战", "res://scenes/Battle.tscn")
	await _check_button("联机对战", "res://scenes/lobby/Lobby.tscn")
	await _check_lobby_to_battle()
	await _check_keep_node_survives()
	await _check_battle_back_to_menu()
	await _check_lobby_back_to_menu()

	print("")
	print("[scene_nav] %d 项检查，%d 项失败" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)


## 模拟点主菜单上的某个按钮，看新场景是不是活下来了
func _check_button(label: String, expect_path: String) -> void:
	var main: Node = load(MAIN_SCENE).instantiate()
	root.add_child(main)
	current_scene = main
	await process_frame

	var btn := _find_btn(main, label)
	if btn == null:
		_fail("%s：主菜单上找不到按钮「%s」" % [expect_path, label])
		await _drop(main)
		return

	btn.pressed.emit()
	# 等几帧，让 queue_free 真正生效（帧末才删）
	for i in range(4):
		await process_frame

	var cur: Node = current_scene
	if not is_instance_valid(cur):
		_fail("%s：点「%s」后当前场景已被释放（黑屏）" % [expect_path, label])
		return
	if cur == main:
		_fail("%s：点「%s」后场景没切换" % [expect_path, label])
		return
	if cur.get_script() == null:
		_fail("%s：点「%s」后新场景没有脚本" % [expect_path, label])
		return
	# 新场景必须真的挂在树上（有内容可画），不能是游离节点
	if cur.get_parent() == null:
		_fail("%s：点「%s」后新场景游离在场景树外（看不见）" % [expect_path, label])
		return
	if cur.get_child_count() == 0:
		_fail("%s：点「%s」后新场景是空的（黑屏）" % [expect_path, label])
		return
	_pass("%s：点「%s」后新场景存活，子节点 %d 个" % [
		expect_path, label, cur.get_child_count()])


## 大厅 → 对战（联机入口）：大厅里切场景不能把对战界面一起带走，
## 也不能把大厅持有的长连接客户端一起带走（否则进了对战就收不到消息）。
func _check_lobby_to_battle() -> void:
	var lobby: Node = load("res://scenes/lobby/Lobby.tscn").instantiate()
	root.add_child(lobby)
	current_scene = lobby
	await process_frame

	# 造一个已登录的身份，好让大厅愿意进对战
	var client: Node = lobby.get("client")
	if client == null:
		_fail("大厅 → 对战：大厅里没有 client")
		await _drop(lobby)
		return
	client.set("token", "test-token")
	client.set("player_id", "test-player")

	lobby.call("_enter_battle")
	for i in range(4):
		await process_frame

	var cur: Node = current_scene
	if not is_instance_valid(cur):
		_fail("大厅 → 对战：切过去后当前场景已被释放（黑屏）")
		return
	if cur.get_parent() == null:
		_fail("大厅 → 对战：新场景游离在场景树外（看不见）")
		return
	if cur.get_child_count() == 0:
		_fail("大厅 → 对战：新场景是空的（黑屏）")
		return
	# 长连接客户端必须还活着，而且已经转到新场景下了
	if not is_instance_valid(client):
		_fail("大厅 → 对战：长连接客户端被跟着大厅一起释放了")
		return
	if not client.is_inside_tree():
		_fail("大厅 → 对战：长连接客户端离开了场景树")
		return
	if client.get_parent() != cur:
		_fail("大厅 → 对战：长连接客户端没有转到新场景下")
		return
	_pass("大厅 → 对战：新场景存活（子节点 %d 个），长连接客户端已转移" % cur.get_child_count())


## 通用检查：SceneRouter.swap 必须保住「要保留的节点」
func _check_keep_node_survives() -> void:
	var old_scene: Node = load(MAIN_SCENE).instantiate()
	root.add_child(old_scene)
	current_scene = old_scene
	await process_frame

	var keeper := Node.new()
	keeper.name = "Keeper"
	old_scene.add_child(keeper)

	var new_scene: Node = load("res://scenes/Battle.tscn").instantiate()
	SceneRouter.swap(self, new_scene, [keeper])
	for i in range(3):
		await process_frame

	if not is_instance_valid(keeper):
		_fail("swap：保留节点被一起释放了")
		return
	if keeper.get_parent() != new_scene:
		_fail("swap：保留节点没有转到新场景下")
		return
	if not is_instance_valid(current_scene) or current_scene != new_scene:
		_fail("swap：current_scene 没指向新场景")
		return
	_pass("swap：保留节点存活并已转移，current_scene 指向新场景")


## 对局中 → 返回主菜单：顶栏「菜单」→ 确认 → 必须回到主菜单
func _check_battle_back_to_menu() -> void:
	var main: Node = load(MAIN_SCENE).instantiate()
	root.add_child(main)
	current_scene = main
	await process_frame

	var btn := _find_btn(main, "单机对战")
	if btn == null:
		_fail("对局返回：找不到「单机对战」按钮")
		await _drop(main)
		return
	btn.pressed.emit()
	for i in range(3):
		await process_frame

	var battle: Node = current_scene
	if not is_instance_valid(battle):
		_fail("对局返回：没进到对局界面")
		return

	var menu_btn := _find_btn(battle, "菜单")
	if menu_btn == null:
		_fail("对局返回：对局界面没有「菜单」按钮")
		return
	menu_btn.pressed.emit()
	await process_frame

	# 退出确认层必须弹出来
	var panel: Node = battle.get("_exit_panel")
	if panel == null or not panel.visible:
		_fail("对局返回：点「菜单」没弹出确认层")
		return

	var home := _find_btn(panel, "返回主菜单")
	if home == null:
		_fail("对局返回：确认层里没有「返回主菜单」按钮")
		return
	home.pressed.emit()
	for i in range(4):
		await process_frame

	var cur: Node = current_scene
	if not is_instance_valid(cur):
		_fail("对局返回：返回主菜单后当前场景被释放了")
		return
	if cur == battle:
		_fail("对局返回：点了「返回主菜单」但场景没变")
		return
	if cur.get_script() == null or cur.get_child_count() == 0:
		_fail("对局返回：回到的不是主菜单")
		return
	if _find_btn(cur, "单机对战") == null:
		_fail("对局返回：回到的界面里没有主菜单的按钮")
		return
	_pass("对局 → 返回主菜单：成功回到主菜单")


## 大厅 → 返回主菜单
func _check_lobby_back_to_menu() -> void:
	var lobby: Node = load("res://scenes/lobby/Lobby.tscn").instantiate()
	root.add_child(lobby)
	current_scene = lobby
	await process_frame

	var btn := _find_btn(lobby, "主菜单")
	if btn == null:
		_fail("大厅返回：大厅里没有「主菜单」按钮")
		await _drop(lobby)
		return
	btn.pressed.emit()
	for i in range(4):
		await process_frame

	var cur: Node = current_scene
	if not is_instance_valid(cur) or cur == lobby:
		_fail("大厅返回：点「主菜单」后没回到主菜单")
		return
	if _find_btn(cur, "单机对战") == null:
		_fail("大厅返回：回到的不是主菜单")
		return
	_pass("大厅 → 返回主菜单：成功回到主菜单")


func _drop(n: Node) -> void:
	if n != null and is_instance_valid(n):
		if n.get_parent() != null:
			n.get_parent().remove_child(n)
		n.queue_free()
	await process_frame


func _find_btn(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n as Button
	for c in n.get_children():
		var r := _find_btn(c, text)
		if r != null:
			return r
	return null


func _pass(msg: String) -> void:
	_checks += 1
	print("[OK]   " + msg)


func _fail(msg: String) -> void:
	_checks += 1
	_fails += 1
	printerr("[FAIL] " + msg)
