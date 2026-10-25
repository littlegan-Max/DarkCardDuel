class_name TurnResolver
extends RefCounted

# 结算管线（B4 十步）
# 1 REVEAL → 2 KUI → 3 AMULET → 4 TIME_REVERSE → 5 COUNTER
# → 6 RESOURCE → 7 DAMAGE(+dot/C4) → 8 SHIELD_SAVE → 9 DEATH → 10 SETTLE

var db: CardDB


func _init(card_db: CardDB) -> void:
    db = card_db


func resolve(state: DuelState) -> Array:
    var ctx := ResolutionContext.new(
        state,
        state.players[0].pending_card,
        state.players[1].pending_card,
        db
    )
    var ledger := HpLedger.new(state)
    ledger.begin()
    var events: Array = []

    var reveal := {"t": "REVEAL", "turn": state.turn}
    reveal["cards"] = ctx.cards.duplicate()
    events.append(reveal)

    _phase_kui(ctx, events)
    _phase_amulet(ctx, events)
    _phase_time(ctx, events)

    if not ctx.time_stopped:
        _phase_counter(ctx, events)
        _phase_resource(ctx, events, ledger)

    # dot / C4 的当期结算不受扭转时空影响（B4 第 4 步）
    _phase_damage(ctx, events, ledger)
    var result := _phase_death(ctx, events)

    if result == "tie":
        # A2 / C29：同死只作废血量变化，其余照常
        ctx.code_kill[0] = false
        ctx.code_kill[1] = false
        ledger.rollback_hp_only()
        events.append({"t": "DAMAGE_VOIDED", "turn": state.turn})
        result = "continue"

    _phase_settle(ctx, events)

    events.append({
        "t": "SNAPSHOT",
        "hp": [state.players[0].hp, state.players[1].hp],
        "yun": [state.players[0].yun, state.players[1].yun],
        "shields": [state.players[0].shields, state.players[1].shields],
        "over": state.over,
    })
    state.turn_logs.append(events)
    return events


func _negate(ctx: ResolutionContext, i: int, by: String, events: Array) -> void:
    ctx.negated[i] = true
    ctx.blocked_by[i] = by
    events.append({"t": "COUNTER", "player": i, "card": ctx.cards[i], "by": by})


# —— 2 龟派 ——
func _phase_kui(ctx: ResolutionContext, events: Array) -> void:
    var kui := -1
    for i in 2:
        var d: SkillDef = ctx.defs[i]
        if d == null:
            continue
        if d.id == "gui_pai" or d.id == "shen_zhi_gui_pai":
            if kui >= 0:
                # C33：双方同时出龟派类 → 两张都不生效
                ctx.negated[0] = true
                ctx.negated[1] = true
                events.append({"t": "KUI_CANCEL"})
                return
            kui = i
    if kui < 0:
        return

    var other := 1 - kui
    var kui_def: SkillDef = ctx.defs[kui]
    ctx.kui_caster = kui
    ctx.kui_mult = 1
    for op in kui_def.ops:
        if str(op.get("op", "")) == "KUI":
            ctx.kui_mult = maxi(1, int(op.get("mult", 1)))

    ctx.redirect[other] = kui
    events.append({
        "t": "KUI", "player": kui, "card": ctx.cards[other], "mult": ctx.kui_mult,
    })

    # 反制型牌被借走：无对象，按无效处理（适配表"吸/超级吸"一行的可达成结论）
    var taken: SkillDef = ctx.defs[other]
    if taken != null and taken.is_counter:
        ctx.negated[other] = true
        events.append({"t": "KUI_NOOP", "player": kui, "card": taken.id})


# —— 3 护身符 ——
func _phase_amulet(ctx: ResolutionContext, events: Array) -> void:
    for i in 2:
        var d: SkillDef = ctx.defs[i]
        if d == null or d.id != "hu_shen_fu" or ctx.negated[i]:
            continue
        var holder := ctx.owner_of(i)
        var lo := 20
        var hi := 30
        for op in d.ops:
            if str(op.get("op", "")) == "IMMUNE_COST_RANGE":
                lo = int(op.get("lo", 20))
                hi = int(op.get("hi", 30))
        for j in 2:
            if j == i or ctx.negated[j]:
                continue
            var atk: SkillDef = ctx.defs[j]
            if atk == null or not atk.is_negative():
                continue
            if ctx.target_of(j) != holder:
                continue
            var spent := ctx.paid[j]
            if spent >= lo and spent <= hi:
                _negate(ctx, j, "hu_shen_fu", events)


# —— 4 扭转时空 ——
func _phase_time(ctx: ResolutionContext, events: Array) -> void:
    for i in 2:
        var d: SkillDef = ctx.defs[i]
        if d == null or d.id != "niu_zhuan_shi_kong" or ctx.negated[i]:
            continue
        ctx.time_stopped = true
        events.append({"t": "TIME_STOP", "player": ctx.owner_of(i)})


# —— 5 反制 ——
func _phase_counter(ctx: ResolutionContext, events: Array) -> void:
    for i in 2:
        if ctx.is_kui_taken(i):
            continue
        var j := 1 - i
        if ctx.is_kui_taken(j):
            continue
        var atk: SkillDef = ctx.defs[i]
        var dfn: SkillDef = ctx.defs[j]
        if atk == null:
            continue

        if dfn != null and not ctx.negated[i]:
            _try_block(ctx, i, j, events)

        # 掐类秒杀：仅当自己没被挡
        if not ctx.negated[i] and atk.kill_tag != "" and dfn != null:
            if dfn.tags.has(atk.kill_tag):
                ctx.negated[j] = true
                ctx.blocked_by[j] = atk.id
                events.append({"t": "COUNTER", "player": j, "card": ctx.cards[j], "by": atk.id})
                ctx.code_kill[j] = true
                events.append({"t": "CODE_KILL", "target": j, "source": i, "by": atk.id})


func _try_block(ctx: ResolutionContext, i: int, j: int, events: Array) -> void:
    var atk: SkillDef = ctx.defs[i]
    var dfn: SkillDef = ctx.defs[j]

    # 1) 闪：只躲"指向自己"的负面技能（手枪不可闪；对自己使用的牌如自杀，闪救不了）
    if dfn.id == "shan" and atk.is_negative() and atk.dodgeable and ctx.target_of(i) == j:
        _negate(ctx, i, "shan", events)
        return

    # 2) 觉醒中防（裁定 8）：只能挡"中防挡得住的集合"+核弹；除核弹外按比例反弹
    if dfn.id == "jue_xing_zhong_fang" and _jue_xing_blocks(atk) and ctx.target_of(i) == j:
        _negate(ctx, i, "jue_xing_zhong_fang", events)
        _jue_xing_reflect(ctx, i, j, events)
        return

    # 3) 中防：可被列本来就以 zhong_fang 标注，直接查数据
    if dfn.id == "zhong_fang" and atk.has_counter("zhong_fang"):
        _negate(ctx, i, "zhong_fang", events)
        if atk.on_blocked_hit != 0:
            ctx.damage_events.append({
                "target": j, "amount": atk.on_blocked_hit, "source": i, "pre_hp": 0,
                "need": atk.shield_cost,
            })
            events.append({"t": "BLOCK_BACKLASH", "player": j, "amount": atk.on_blocked_hit})
        return

    # 4) 负运：只挡自己 blocks 清单里的牌（裁定：清单外一律挡不了），自身 -1 运照常（C7）
    if dfn.id == "fu_yun":
        if dfn.blocks.has(atk.id):
            _negate(ctx, i, "fu_yun", events)
        return

    # 5) 吸 / 超级吸
    if dfn.is_counter:
        var mult := maxi(1, dfn.steal_multiplier)
        if atk.id == "yun":
            _negate(ctx, i, "xi", events)
            ctx.state.players[j].yun += 10 * mult
            events.append({"t": "STEAL_YUN", "player": j, "amount": 10 * mult})
            return
        if atk.id == "qiang_hua_yun":
            ctx.state.players[j].yun += 10 * mult
            ctx.state.players[i].yun -= 10
            events.append({"t": "STEAL_YUN", "player": j, "amount": 10 * mult})
            return
        if atk.has_counter("xi"):
            _negate(ctx, i, "xi", events)
            # C9：降龙/降飞被吸时伤害归 0，但吸者照样 +2 运（覆盖 C10 的"按实付运数"）
            var gain: int = ctx.paid[i] * mult
            if atk.id == "jiang_long" or atk.id == "jiang_fei":
                gain = 20 * mult
            if atk.id == "fu_yun":
                # 裁定 2：负运被吸 → 扣"出吸的人" 1 运
                ctx.state.players[j].yun -= 10
                events.append({"t": "YUN", "player": j, "amount": -10})
                return
            if gain != 0:
                ctx.state.players[j].yun += gain
            events.append({"t": "STEAL_YUN", "player": j, "amount": gain})
            # 裁定 7：长攻分散被吸 → 时间分散（被吸者自下回合起每回合 -0.4，持续 k 回合，k=吸到的运数）
            if atk.time_spread > 0:
                var turns := maxi(1, gain / Units.YUN)
                ctx.state.players[i].add_effect(atk.time_spread, turns, ctx.turn + 1, j, "time_spread")
                events.append({"t": "TIME_SPREAD", "player": i, "amount": atk.time_spread, "turns": turns})
            if atk.stolen_self_yun != 0:
                ctx.state.players[i].yun += atk.stolen_self_yun
                events.append({"t": "YUN", "player": i, "amount": atk.stolen_self_yun})
            return

    # 6) 运 / 强化运挡
    if dfn.id == "yun" or dfn.id == "qiang_hua_yun":
        if atk.has_counter("yun"):
            _negate(ctx, i, "yun", events)
            if atk.yun_block == "consume":
                ctx.yun_consumed[j] = true
                events.append({"t": "YUN_CONSUMED", "player": j, "card": dfn.id})
            elif atk.yun_block == "steal_gain":
                # C23：究掐被运挡 → 抢走对方本回合获得的运
                var gained := 10 if dfn.id == "yun" else 20
                ctx.yun_consumed[j] = true
                ctx.state.players[i].yun += gained
                events.append({"t": "YUN_STOLEN", "player": i, "amount": gained})
            if atk.id == "jiang_fei":
                ctx.state.players[i].flags["fly_dragon_ready"] = true
                events.append({"t": "FLY_DRAGON_KEPT", "player": i})
            return

    # 7) 通用可被列：攻击牌.countered_by 含阻挡者 id（裁定 9 起全表走数据）
    if atk.has_counter(dfn.id):
        _negate(ctx, i, dfn.id, events)


# 觉醒中防的阻挡集合（裁定 8）：中防挡得住的全部 + 核弹
func _jue_xing_blocks(atk: SkillDef) -> bool:
    return atk.has_counter("zhong_fang") or atk.has_counter("jue_xing_zhong_fang")


func _jue_xing_reflect(ctx: ResolutionContext, i: int, j: int, events: Array) -> void:
    var dfn: SkillDef = ctx.defs[j]
    var atk: SkillDef = ctx.defs[i]

    # 比心：反弹使对面扣 1 运（沿用比心的 -3 运下限）
    if atk.id == "bi_xin":
        var p := ctx.state.players[i]
        if p.yun > -30:
            p.yun = maxi(p.yun - Units.YUN, -30)
        events.append({"t": "REFLECT_YUN", "player": i, "amount": -Units.YUN})
        return

    # 鄙视：反弹回去就是让对面下回合强制空过（什么都不出），与鄙视自身效果一致
    if atk.id == "bi_shi":
        ctx.state.players[i].skip_turn = ctx.turn + 1
        events.append({"t": "REFLECT_SKIP", "player": i})
        return

    var base := _card_damage_amount(ctx, atk)
    if base <= 0 or dfn.reflect_percent <= 0:
        return
    var reflect := mini(base * dfn.reflect_percent / Units.PERCENT, dfn.reflect_cap)
    if reflect <= 0:
        return
    ctx.damage_events.append({
        "target": i, "amount": reflect, "source": j, "pre_hp": 0,
        "need": dfn.shield_cost,
    })
    events.append({"t": "REFLECT", "player": j, "amount": reflect})


# 反弹基数 = 该牌本回合的牌面伤害（多段求和；三棱镜按公式现算）
func _card_damage_amount(ctx: ResolutionContext, atk: SkillDef) -> int:
    if atk.id == "san_leng_jing":
        return maxi(0, 40 + 30 * _prism_k(ctx))
    var total := 0
    for op in atk.ops:
        var kind := str(op.get("op", ""))
        if kind == "DMG" or kind == "TRUE_DMG":
            var amount := int(op.get("amount", 0))
            if ctx.kui_mult > 1:
                amount *= ctx.kui_mult
            total += amount
    return total


# —— 6 资源与状态 ——
func _phase_resource(ctx: ResolutionContext, events: Array, ledger: HpLedger) -> void:
    # 勾魂必须晚于本回合的运结算，否则"本回合获得的运"夺不到（技能表备注）
    var steal_all: Array = []
    for i in 2:
        var d: SkillDef = ctx.defs[i]
        if d == null:
            continue
        if d.id == "gui_pai" or d.id == "shen_zhi_gui_pai":
            continue

        var o := ctx.owner_of(i)
        var tgt := ctx.target_of(i)

        # 三棱镜被挡：附带效果照常
        if ctx.negated[i] and d.id == "san_leng_jing":
            _prism_blocked_side(ctx, events, ledger)
            continue

        # 桃桃（过程中）：永久解除自己身上的偷袭/C4（C17）
        if d.id == "tao_tao":
            var cleared := ctx.state.players[o].clear_dots()
            if cleared > 0:
                events.append({"t": "DOT_CLEARED", "player": o, "count": cleared})

        for op in d.ops:
            var kind := str(op.get("op", ""))
            var amount := int(op.get("amount", 0))
            if ctx.kui_mult > 1 and _kui_scalable(kind):
                amount *= ctx.kui_mult

            if ctx.negated[i]:
                if ctx.blocked_by[i] == "shan":
                    continue
                var keep := false
                if kind == "TRUE_DMG" or bool(op.get("true_dmg", false)):
                    keep = true                      # B9：真伤只受闪约束
                elif bool(op.get("on_blocked", false)):
                    keep = true                      # C32：定海被防仍加血
                elif kind == "PRC_DMG" and ctx.blocked_by[i] == "yun":
                    keep = true                      # 毒药被运挡 → 40%
                if not keep:
                    continue

            var combo_ok := ComboMatcher.suffix_matches(ctx.state.players[i].history, d.combo)
            if bool(op.get("combo_only", false)) and not combo_ok:
                continue
            if bool(op.get("no_combo", false)) and combo_ok:
                continue

            match kind:
                "DMG":
                    ctx.damage_events.append({
                        "target": tgt, "amount": amount, "source": o, "pre_hp": 0,
                        "need": d.shield_cost,
                    })
                "TRUE_DMG":
                    ctx.damage_events.append({
                        "target": tgt, "amount": amount, "source": o, "pre_hp": 0,
                        "true_dmg": true, "need": d.shield_cost,
                    })
                "PRC_DMG":
                    var pct := int(op.get("percent", 80))
                    if ctx.negated[i] and ctx.blocked_by[i] == "yun":
                        pct = int(op.get("blocked_percent", 40))
                    var base := maxi(0, ctx.state.players[tgt].hp)
                    var dmg := base * pct / Units.PERCENT
                    ctx.damage_events.append({
                        "target": tgt, "amount": dmg, "source": o, "pre_hp": 0,
                        "ratio": pct, "need": d.shield_cost,
                    })
                "HEAL":
                    ledger.apply(o, amount)
                    events.append({"t": "HEAL", "player": o, "amount": amount})
                "HEAL_ALL":
                    for k in 2:
                        ledger.apply(k, amount)
                        events.append({"t": "HEAL", "player": k, "amount": amount})
                "YUN_ADD":
                    if ctx.yun_consumed[i] and (d.id == "yun" or d.id == "qiang_hua_yun"):
                        events.append({"t": "YUN_CONSUMED", "player": i, "card": d.id, "amount": amount})
                    else:
                        ctx.state.players[o].yun += amount
                        events.append({"t": "YUN", "player": o, "amount": amount})
                "YUN_ENEMY":
                    ctx.state.players[tgt].yun += amount
                    events.append({"t": "YUN", "player": tgt, "amount": amount, "from": o})
                "YUN_STEAL_ALL":
                    steal_all.append({"o": o, "tgt": tgt})
                "YUN_MINUS":
                    var v := ctx.state.players[tgt]
                    var floor_v := int(op.get("floor", -30))
                    if v.yun > floor_v:
                        v.yun = maxi(v.yun + amount, floor_v)
                    events.append({"t": "YUN", "player": tgt, "amount": amount, "capped": true})
                "SHIELD_ADD":
                    ctx.state.players[o].shields += 1
                    events.append({"t": "SHIELD_ADD", "player": o})
                "DOT":
                    ctx.state.players[tgt].add_dot(amount, int(op.get("turns", 5)), o, ctx.turn)
                    events.append({
                        "t": "DOT_APPLY", "player": tgt, "amount": amount,
                        "turns": int(op.get("turns", 5)),
                    })
                "DELAY_DMG":
                    var wait := int(op.get("turns", 3))
                    ctx.state.players[tgt].add_effect(amount, 1, ctx.turn + wait, o, "c4")
                    events.append({
                        "t": "C4_APPLY", "player": tgt, "amount": amount, "fire_turn": ctx.turn + wait,
                    })
                "IMMUNE_LE":
                    ctx.state.players[o].immune_le = amount
                    events.append({"t": "IMMUNE_UP", "player": o, "amount": amount})
                "PRISM":
                    _prism_damage(ctx, i, events)
                "CODE_KILL":
                    ctx.code_kill[tgt] = true
                    events.append({"t": "CODE_KILL", "target": tgt, "source": o})
                "SELF_CODE_KILL":
                    ctx.code_kill[o] = true
                    events.append({"t": "CODE_KILL", "target": o, "source": o, "self": true})
                "COST_HALF":
                    ctx.state.players[o].cost_percent = int(op.get("percent", 50))
                    events.append({"t": "COST_HALF", "player": o})
                "SCHEDULE_YUN":
                    var p := ctx.state.players[o]
                    p.yun += amount
                    events.append({"t": "YUN", "player": o, "amount": amount})
                    for n in range(1, int(op.get("turns", 2))):
                        p.schedule_yun(amount, ctx.turn + n)
                    events.append({"t": "SCHEDULE_YUN", "player": o, "amount": amount,
                        "turns": int(op.get("turns", 2))})
                "CANNON_DISCOUNT":
                    var p2 := ctx.state.players[o]
                    p2.cannon_from = ctx.turn + 1
                    p2.cannon_until = ctx.turn + 1 + int(op.get("turns", 3))
                    events.append({"t": "CANNON_BUFF", "player": o,
                        "until": p2.cannon_until})
                "SKIP_NEXT":
                    ctx.state.players[tgt].skip_turn = ctx.turn + 1
                    events.append({"t": "SKIP_NEXT", "player": tgt, "turn": ctx.turn + 1})
                "DOT_CLEAR_MAX_HP":
                    var p3 := ctx.state.players[o]
                    var n := p3.clear_dots()
                    var healed := maxi(0, p3.hp_max_ever - p3.hp)
                    p3.hp = p3.hp_max_ever
                    events.append({"t": "PURIFY", "player": o, "cleared": n, "healed": healed})
                "IMMUNE_COST_RANGE", "NEGATE_ALL", "REFLECT", "KUI":
                    pass
                _:
                    pass

    for sv in steal_all:
        var so: int = int(sv["o"])
        var st: int = int(sv["tgt"])
        var victim := ctx.state.players[st]
        var stolen := maxi(victim.yun, 0)
        victim.yun = 0
        ctx.state.players[so].yun += stolen
        events.append({"t": "STEAL_YUN", "player": so, "amount": stolen, "all": true})


# 神之龟派翻倍的范围（C34）：只翻"牌面写死的 ±血量 / ±运"。
# 不翻：比例伤害（毒药）、公式伤害（三棱镜）、阈值（酒 ≤1、护身符 2~3）、
#       计数与时长（盾数、回合数、费用百分比）。
static func _kui_scalable(kind: String) -> bool:
    return kind in ["DMG", "TRUE_DMG", "HEAL", "HEAL_ALL", "YUN_ADD", "YUN_ENEMY",
        "YUN_MINUS", "DOT", "DELAY_DMG", "SCHEDULE_YUN"]


func _prism_k(ctx: ResolutionContext) -> int:
    var k := 0
    for i in 2:
        # 裁定 1：被龟派取走的牌不算"出过"，不进 k
        if ctx.is_kui_taken(i):
            continue
        var c := ctx.cards[i]
        if c == "yun" or c == "qiang_hua_yun":
            k += 1
        elif c == "fu_yun":
            k -= 1
    return k


func _prism_damage(ctx: ResolutionContext, i: int, events: Array) -> void:
    var k := _prism_k(ctx)
    var dmg := 40 + 30 * k
    ctx.damage_events.append({
        "target": ctx.target_of(i), "amount": dmg, "source": ctx.owner_of(i),
        "pre_hp": 0, "formula": "prism", "need": ctx.defs[i].shield_cost,
    })
    events.append({"t": "PRISM", "player": ctx.owner_of(i), "k": k, "amount": dmg})


func _prism_blocked_side(ctx: ResolutionContext, events: Array, ledger: HpLedger) -> void:
    # 走伤害事件而不是直接扣血：否则不触发盾保命（B8）
    for c in 2:
        if ctx.is_kui_taken(c):
            continue
        var who := ctx.cards[c]
        if who == "yun" or who == "qiang_hua_yun":
            ctx.damage_events.append({
                "target": c, "amount": 20, "source": 1 - c, "pre_hp": 0,
                "need": 1, "side": true,
            })
        elif who == "fu_yun":
            ledger.apply(c, 20)
            events.append({"t": "HEAL", "player": c, "amount": 20, "side": true})


# —— 7 伤害互拼（含 dot / C4 当期）——
# 作者裁定 4：不再"所有伤害同时结算"，改为比大小——
#   比的量 = 本回合每个人对对方造成的伤害总量（含 dot 当期跳伤）
#   总量相同 → 互相抵消，双方伤害全部不生效
#   总量不同 → 只有高的一方生效，低的一方伤害归零（高方伤害完整生效，不按差额）
func _phase_damage(ctx: ResolutionContext, events: Array, ledger: HpLedger) -> void:
    for i in 2:
        var p := ctx.state.players[i]
        var keep: Array[Dictionary] = []
        for e in p.dots:
            if ctx.turn < int(e.get("first", 0)):
                keep.append(e)
                continue
            if int(e["left"]) > 0:
                ctx.damage_events.append({
                    "target": i, "amount": int(e["amount"]), "source": int(e["source"]),
                    "pre_hp": 0, "dot": true, "kind": str(e.get("kind", "dot")), "need": 1,
                })
                e["left"] = int(e["left"]) - 1
            if int(e["left"]) > 0:
                keep.append(e)
            else:
                events.append({"t": "DOT_END", "player": i, "kind": str(e.get("kind", "dot"))})
        p.dots = keep

    # ① 按归属方汇总总量（源=被龟派后的效果归属者，所以龟派的反噬天然算在龟派者头上）
    var totals: Array[int] = [0, 0]
    for ev in ctx.damage_events:
        var src := int(ev["source"])
        if src != int(ev["target"]):
            totals[src] += int(ev["amount"])

    # ② 比大小：平则全抵，不平则只有高的一方留下
    #    注意"自己挂给自己的 dot"（源=目标）不参与比较，永远照跳。
    var applied: Array = []
    if totals[0] == totals[1]:
        events.append({"t": "DAMAGE_TIE", "totals": [totals[0], totals[1]]})
        for ev in ctx.damage_events:
            if int(ev["source"]) == int(ev["target"]):
                applied.append(ev)
    else:
        var loser := 0 if totals[0] < totals[1] else 1
        events.append({"t": "DAMAGE_RACE", "totals": [totals[0], totals[1]], "loser": loser})
        for ev in ctx.damage_events:
            if int(ev["source"]) == loser and int(ev["target"]) != loser:
                continue
            applied.append(ev)

    # 按"一次攻击"分组（C16）：同一张牌打同一目标的多段合并；dot 每跳独立成组
    var groups: Array = []
    for ev in applied:
        var is_dot := bool(ev.get("dot", false))
        var gkey := ("dot#%d" % groups.size()) if is_dot else ("%d>%d" % [int(ev["source"]), int(ev["target"])])
        var idx := -1
        if not is_dot:
            for gi in groups.size():
                if str(groups[gi]["key"]) == gkey:
                    idx = gi
                    break
        if idx < 0:
            groups.append({
                "key": gkey, "target": int(ev["target"]), "source": int(ev["source"]),
                "total": 0, "need": int(ev.get("need", 1)), "events": [],
            })
            idx = groups.size() - 1
        groups[idx]["total"] = int(groups[idx]["total"]) + absi(int(ev["amount"]))
        groups[idx]["need"] = maxi(int(groups[idx]["need"]), int(ev.get("need", 1)))
        groups[idx]["events"].append(ev)

    for g in groups:
        var tgt: int = int(g["target"])
        var p := ctx.state.players[tgt]
        var total: int = int(g["total"])

        # 酒：整组按总伤害判（B9）
        if not ctx.time_stopped and p.immune_le >= 0 and total <= p.immune_le:
            for ev in g["events"]:
                events.append({"t": "IMMUNE", "player": tgt, "amount": int(ev["amount"])})
            continue

        var start_hp := p.hp
        for ev in g["events"]:
            var amount: int = int(ev["amount"])
            ev["pre_hp"] = p.hp
            if amount >= 0:
                ledger.apply(tgt, -amount)
                events.append({
                    "t": "DAMAGE", "target": tgt, "amount": amount,
                    "hp": p.hp, "dot": bool(ev.get("dot", false)),
                })
            else:
                ledger.apply(tgt, -amount)
                events.append({"t": "HEAL", "player": tgt, "amount": -amount})

        # 盾保命（B8 / B4 第 8 步）：一次攻击只消耗一次盾，恢复到该次攻击前（C37）
        if p.hp <= 0:
            var need: int = int(g["need"])
            if p.shields >= need:
                p.shields -= need
                p.hp = start_hp
                events.append({"t": "SHIELD_SAVE", "player": tgt, "used": need})
            else:
                events.append({
                    "t": "SHIELD_FAIL", "player": tgt, "need": need, "have": p.shields,
                })


func _phase_death(ctx: ResolutionContext, events: Array) -> String:
    var dead0 := ctx.state.players[0].hp <= 0 or ctx.code_kill[0]
    var dead1 := ctx.state.players[1].hp <= 0 or ctx.code_kill[1]

    if not dead0 and not dead1:
        return "continue"

    if dead0 and dead1:
        if ctx.code_kill[0] != ctx.code_kill[1]:
            var winner := 0 if ctx.code_kill[0] else 1
            _end(ctx.state, winner, "code_kill_priority")
            events.append({"t": "GAME_OVER", "winner": winner, "reason": "code_kill_priority"})
            return "win"
        if ctx.state.players[0].hp == ctx.state.players[1].hp:
            return "tie"
        var loser := 0 if ctx.state.players[0].hp < ctx.state.players[1].hp else 1
        _end(ctx.state, 1 - loser, "more_negative")
        events.append({"t": "GAME_OVER", "winner": 1 - loser, "reason": "more_negative"})
        return "win"

    var w := 1 if dead0 else 0
    _end(ctx.state, w, "death")
    events.append({"t": "GAME_OVER", "winner": w, "reason": "death"})
    return "win"


func _phase_settle(ctx: ResolutionContext, events: Array) -> void:
    var st := ctx.state
    for i in 2:
        var p := st.players[i]
        var cid := ctx.cards[i]
        p.immune_le = -1

        var d: SkillDef = ctx.defs[i]
        # 裁定 1：被龟派取走的牌不算"出过"（B2 三处语义：连招推进 / 冷却 / 三棱镜 k）
        if not ctx.is_kui_taken(i):
            p.history.append(cid)
            if d != null:
                var pool := d.pool_id if d.pool_id != "" else d.id
                p.remember_played(pool, st.turn)

        if cid == "dun":
            p.shield_bought_once = true

        p.reset_pending()

    st.turn += 1

    # 新回合开始前，发放预约运（向运葵；不受扭转时空影响，C19）
    for i in 2:
        var p := st.players[i]
        var keep: Array[Dictionary] = []
        for e in p.scheduled_yun:
            if int(e["turn"]) == st.turn:
                p.yun += int(e["amount"])
                events.append({"t": "YUN", "player": i, "amount": int(e["amount"]), "scheduled": true})
            else:
                keep.append(e)
        p.scheduled_yun = keep
        if p.skip_turn >= 0 and p.skip_turn < st.turn:
            p.skip_turn = -1

    events.append({"t": "SETTLE", "turn": st.turn})


func _end(state: DuelState, winner: int, reason: String) -> void:
    state.over = true
    state.winner = winner
    state.end_reason = reason
