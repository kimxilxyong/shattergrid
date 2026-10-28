class_name Projectile
extends Node3D
## Cannon projectile: voxel dart with manually integrated ballistics and swept collision.
##
## It is not a `RigidBody3D`: at hundreds of m/s, Jolt would need to run CCD against half the map
## every step for an object that neither bounces, rolls, nor stacks. Instead, the trajectory is
## integrated (gravity plus quadratic drag) and a ray is cast each frame from the previous point
## to the new one, so it cannot pass through a wall due to speed.
##
## A projectile "type" is its data entry, not a subclass: muzzle velocity, drag, penetration, and
## explosive charge. These four values describe the three real families without extra code: this
## AP has a narrow hole and high penetration; an HE would have near-zero `penetration` and a large
## blast radius; a HEAT round would have short penetration and a medium charge. Adding one means
## adding an entry to `AMMO`.

## Specs. `pierce_*` and `blast_*` use `VoxelShapeData::damage_sphere` semantics: radius is the
## hole size in soft material, and energy is the tool strength relative to material hardness
## (`radius * min(1, energy/hardness)`). An AP therefore has a dart-sized radius and energy well
## above any hardness—it pierces concrete as easily as wood—while its trailing charge is the
## opposite: a wide radius and bomb-level energy.
const AMMO := {
	"ap": {
		"label": "AP 120 mm",
		## Muzzle velocity. A real 120 mm kinetic-energy round travels at 1,750 m/s, reaching a
		## target 200 m away in 0.11 s: the tracer is invisible and drop is negligible. At 420 m/s,
		## the shot takes half a second and drops over a metre across those 200 m, making elevation
		## matter. This is THE value to tune when calibrating the shot.
		"speed": 420.0,
		## Aerodynamic drag coefficient k for `a = k·v²`, in 1/m. Derived from `0.5·ρ·Cd·A/m` with
		## air density 1.225 kg/m³, Cd 0.3 (supersonic), 120 mm caliber, and a 10 kg projectile.
		"drag_k": 0.0002,
		## Material thickness in meters penetrated at muzzle velocity on a perpendicular impact.
		"penetration": 2.2,
		"pierce_radius": 0.34,
		"pierce_energy": 90.0,
		"blast_radius": 3.2,
		"blast_energy": 14.0,
		## Actual caliber in meters. This is the size of the model's `.vox` bar, used to derive the
		## voxel size for the entire dart.
		"caliber": 0.12,
		"tracer_color": Color(1.0, 0.62, 0.22),
		## Length of the tracer flame behind the projectile base, not the projectile itself.
		"tracer_length": 0.55,
	},
}

const GRAVITY := 9.81
## A shot that hits nothing eventually falls, but an upward shot can take a long time to return.
## Without this, projectiles could keep integrating forever outside the map.
const MAX_LIFE := 12.0

var _stats := {}
var _velocity := Vector3.ZERO
var _muzzle_speed := 1.0
var _drag_k := 0.0
var _exclude: Array[RID] = []
var _age := 0.0


## Adds a projectile to the world, launched from `muzzle` (Godot convention: `-basis.z` is forward).
## `exclude` contains the shooter's bodies: the muzzle is half a meter from the cannon, and without
## this the first ray hits the turret itself. `carrier_velocity` is the weapon's velocity, which
## the projectile inherits like anything fired from a moving vehicle.
static func spawn(
	world: VoxelWorld3D, muzzle: Transform3D, kind := "ap",
	exclude: Array[RID] = [], carrier_velocity := Vector3.ZERO
) -> Projectile:
	var stats: Dictionary = AMMO.get(kind, {})
	if world == null or not is_instance_valid(world) or stats.is_empty():
		return null
	var shell := Projectile.new()
	shell.name = "Projectile"
	shell._stats = stats
	shell._exclude = exclude
	shell._muzzle_speed = float(stats.speed)
	shell._drag_k = float(stats.drag_k)
	shell._velocity = -muzzle.basis.z * shell._muzzle_speed + carrier_velocity
	world.add_child(shell)
	shell.global_position = muzzle.origin
	shell._orient()
	return shell


## MagicaVoxel dart model: hardened tip, tungsten rod, fins, and tracer, each section with its own
## palette index. Change the silhouette in the `.vox` file, not here.
const MODEL_PATH := "res://assets/models/tank/proyectil_ap.vox"
## Width of the rod in model voxels. The caliber from the spec is divided across them, so a 120 mm
## round gets a 120 mm rod without stray magic numbers.
const MODEL_BODY_VOXELS := 5

## Decode once per game, not once per shot: parsing the `.vox` takes milliseconds, and dozens of
## projectiles are fired every minute.
static var _model: Dictionary = {}


static func model() -> Dictionary:
	if _model.is_empty():
		_model = VoxelAssetImporter.load_asset(MODEL_PATH)
	return _model


func _ready() -> void:
	var caliber := float(_stats.get("caliber", 0.12))
	var unit := caliber / float(MODEL_BODY_VOXELS)
	var length := unit
	for view in _build_dart(unit):
		add_child(view)
		if view.has_meta("dart_length"):
			length = float(view.get_meta("dart_length"))
	add_child(_build_tracer(caliber, length))


## The dart uses two MultiMeshes—steel and tracer—because emissive material cannot share a material
## with shaded geometry. This keeps the entire projectile to two draw calls. The decoder already
## puts the model in Godot axes, with the `.vox` nose along -Z, which `_orient` aligns with travel.
func _build_dart(unit: float) -> Array[MultiMeshInstance3D]:
	var asset := model()
	var shapes: Array = asset.get("shapes", [])
	var palette: VoxelPalette = asset.get("palette")
	if shapes.is_empty() or palette == null:
		push_error("Projectile: failed to load %s" % MODEL_PATH)
		return []
	var data: VoxelShapeData = shapes[0].data
	var dimensions := data.get_dimensions()
	var cells := data.get_cells()
	var center := Vector3(dimensions - Vector3i.ONE) * 0.5
	var steel: Array[Vector3] = []
	var steel_tint: PackedColorArray = []
	var glow: Array[Vector3] = []
	var glow_tint: PackedColorArray = []
	for index in data.get_live_indices():
		var material := int(cells[index])
		var cell := Vector3i(
			index % dimensions.x,
			(index / dimensions.x) % dimensions.y,
			index / (dimensions.x * dimensions.y)
		)
		var properties := palette.get_material(material)
		var offset := (Vector3(cell) - center) * unit
		if float(properties.get("emission", 0.0)) > 0.0:
			glow.append(offset)
			glow_tint.append(properties.get("color", Color.WHITE))
		else:
			steel.append(offset)
			steel_tint.append(properties.get("color", Color.WHITE))

	var metal := StandardMaterial3D.new()
	metal.vertex_color_use_as_albedo = true
	metal.metallic = 0.85
	metal.roughness = 0.4
	var burning := StandardMaterial3D.new()
	burning.vertex_color_use_as_albedo = true
	burning.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var views: Array[MultiMeshInstance3D] = [_batch(steel, steel_tint, unit, metal)]
	views[0].set_meta("dart_length", float(dimensions.z) * unit)
	if not glow.is_empty():
		views.append(_batch(glow, glow_tint, unit, burning))
	return views


func _batch(
	offsets: Array[Vector3], colors: PackedColorArray, unit: float, material: Material
) -> MultiMeshInstance3D:
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE * unit
	cube.material = material
	var grid := MultiMesh.new()
	grid.transform_format = MultiMesh.TRANSFORM_3D
	grid.use_colors = true
	grid.mesh = cube
	grid.instance_count = offsets.size()
	for index in offsets.size():
		grid.set_instance_transform(index, Transform3D(Basis.IDENTITY, offsets[index]))
		grid.set_instance_color(index, colors[index])
	var view := MultiMeshInstance3D.new()
	view.multimesh = grid
	# It neither casts nor receives shadows: it is only 12 cm long and crosses the screen in two
	# frames, so an extra sun draw call is not worthwhile.
	view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return view


## Tracer: the flame burning behind the projectile base. It is separate from the model because it
## is the projectile's trail, not part of it, and it is the only way to track the shot by eye.
func _build_tracer(caliber: float, dart_length: float) -> MeshInstance3D:
	var color: Color = _stats.get("tracer_color", Color(1.0, 0.6, 0.2))
	var length := float(_stats.get("tracer_length", 0.5))
	var flame := BoxMesh.new()
	flame.size = Vector3(caliber * 0.55, caliber * 0.55, length)
	var glow := StandardMaterial3D.new()
	glow.albedo_color = color
	glow.emission_enabled = true
	glow.emission = color
	glow.emission_energy_multiplier = 6.0
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var view := MeshInstance3D.new()
	view.mesh = flame
	view.material_override = glow
	view.position = Vector3(0.0, 0.0, (dart_length + length) * 0.5)
	view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return view


func _physics_process(delta: float) -> void:
	_age += delta
	if _age > MAX_LIFE:
		queue_free()
		return
	# At these speeds, quadratic drag dominates; linear Stokes drag applies only to fog droplets.
	# Explicit integration with a fixed physics step and v² keeps error well below the dispersion
	# of a real cannon.
	_velocity += (Vector3.DOWN * GRAVITY - _velocity * (_velocity.length() * _drag_k)) * delta
	var from := global_position
	var to := from + _velocity * delta
	var hit := _cast(from, to)
	if not hit.is_empty():
		_detonate(hit.get("position", to), hit.get("normal", Vector3.UP))
		return
	global_position = to
	_orient()


func _cast(from: Vector3, to: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	if space == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = _exclude
	query.collide_with_areas = false
	# TODO: the World bakes static collision around the player
	# (`BAKED_COLLISION_PREFETCH_RADIUS`, 80 m). A shot longer than that could pass through a
	# building that has no boxes yet. If needed, call `prime_baked_static_collision` on the segment
	# before casting the ray.
	return space.intersect_ray(query)


## Impact: pierce and detonate behind the target. An AP round uses a base fuze with about a
## millisecond delay—less than one 60 Hz frame—so the delay is simulated by the distance to the
## charge center, not with a timer.
func _detonate(point: Vector3, normal: Vector3) -> void:
	var world := get_parent() as VoxelWorld3D
	if world == null or not is_instance_valid(world):
		queue_free()
		return
	var direction := _velocity.normalized()
	# Penetration: kinetic energy scales with v², and an oblique impact must pass through more armor
	# to travel the same distance. A glancing dart barely bites, and the charge detonates on the
	# target's surface, as it does in reality.
	var punch := clampf(_velocity.length() / _muzzle_speed, 0.0, 1.0)
	var bite := clampf(-direction.dot(normal), 0.0, 1.0)
	var depth: float = float(_stats.penetration) * punch * punch * bite
	var pierce_radius := float(_stats.pierce_radius)
	var pierce_energy := float(_stats.pierce_energy)
	# Create an entry channel, not a crater: chain spheres along the shot axis. Use at most four,
	# because each `damage_sphere` triggers structural analysis.
	var steps := clampi(ceili(depth / maxf(pierce_radius * 1.6, 0.01)), 1, 4)
	for step in steps:
		var along := depth * float(step) / float(steps)
		world.damage_sphere(
			point + direction * along, pierce_radius, pierce_energy, {"cause": "impact"}
		)
	Explosion.at(
		world, point + direction * depth, float(_stats.blast_radius), float(_stats.blast_energy)
	)
	queue_free()


## Aligns the tracer with travel. `looking_at` fails if the direction is parallel to its reference
## axis, which is exactly the case for a vertical anti-aircraft shot.
func _orient() -> void:
	if _velocity.length_squared() < 0.0001:
		return
	var forward := _velocity.normalized()
	var reference := Vector3.UP if absf(forward.y) < 0.99 else Vector3.FORWARD
	global_basis = Basis.looking_at(forward, reference)
