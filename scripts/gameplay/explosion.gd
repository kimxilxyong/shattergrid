class_name Explosion
## Distributes a blast wave across everything it can affect.
##
## The explosion is not tied to the building in front of the player: in the original game's town, a
## bomb between two houses needed to damage both. Here, the group is scanned directly, which is
## cheaper than creating an `Area3D` when there are only a few buildings.

static func at(node: Node, center: Vector3, radius: float, energy: float) -> void:
	var tree := node.get_tree()
	var worlds := tree.get_nodes_in_group(VoxelWorld3D.GROUP)
	for world: VoxelWorld3D in worlds:
		# Smoke is exclusive to explosions; `VoxelParticlePool` selects it based on this cause.
		world.damage_sphere(center, radius, energy, {"cause": "explosion"})
	# Emit the fireball only once even if damage reaches several worlds: the particle pool is
	# per-world, but the player sees one explosion.
	if not worlds.is_empty():
		(worlds[0] as VoxelWorld3D).emit_explosion(center, radius)
