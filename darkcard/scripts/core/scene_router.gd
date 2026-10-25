class_name SceneRouter
extends RefCounted

# 场景切换的统一入口。
#
# 这里集中挡掉三个坑——踩中任何一个，玩家看到的表现都是「点进去一片黑，什么也没发生」：
#
#   1. 新场景不能 add_child 到「马上要释放的旧场景」身上。
#      那样新场景就是旧场景的子节点，旧场景被释放时它跟着一起被删，
#      屏幕上什么都不剩。（主菜单黑屏就是这个原因。）
#   2. Godot 要求 current_scene 必须是 root 的直接子节点，
#      否则 `get_tree().current_scene = x` 会被引擎拒绝并报错：
#      Condition "p_scene && p_scene->get_parent() != root" is true.
#   3. 旧场景持有的长连接节点（NetClient）会跟着旧场景一起死，
#      所以要先把这些节点 transfer 到新场景下。


## 切到新场景。
##
## tree : 当前的 SceneTree
## next : 新场景实例（还没进场景树）
## keep : 需要从旧场景转移到新场景的节点（比如长连接客户端 NetClient）
static func swap(tree: SceneTree, next: Node, keep: Array = []) -> void:
	if tree == null or next == null or not is_instance_valid(next):
		push_error("SceneRouter.swap: 参数无效")
		return

	var old: Node = tree.current_scene

	# 1. 保留节点先从旧场景摘下来（还没进新场景，不会被顺手删掉）
	for n in keep:
		if n != null and is_instance_valid(n) and n.get_parent() != null:
			n.get_parent().remove_child(n)

	# 2. 旧场景摘出场景树（先摘后放，保证同一时刻只有一屏 UI 在树上）
	if old != null and is_instance_valid(old):
		var op := old.get_parent()
		if op != null:
			op.remove_child(old)

	# 3. 新场景挂到 root 下——current_scene 必须是 root 的直接子节点
	tree.root.add_child(next)
	tree.current_scene = next

	# 4. 保留节点挂到新场景下，并通知它「场景变了，自己重新接上」
	for n in keep:
		if n != null and is_instance_valid(n):
			next.add_child(n)
			if n.has_method("on_scene_transferred"):
				n.call("on_scene_transferred")

	# 5. 释放旧场景（延迟到帧末，避免正在执行的回调里把自己删掉）
	if old != null and is_instance_valid(old):
		old.queue_free()
