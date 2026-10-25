extends SceneTree

# 数一数对战界面里到底建了多少张牌、有多少张可见。
# 用来核实「app 里少了 10 个技能」这条反馈。

func _initialize() -> void:
	_run()


func _run() -> void:
	var db := CardDB.load_all()
	print("卡表条目数：%d" % db.size())

	var packed = load("res://scenes/Battle.tscn")
	if packed == null:
		printerr("cannot load Battle.tscn")
		quit(1)
		return
	var scene = packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	var tiles: Array = scene.get("_tiles")
	if tiles == null:
		printerr("拿不到 _tiles")
		quit(1)
		return
	print("界面建的牌块数：%d" % tiles.size())

	# 按当前筛选统计可见的
	var visible_count := 0
	var names: Array = []
	for t in tiles:
		if t.visible:
			visible_count += 1
		names.append(str(t.get("card_id")))
	print("当前筛选下可见：%d" % visible_count)
	print("去重后的牌名数：%d" % _uniq(names).size())
	var missing: Array = []
	for cid in db.order:
		if not names.has(cid):
			missing.append(cid)
	if missing.is_empty():
		print("没有牌缺失于界面")
	else:
		print("界面上没有的牌：%s" % str(missing))

	# 搜索框有内容时再数一次（模拟玩家输入了字）
	var search = scene.get("_search")
	if search != null:
		search.text = "镖"
		search.text_changed.emit("镖")
		await process_frame
		var v2 := 0
		for t in tiles:
			if t.visible:
				v2 += 1
		print("搜索「镖」后可见：%d" % v2)

	quit(0)


func _uniq(a: Array) -> Array:
	var out: Array = []
	for x in a:
		if not out.has(x):
			out.append(x)
	return out
