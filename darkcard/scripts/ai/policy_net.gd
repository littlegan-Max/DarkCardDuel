class_name PolicyNet
extends RefCounted

# 策略网络：22→64→64→51 的 MLP，权重由 train/distill.py 导出。
# 特征顺序与 train/features.py 逐位一致，改任何一侧都要同步另一侧。

const FEATURES := 21
const HIDDEN := 64

var actions: Array[String] = []
var w1: Array = []
var b1: Array = []
var w2: Array = []
var b2: Array = []
var w3: Array = []
var b3: Array = []
var loaded := false

var _chain_cache: Dictionary = {}


func load_file(path: String) -> bool:
    if not FileAccess.file_exists(path):
        push_error("policy net missing: " + path)
        return false
    var f := FileAccess.open(path, FileAccess.READ)
    if f == null:
        return false
    var txt := f.get_as_text()
    f.close()
    var parsed = JSON.parse_string(txt)
    if parsed == null or not (parsed is Dictionary):
        push_error("policy net invalid json")
        return false

    for a in parsed.get("actions", []):
        actions.append(str(a))
    w1 = parsed.get("w1", [])
    b1 = parsed.get("b1", [])
    w2 = parsed.get("w2", [])
    b2 = parsed.get("b2", [])
    w3 = parsed.get("w3", [])
    b3 = parsed.get("b3", [])
    loaded = not (w1.is_empty() or w2.is_empty() or w3.is_empty())
    return loaded


func probs(feats: Array, legal_idx: Array) -> Array:
    if not loaded:
        return []
    var h1 := _dense(feats, w1, b1)
    var h2 := _dense(h1, w2, b2)
    # 输出层必须是线性的：套 ReLU 会把所有负 logit 截成 0，策略退化成均匀分布
    var logits := _linear(h2, w3, b3)

    # 只在合法动作上做 softmax
    var best := -INF
    for i in legal_idx:
        if i < logits.size():
            best = maxf(best, float(logits[i]))
    var sum := 0.0
    var out: Array = []
    for i in legal_idx:
        var v: float = exp(float(logits[i]) - best) if i < logits.size() else 0.0
        out.append(v)
        sum += v
    if sum <= 0.0:
        var u := 1.0 / maxf(1.0, float(legal_idx.size()))
        out.clear()
        for i in legal_idx:
            out.append(u)
        return out
    for k in out.size():
        out[k] = out[k] / sum
    return out


func _linear(x: Array, w: Array, b: Array) -> Array:
    var out: Array = []
    out.resize(w.size())
    for j in w.size():
        var row: Array = w[j]
        var s: float = float(b[j])
        var n: int = mini(row.size(), x.size())
        for i in n:
            s += float(row[i]) * float(x[i])
        out[j] = s
    return out


func _dense(x: Array, w: Array, b: Array) -> Array:
    var out: Array = []
    out.resize(w.size())
    for j in w.size():
        var row: Array = w[j]
        var s: float = float(b[j])
        var n: int = mini(row.size(), x.size())
        for i in n:
            s += float(row[i]) * float(x[i])
        out[j] = maxf(0.0, s)
    return out


# ---------- 特征（与 features.py 同序） ----------

func make_features(g: Duel, who: int) -> Array:
    var me := g.state.players[who]
    var opp := g.state.players[1 - who]
    var mc := _combo_feat(me.history)
    var oc := _combo_feat(opp.history)
    var md := _dot_feat(me)
    var od := _dot_feat(opp)
    return [
        _clamp(me.hp / 400.0, -1.0, 2.0),
        _clamp(opp.hp / 400.0, -1.0, 2.0),
        _clamp(me.yun / 60.0, -1.0, 2.0),
        _clamp(opp.yun / 60.0, -1.0, 2.0),
        mini(me.shields, 3) / 3.0,
        mini(opp.shields, 3) / 3.0,
        mc[0], mc[1],
        oc[0], oc[1],
        md[0], md[1],
        od[0], od[1],
        me.cost_percent / float(Units.PERCENT),
        opp.cost_percent / float(Units.PERCENT),
        1.0 if me.cannon_discounted(g.state.turn) else 0.0,
        1.0 if opp.cannon_discounted(g.state.turn) else 0.0,
        1.0 if me.skip_turn == g.state.turn else 0.0,
        1.0 if opp.skip_turn == g.state.turn else 0.0,
        _clamp(g.state.turn / 30.0, 0.0, 1.0),
    ]


const CHAINS := [
    ["zhong_fang"],
    ["zhong_fang", "xi", "yun"],
    ["zhong_fang", "xi", "yun", "chao_ji_xi"],
    ["zhong_fang", "zhong_fang", "xi", "zhong_fang"],
    ["yun", "yun", "yun", "yun"],
    ["jue_xing_zhong_fang"],
    ["jue_xing_zhong_fang", "chao_ji_xi", "qiang_hua_yun"],
    ["xiao_qia", "chao_qia"],
]


func _combo_feat(history: Array) -> Array:
    var best_chain := -1
    var best_prog := 0
    for idx in CHAINS.size():
        var p := _suffix_progress(history, CHAINS[idx])
        if p > best_prog:
            best_prog = p
            best_chain = idx
    return [(best_chain + 1) / 8.0, best_prog / 4.0]


func _suffix_progress(history: Array, pattern: Array) -> int:
    var best := 0
    for n in range(1, pattern.size() + 1):
        if history.size() < n:
            break
        var ok := true
        var start := history.size() - n
        for i in n:
            if str(history[start + i]) != str(pattern[i]):
                ok = false
                break
        if ok:
            best = n
    return best


func _dot_feat(p: PlayerState) -> Array:
    var dots := 0
    var c4 := 0.0
    for e in p.dots:
        if str(e.get("kind", "dot")) == "c4":
            c4 = 1.0
        else:
            dots += 1
    return [mini(dots, 3) / 3.0, c4]


static func _clamp(v: float, lo: float, hi: float) -> float:
    return lo if v < lo else (hi if v > hi else v)
