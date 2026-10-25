extends SceneTree

# 只跑"神之龟派 × 比例伤害 / 三棱镜 / 阈值类"这一组极难触发的组合，打印实际结算值。

var db: CardDB


func _initialize() -> void:
	db = CardDB.load_all()
	_probe_wine()
	_probe_poison()
	_probe_prism()
	_probe_bixin()
	quit(0)


func _duel(turn_index: int, yun0: int, yun1: int, hp0: int, hp1: int) -> Duel:
	var d := Duel.new(db)
	d.state.turn = turn_index
	var p0 := d.state.players[0]
	var p1 := d.state.players[1]
	p0.yun = yun0
	p0.hp = hp0
	p0.hp_max_ever = hp0
	p1.yun = yun1
	p1.hp = hp1
	p1.hp_max_ever = hp1
	return d


func _prep(d: Duel, player: int, history: Array) -> void:
	for c in history:
		d.state.players[player].history.append(str(c))


func _shen(d: Duel, other_card: String) -> Array:
	_prep(d, 1, ["jue_xing_zhong_fang", "chao_ji_xi", "qiang_hua_yun"])
	return d.play_turn(other_card, "shen_zhi_gui_pai")


func _probe_wine() -> void:
	# 酒被神之龟派借走：B 应只免疫 ≤1 的攻击；B 身上有 1.5/回合的 dot
	var d := _duel(5, 10, 0, 300, 300)
	d.state.players[1].add_dot(150, 1, 1, 1)  # 挂给 B，本回合就跳
	var ev: Array = _shen(d, "jiu")
	var immune := false
	for e in ev:
		if str(e.get("t", "")) == "IMMUNE":
			immune = true
	print("酒 + 神之龟派：B.hp=%d  B.immune_le=%d  跳 1.5 是否被免疫=%s" % [
		d.state.players[1].hp, d.state.players[1].immune_le, str(immune)])


func _probe_poison() -> void:
	# 毒药 -80% 被借走 → 打回 A；A 300 血应剩 60（比例不翻倍）
	var d := _duel(5, 20, 0, 300, 300)
	_shen(d, "du_yao")
	print("毒药 + 神之龟派：A.hp=%d  B.hp=%d  （不翻倍应 60，翻倍应 0）" % [
		d.state.players[0].hp, d.state.players[1].hp])


func _probe_prism() -> void:
	# 三棱镜 k=0 → 0.4；被神之龟派借走打回 A
	var d := _duel(5, 10, 0, 300, 300)
	_shen(d, "san_leng_jing")
	print("三棱镜 + 神之龟派：A.hp=%d  （不翻倍应 280，翻倍应 292）" % d.state.players[0].hp)


func _probe_bixin() -> void:
	# 比心 -2 运，神之龟派应翻成 -4（下限 -3 仍生效）
	var d := _duel(5, 50, 0, 300, 300)
	_shen(d, "bi_xin")
	print("比心 + 神之龟派：A.yun=%d  （翻倍应 10，不翻倍应 30）" % d.state.players[0].yun)
