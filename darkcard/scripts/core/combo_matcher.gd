class_name ComboMatcher
extends RefCounted

# 连招口径（A4）：从本回合向前倒推连续读取。
# 被挡 / 被吸 / 被闪仍算"出过"（C20），龟派者不算（C22，留给后续实现）。


static func suffix_matches(history: Array[String], pattern: Array[String]) -> bool:
    if pattern.is_empty():
        return true
    if history.size() < pattern.size():
        return false
    var start := history.size() - pattern.size()
    for i in pattern.size():
        if history[start + i] != pattern[i]:
            return false
    return true


static func progress(history: Array[String], pattern: Array[String]) -> int:
    var best := 0
    for n in range(1, pattern.size() + 1):
        if _prefix_is_suffix(history, pattern, n):
            best = n
    return best


static func _prefix_is_suffix(history: Array[String], pattern: Array[String], n: int) -> bool:
    if history.size() < n:
        return false
    var start := history.size() - n
    for i in n:
        if history[start + i] != pattern[i]:
            return false
    return true
