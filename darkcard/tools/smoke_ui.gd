extends SceneTree

# UI 冒烟：加载 Boot 场景 → 跑一局 → 检查日志生成
# godot --headless --path <proj> --script res://tools/smoke_ui.gd

func _initialize() -> void:
    _run()


func _run() -> void:
    var packed = load("res://scenes/Boot.tscn")
    if packed == null:
        printerr("cannot load Boot.tscn")
        quit(1)
        return

    var boot = packed.instantiate()
    root.add_child(boot)
    await process_frame

    var log = boot.get("_log")
    var status = boot.get("_status")
    if log == null or status == null:
        printerr("ui nodes missing, children=%d" % boot.get_child_count())
        quit(1)
        return

    boot._on_run()

    print("log_chars=%d" % log.text.length())
    print("status=" + status.text)
    print("---- log head ----")
    var lines: PackedStringArray = log.text.split("\n")
    for i in mini(6, lines.size()):
        print(lines[i])
    print("---- log tail ----")
    for i in range(maxi(0, lines.size() - 3), lines.size()):
        print(lines[i])

    quit(0 if log.text.length() > 100 else 1)
