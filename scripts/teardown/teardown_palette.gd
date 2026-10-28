class_name TeardownPalette
extends RefCounted
## Palette index -> material, matching Teardown.
##
## Teardown does not infer material from color: it reserves fixed bands of 8 palette indices, and
## the index determines the material. Teardown-Converter reorders the palette when exporting
## (`FIX_PALETTE_MAPPING`) so each material falls into its band, with row 31 at the lowest indices:
##
##     row = 31 - (index - 1) / 8
##
## This is an exact signal, not an inference, so it replaces the HSV heuristic in
## `VoxelAssetImporter._toughness_of` for map `.vox` files. That heuristic is needed only because
## third-party `.vox` files use arbitrary palettes.

## The 32 rows in the order written by the converter (row 0 is at the bottom in MagicaVoxel).
const ROWS := [
	"none", "reserved", "unphysical", "unphysical", "reserved", "reserved", "reserved", "reserved",
	"ice", "hardmasonry", "hardmetal", "plastic", "plastic", "heavymetal", "heavymetal", "metal",
	"metal", "plaster", "plaster", "masonry", "masonry", "masonry", "masonry", "wood",
	"wood", "rock", "rock", "dirt", "dirt", "foliage", "foliage", "glass",
]

## `hardness` on the `damage_sphere_material` scale: it divides the hole radius, with 1.0 as the
## reference for a soft material. Teardown's four `MakeHole` classes (soft, medium, hard,
## indestructible) are derived by grouping these rows. `density` is in kg/m3.
const MATERIALS := {
	"glass": {"hardness": 0.5, "density": 2500.0, "opacity": 0.35, "roughness": 0.1},
	"foliage": {"hardness": 0.6, "density": 300.0},
	"dirt": {"hardness": 0.7, "density": 1500.0},
	"ice": {"hardness": 0.7, "density": 900.0, "opacity": 0.6, "roughness": 0.15},
	"plastic": {"hardness": 0.8, "density": 900.0},
	"wood": {"hardness": 1.0, "density": 700.0},
	"plaster": {"hardness": 1.0, "density": 1200.0},
	"masonry": {"hardness": 2.0, "density": 2000.0},
	"metal": {"hardness": 2.4, "density": 7800.0, "metallic": 0.8, "roughness": 0.35},
	"hardmasonry": {"hardness": 4.0, "density": 2600.0},
	"hardmetal": {"hardness": 4.5, "density": 7900.0, "metallic": 0.9, "roughness": 0.25},
	# Teardown excludes rock and heavy metal from all three `MakeHole` classes: they cannot be drilled.
	"rock": {"hardness": 1000000.0, "density": 2700.0},
	"heavymetal": {"hardness": 1000000.0, "density": 8000.0, "metallic": 0.9, "roughness": 0.3},
	# Decoration without its own physics (background fences, signs). Treat as plaster so it gives way.
	"unphysical": {"hardness": 1.0, "density": 1200.0},
	"none": {"hardness": 1.0, "density": 1200.0},
	"reserved": {"hardness": 1.0, "density": 1200.0},
}


## `IMAP` is MagicaVoxel's reindexing table. In converter `.vox` files it is NOT the identity:
## voxels use compact indices starting at 1, and `IMAP` contains the actual band index. Without
## applying it, Lee's terrain (16 million voxels at index 1) was treated as `glass` with hardness
## 0.5 instead of indestructible `rock`, so one click opened the ground. Files whose palettes are
## already ordered by band have an identity IMAP, so this does not change them.
static func banded_index(index: int, imap: PackedByteArray) -> int:
	if imap.size() < 255 or index < 1 or index > 255:
		return index
	return imap[index - 1]


static func material_name(index: int, imap := PackedByteArray()) -> String:
	var banded := banded_index(index, imap)
	if banded < 1 or banded > 255:
		return "none"
	return ROWS[31 - (banded - 1) / 8]


## Appearance and physical material are independent in Teardown. The index determines hardness and
## density; `MATL` determines whether that sample looks matte, metallic, emissive, or like glass.
## For example, physical index 1 (`glass`) can have `_metal` appearance and be opaque.
static func appearance(attributes: Dictionary, fallback_alpha := 1.0) -> Dictionary:
	var kind: String = attributes.get("_type", "_diffuse")
	var roughness := clampf(float(attributes.get("_rough", 1.0)), 0.0, 1.0)
	var result := {
		"opacity": 1.0,
		"roughness": roughness,
		"metallic": 0.0,
		"emission": 0.0,
	}
	match kind:
		"_glass":
			# MagicaVoxel stores 100% transparency as alpha=1. Teardown explicitly treats that value
			# as opaque; any lower value enables one glass appearance, without grading transparency
			# from 0 to 99.
			var alpha := clampf(float(attributes.get("_alpha", fallback_alpha)), 0.0, 1.0)
			result.opacity = 1.0 if alpha >= 0.999 else 0.35
			result.roughness = 0.08
		"_metal":
			result.metallic = clampf(float(
				attributes.get("_metal", attributes.get("_weight", 0.0))
			), 0.0, 1.0)
		"_emit":
			# `_emit` is the emissive amount and `_flux` its power. Keep the runtime value in
			# Teardown's documented 0..32 material range.
			result.emission = clampf(
				float(attributes.get("_emit", attributes.get("_weight", 0.0)))
					* maxf(1.0, float(attributes.get("_flux", 1.0))) * 8.0,
				0.0, 32.0
			)
		"_diffuse":
			result.roughness = 1.0
	return result


## Materials the player always passes through. `unphysical` is Teardown's category for decoration
## without physics: background fences, signs, and details placed on the ground that were never
## intended to be walked on. Giving them a mesh costs performance and turns ground decoration into
## steps. They are still rendered and destroyed as before; they are simply excluded from the mesh
## passed to Jolt.
##
## `foliage` is included in full: in the original, the player walks over the ground and grass does
## not lift the camera. Distinguishing grass from shrubs by Shape height did not work—Lee's weeds
## are part of tall Shapes and still caused collisions.
##
## Known limitation: large shrubs also do not block the player. Distinguishing them requires
## measuring the height of each foliage column, a query reserved for the native path.
const WALK_THROUGH := ["unphysical", "foliage"]


## One entry per palette index; 0 means pass-through. Stored as palette metadata because this
## applies only to converted Teardown palettes: index bands have no meaning in third-party `.vox`
## files, and without the metadata `build_macro_faces` collides with everything as before.
static func collide_mask(walk_through: Array, imap := PackedByteArray()) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(256)
	for index in range(1, 256):
		mask[index] = 0 if material_name(index, imap) in walk_through else 1
	return mask


static func mask_for(shape: VoxelShape3D) -> PackedByteArray:
	if shape.palette == null:
		return PackedByteArray()
	return shape.palette.get_meta("collide_mask", PackedByteArray())


## Build the `VoxelPalette` for a map `.vox`: RGBA+MATL color/appearance and physical properties
## from Teardown's official index bands.
static func build(colors: PackedColorArray, material_attributes: Dictionary,
		imap := PackedByteArray()) -> VoxelPalette:
	var palette := VoxelPalette.new()
	palette.set_meta("collide_mask", collide_mask(WALK_THROUGH, imap))
	# Store this so probes can name a voxel's material without reopening the `.vox`: without IMAP,
	# `material_name` returns the wrong name for a raw index.
	palette.set_meta("imap", imap)
	for index in range(1, 256):
		var traits: Dictionary = MATERIALS[material_name(index, imap)]
		var visual := appearance(material_attributes.get(index, {}), 1.0)
		palette.set_material(index, {
			"color": colors[index],
			"opacity": visual.opacity,
			"roughness": visual.roughness,
			"metallic": visual.metallic,
			"emission": visual.emission,
			"hardness": traits.hardness,
			"density": traits.density,
			"friction": 0.9,
			"restitution": 0.02,
		})
	return palette
