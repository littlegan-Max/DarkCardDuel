class_name PlayerState
extends RefCounted

var hp: int = 100                 # 1 血 = 100
var hp_max_ever: int = 100        # 净化用（A3）
var yun: int = 0                  # 1 运 = 10
var shields: int = 0
var last_played: Dictionary = {}  # pool_id -> 出牌回合
var history: Array[String] = []   # 逐回合出牌，用于连招
var cost_percent: int = 100       # 葵花：50
var shield_bought_once: bool = false
var flags: Dictionary = {}
var pending_card: String = ""
var pending_paid: int = 0

# dot / 延迟伤害：{ amount, left, first, source, kind }
var dots: Array[Dictionary] = []
# 本回合免疫 ≤ 该值的攻击（酒）；-1 表示无
var immune_le: int = -1
# 预约发放的运：[{ turn, amount }]（向运葵）
var scheduled_yun: Array[Dictionary] = []
# 下回合空过（鄙视 / 被觉醒中防反弹的鄙视）：该回合只能出 pass
var skip_turn: int = -1
# 元首の愤怒：意大利炮折扣生效区间 [from, until)
var cannon_from: int = -1
var cannon_until: int = -1


func reset_pending() -> void:
    pending_card = ""
    pending_paid = 0


func remember_played(pool: String, turn_index: int) -> void:
    last_played[pool] = turn_index


func can_use(pool: String, cooldown: int, turn_index: int) -> bool:
    var last: int = int(last_played.get(pool, -9999))
    return turn_index - last > cooldown


func add_effect(amount: int, left: int, first: int, source: int, kind: String) -> void:
    dots.append({"amount": amount, "left": left, "first": first, "source": source, "kind": kind})


func add_dot(amount: int, turns: int, source: int, born: int) -> void:
    add_effect(amount, turns, born + 1, source, "dot")


func schedule_yun(amount: int, turn: int) -> void:
    scheduled_yun.append({"turn": turn, "amount": amount})


func clear_dots() -> int:
    var n := dots.size()
    dots.clear()
    return n


func cannon_discounted(turn_index: int) -> bool:
    return turn_index >= cannon_from and turn_index < cannon_until
