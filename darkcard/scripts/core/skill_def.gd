class_name SkillDef
extends RefCounted

# 数值口径（全局定点，禁 float）：
#   cost / 运：1 运 = 10（0.1 精度）
#   HP / 伤害：1 血 = 100（0.01 精度）

var id: String = ""
var display_name: String = ""
var desc: String = ""
var cost: int = 0
var cost_kind: String = "fixed"      # fixed | all_in
var cost_rule: String = ""           # "" | shield_price | cannon_price
var countered_by: Array[String] = []
var tags: Array[String] = []
var ops: Array[Dictionary] = []
var combo: Array[String] = []
var combo_optional: bool = false     # 连招不满足也能出（究掐）
var cooldown: int = 0
var pool_id: String = ""
var shield_cost: int = 1
var notes: String = ""

# 龟派重定向用的目标语义：self | enemy | global
var target: String = "self"

# —— 牌级机制字段 ——
var kill_tag: String = ""            # "nengbao"：命中该 tag 的牌 → 代码杀（掐类）
var yun_block: String = ""           # "" | "consume"（运挡为抵消）| "steal_gain"（究掐）
var dodgeable: bool = true           # 手枪为 false（不可被闪）
var on_blocked_hit: int = 0          # 被挡时，挡者反受伤害（长攻分散）
var stolen_self_yun: int = 0         # 被吸时自己获得运（微镖）
var steal_multiplier: int = 1        # 超级吸：吸到的运 ×2
var is_counter: bool = false         # 反制型（吸/超级吸）

# —— 作者裁定（2026-10-25）新增字段 ——
var blocks: Array[String] = []       # 阻挡者自己的可挡清单（负运；不用 countered_by 是因为语义相反）
var time_spread: int = 0             # 被吸后的"时间分散"每回合伤害（长攻分散）
var reflect_percent: int = 0         # 被挡反弹比例（觉醒中防）
var reflect_cap: int = 0             # 反弹上限（觉醒中防）


static func from_dict(src: Dictionary) -> SkillDef:
    var s := SkillDef.new()
    s.id = str(src.get("id", ""))
    s.display_name = str(src.get("name", s.id))
    s.desc = str(src.get("desc", ""))
    s.cost = int(src.get("cost", 0))
    s.cost_kind = str(src.get("cost_kind", "fixed"))
    s.cost_rule = str(src.get("cost_rule", ""))
    s.cooldown = int(src.get("cooldown", 0))
    s.pool_id = str(src.get("pool_id", ""))
    s.shield_cost = int(src.get("shield_cost", 1))
    s.notes = str(src.get("notes", ""))
    s.target = str(src.get("target", "self"))
    s.combo_optional = bool(src.get("combo_optional", false))
    s.kill_tag = str(src.get("kill_tag", ""))
    s.yun_block = str(src.get("yun_block", ""))
    s.dodgeable = bool(src.get("dodgeable", true))
    s.on_blocked_hit = int(src.get("on_blocked_hit", 0))
    s.stolen_self_yun = int(src.get("stolen_self_yun", 0))
    s.steal_multiplier = int(src.get("steal_multiplier", 1))
    s.is_counter = bool(src.get("is_counter", false))
    s.time_spread = int(src.get("time_spread", 0))

    for key in ["countered_by", "blocks", "tags", "combo"]:
        var arr = src.get(key, [])
        if arr is Array:
            for v in arr:
                match key:
                    "countered_by": s.countered_by.append(str(v))
                    "blocks": s.blocks.append(str(v))
                    "tags": s.tags.append(str(v))
                    "combo": s.combo.append(str(v))

    var raw_ops = src.get("ops", [])
    if raw_ops is Array:
        for o in raw_ops:
            if o is Dictionary:
                var op: Dictionary = o.duplicate(true)
                s.ops.append(op)
                if str(op.get("op", "")) == "REFLECT":
                    s.reflect_percent = int(op.get("percent", 0))
                    s.reflect_cap = int(op.get("cap", 0))

    return s


func has_counter(card_id: String) -> bool:
    return countered_by.has(card_id)


func is_negative() -> bool:
    return tags.has("negative")


func is_dot() -> bool:
    for o in ops:
        if str(o.get("op", "")) == "DOT":
            return true
    return false
