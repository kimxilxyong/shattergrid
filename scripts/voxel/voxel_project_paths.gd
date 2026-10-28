class_name VoxelProjectPaths
extends RefCounted
## Portable paths for optional resources that are not part of the repository.

const DEFAULT_TEARDOWN_ROOT := "res://external/teardown_maps/lee"
const DEFAULT_TEARDOWN_MAP := DEFAULT_TEARDOWN_ROOT + "/main.xml"
## Layout used during development: both repositories live in sibling folders under
## `Documents/Godot`. Convert to a global path because `res://..` is outside the project's resource tree.
const DEVELOPMENT_TEARDOWN_MAP := "res://../teardown_maps/lee/main.xml"
const TEARDOWN_MAP_ENV := "SHATTERGRID_MAP"


static func teardown_map_path() -> String:
	var configured := OS.get_environment(TEARDOWN_MAP_ENV).strip_edges()
	if not configured.is_empty():
		return configured
	if FileAccess.file_exists(DEFAULT_TEARDOWN_MAP):
		return DEFAULT_TEARDOWN_MAP
	var development_map := ProjectSettings.globalize_path(DEVELOPMENT_TEARDOWN_MAP)
	return development_map if FileAccess.file_exists(development_map) else DEFAULT_TEARDOWN_MAP


static func teardown_vox_dir() -> String:
	return teardown_map_path().get_base_dir().path_join("vox") + "/"
