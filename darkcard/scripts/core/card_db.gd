class_name CardDB
extends RefCounted

const CARDS_PATH := "res://data/cards.json"
const SKILLS_DIR := "res://data/skills"

var defs: Dictionary = {}
var order: Array[String] = []
var rules_version: String = ""


static func load_all() -> CardDB:
    var db := CardDB.new()
    db._load_file(CARDS_PATH)
    db._load_dir(SKILLS_DIR)
    db._install_builtin()
    # 保持卡表文件顺序（按费用排列），不按字母序
    return db


func _install_builtin() -> void:
    # 内置"空过"：只在被鄙视的回合出现，不进卡池、不进 order
    var p := SkillDef.new()
    p.id = "pass"
    p.display_name = "空过"
    p.desc = "被鄙视，本回合不能出牌"
    p.cost = 0
    p.target = "self"
    defs["pass"] = p


func _load_file(path: String) -> void:
    if not FileAccess.file_exists(path):
        return
    var f := FileAccess.open(path, FileAccess.READ)
    if f == null:
        push_error("cannot open " + path)
        return
    var txt := f.get_as_text()
    f.close()

    var parsed = JSON.parse_string(txt)
    if parsed == null:
        push_error("invalid json: " + path)
        return

    if parsed is Dictionary:
        if rules_version == "":
            rules_version = str(parsed.get("rules_version", ""))
        var arr = parsed.get("cards", [])
        if arr is Array:
            for item in arr:
                _add(item)
    elif parsed is Array:
        for item in parsed:
            _add(item)


func _load_dir(path: String) -> void:
    var dir := DirAccess.open(path)
    if dir == null:
        return
    for f in dir.get_files():
        if f.ends_with(".json"):
            _load_file(path + "/" + f)


func _add(item) -> void:
    if not (item is Dictionary):
        return
    var s := SkillDef.from_dict(item)
    if s.id == "":
        return
    defs[s.id] = s
    if not order.has(s.id):
        order.append(s.id)


func get_def(id: String) -> SkillDef:
    return defs.get(id, null)


func has_card(id: String) -> bool:
    return defs.has(id)


func size() -> int:
    return order.size()
