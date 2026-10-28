class_name Vox
## Constants used only by the legacy blueprint adapter.
##
## Runtime geometry always uses 10 cm voxels. The 30 cm blueprint cells are expanded once by
## `VoxelAssetImporter`; structural behavior comes exclusively from six-face connectivity.

enum Kind { LADRILLO, PIEDRA, MADERA, TECHO, VIDRIO, METAL, CARBON }

const BLUEPRINT_CELL := 0.30
const VOXEL_SIZE := 0.10
const MASS_PER_M3 := 1800.0

const COLOR_HEX := [0xB5552D, 0x9A9AA0, 0x8B5A2B, 0xB02E2E, 0x9AD0EC, 0x5E6770, 0x232323]
## Hardness on the `damage_sphere_material` scale: 1.0 is the reference soft material (wood, plaster),
## and each point above that reduces the crater radius. Teardown groups its materials as soft,
## medium, hard, and indestructible.
const TOUGHNESS := [2.0, 2.6, 1.0, 1.2, 0.5, 4.0, 1.0]
const DENSITY := [1.0, 1.4, 0.4, 1.0, 1.3, 4.0, 0.3]


static func color_of(kind: int) -> Color:
	var rgb: int = COLOR_HEX[kind]
	return Color8((rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff)
