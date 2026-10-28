#[vertex]
#version 450

void main() {
	const vec2 positions[3] = vec2[](
		vec2(-1.0, -1.0),
		vec2(3.0, -1.0),
		vec2(-1.0, 3.0)
	);
	gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
}

#[fragment]
#version 450

// ABI-compatible prefix of Godot Forward+'s SceneData UBO. The complete engine block contains
// more lighting/fog fields after these; this pass only needs the camera matrices at its start.
layout(set = 0, binding = 0, std140) uniform SceneDataBlock {
	mat4 projection_matrix;
	mat4 inv_projection_matrix;
	mat3x4 inv_view_matrix;
	mat3x4 view_matrix;
	mat4 projection_matrix_view[2];
	mat4 inv_projection_matrix_view[2];
	vec4 eye_offset[2];
} scene_data;

layout(set = 0, binding = 1) uniform usampler3D voxel_texture;
layout(set = 0, binding = 2) uniform usampler3D macro_texture;
layout(set = 0, binding = 3) uniform sampler2D palette_texture;

struct BVHNode {
	vec4 minimum_left;
	vec4 maximum_right;
	vec4 shape_padding;
};

struct ShapeData {
	mat4 world_to_local;
	mat4 local_to_world;
	vec4 atlas_origin_palette;
	vec4 dimensions_voxel_size;
	vec4 macro_origin_padding;
	vec4 macro_dimensions_padding;
	vec4 surface_animation;
	vec4 surface_bounds_min;
	vec4 surface_bounds_max;
};

layout(set = 0, binding = 4, std430) readonly buffer BVHNodes {
	BVHNode nodes[];
};

layout(set = 0, binding = 5, std430) readonly buffer Shapes {
	ShapeData shapes[];
};

layout(set = 0, binding = 6) uniform usampler3D clip_static_0;
layout(set = 0, binding = 7) uniform usampler3D clip_static_1;
layout(set = 0, binding = 8) uniform usampler3D clip_static_2;
layout(set = 0, binding = 9) uniform usampler3D clip_static_3;
layout(set = 0, binding = 10) uniform usampler3D clip_dynamic_0;
layout(set = 0, binding = 11) uniform usampler3D clip_dynamic_1;
layout(set = 0, binding = 12) uniform usampler3D clip_dynamic_2;
layout(set = 0, binding = 13) uniform usampler3D clip_dynamic_3;

// The shadow volume is fixed and covers the entire map: the four levels share a corner and differ
// only in cell size. Previously, each level had its own origin because it moved with the camera.
//   origin_enabled: xyz = volume corner in meters, w = 1 if shadows are enabled
//   level_size_cell: xyz = level size in cells, w = meters per cell
layout(set = 0, binding = 14, std140) uniform ShadowClipmapBlock {
	vec4 origin_enabled;
	vec4 level_size_cell[4];
} shadow_clipmap;

layout(set = 0, binding = 15) uniform usampler3D local_shadow_0;
layout(set = 0, binding = 16) uniform usampler3D local_shadow_1;
layout(set = 0, binding = 17) uniform usampler3D local_shadow_2;
layout(set = 0, binding = 18) uniform usampler3D local_shadow_3;
layout(set = 0, binding = 19) uniform usampler3D local_shadow_4;
layout(set = 0, binding = 20) uniform usampler3D local_shadow_5;
layout(set = 0, binding = 21) uniform usampler3D local_shadow_6;
layout(set = 0, binding = 22) uniform usampler3D local_shadow_7;

struct LocalLightData {
	vec4 position_range;
	vec4 direction_spot_cosine;
	vec4 color_energy;
	vec4 origin_cell_size;
};

layout(set = 0, binding = 23, std140) uniform LocalShadowBlock {
	LocalLightData lights[32];
	vec4 options;
} local_shadow_block;

// Table `macrocell -> brick` for all Shapes, stored consecutively. The voxel atlas stores only
// occupied 8x8x8 bricks for each Shape, not its full volume:
// `macro_dimensions_padding.w` gives the start of this Shape's range, and -1 marks an empty slot.
layout(set = 0, binding = 24, std430) readonly buffer BrickSlots {
	int brick_slots[];
};

// Uses 112 of the 128 bytes Vulkan guarantees for push constants. One vec4 remains; beyond that,
// lighting needs to move to its own UBO.
layout(push_constant, std430) uniform Params {
	vec4 raster_view_nodes;
	vec4 render_options;
	vec4 reserved;
	vec4 sun_direction_energy;
	vec4 sun_color;
	vec4 ambient_sky;
	vec4 ambient_ground;
} params;

layout(location = 0) out vec4 frag_color;


vec2 intersect_box(vec3 origin, vec3 direction, vec3 minimum, vec3 maximum) {
	vec3 safe_direction = mix(-vec3(1.0), vec3(1.0), greaterThanEqual(direction, vec3(0.0)))
		* max(abs(direction), vec3(1e-7));
	vec3 a = (minimum - origin) / safe_direction;
	vec3 b = (maximum - origin) / safe_direction;
	vec3 near_axis = min(a, b);
	vec3 far_axis = max(a, b);
	return vec2(
		max(near_axis.x, max(near_axis.y, near_axis.z)),
		min(far_axis.x, min(far_axis.y, far_axis.z))
	);
}


vec3 srgb_to_linear(vec3 color) {
	vec3 low = color / 12.92;
	vec3 high = pow((color + vec3(0.055)) / 1.055, vec3(2.4));
	return mix(low, high, greaterThan(color, vec3(0.04045)));
}


float box_near_distance(
	vec3 origin, vec3 direction, vec3 minimum, vec3 maximum, float distance_limit
) {
	vec2 interval = intersect_box(origin, direction, minimum, maximum);
	float near_distance = max(interval.x, 0.0);
	return interval.y >= near_distance && near_distance < distance_limit ? near_distance : 1.0e30;
}


// Static and dynamic data are merged into the same volume, so each sample needs only one read
// instead of two reads and an OR. The `clip_dynamic_*` samplers point to these same textures.
uint clipmap_fetch(int level, ivec3 packed_cell) {
	if (level == 0) return texelFetch(clip_static_0, packed_cell, 0).r;
	if (level == 1) return texelFetch(clip_static_1, packed_cell, 0).r;
	if (level == 2) return texelFetch(clip_static_2, packed_cell, 0).r;
	return texelFetch(clip_static_3, packed_cell, 0).r;
}


// All levels cover the same region of the world, so select a level directly by distance traveled
// rather than by "which one contains me." Outside the volume there is no geometry and therefore no
// occlusion.
//
// There is no longer any stochastic selection between levels. It was used to hide the seam where
// one clipmap ended and the next began, supposedly relying on TAA to integrate the noise—but the
// project had no TAA, so it was pure noise. Without clipmaps, there is no seam to hide.
bool clipmap_occupied(vec3 world_position, int level, out float selected_cell_size) {
	vec3 origin = shadow_clipmap.origin_enabled.xyz;
	float cell_size = shadow_clipmap.level_size_cell[level].w;
	vec3 size = shadow_clipmap.level_size_cell[level].xyz;
	selected_cell_size = cell_size;
	vec3 local = (world_position - origin) / cell_size;
	if (any(lessThan(local, vec3(0.0))) || any(greaterThanEqual(local, size))) return false;
	ivec3 logical = ivec3(local);
	ivec3 packed = logical / 2;
	ivec3 subcell = logical & ivec3(1);
	int bit = subcell.x | (subcell.y << 1) | (subcell.z << 2);
	return (clipmap_fetch(level, packed) & (1u << bit)) != 0u;
}


// Hierarchical tracing, following Teardown's "super sparse voxel tracing": start at the coarsest
// mip and descend only when that level reports something ahead.
//
// Previously, the level was selected from a fixed-distance table and the ray always advanced five
// cells. This caused two problems. First, quality: a 0.5 m step passed through a one-voxel wall
// without seeing it, which made the shadows "unnoticeable." Second, cost: rays toward open sky still
// read level 0, which occupies 133 MB and does not fit in the GPU texture cache; measured frame time
// reached 17 ms depending on where you looked.
//
// Here, a clear ray is resolved by reading level 3, which is 0.3 MB and fits entirely in cache; it
// descends to the large volume only when it actually approaches something. When descending, the
// step is one cell at that level, so steps near geometry are 0.2 m and nothing is missed.
float trace_sun_shadow(vec3 world_hit, vec3 normal, vec3 light_direction) {
	if (shadow_clipmap.origin_enabled.w < 0.5) return 1.0;
	vec3 ray_origin = world_hit + normal * 0.06;
	float distance_along_ray = 0.12;
	int level = 3;
	for (int step = 0; step < 40; step++) {
		float cell_size;
		if (clipmap_occupied(ray_origin + light_direction * distance_along_ray, level, cell_size)) {
			// Occupied at the fine level means a real shadow. At a coarse level it only means
			// "something is in this large cell": descend and check the same point again without advancing.
			if (level == 0) return 0.28;
			level--;
			continue;
		}
		// Empty: advance one cell at this level and try to ascend. If the level above is also empty,
		// the ray can take long, inexpensive steps again.
		distance_along_ray += shadow_clipmap.level_size_cell[level].w;
		level = min(level + 1, 3);
		if (distance_along_ray > 80.0) break;
	}
	return 1.0;
}


uint local_shadow_fetch(int light_index, ivec3 packed_cell) {
	if (light_index == 0) return texelFetch(local_shadow_0, packed_cell, 0).r;
	if (light_index == 1) return texelFetch(local_shadow_1, packed_cell, 0).r;
	if (light_index == 2) return texelFetch(local_shadow_2, packed_cell, 0).r;
	if (light_index == 3) return texelFetch(local_shadow_3, packed_cell, 0).r;
	if (light_index == 4) return texelFetch(local_shadow_4, packed_cell, 0).r;
	if (light_index == 5) return texelFetch(local_shadow_5, packed_cell, 0).r;
	if (light_index == 6) return texelFetch(local_shadow_6, packed_cell, 0).r;
	return texelFetch(local_shadow_7, packed_cell, 0).r;
}


bool local_shadow_occupied(int light_index, vec3 world_position) {
	LocalLightData light = local_shadow_block.lights[light_index];
	ivec3 logical = ivec3(floor(
		(world_position - light.origin_cell_size.xyz) / light.origin_cell_size.w
	));
	if (any(lessThan(logical, ivec3(0))) || any(greaterThanEqual(logical, ivec3(256)))) {
		return false;
	}
	ivec3 packed = logical / 2;
	ivec3 subcell = logical & ivec3(1);
	int bit = subcell.x | (subcell.y << 1) | (subcell.z << 2);
	return (local_shadow_fetch(light_index, packed) & (1u << bit)) != 0u;
}


float trace_local_shadow(
	int light_index, vec3 world_hit, vec3 normal, vec3 direction_to_light, float distance_to_light
) {
	float cell_size = local_shadow_block.lights[light_index].origin_cell_size.w;
	float distance_along_ray = max(0.16, cell_size * 1.5);
	for (int step = 0; step < 48; step++) {
		if (distance_along_ray >= distance_to_light) break;
		vec3 sample_position = world_hit + normal * 0.06
			+ direction_to_light * distance_along_ray;
		if (local_shadow_occupied(light_index, sample_position)) return 0.18;
		distance_along_ray += cell_size * 1.6;
	}
	return 1.0;
}


vec3 entry_normal(vec3 point, vec3 direction, vec3 volume_size) {
	const float epsilon = 0.002;
	if (abs(point.x) < epsilon) return vec3(-1.0, 0.0, 0.0);
	if (abs(point.x - volume_size.x) < epsilon) return vec3(1.0, 0.0, 0.0);
	if (abs(point.y) < epsilon) return vec3(0.0, -1.0, 0.0);
	if (abs(point.y - volume_size.y) < epsilon) return vec3(0.0, 1.0, 0.0);
	if (abs(point.z) < epsilon) return vec3(0.0, 0.0, -1.0);
	if (abs(point.z - volume_size.z) < epsilon) return vec3(0.0, 0.0, 1.0);
	vec3 axis = abs(direction);
	if (axis.x > axis.y && axis.x > axis.z) return vec3(-sign(direction.x), 0.0, 0.0);
	if (axis.y > axis.z) return vec3(0.0, -sign(direction.y), 0.0);
	return vec3(0.0, 0.0, -sign(direction.z));
}


// Track-link phase within the loop, in [0,1), or -1.0 if the cell is not an animated track.
// The decoder stores cells as (length, height, lateral): the profile occupies XY, and Z identifies
// the track. Unwrap by direction from the profile center, not by "the nearest box edge": at the
// front and rear, the ring is curved and no cell is near a straight edge, so the previous method
// jumped between segments and made the pattern appear to slide sideways.
float surface_link_phase(ShapeData shape, uint material, vec3 cell) {
	vec4 animation = shape.surface_animation;
	if (animation.w < 0.5 || material != uint(round(animation.z))) return -1.0;
	vec3 track_min = shape.surface_bounds_min.xyz;
	vec3 track_max = shape.surface_bounds_max.xyz;
	if (any(lessThan(cell, track_min)) || any(greaterThanEqual(cell, track_max))) return -1.0;
	// Arc length along the profile octagon. Mapping by direction from the center would be shorter,
	// but stretches the links at the front and rear: there, the edge is farther from the center and
	// the same parameter interval covers twice as many cells. True arc length keeps spacing uniform
	// vuelta.
	vec2 extent = (track_max.xy - track_min.xy) * 0.5 - 0.5;
	float chamfer = shape.surface_bounds_max.w;
	vec2 p = cell.xy - (track_min.xy + track_max.xy) * 0.5;
	vec2 a = abs(p);
	float flat_x = 2.0 * (extent.x - chamfer);
	float flat_y = 2.0 * (extent.y - chamfer);
	float diagonal = chamfer * 1.41421356;
	float perimeter = 2.0 * (flat_x + flat_y) + 4.0 * diagonal;
	float s;
	if (a.x + a.y - (extent.x + extent.y - chamfer) >= max(a.x - extent.x, a.y - extent.y)) {
		if (p.x > 0.0 && p.y < 0.0) s = flat_x + (p.x - (extent.x - chamfer)) * 1.41421356;
		else if (p.x > 0.0) s = flat_x + diagonal + flat_y + (extent.x - p.x) * 1.41421356;
		else if (p.y > 0.0) s = 2.0 * flat_x + 2.0 * diagonal + flat_y
			+ (-(extent.x - chamfer) - p.x) * 1.41421356;
		else s = 2.0 * flat_x + 3.0 * diagonal + 2.0 * flat_y + (p.x + extent.x) * 1.41421356;
	} else if (a.x - extent.x >= a.y - extent.y) {
		s = p.x > 0.0
			? flat_x + diagonal + (p.y + (extent.y - chamfer))
			: 2.0 * flat_x + 3.0 * diagonal + flat_y + ((extent.y - chamfer) - p.y);
	} else {
		s = p.y < 0.0
			? p.x + (extent.x - chamfer)
			: flat_x + 2.0 * diagonal + flat_y + ((extent.x - chamfer) - p.x);
	}
	// The perimeter is rarely an exact multiple of the link spacing. Rounding the link count and
	// distributing the links around the perimeter closes the loop without a broken seam.
	float links = max(round(perimeter / max(shape.surface_bounds_min.w, 1.0)), 1.0);
	float offset = cell.z < (track_min.z + track_max.z) * 0.5 ? animation.x : animation.y;
	return fract((s + offset) / perimeter * links);
}


// Only the outer ring layer can be emptied: the inside is hollow, and removing both thickness
// layers would create a hole visible through the tank. The track profile is an octagon (ends
// chamfered at 45 degrees), so its signed distance comes from three half-planes.
bool surface_link_outer_shell(ShapeData shape, vec3 cell) {
	vec3 track_min = shape.surface_bounds_min.xyz;
	vec3 track_max = shape.surface_bounds_max.xyz;
	vec2 extent = (track_max.xy - track_min.xy) * 0.5 - 0.5;
	vec2 d = abs(cell.xy - (track_min.xy + track_max.xy) * 0.5);
	float chamfer = shape.surface_bounds_max.w;
	return max(
		max(d.x - extent.x, d.y - extent.y),
		d.x + d.y - (extent.x + extent.y - chamfer)
	) > -0.5;
}


// Fraction of the spacing occupied by a link; the remainder is the gap that moves with the track.
const float SURFACE_LINK_DUTY = 0.75;


bool trace_shape(
	int shape_index,
	vec3 ray_origin_world,
	vec3 ray_direction_world,
	float best_world_t,
	out float hit_world_t,
	out vec3 hit_normal_world,
	out uint material_index,
	out int palette_row,
	out vec3 hit_cell,
	out vec3 hit_normal_local_out,
	out int steps_taken
) {
	ShapeData shape = shapes[shape_index];
	bool glass_pass = params.render_options.z > 0.5;
	if (glass_pass && shape.macro_origin_padding.w < 0.5) return false;
	float voxel_size = shape.dimensions_voxel_size.w;
	vec3 dimensions = shape.dimensions_voxel_size.xyz;
	ivec3 volume_dimensions = ivec3(dimensions);
	ivec3 macro_dimensions = ivec3(shape.macro_dimensions_padding.xyz);
	ivec3 macro_origin = ivec3(shape.macro_origin_padding.xyz);
	int table_base = int(shape.macro_dimensions_padding.w);
	ivec2 brick_grid = ivec2(params.reserved.yz);
	palette_row = int(shape.atlas_origin_palette.w);
	vec3 local_origin_meters = (shape.world_to_local * vec4(ray_origin_world, 1.0)).xyz;
	vec3 local_direction = normalize((shape.world_to_local * vec4(ray_direction_world, 0.0)).xyz);
	vec3 ray_origin = local_origin_meters / voxel_size + dimensions * 0.5;
	vec2 bounds = intersect_box(ray_origin, local_direction, vec3(0.0), dimensions);
	float best_voxel_t = best_world_t / voxel_size;
	if (bounds.y < max(bounds.x, 0.0) || max(bounds.x, 0.0) > best_voxel_t) {
		return false;
	}

	float current_t = max(bounds.x, 0.0) + 0.0005;
	vec3 entry_point = ray_origin + local_direction * current_t;
	ivec3 cell = clamp(ivec3(floor(entry_point)), ivec3(0), volume_dimensions - ivec3(1));
	ivec3 step_direction = ivec3(sign(local_direction));
	vec3 safe_direction = mix(
		-vec3(1.0), vec3(1.0), greaterThanEqual(local_direction, vec3(0.0))
	) * max(abs(local_direction), vec3(1e-7));
	vec3 delta_t = abs(1.0 / safe_direction);
	vec3 next_boundary = vec3(cell) + mix(
		vec3(0.0), vec3(1.0), greaterThan(local_direction, vec3(0.0))
	);
	vec3 side_t = (next_boundary - ray_origin) / safe_direction;
	vec3 hit_normal_local = entry_normal(entry_point, local_direction, dimensions);
	material_index = 0u;
	hit_cell = vec3(0.0);
	hit_normal_local_out = vec3(0.0);
	steps_taken = 0;
	int max_steps = int(params.render_options.x);
	// The brick changes only every eight cells; cache it to avoid rereading the table at each step.
	ivec3 cached_macro = ivec3(-1);
	ivec3 brick_origin = ivec3(0);

	for (int iteration = 0; iteration < 256; iteration++) {
		if (iteration >= max_steps || current_t > bounds.y || current_t > best_voxel_t) break;
		if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, volume_dimensions))) break;
		steps_taken = iteration + 1;
		ivec3 macro_cell = clamp(cell / 8, ivec3(0), macro_dimensions - ivec3(1));
		if (texelFetch(macro_texture, macro_origin + macro_cell, 0).r == 0u) {
			vec3 macro_minimum = vec3(macro_cell * 8);
			vec3 macro_maximum = min(macro_minimum + vec3(8.0), dimensions);
			vec3 macro_boundary = mix(
				macro_minimum, macro_maximum, greaterThan(local_direction, vec3(0.0))
			);
			vec3 macro_side_t = (macro_boundary - ray_origin) / safe_direction;
			float macro_t = min(macro_side_t.x, min(macro_side_t.y, macro_side_t.z));
			// The face used to leave the empty macrocell is also the one used to enter the next, so
			// it is the correct normal for the next voxel. Without this, that voxel
			// hereda la normal de la entrada al volumen: en el terreno de Lee, que va al 8 % de
			// is filled, the ray crosses empty macrocells and suddenly hits the surface, which looked
			// flat-shaded—gray sheets with the straight edges of the macrocells.
			if (macro_t == macro_side_t.x) {
				hit_normal_local = vec3(-float(step_direction.x), 0.0, 0.0);
			} else if (macro_t == macro_side_t.y) {
				hit_normal_local = vec3(0.0, -float(step_direction.y), 0.0);
			} else {
				hit_normal_local = vec3(0.0, 0.0, -float(step_direction.z));
			}
			current_t = macro_t + 0.0005;
			if (current_t > bounds.y || current_t > best_voxel_t) break;
			cell = ivec3(floor(ray_origin + local_direction * current_t));
			if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, volume_dimensions))) break;
			next_boundary = vec3(cell) + mix(
				vec3(0.0), vec3(1.0), greaterThan(local_direction, vec3(0.0))
			);
			side_t = (next_boundary - ray_origin) / safe_direction;
			continue;
		}

		if (macro_cell != cached_macro) {
			cached_macro = macro_cell;
			int slot = brick_slots[table_base + macro_cell.x
				+ macro_dimensions.x * (macro_cell.y + macro_dimensions.y * macro_cell.z)];
			// The macrocell is occupied, so the brick exists; otherwise, the Shape has not been uploaded.
			if (slot < 0) break;
			brick_origin = ivec3(
				slot % brick_grid.x,
				(slot / brick_grid.x) % brick_grid.y,
				slot / (brick_grid.x * brick_grid.y)
			) * 8;
		}
		material_index = texelFetch(voxel_texture, brick_origin + (cell & ivec3(7)), 0).r;
		// Links are actually cut out instead of painted on top: phase determines which outer-layer
		// cells are missing, so the gap moves with the track and gives it depth. This is render
		// geometry, not volume geometry; physics and destruction are unaffected.
		vec3 link_cell = vec3(cell) + vec3(0.5);
		if (material_index != 0u
			&& surface_link_phase(shape, material_index, link_cell) > SURFACE_LINK_DUTY
			&& surface_link_outer_shell(shape, link_cell)) {
			material_index = 0u;
		}
		if (material_index != 0u) {
			float alpha = texelFetch(
				palette_texture, ivec2(int(material_index), palette_row), 0
			).a;
			bool is_glass = alpha < 0.995;
			if (is_glass == glass_pass) {
				hit_world_t = current_t * voxel_size;
				hit_normal_world = normalize(mat3(shape.local_to_world) * hit_normal_local);
				hit_cell = vec3(cell) + vec3(0.5);
				hit_normal_local_out = hit_normal_local;
				return true;
			}
			// The other material class is transparent to this pass; advance to the next cell.
			material_index = 0u;
		}

		if (side_t.x <= side_t.y && side_t.x <= side_t.z) {
			current_t = side_t.x;
			side_t.x += delta_t.x;
			cell.x += step_direction.x;
			hit_normal_local = vec3(-float(step_direction.x), 0.0, 0.0);
		} else if (side_t.y <= side_t.z) {
			current_t = side_t.y;
			side_t.y += delta_t.y;
			cell.y += step_direction.y;
			hit_normal_local = vec3(0.0, -float(step_direction.y), 0.0);
		} else {
			current_t = side_t.z;
			side_t.z += delta_t.z;
			cell.z += step_direction.z;
			hit_normal_local = vec3(0.0, 0.0, -float(step_direction.z));
		}
	}
	return false;
}


void main() {
	int view_index = int(params.raster_view_nodes.z);
	mat4 projection = view_index == 0
		? scene_data.projection_matrix
		: scene_data.projection_matrix_view[view_index];
	mat4 inverse_projection = view_index == 0
		? scene_data.inv_projection_matrix
		: scene_data.inv_projection_matrix_view[view_index];
	mat4 inverse_view = transpose(mat4(
		scene_data.inv_view_matrix[0],
		scene_data.inv_view_matrix[1],
		scene_data.inv_view_matrix[2],
		vec4(0.0, 0.0, 0.0, 1.0)
	));
	mat4 view_matrix = transpose(mat4(
		scene_data.view_matrix[0],
		scene_data.view_matrix[1],
		scene_data.view_matrix[2],
		vec4(0.0, 0.0, 0.0, 1.0)
	));
	vec2 uv = gl_FragCoord.xy / params.raster_view_nodes.xy;
	vec2 ndc = uv * 2.0 - 1.0;
	vec4 far_view = inverse_projection * vec4(ndc, 0.0, 1.0);
	vec3 ray_direction_view = normalize(far_view.xyz / far_view.w);
	vec3 ray_origin_world = inverse_view[3].xyz;
	vec3 ray_direction_world = normalize(mat3(inverse_view) * ray_direction_view);

	float best_t = 1.0e30;
	vec3 best_normal = vec3(0.0);
	uint best_material = 0u;
	int best_palette_row = 0;
	int best_shape_index = -1;
	vec3 best_cell = vec3(0.0);
	vec3 best_normal_local = vec3(0.0);
	int best_steps = 0;
	int stack[64];
	int stack_size = 1;
	stack[0] = 0;
	int node_count = int(params.raster_view_nodes.w);

	for (int traversal = 0; traversal < 512 && stack_size > 0; traversal++) {
		int node_index = stack[--stack_size];
		if (node_index < 0 || node_index >= node_count) continue;
		BVHNode node = nodes[node_index];
		vec2 interval = intersect_box(
			ray_origin_world,
			ray_direction_world,
			node.minimum_left.xyz,
			node.maximum_right.xyz
		);
		if (interval.y < max(interval.x, 0.0) || max(interval.x, 0.0) >= best_t) continue;
		int shape_index = int(node.shape_padding.x);
		if (shape_index >= 0) {
			float candidate_t;
			vec3 candidate_normal;
			uint candidate_material;
			int candidate_palette_row;
			vec3 candidate_cell;
			vec3 candidate_normal_local;
			int candidate_steps;
			if (trace_shape(
				shape_index,
				ray_origin_world,
				ray_direction_world,
				best_t,
				candidate_t,
				candidate_normal,
				candidate_material,
				candidate_palette_row,
				candidate_cell,
				candidate_normal_local,
				candidate_steps
			) && candidate_t < best_t) {
				best_t = candidate_t;
				best_normal = candidate_normal;
				best_material = candidate_material;
				best_palette_row = candidate_palette_row;
				best_shape_index = shape_index;
				best_cell = candidate_cell;
				best_normal_local = candidate_normal_local;
				best_steps = candidate_steps;
			}
		} else if (stack_size <= 61) {
			int left_index = int(node.minimum_left.w);
			int right_index = int(node.maximum_right.w);
			BVHNode left_node = nodes[left_index];
			BVHNode right_node = nodes[right_index];
			float left_near = box_near_distance(
				ray_origin_world, ray_direction_world,
				left_node.minimum_left.xyz, left_node.maximum_right.xyz, best_t
			);
			float right_near = box_near_distance(
				ray_origin_world, ray_direction_world,
				right_node.minimum_left.xyz, right_node.maximum_right.xyz, best_t
			);
			if (left_near < right_near) {
				if (right_near < 1.0e29) stack[stack_size++] = right_index;
				if (left_near < 1.0e29) stack[stack_size++] = left_index;
			} else {
				if (left_near < 1.0e29) stack[stack_size++] = left_index;
				if (right_near < 1.0e29) stack[stack_size++] = right_index;
			}
		}
	}

	if (best_material == 0u) discard;
	vec3 world_hit = ray_origin_world + ray_direction_world * best_t;
	vec4 clip_hit = projection * view_matrix * vec4(world_hit, 1.0);
	gl_FragDepth = clip_hit.z / clip_hit.w;
	vec4 material_color = texelFetch(
		palette_texture, ivec2(int(best_material), best_palette_row), 0
	);
	vec4 material_properties = texelFetch(
		palette_texture, ivec2(int(best_material) + 256, best_palette_row), 0
	);
	// MagicaVoxel RGBA is authored in sRGB. The compositor target is HDR-linear; treating the
	// palette bytes as linear was the reason imported maps looked pale and overexposed.
	vec3 albedo = srgb_to_linear(material_color.rgb);
	if (best_shape_index >= 0) {
		float link_phase = surface_link_phase(shapes[best_shape_index], best_material, best_cell);
		if (link_phase >= 0.0) {
			// Traversal already removes the gap; here, only darken the adjacent edge so the slot
			// reads clearly under flat lighting, while the gap's bottom (inner layer) remains shadowed.
			albedo *= mix(
				0.45, 1.15,
				smoothstep(0.0, 0.22, min(link_phase, SURFACE_LINK_DUTY - link_phase))
			);
		}
	}
	float roughness = clamp(material_properties.r, 0.02, 1.0);
	float metallic = clamp(material_properties.g, 0.0, 1.0);
	float emission = material_properties.b * 32.0;
	// The scene supplies the sun: direction, color, and energy come from the imported skybox, as in
	// Teardown, which takes its direction from the HDRI's brightest pixel. Previously it was fixed
	// at (-0.45, 0.82, 0.35)—55 degrees elevation, noon—with no relation to the sky being rendered.
	vec3 light_direction = params.sun_direction_energy.xyz;
	vec3 sun_light = params.sun_color.rgb * params.sun_direction_energy.w;
	float diffuse = max(dot(best_normal, light_direction), 0.0);
	float shadow = trace_sun_shadow(world_hit, best_normal, light_direction);
	vec3 view_direction = -ray_direction_world;
	vec3 half_direction = normalize(light_direction + view_direction);
	float specular_power = mix(128.0, 3.0, roughness * roughness);
	float specular_amount = pow(max(dot(best_normal, half_direction), 0.0), specular_power)
		* (1.0 - roughness * 0.65);
	vec3 fresnel_zero = mix(vec3(0.04), albedo, metallic);
	vec3 diffuse_color = albedo * (1.0 - metallic * 0.78);
	// Hemispheric ambient light replaces the previous `albedo * 0.30` constant: both the sky above
	// and ground bounce below are averaged from the skybox itself. With a single constant, a face
	// toward the sky and a porch roof looked identical, making everything appear flat—far more than
	// the lack of shadows did.
	vec3 ambient = mix(
		params.ambient_ground.rgb, params.ambient_sky.rgb, best_normal.y * 0.5 + 0.5
	);
	vec3 shaded = albedo * ambient
		+ diffuse_color * diffuse * sun_light * shadow
		+ fresnel_zero * specular_amount * sun_light * shadow;
	int local_light_count = int(local_shadow_block.options.x);
	int local_shadow_count = int(local_shadow_block.options.y);
	for (int light_index = 0; light_index < 32; light_index++) {
		if (light_index >= local_light_count) break;
		LocalLightData local_light = local_shadow_block.lights[light_index];
		vec3 to_light = local_light.position_range.xyz - world_hit;
		float distance_to_light = length(to_light);
		if (distance_to_light <= 0.001 || distance_to_light >= local_light.position_range.w) continue;
		vec3 direction_to_light = to_light / distance_to_light;
		vec3 direction_from_light = -direction_to_light;
		if (dot(direction_from_light, local_light.direction_spot_cosine.xyz)
			< local_light.direction_spot_cosine.w) continue;
		float attenuation = 1.0 - distance_to_light / local_light.position_range.w;
		attenuation *= attenuation;
		float local_diffuse = max(dot(best_normal, direction_to_light), 0.0);
		float local_shadow = light_index < local_shadow_count
			? trace_local_shadow(
				light_index, world_hit, best_normal, direction_to_light, distance_to_light
			) : 1.0;
		vec3 local_half = normalize(direction_to_light + view_direction);
		float local_specular = pow(
			max(dot(best_normal, local_half), 0.0), specular_power
		) * (1.0 - roughness * 0.65);
		shaded += (diffuse_color * local_diffuse + fresnel_zero * local_specular)
			* local_light.color_energy.rgb * local_light.color_energy.w
			* attenuation * local_shadow;
	}
	shaded += albedo * emission;
	if (params.render_options.y > 0.5) {
		shaded = mix(vec3(0.05, 0.2, 0.8), vec3(1.0, 0.12, 0.02), float(best_steps) / 192.0);
	}
	frag_color = vec4(shaded, material_color.a);
}
