extends SceneTree


func _init() -> void:
	var colors := PackedColorArray()
	colors.resize(256)
	colors.fill(Color(0.42, 0.31, 0.18, 1.0))
	var palette := TeardownPalette.build(colors, {
		# Physical glass band, but deliberately authored as an opaque metal appearance.
		1: {"_type": "_metal", "_metal": "1", "_rough": "0.5"},
		# Physical reserved band, deliberately authored as visual glass.
		255: {"_type": "_glass", "_alpha": "0.5", "_rough": "0"},
		57: {"_type": "_emit", "_emit": "0.5", "_flux": "3"},
	})
	var opaque_metal: Dictionary = palette.get_material(1)
	var visual_glass: Dictionary = palette.get_material(255)
	var emissive_wood: Dictionary = palette.get_material(57)
	# The real `IMAP` from Lee's `palette103.vox`: voxel index 1 is rock, not glass, and index 2 is dirt.
	var imap := PackedByteArray()
	imap.resize(255)
	for i in 255:
		imap[i] = i + 1
	imap[0] = 41
	imap[1] = 25
	var banded := TeardownPalette.collide_mask(TeardownPalette.WALK_THROUGH, imap)
	var passed := TeardownPalette.material_name(1, imap) == "rock" \
		and TeardownPalette.material_name(2, imap) == "dirt" \
		and TeardownPalette.material_name(1) == "glass" \
		and banded[1] == 1 \
		and TeardownPalette.material_name(9) == "foliage" \
		and TeardownPalette.material_name(57) == "wood" \
		and is_equal_approx(float(opaque_metal.opacity), 1.0) \
		and is_equal_approx(float(opaque_metal.metallic), 1.0) \
		and is_equal_approx(float(opaque_metal.roughness), 0.5) \
		and is_equal_approx(float(visual_glass.opacity), 0.35) \
		and float(emissive_wood.emission) > 0.0
	print("TEARDOWN_PALETTE_SELFTEST_%s opaque=%s glass=%s emit=%s" % [
		"OK" if passed else "FAIL", opaque_metal, visual_glass, emissive_wood,
	])
	quit(0 if passed else 1)
