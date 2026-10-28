extends SceneTree


const SOURCE := "res://shaders/voxel/voxel_dda_dedicated.glsl"


func _init() -> void:
	# `load()` on a .glsl file does not compile the source; it returns the RDShaderFile left by the
	# importer. If the .glsl file was edited outside the editor, this validates the old version and
	# gives a false OK—the game once stopped drawing every voxel because the old .res push constant
	# was 48 bytes while the code already pushed 112. Fix: `godot --headless --import`.
	# Compare by md5 rather than date, matching the importer's own logic: reimport does not update
	# the .res if its content has not changed, so the timestamp produces false positives.
	var prefix := SOURCE.get_file()
	for file in DirAccess.get_files_at("res://.godot/imported"):
		if file.begins_with(prefix) and file.ends_with(".md5"):
			var record := FileAccess.get_file_as_string("res://.godot/imported/" + file)
			var recorded := record.split('source_md5="')[-1].split('"')[0]
			var actual := FileAccess.get_md5(SOURCE)
			if recorded != actual:
				print("DEDICATED_SHADER_STALE imported=%s source=%s — missing `godot --headless "
					% [recorded.left(8), actual.left(8)] + "--import`")
				quit(1)
	var shader_file: RDShaderFile = load(SOURCE)
	print("DEDICATED_SHADER_VERSIONS ", shader_file.get_version_list())
	print("DEDICATED_SHADER_ERROR ", shader_file.base_error)
	for version in shader_file.get_version_list():
		var spirv := shader_file.get_spirv(version)
		print("DEDICATED_SHADER_STAGE_ERRORS version=", version,
			" vertex=", spirv.compile_error_vertex,
			" fragment=", spirv.compile_error_fragment)
	quit(0)
