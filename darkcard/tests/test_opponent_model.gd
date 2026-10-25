extends SceneTree

# 对手习惯模型的功能测试：
#   1. 反复出同一张牌 → 倾向升高、置信度升高
#   2. 习惯分布归一化
#   3. 一局结束会衰减
#   4. 序列化往返一致
#   5. 存档落盘/读取往返一致
#   6. 老版本存档能被迁移

var _pass := 0
var _fail := 0


func _initialize() -> void:
    _test_learn()
    _test_decay()
    _test_roundtrip()
    _test_store()
    _test_migrate()
    print("PASS %d  FAIL %d" % [_pass, _fail])
    quit(0 if _fail == 0 else 1)


func _ok(name: String, cond: bool, detail: String = "") -> void:
    if cond:
        _pass += 1
        print("  ok    " + name)
    else:
        _fail += 1
        printerr("  FAIL  " + name + ("  " + detail if detail != "" else ""))


func _test_learn() -> void:
    print("[learn]")
    var m := OpponentModel.new()
    var ctx := "t1|hp_hi|y0|res"
    for i in 20:
        m.observe(ctx, "wei_biao", ["attack"], false, false)
    for i in 4:
        m.observe(ctx, "yun", ["resource"], false, false)

    var t_bias := m.tendency("wei_biao", ctx)
    var t_res := m.tendency("yun", ctx)
    _ok("repeated card gets higher tendency", t_bias > 0.7,
        "wei_biao=%.3f" % t_bias)
    _ok("other card gets lower tendency", t_res < 0.3, "yun=%.3f" % t_res)
    _ok("confidence rises with evidence", m.confidence(ctx) > 0.3,
        "conf=%.3f" % m.confidence(ctx))
    _ok("mix weight stays capped", m.mix_weight(ctx) <= OpponentModel.MAX_MIX + 0.001,
        "mix=%.3f" % m.mix_weight(ctx))
    _ok("mix weight is positive when confident", m.mix_weight(ctx) > 0.0)

    # 习惯分布必须归一化
    var dist := m.habit_distribution(ctx, ["wei_biao", "yun", "zhong_fang"])
    var sum := 0.0
    for d in dist:
        sum += float(d)
    _ok("habit distribution sums to 1", absf(sum - 1.0) < 0.001, "sum=%.4f" % sum)
    _ok("habit distribution favours the habit", float(dist[0]) > float(dist[2]))

    # 套路度
    var m2 := OpponentModel.new()
    for i in 6:
        m2.observe(ctx, "yun", ["resource"], false, false)
    _ok("repetition is measured", m2.predictability() > 0.0,
        "predictability=%.3f" % m2.predictability())
    _ok("longest streak recorded", m2.max_streak >= 5, "streak=%d" % m2.max_streak)

    # 攻防倾向
    var m3 := OpponentModel.new()
    m3.observe(ctx, "xiao_biao", ["attack"], false, false)
    m3.observe(ctx, "zhong_fang", ["defense"], false, false)
    _ok("attack share tracked", m3.tag_share("attack") > 0.0
        and m3.tag_share("defense") > 0.0)

    # 连招意图
    var m4 := OpponentModel.new()
    m4.observe(ctx, "zhong_fang", ["defense"], true, false)
    m4.observe(ctx, "gui_pai", ["combo"], false, true)
    _ok("combo setup/finish counted", m4.combo_setup == 1.0 and m4.combo_finish == 1.0)


func _test_decay() -> void:
    print("[decay]")
    var m := OpponentModel.new()
    var ctx := "t2_3|hp_hi|y1_2|atk"
    for i in 10:
        m.observe(ctx, "xiao_qiao", ["attack"], false, false)
    var before := m.tendency("xiao_qiao", ctx)
    var total_before := m.card_total
    var ctx_total_before := float(m.context_total.get(ctx, 0.0))
    m.end_match()
    var after := m.tendency("xiao_qiao", ctx)
    # 上下文内的比率是"信号"，不该衰减（衰减的作用是让新样本更快盖过旧样本）
    _ok("context ratio is preserved (it is the signal)", absf(after - before) < 0.001,
        "before=%.3f after=%.3f" % [before, after])
    # 衰减的是有效样本量与全局回退 → 置信度随之下降
    _ok("effective sample size decays", m.card_total < total_before
        and float(m.context_total.get(ctx, 0.0)) < ctx_total_before,
        "card_total %.1f->%.1f" % [total_before, m.card_total])
    _ok("match counter increments", m.matches == 1)


func _test_roundtrip() -> void:
    print("[roundtrip]")
    var m := OpponentModel.new()
    var ctx := "t1|hp_hi|y0|res"
    for i in 8:
        m.observe(ctx, "tao_tao", ["heal"], false, false)
    var d := m.to_dict()
    var m2 := OpponentModel.new()
    m2.from_dict(d)
    _ok("tendency survives roundtrip",
        absf(m.tendency("tao_tao", ctx) - m2.tendency("tao_tao", ctx)) < 0.0001)
    _ok("decisions survive roundtrip", m2.decisions == m.decisions)
    _ok("schema version present", int(d.get("schema_version", 0)) == OpponentModel.SCHEMA_VERSION)


func _test_store() -> void:
    print("[store]")
    OpponentStore.clear()
    var m := OpponentModel.new()
    var ctx := "t1|hp_hi|y0|res"
    for i in 12:
        m.observe(ctx, "kai_sa", ["attack"], false, false)
    var ok := OpponentStore.save_model(m)
    _ok("save succeeds", ok)
    _ok("file exists", OpponentStore.exists())

    var m2 := OpponentStore.load_model()
    _ok("loaded model keeps the habit",
        m2.tendency("kai_sa", ctx) > 0.5,
        "tendency=%.3f" % m2.tendency("kai_sa", ctx))
    _ok("loaded decisions match", m2.decisions == m.decisions)

    # 损坏文件不应崩，应回退到空画像
    var f := FileAccess.open(OpponentStore.PATH, FileAccess.WRITE)
    f.store_string("{ this is not json")
    f.close()
    var m3 := OpponentStore.load_model()
    _ok("corrupt file falls back to empty model", m3 != null and m3.decisions == 0)
    OpponentStore.clear()


func _test_migrate() -> void:
    print("[migrate]")
    var legacy := {
        "card_counts": {"yun": 5.0},
        "card_total": 5.0,
        "tag_counts": {"resource": 5.0},
        "decisions": 5,
        "matches": 1,
    }
    var migrated: Dictionary = OpponentStore._migrate(legacy)
    _ok("legacy version is migrated", int(migrated.get("schema_version", 0)) == 1)
    _ok("legacy global counts survive", float(migrated.get("card_total", 0.0)) == 5.0)
    var m := OpponentModel.new()
    m.from_dict(migrated)
    _ok("migrated data loads into model", m.decisions == 5)
    _ok("migrated model has empty contexts", m.context_counts.is_empty())
