class_name OpponentModel
extends RefCounted

# 对手习惯模型：只要 app 开着，就持续学习人类对手的出招习惯。
#
# 学什么（都是可量化的倾向，不是"读心"）：
#   1. 全局出牌偏好：每张牌被出的次数（带轻微衰减，允许习惯改变）
#   2. 情境偏好：在"回合阶段 / 血量区间 / 运区间 / 上手性质"这样的情境下偏好哪张牌
#   3. 套路度：连续出同一张牌、最高重复率 → 越高说明越容易被预判
#   4. 攻防倾向：攻击 / 防御 / 资源 / 治疗 的比例
#   5. 连招意图：是否在铺长连招的前置（中防→吸→运…）
#
# 怎么用：AI 选牌时，把"对手在这个情境下的习惯分布"按权重混进自己的策略分布里。
# 习惯越明显、样本越多，混入权重越高（自适应置信度），避免用噪声当信号。
#
# 持久化：OpponentStore 负责存 user://，带 schema 版本号与迁移函数。

const SCHEMA_VERSION := 1
const DECAY := 0.97            # 每次对局结束轻微衰减：习惯是趋势，不是永久标签
const MIN_OBS_FOR_CONF := 8.0  # 少于这么多样本不信任该情境
const MAX_MIX := 0.35         # 习惯模型最多能占决策权重的上限

# 全局牌频（float 计数，便于衰减）
var card_counts: Dictionary = {}
var card_total := 0.0

# 情境 → {card_id: count}
var context_counts: Dictionary = {}
var context_total: Dictionary = {}

# 攻防倾向累计
var tag_counts: Dictionary = {}

# 连招意图：铺垫了前置牌的次数
var combo_setup := 0.0
var combo_finish := 0.0

# 套路度
var last_card := ""
var streak := 0
var max_streak := 0
var repeat_pairs := 0        # 与上一手相同的次数
var decisions := 0

# 每局结束调用：衰减 + 局数统计
var matches := 0


# ---------- 记录 ----------

func observe(context: String, card_id: String, tags: Array, is_combo_setup: bool,
        is_combo_finish: bool) -> void:
    if card_id == "":
        return
    decisions += 1
    card_counts[card_id] = float(card_counts.get(card_id, 0.0)) + 1.0
    card_total += 1.0

    if not context_counts.has(context):
        context_counts[context] = {}
        context_total[context] = 0.0
    var d: Dictionary = context_counts[context]
    d[card_id] = float(d.get(card_id, 0.0)) + 1.0
    context_total[context] += 1.0

    for t in tags:
        tag_counts[t] = float(tag_counts.get(t, 0.0)) + 1.0

    if card_id == last_card:
        repeat_pairs += 1.0
        streak += 1
        max_streak = maxf(max_streak, float(streak))
    else:
        streak = 0
    last_card = card_id

    if is_combo_setup:
        combo_setup += 1.0
    if is_combo_finish:
        combo_finish += 1.0


func end_match() -> void:
    matches += 1
    # 衰减：保留历史，但给新趋势留出空间
    for k in card_counts.keys():
        card_counts[k] = float(card_counts[k]) * DECAY
    card_total *= DECAY
    for ctx in context_counts.keys():
        var d: Dictionary = context_counts[ctx]
        for k in d.keys():
            d[k] = float(d[k]) * DECAY
        context_total[ctx] = float(context_total[ctx]) * DECAY
    for k in tag_counts.keys():
        tag_counts[k] = float(tag_counts[k]) * DECAY
    streak = 0
    last_card = ""


# ---------- 查询 ----------

# 某张牌在给定情境下的倾向（0~1）；样本不足时退回到全局倾向
func tendency(card_id: String, context: String) -> float:
    var ctx_n := float(context_total.get(context, 0.0))
    if ctx_n > 0.0:
        var d: Dictionary = context_counts.get(context, {})
        var c := float(d.get(card_id, 0.0))
        return c / ctx_n
    if card_total > 0.0:
        return float(card_counts.get(card_id, 0.0)) / card_total
    return 0.0


# 该情境下最可能被出的牌（用于判断"可预判程度"）
func top_card(context: String) -> String:
    var d: Dictionary = context_counts.get(context, {})
    var best := ""
    var best_n := -1.0
    for k in d.keys():
        var n := float(d[k])
        if n > best_n:
            best_n = n
            best = str(k)
    return best


# 习惯模型的置信度：样本够多且倾向够明显 → 接近 1
func confidence(context: String) -> float:
    var ctx_n := float(context_total.get(context, 0.0))
    if ctx_n < MIN_OBS_FOR_CONF or card_total <= 0.0:
        return 0.0
    var top := 0.0
    var d: Dictionary = context_counts.get(context, {})
    for k in d.keys():
        top = maxf(top, float(d[k]))
    if top <= 0.0:
        return 0.0
    var share := top / ctx_n
    # 观察到的牌种越多，单一牌的占比越低 → 越难预判
    var kinds := float(d.size())
    var baseline := 1.0 / maxf(1.0, kinds)
    var excess := (share - baseline) / maxf(0.0001, 1.0 - baseline)
    return clampf(excess, 0.0, 1.0) * clampf(ctx_n / (MIN_OBS_FOR_CONF * 4.0), 0.0, 1.0)


# 给 AI 用的混合权重：越有把握，混入越多
func mix_weight(context: String) -> float:
    return MAX_MIX * confidence(context)


# 人类玩家的出牌习惯分布（用于 AI 混合）
func habit_distribution(context: String, legal: Array) -> Array:
    var out: Array = []
    var total := 0.0
    for c in legal:
        var t := tendency(str(c), context)
        out.append(t)
        total += t
    if total <= 0.0:
        return []
    for i in out.size():
        out[i] = float(out[i]) / total
    return out


# 套路度：连续重复的比例（越高越容易被预判）
func predictability() -> float:
    if decisions <= 0:
        return 0.0
    return clampf(repeat_pairs / float(decisions), 0.0, 1.0)


func tag_share(tag: String) -> float:
    var tot := 0.0
    for k in tag_counts.keys():
        tot += float(tag_counts[k])
    if tot <= 0.0:
        return 0.0
    return float(tag_counts.get(tag, 0.0)) / tot


# 人类最常用的 5 张牌
func top_cards(n: int = 5) -> Array:
    var arr: Array = []
    for k in card_counts.keys():
        arr.append([str(k), float(card_counts[k])])
    arr.sort_custom(func(a, b): return float(a[1]) > float(b[1]))
    return arr.slice(0, mini(n, arr.size()))


# ---------- 序列化 ----------

func to_dict() -> Dictionary:
    return {
        "schema_version": SCHEMA_VERSION,
        "card_counts": card_counts,
        "card_total": card_total,
        "context_counts": context_counts,
        "context_total": context_total,
        "tag_counts": tag_counts,
        "combo_setup": combo_setup,
        "combo_finish": combo_finish,
        "max_streak": max_streak,
        "repeat_pairs": repeat_pairs,
        "decisions": decisions,
        "matches": matches,
    }


func from_dict(d: Dictionary) -> void:
    card_counts = d.get("card_counts", {})
    card_total = float(d.get("card_total", 0.0))
    context_counts = d.get("context_counts", {})
    context_total = d.get("context_total", {})
    tag_counts = d.get("tag_counts", {})
    combo_setup = float(d.get("combo_setup", 0.0))
    combo_finish = float(d.get("combo_finish", 0.0))
    max_streak = int(d.get("max_streak", 0))
    repeat_pairs = float(d.get("repeat_pairs", 0.0))
    decisions = int(d.get("decisions", 0))
    matches = int(d.get("matches", 0))
    last_card = ""
    streak = 0
