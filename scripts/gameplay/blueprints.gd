class_name Blueprints
## Blueprints for destructible buildings and the primitives used to create them.
##
## They are written on the **coarse grid** (cell = `Vox.BLUEPRINT_CELL`). The legacy importer
## expands each cell exactly once into 3x3x3 voxels of 10 cm.
##
## Legacy grid convention: **`y` is never negative**, and anything that should remain standing must
## retain a 6-connected path to anchors at `y == 0`.

const K := Vox.Kind


static func of(name: String) -> Dictionary:
	var coarse: Dictionary = {}
	match name:
		"casa": coarse = _casa()
		"torre": coarse = _torre()
		"fabrica": coarse = _fabrica()
		_: push_error("unknown blueprint: %s" % name)
	return coarse


# MARK: - Primitivas


static func solid(v: Dictionary, x: Vector2i, y: Vector2i, z: Vector2i, kind: int) -> void:
	for xi in range(x.x, x.y + 1):
		for yi in range(y.x, y.y + 1):
			for zi in range(z.x, z.y + 1):
				v[Vector3i(xi, yi, zi)] = kind


## The four walls of a box, without a floor or roof.
static func shell(v: Dictionary, x: Vector2i, y: Vector2i, z: Vector2i, kind: int) -> void:
	for xi in range(x.x, x.y + 1):
		for yi in range(y.x, y.y + 1):
			for zi in range(z.x, z.y + 1):
				if xi == x.x or xi == x.y or zi == z.x or zi == z.y:
					v[Vector3i(xi, yi, zi)] = kind


## A horizontal layer: floors, roofs, streets.
static func slab(v: Dictionary, y: int, x: Vector2i, z: Vector2i, kind: int) -> void:
	solid(v, x, Vector2i(y, y), z, kind)


static func column(v: Dictionary, x: int, z: int, y: Vector2i, kind: int) -> void:
	solid(v, Vector2i(x, x), y, Vector2i(z, z), kind)


## Circular cross-section cylinder. With `inner > 0`, it forms a hollow tube for towers or
## chimneys. Radii are in cells and floating-point because edges look much better with half steps:
## a radius of 2.4 produces a rounder cross-section than 2.
static func cylinder(
	v: Dictionary, cx: int, cz: int, outer: float, inner: float, y: Vector2i, kind: int
) -> void:
	var bound := ceili(outer)
	for dx in range(-bound, bound + 1):
		for dz in range(-bound, bound + 1):
			var distance := sqrt(float(dx * dx + dz * dz))
			if distance > outer or distance < inner:
				continue
			for yi in range(y.x, y.y + 1):
				v[Vector3i(cx + dx, yi, cz + dz)] = kind


## Carves a volume: doors, gates, windows.
static func carve(v: Dictionary, x: Vector2i, y: Vector2i, z: Vector2i) -> void:
	for xi in range(x.x, x.y + 1):
		for yi in range(y.x, y.y + 1):
			for zi in range(z.x, z.y + 1):
				v.erase(Vector3i(xi, yi, zi))


# MARK: - Planos


## Brick house with wooden corners, large windows, and a solid pyramidal roof.
static func _casa() -> Dictionary:
	var v := {}
	var x := Vector2i(-7, 7)
	var z := Vector2i(-5, 5)
	var wall_top := 7

	for yi in range(0, wall_top + 1):
		for xi in range(x.x, x.y + 1):
			for zi in range(z.x, z.y + 1):
				var on_x := xi == x.x or xi == x.y
				var on_z := zi == z.x or zi == z.y
				if not (on_x or on_z):
					continue
				# Door in the front facade.
				if zi == z.y and absi(xi) <= 1 and yi <= 3:
					continue
				var kind := K.LADRILLO
				if (on_x and on_z) or yi == 0:
					kind = K.MADERA
				elif yi >= 3 and yi <= 4:
					if on_z and absi(xi) % 4 == 2:
						kind = K.VIDRIO
					if on_x and absi(zi) % 3 == 2:
						kind = K.VIDRIO
				v[Vector3i(xi, yi, zi)] = kind

	# Tiered roof, each level **solid**. Recessed rings leave each level one voxel in from the one
	# below, so they do not touch: the entire roof floats above the house and falls with the first
	# explosion anywhere.
	var level := 0
	while true:
		var lo := Vector2i(x.x - 1 + level, x.y + 1 - level)
		var lz := Vector2i(z.x - 1 + level, z.y + 1 - level)
		if lo.x > lo.y or lz.x > lz.y:
			break
		slab(v, wall_top + 1 + level, lo, lz, K.TECHO)
		if lz.y - lz.x <= 1 or lo.y - lo.x <= 1:
			break
		level += 1
	return v


## Hollow stone tower with wooden floors and alternating battlements.
static func _torre() -> Dictionary:
	var v := {}
	var height := 17
	for yi in range(0, height + 1):
		for xi in range(-5, 6):
			for zi in range(-5, 6):
				var distance := sqrt(float(xi * xi + zi * zi))
				var is_wall := distance <= 5.3 and distance >= 3.9
				var is_inside := distance < 3.9
				if yi == height:
					if is_wall and (xi + zi) % 2 == 0:
						v[Vector3i(xi, yi, zi)] = K.PIEDRA
					continue
				if is_wall:
					var kind := K.PIEDRA
					if yi > 1 and yi % 5 == 3 and (absi(xi) <= 1 or absi(zi) <= 1):
						kind = K.VIDRIO
					v[Vector3i(xi, yi, zi)] = kind
				elif is_inside and yi > 0 and yi % 6 == 0:
					v[Vector3i(xi, yi, zi)] = K.MADERA
	return v


## Industrial building with chimney. The chimney falls onto the building, demonstrating collision
## between a detached piece and what remains standing.
static func _fabrica() -> Dictionary:
	var v := {}
	var x := Vector2i(-11, 11)
	var z := Vector2i(-5, 5)
	var eaves := 9

	shell(v, x, Vector2i(0, eaves), z, K.LADRILLO)
	# Continuous skylight below the eaves. It goes **before** the frames so their pillars pass
	# through it; otherwise, glass would overwrite steel on those two rows and cut all three pillars
	# in every frame, leaving the roof without a path to the ground.
	solid(v, x, Vector2i(eaves - 2, eaves - 1), Vector2i(z.x, z.x), K.VIDRIO)
	solid(v, x, Vector2i(eaves - 2, eaves - 1), Vector2i(z.y, z.y), K.VIDRIO)

	# Steel frames every three cells, with a central pillar. Skip x = 1 to open the gap for the
	# loading gate.
	for cx in range(x.x, x.y + 1, 3):
		if cx == 1:
			continue
		column(v, cx, z.x, Vector2i(0, eaves), K.METAL)
		column(v, cx, 0, Vector2i(0, eaves), K.METAL)
		column(v, cx, z.y, Vector2i(0, eaves), K.METAL)
		slab(v, eaves, Vector2i(cx, cx), z, K.METAL)
		# Wooden purlins over the frames: the fuel.
		slab(v, eaves + 1, Vector2i(cx, cx), z, K.MADERA)
	slab(v, eaves + 1, x, Vector2i(z.x, z.x), K.MADERA)
	slab(v, eaves + 1, x, Vector2i(z.y, z.y), K.MADERA)
	# Tile roof over the purlins.
	slab(v, eaves + 2, x, z, K.TECHO)

	# Loading gate: the opening reaches the eaves, with no wall above it.
	carve(v, Vector2i(-1, 3), Vector2i(0, eaves), Vector2i(z.y, z.y))
	slab(v, eaves, Vector2i(-2, 4), Vector2i(z.y, z.y), K.METAL)

	# Chimney: brick tube, solid at the base so it is genuinely supported.
	cylinder(v, 17, 0, 2.4, 0.0, Vector2i(0, 1), K.LADRILLO)
	cylinder(v, 17, 0, 2.4, 1.4, Vector2i(2, 30), K.LADRILLO)
	return v
