class_name Bomb
extends RigidBody3D
## A thrown charge that explodes on first contact or when its fuse expires.

var radius := 2.3
var energy := 12.0

## Seconds before detonation if nothing is hit. Without it, a bomb thrown into empty space would
## fall forever and keep costing broad-phase work.
const FUSE := 4.0

var _spent := false


func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 1
	mass = 8.0

	var view := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.18
	ball.height = 0.36
	view.mesh = ball
	var paint := StandardMaterial3D.new()
	paint.albedo_color = Color(0.1, 0.1, 0.12)
	paint.emission_enabled = true
	paint.emission = Color(0.9, 0.25, 0.1)
	paint.emission_energy_multiplier = 1.5
	view.material_override = paint
	add_child(view)

	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.18
	shape.shape = sphere
	add_child(shape)

	body_entered.connect(_on_touch)
	get_tree().create_timer(FUSE).timeout.connect(_detonate)


func _on_touch(_body: Node) -> void:
	# `body_entered` runs inside the physics step, when a body cannot be removed from the tree:
	# Jolt is traversing its own list. Mark it spent now—so two contacts in the same step cannot
	# detonate it twice—and defer the rest until the step ends.
	if _spent:
		return
	_spent = true
	_detonate.call_deferred()


func _detonate() -> void:
	if not is_inside_tree():
		return
	_spent = true
	var center := global_position
	var parent := get_parent()
	# Remove it before applying the blast: otherwise the debris sweep pushes the bomb itself, and
	# the later `queue_free` leaves a partially affected body.
	get_parent().remove_child(self)
	queue_free()
	Explosion.at(parent, center, radius, energy)
