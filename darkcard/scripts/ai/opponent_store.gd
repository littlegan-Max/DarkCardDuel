class_name OpponentStore
extends RefCounted

# 对手画像的持久化。
#
# 规则：存档结构带版本号，带迁移函数；写入失败要有兜底（不静默丢档）。
# 路径用 user://（平台无关，符合规范），Windows 下落在
# %APPDATA%\Godot\app_userdata\暗牌技能对战\opponent_model.json。

const PATH := "user://opponent_model.json"
const SCHEMA_VERSION := 1
const BACKUP_PATH := "user://opponent_model.bak.json"


static func load_model() -> OpponentModel:
    var m := OpponentModel.new()
    if not FileAccess.file_exists(PATH):
        return m
    var f := FileAccess.open(PATH, FileAccess.READ)
    if f == null:
        push_warning("对手画像读取失败：%s" % error_string(FileAccess.get_open_error()))
        return m
    var text := f.get_as_text()
    f.close()
    var parsed = JSON.parse_string(text)
    if typeof(parsed) != TYPE_DICTIONARY:
        push_warning("对手画像文件损坏，按空画像启动")
        _rotate_backup()
        return m
    var data: Dictionary = parsed
    data = _migrate(data)
    m.from_dict(data)
    return m


static func save_model(m: OpponentModel) -> bool:
    var payload := m.to_dict()
    payload["saved_at"] = Time.get_datetime_string_from_system()
    var text := JSON.stringify(payload, "\t")
    # 先写临时文件再替换，避免写一半掉电把旧档弄坏
    var tmp := PATH + ".tmp"
    var f := FileAccess.open(tmp, FileAccess.WRITE)
    if f == null:
        push_warning("对手画像写入失败：%s" % error_string(FileAccess.get_open_error()))
        return false
    f.store_string(text)
    f.close()
    # 保留上一份作为备份
    if FileAccess.file_exists(PATH):
        var old := FileAccess.open(PATH, FileAccess.READ)
        if old != null:
            var b := FileAccess.open(BACKUP_PATH, FileAccess.WRITE)
            if b != null:
                b.store_string(old.get_as_text())
                b.close()
            old.close()
    var err := DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp),
        ProjectSettings.globalize_path(PATH))
    if err != OK:
        # 兜底：直接覆盖
        var f2 := FileAccess.open(PATH, FileAccess.WRITE)
        if f2 == null:
            return false
        f2.store_string(text)
        f2.close()
    return true


# 文件损坏时：把坏档挪到备份位置，避免直接丢档
static func _rotate_backup() -> void:
    if not FileAccess.file_exists(PATH):
        return
    var f := FileAccess.open(PATH, FileAccess.READ)
    if f != null:
        var b := FileAccess.open(BACKUP_PATH, FileAccess.WRITE)
        if b != null:
            b.store_string(f.get_as_text())
            b.close()
        f.close()
    DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))


static func clear() -> void:
    if FileAccess.file_exists(PATH):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
    if FileAccess.file_exists(BACKUP_PATH):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(BACKUP_PATH))


static func exists() -> bool:
    return FileAccess.file_exists(PATH)


# 版本迁移链：老版本 → 新版本。v0（无版本号）视为空画像。
static func _migrate(data: Dictionary) -> Dictionary:
    var version := int(data.get("schema_version", 0))
    if version >= SCHEMA_VERSION:
        return data
    if version < 1:
        # v0 → v1：老数据没有上下文维度，只保留全局牌频
        var out := {
            "schema_version": 1,
            "card_counts": data.get("card_counts", {}),
            "card_total": float(data.get("card_total", 0.0)),
            "context_counts": {},
            "context_total": {},
            "tag_counts": data.get("tag_counts", {}),
            "combo_setup": 0.0,
            "combo_finish": 0.0,
            "max_streak": int(data.get("max_streak", 0)),
            "repeat_pairs": float(data.get("repeat_pairs", 0.0)),
            "decisions": int(data.get("decisions", 0)),
            "matches": int(data.get("matches", 0)),
        }
        return out
    return data
