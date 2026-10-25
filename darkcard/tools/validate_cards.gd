extends SceneTree

# 卡表校验：godot --headless --path <proj> --script res://tools/validate_cards.gd

const KNOWN_OPS := ["DMG", "TRUE_DMG", "PRC_DMG", "HEAL", "HEAL_ALL", "YUN_ADD", "YUN_ENEMY",
    "YUN_STEAL_ALL", "YUN_MINUS", "SHIELD_ADD", "CODE_KILL", "SELF_CODE_KILL",
    "DOT", "DELAY_DMG", "IMMUNE_LE", "IMMUNE_COST_RANGE", "PRISM", "COST_HALF",
    "SCHEDULE_YUN", "CANNON_DISCOUNT", "SKIP_NEXT", "NEGATE_ALL", "REFLECT",
    "DOT_CLEAR_MAX_HP", "KUI"]
const NEGATIVE_OK := ["YUN_ENEMY", "YUN_MINUS"]
# REFLECT 带 percent/cap 不带 amount（作者裁定 8：比例反弹 + 上限）
const NO_AMOUNT := ["YUN_STEAL_ALL", "SELF_CODE_KILL", "PRISM", "NEGATE_ALL",
    "DOT_CLEAR_MAX_HP", "KUI", "SKIP_NEXT", "IMMUNE_COST_RANGE", "PRC_DMG",
    "CANNON_DISCOUNT", "COST_HALF", "REFLECT"]
const KNOWN_COST_KINDS := ["fixed", "all_in"]
const KNOWN_COST_RULES := ["", "shield_price", "cannon_price"]
const KNOWN_YUN_BLOCK := ["", "consume", "steal_gain"]
const KNOWN_TARGETS := ["self", "enemy", "global"]


func _initialize() -> void:
    var db := CardDB.load_all()
    var errors: Array[String] = []

    if db.size() == 0:
        errors.append("no cards loaded")

    var seen := {}
    var tag_owner := {}
    for cid in db.order:
        var d := db.get_def(cid)
        if seen.has(cid):
            errors.append("duplicate id: " + cid)
        seen[cid] = true

        if d.display_name == "":
            errors.append("%s: missing name" % cid)
        if d.desc == "":
            errors.append("%s: missing desc" % cid)
        if d.cost < 0:
            errors.append("%s: negative cost" % cid)
        if d.cost % 5 != 0:
            errors.append("%s: cost must be 0.5 step" % cid)
        if not KNOWN_COST_KINDS.has(d.cost_kind):
            errors.append("%s: unknown cost_kind %s" % [cid, d.cost_kind])
        if not KNOWN_COST_RULES.has(d.cost_rule):
            errors.append("%s: unknown cost_rule %s" % [cid, d.cost_rule])
        if not KNOWN_YUN_BLOCK.has(d.yun_block):
            errors.append("%s: unknown yun_block %s" % [cid, d.yun_block])
        if not KNOWN_TARGETS.has(d.target):
            errors.append("%s: unknown target %s" % [cid, d.target])
        if d.cost_kind == "all_in" and d.cost <= 0:
            errors.append("%s: all_in needs a positive nominal cost" % cid)

        for c in d.countered_by:
            if not db.has_card(c):
                errors.append("%s: countered_by missing %s" % [cid, c])
            if c == cid:
                errors.append("%s: counters itself" % cid)
        for c in d.blocks:
            if not db.has_card(c):
                errors.append("%s: blocks missing %s" % [cid, c])
            if c == cid:
                errors.append("%s: blocks itself" % cid)
        if d.blocks.size() > 0 and d.tags.has("attack"):
            errors.append("%s: attack cards should use countered_by, not blocks" % cid)
        if d.time_spread < 0:
            errors.append("%s: negative time_spread" % cid)
        if d.time_spread > 0 and d.countered_by.has("xi") == false:
            errors.append("%s: time_spread needs xi in countered_by" % cid)
        if d.reflect_percent < 0 or d.reflect_percent > 100:
            errors.append("%s: reflect_percent out of range" % cid)
        if d.reflect_percent > 0 and d.reflect_cap <= 0:
            errors.append("%s: reflect_percent needs a positive reflect_cap" % cid)
        if d.stolen_yun_to != "self" and d.stolen_yun_to != "stole":
            errors.append("%s: unknown stolen_yun_to %s" % [cid, d.stolen_yun_to])
        if d.stolen_self_yun != 0 and d.countered_by.has("xi") == false:
            errors.append("%s: stolen_self_yun needs xi in countered_by" % cid)
        for c in d.combo:
            if not db.has_card(c):
                errors.append("%s: combo missing %s" % [cid, c])
        for t in d.tags:
            if t in ["attack", "defense", "heal", "resource", "counter", "combo",
                    "positive", "negative", "dot"]:
                continue
            tag_owner[t] = cid

        for op in d.ops:
            var kind := str(op.get("op", ""))
            if not KNOWN_OPS.has(kind):
                errors.append("%s: unknown op %s" % [cid, kind])
                continue
            if kind == "REFLECT":
                var pct := int(op.get("percent", 0))
                if pct <= 0 or pct > 100:
                    errors.append("%s: REFLECT percent out of range" % cid)
                if int(op.get("cap", 0)) <= 0:
                    errors.append("%s: REFLECT needs a positive cap" % cid)
                continue
            if NO_AMOUNT.has(kind):
                continue
            if not op.has("amount"):
                errors.append("%s: op %s missing amount" % [cid, kind])
                continue
            var amount := int(op.get("amount", 0))
            if NEGATIVE_OK.has(kind):
                if amount >= 0:
                    errors.append("%s: %s needs negative amount" % [cid, kind])
            elif amount <= 0:
                errors.append("%s: op %s amount must be positive" % [cid, kind])
            if kind == "DOT" and int(op.get("turns", 0)) <= 0:
                errors.append("%s: DOT needs turns" % cid)
            if kind == "DELAY_DMG" and int(op.get("turns", 0)) <= 0:
                errors.append("%s: DELAY_DMG needs turns" % cid)

        if d.kill_tag != "" and not _tag_exists(db, d.kill_tag):
            errors.append("%s: kill_tag %s has no owner" % [cid, d.kill_tag])

    var by_cost := {}
    for cid in db.order:
        var c := db.get_def(cid).cost / 10
        by_cost[c] = int(by_cost.get(c, 0)) + 1

    print("cards=%d errors=%d" % [db.size(), errors.size()])
    var keys := by_cost.keys()
    keys.sort()
    var dist := ""
    for k in keys:
        dist += "%s费=%d  " % [k, by_cost[k]]
    print("cost> " + dist)
    for e in errors:
        printerr("  - " + e)
    quit(0 if errors.is_empty() else 1)


func _tag_exists(db: CardDB, tag: String) -> bool:
    for cid in db.order:
        if db.get_def(cid).tags.has(tag):
            return true
    return false
