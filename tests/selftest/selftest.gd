class_name VoxelSelfTest
extends SceneTree
## Self-test base: failure counter, world setup, and static boxes. This replaces code that had been
## copied verbatim into 28 files.
##
## A test inherits this class and defines `_run()`; this class already defers it from `_init`.
## Do not redefine `_init` in a subclass: GDScript still calls the parent implementation and `_run`
## would execute twice.

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	push_error("the self-test does not define _run()")
	quit(1)


func _check(condition: bool, message := "") -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FAIL ", message)


## The world setup used by most tests: no diagnostics and with a physics budget.
func make_world(with_budget := true) -> VoxelWorld3D:
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	if with_budget:
		world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)
	return world


## Floor, wall, or ledge. Position the whole body instead of offsetting the Shape inside it: for a
## StaticBody the pose is equivalent, and this avoids adjusting it manually at every call site.
static func make_box_body(parent: Node, size: Vector3, position := Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	collision.shape = box
	body.add_child(collision)
	parent.add_child(body)
	body.position = position
	return body
