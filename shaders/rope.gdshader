shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_opaque;

// Camera-facing cable strips, as in Teardown: cables are neither voxels nor SDFs, but billboarded
// triangle strips drawn after solid geometry.
//
// Width expansion is done here rather than on the CPU. The mesh always has the same two vertices
// per point and changes only when a cable actually moves; calculating the billboard on the CPU
// would require rebuilding it whenever the player turns their head, even with 79 stationary cables.
//
// The mesh is assumed to be in world coordinates (the node hangs from the untransformed origin),
// which is how the importer creates it. `VERTEX` is therefore already a world position, and the
// camera position can be used directly without inverting the model matrix per vertex.

uniform float radius = 0.025;
uniform vec4 albedo : source_color = vec4(0.045, 0.045, 0.055, 1.0);
/// A round cable should not look flat: darken the ribbon edges to suggest a cylinder.
uniform float rim = 0.55;

varying float side_offset;

void vertex() {
	// NORMAL contains the cable tangent at this point, and UV.x identifies the ribbon side (0 or 1).
	side_offset = UV.x * 2.0 - 1.0;
	vec3 to_camera = CAMERA_POSITION_WORLD - VERTEX;
	vec3 across = cross(NORMAL, to_camera);
	float span = length(across);
	// Viewed end-on, the cross product degenerates; leave the vertex in place instead of exploding.
	if (span > 0.00001) {
		VERTEX += (across / span) * radius * side_offset;
	}
}

void fragment() {
	float edge = 1.0 - abs(side_offset);
	ALBEDO = albedo.rgb * mix(1.0 - rim, 1.0, sqrt(clamp(edge, 0.0, 1.0)));
}
