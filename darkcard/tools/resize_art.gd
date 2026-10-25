extends SceneTree

# 一次性工具：把 assets/cards 下的插画缩到 512x512
# godot --headless --path <proj> --script res://tools/resize_art.gd

const TARGET := 512


func _initialize() -> void:
    var dir := DirAccess.open("res://assets/cards")
    if dir == null:
        printerr("no cards dir")
        quit(1)
        return

    var count := 0
    for f in dir.get_files():
        if not f.ends_with(".png"):
            continue
        var path := "res://assets/cards/" + f
        var img := Image.load_from_file(path)
        if img == null:
            printerr("load failed: " + f)
            continue
        if img.get_width() > TARGET:
            img.resize(TARGET, TARGET, Image.INTERPOLATE_LANCZOS)
            var err := img.save_png(path)
            print("%s -> %dx%d (%s)" % [f, img.get_width(), img.get_height(), str(err)])
            count += 1

    print("resized=%d" % count)
    quit(0)
