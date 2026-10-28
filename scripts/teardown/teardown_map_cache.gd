class_name TeardownMapCache
extends RefCounted
## Local cache of the importer's most expensive output: already-merged static collision faces.
##
## This does not copy the map into the project or create a redistributable scene. The file lives in
## `user://`, belongs to this installation, and contains only data derived from the user's local copy.

const FORMAT_VERSION := 1
const CACHE_DIRECTORY := "user://compiled_teardown_maps"
const EXTENSION := ".tdcollision"

## Changing any of these implementations automatically invalidates previous artifacts.
## `FORMAT_VERSION` covers purely semantic changes that do not modify these files.
const IMPLEMENTATION_FILES := [
	"res://scripts/teardown/teardown_map_cache.gd",
	"res://scripts/teardown/teardown_map_importer.gd",
	"res://scripts/teardown/teardown_palette.gd",
	"res://scripts/voxel/voxel_body_3d.gd",
	"res://scripts/voxel/voxel_world_3d.gd",
	"res://native/bin/libshattergrid_core.dylib",
]


static func prepare(
	xml_path: String, center: Vector3, radius: float, offset: Vector3, collision: bool
) -> Dictionary:
	var enabled := collision and center == Vector3.INF and is_inf(radius) \
		and offset.is_zero_approx() \
		and not "--no-teardown-cache" in OS.get_cmdline_user_args()
	if not enabled:
		return {"enabled": false, "status": "disabled"}
	var signature := source_signature(xml_path)
	var cache_path := cache_path_for(xml_path, signature)
	return {
		"enabled": true,
		"signature": signature,
		"path": cache_path,
		"force_rebuild": "--rebuild-teardown-cache" in OS.get_cmdline_user_args(),
		"status": "miss",
	}


static func source_signature(xml_path: String) -> String:
	var stamps := PackedStringArray([
		"format=%d" % FORMAT_VERSION,
		"godot=%s" % String(Engine.get_version_info().get("string", "unknown")),
		_file_stamp(xml_path),
	])
	var vox_folder := xml_path.get_base_dir().path_join("vox")
	var directory := DirAccess.open(vox_folder)
	if directory != null:
		var names := PackedStringArray()
		directory.list_dir_begin()
		var file_name := directory.get_next()
		while not file_name.is_empty():
			if not directory.current_is_dir() and file_name.get_extension().to_lower() == "vox":
				names.append(file_name)
			file_name = directory.get_next()
		directory.list_dir_end()
		names.sort()
		for name in names:
			stamps.append(_file_stamp(vox_folder.path_join(name)))
	for implementation in IMPLEMENTATION_FILES:
		stamps.append(_content_stamp(implementation))
	return "\n".join(stamps).sha256_text()


static func cache_path_for(xml_path: String, signature: String) -> String:
	var safe_name := xml_path.get_base_dir().get_file().validate_filename()
	if safe_name.is_empty():
		safe_name = "map"
	return "%s/%s-%s%s" % [CACHE_DIRECTORY, safe_name, signature.left(20), EXTENSION]


static func load_payload(context: Dictionary) -> Dictionary:
	if not bool(context.get("enabled", false)) or bool(context.get("force_rebuild", false)):
		return {}
	var path: String = context.get("path", "")
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open_compressed(
		path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD
	)
	if file == null:
		return {}
	var value: Variant = file.get_var(false)
	file.close()
	if not value is Dictionary:
		return {}
	var payload := value as Dictionary
	if int(payload.get("format", -1)) != FORMAT_VERSION \
			or String(payload.get("signature", "")) != String(context.get("signature", "")) \
			or not payload.get("entries", null) is Array:
		return {}
	return payload


static func save_payload(context: Dictionary, entries: Array, face_blocks: int) -> Dictionary:
	if not bool(context.get("enabled", false)):
		return {"ok": false, "error": ERR_UNAVAILABLE}
	var absolute_directory := ProjectSettings.globalize_path(CACHE_DIRECTORY)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		return {"ok": false, "error": directory_error}
	var path: String = context.get("path", "")
	var file := FileAccess.open_compressed(
		path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD
	)
	if file == null:
		return {"ok": false, "error": FileAccess.get_open_error()}
	file.store_var({
		"format": FORMAT_VERSION,
		"signature": context.get("signature", ""),
		"entries": entries,
		"face_blocks": face_blocks,
	}, false)
	var error := file.get_error()
	file.close()
	if error == OK:
		_prune_older_artifacts(path)
	return {
		"ok": error == OK,
		"error": error,
		"path": path,
		"bytes": FileAccess.get_size(path) if error == OK else 0,
	}


static func invalidate(path: String) -> void:
	if path.is_empty() or not FileAccess.file_exists(path):
		return
	# The target must be a file with the dedicated extension inside `user://`.
	if not path.begins_with(CACHE_DIRECTORY + "/") or not path.ends_with(EXTENSION):
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## One artifact per map. Each new signature wrote 82 MB without deleting the previous one, causing
## the installation to accumulate gigabytes of obsolete `.tdcollision` files.
static func _prune_older_artifacts(kept_path: String) -> void:
	var kept := kept_path.get_file()
	var prefix := kept.rsplit("-", true, 1)[0] + "-"
	var directory := DirAccess.open(CACHE_DIRECTORY)
	if directory == null:
		return
	directory.list_dir_begin()
	var file_name := directory.get_next()
	while not file_name.is_empty():
		if not directory.current_is_dir() and file_name != kept \
				and file_name.begins_with(prefix) and file_name.ends_with(EXTENSION):
			directory.remove(file_name)
		file_name = directory.get_next()
	directory.list_dir_end()


static func _file_stamp(path: String) -> String:
	var absolute := ProjectSettings.globalize_path(path) \
		if path.begins_with("res://") or path.begins_with("user://") else path
	if not FileAccess.file_exists(absolute):
		return "%s:missing" % path
	return "%s:%d:%d" % [
		path, FileAccess.get_size(absolute), FileAccess.get_modified_time(absolute),
	]


## Implementation files are fingerprinted by content, not modification time: `git checkout`,
## `touch`, or an identical rebuild changed the mtime and invalidated a still-valid 82 MB artifact.
## Scripts and the dylib total only a few MB, so hashing them takes milliseconds. `.vox` and XML
## files still use size+mtime: they total 292 MB, making hashing more expensive than the savings.
static func _content_stamp(path: String) -> String:
	var absolute := ProjectSettings.globalize_path(path) \
		if path.begins_with("res://") or path.begins_with("user://") else path
	if not FileAccess.file_exists(absolute):
		return "%s:missing" % path
	return "%s:%s" % [path, FileAccess.get_sha256(absolute)]
