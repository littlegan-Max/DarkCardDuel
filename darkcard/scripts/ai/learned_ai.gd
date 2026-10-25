class_name LearnedAI
extends RefCounted

# 训练策略的运行时封装：加载 policy_net.json，按混合策略采样出牌。
# 加载失败时自动退回 SimpleAI，保证游戏永远能跑。

const NET_PATH := "res://data/policy_net.json"
# 探索底噪：每个合法动作的最小权重
const EXPLORE := 0.08
# 采样温度：p ∝ q^(1/T)。T 越大分布越平，避免"同一局面永远出同一张牌"的套路感。
# 实测：T=1.0 时同局面最常出牌占比 56.8%（122 次里 122 次都是"运"），
#       T=1.4 降到 34.6%。
const TEMPERATURE := 1.4

static var _net: PolicyNet = null
static var _index: Dictionary = {}
static var _tried := false


static func is_ready() -> bool:
    _ensure()
    return _net != null and _net.loaded


static func _ensure() -> void:
    if _tried:
        return
    _tried = true
    _net = PolicyNet.new()
    if not _net.load_file(NET_PATH):
        _net = null
        return
    for i in _net.actions.size():
        _index[_net.actions[i]] = i


# habit：对手在该情境下的出牌习惯分布（与 legal 等长，缺省为空）
# mix ：混入权重（0~1），由 OpponentModel.confidence 决定
static func choose(duel: Duel, player: int, rng: RandomNumberGenerator,
        habit: Array = [], mix: float = 0.0) -> String:
    _ensure()
    if _net == null or not _net.loaded:
        return SimpleAI.choose(duel, player, rng, "turtle")

    var legal := duel.legal_cards(player)
    if legal.is_empty():
        return ""

    var idx: Array[int] = []
    var cards: Array[String] = []
    for c in legal:
        if _index.has(c):
            idx.append(int(_index[c]))
            cards.append(c)
    if idx.is_empty():
        return SimpleAI.choose(duel, player, rng, "turtle")

    if rng.randf() < EXPLORE:
        return cards[rng.randi_range(0, cards.size() - 1)]

    var feats := _net.make_features(duel, player)
    var probs := _net.probs(feats, idx)
    if probs.is_empty():
        return cards[0]

    probs = _soften(probs)
    probs = _mix_habit(probs, habit, mix)

    var r := rng.randf()
    var acc := 0.0
    for i in probs.size():
        acc += float(probs[i])
        if r <= acc:
            return cards[i]
    return cards[cards.size() - 1]


# 把"对手习惯"混进策略分布：按 mix 权重做一次混合，
# 这样 AI 会在你形成习惯的情境里提前应对，而不是随机乱打。
static func _mix_habit(probs: Array, habit: Array, mix: float) -> Array:
    if mix <= 0.0 or habit.is_empty() or habit.size() != probs.size():
        return probs
    var out: Array = []
    var total := 0.0
    for i in probs.size():
        var v := float(probs[i]) * (1.0 - mix) + float(habit[i]) * mix
        out.append(v)
        total += v
    if total <= 0.0:
        return probs
    for i in out.size():
        out[i] = float(out[i]) / total
    return out


# 温度采样：把分布压平，避免同局面重复出同一张牌
static func _soften(probs: Array) -> Array:
    if TEMPERATURE <= 1.0:
        return probs
    var q: Array = []
    var total := 0.0
    for p in probs:
        var v: float = pow(maxf(float(p), 0.000001), 1.0 / TEMPERATURE)
        q.append(v)
        total += v
    if total <= 0.0:
        return probs
    var out: Array = []
    for v in q:
        out.append(float(v) / total)
    return out
