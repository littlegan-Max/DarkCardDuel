class_name SimpleAI
extends RefCounted

# 演示用启发式 AI：出牌评分 + 15% 随机失误。
# 随机项全部走外部 RNG，保证同种子可复现。

const BLUNDER_RATE := 0.15


static func choose(duel: Duel, player: int, rng: RandomNumberGenerator, profile: String = "balanced") -> String:
    var legal := duel.legal_cards(player)
    if legal.is_empty():
        return ""

    # 随机失误：打破"双方永远出同一张牌 → 同死作废 → 再来一次"的镜像停滞
    if rng.randf() < BLUNDER_RATE:
        return legal[rng.randi_range(0, legal.size() - 1)]

    var me: PlayerState = duel.state.players[player]
    var opp: PlayerState = duel.state.players[1 - player]

    var dmg_w := 11.0
    var def_w := 5.0
    var heal_w := 6.0
    var yun_w := 4.0
    if profile == "aggro":
        dmg_w = 13.0
        def_w = 2.0
        heal_w = 3.0
        yun_w = 3.0
    elif profile == "turtle":
        dmg_w = 9.0
        def_w = 9.0
        heal_w = 10.0
        yun_w = 6.0

    var opp_last := ""
    if not opp.history.is_empty():
        opp_last = opp.history[opp.history.size() - 1]

    var best := ""
    var best_score := -99999.0

    for cid in legal:
        var d: SkillDef = duel.db.get_def(cid)
        if d == null:
            continue

        var score := rng.randf_range(0.0, 2.5)

        for op in d.ops:
            var kind := str(op.get("op", ""))
            var amount := int(op.get("amount", 0))
            match kind:
                "DMG":
                    var dmg := float(amount) / float(Units.HP)
                    score += dmg * dmg_w
                    if amount >= opp.hp:
                        score += 16.0
                "HEAL":
                    var heal := float(amount) / float(Units.HP)
                    var hw := heal_w if me.hp <= 120 else 2.0
                    score += heal * hw
                "HEAL_ALL":
                    # 双方都回血：净血差 0，只在劣势时当"续命"用
                    if me.hp <= 120:
                        score += 2.0
                    else:
                        score -= 2.5
                "YUN_ADD":
                    score += yun_w if me.yun < 20 else 1.0
                "YUN_ENEMY":
                    score += 3.0 if opp.yun >= 20 else 1.0
                "SHIELD_ADD":
                    score += 7.0 if me.shields == 0 else 2.0
                "DOT":
                    # 延迟伤害：按总量 60% 计，且对方血少时更值
                    var total := float(amount) * float(int(op.get("turns", 5))) / float(Units.HP)
                    score += total * dmg_w * 0.6
                "PRISM":
                    # 未知 k，按 k=0 估算 0.4 伤害
                    score += 0.4 * dmg_w
                "IMMUNE_LE":
                    score += def_w * 0.8 if opp.yun >= 10 else 1.5

        if cid == "zhong_fang" or cid == "shan":
            if opp.yun >= 20 or me.hp <= 100:
                score += def_w
            else:
                score += 0.5
        if cid == "xi":
            score += 4.0 if opp.yun >= 10 else 0.5
        # 掐类：对手上一张是乃爆才值得
        if d.kill_tag == "nengbao":
            score += 9.0 if opp_last == "nai_bao" else 0.0
        # 乃爆：对手上一张是超掐 = 送死
        if d.tags.has("nengbao") and opp_last == "chao_qia":
            score -= 20.0
        # 桃桃能解 dot（C17）
        if cid == "tao_tao" and not me.dots.is_empty():
            score += 6.0

        # 与对手上一张相同 → 大概率镜像同死，降权
        if cid == opp_last:
            score -= 7.0 if me.hp <= 100 else 3.0

        # 可被性风险：可被列越长，越容易被读中挡掉
        score -= float(d.countered_by.size()) * 2.0
        # 0 费攻击牌的机会成本：占掉本回合出牌位，却换不到资源
        if d.cost == 0 and d.tags.has("attack"):
            score -= 1.5
        # 资源规划：运不够时优先攒运，否则永远被 1 费牌锁死
        if d.tags.has("resource") and me.yun < 30:
            score += 8.0

        if d.cost_kind != "all_in":
            score -= float(duel.effective_cost(player, d)) / float(Units.YUN) * 0.7
        if cid == "yun" and me.yun >= 50:
            score -= 4.0

        if score > best_score:
            best_score = score
            best = cid

    return best
