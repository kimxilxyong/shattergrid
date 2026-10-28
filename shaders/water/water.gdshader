shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

// Water is drawn last, as in Teardown: first read the opaque scene's color and depth, then refract
// that color and search for a short reflection in the depth buffer. Eight steps are deliberate:
// at the project's internal 0.4 scale, they cost much less than a reflection camera and do not
// redraw Lee's 79 million voxels.
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D wave_normal : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform bool reflections_enabled = true;
uniform float reflection_strength : hint_range(0.0, 1.0) = 0.72;
uniform float refraction_strength : hint_range(0.0, 0.04) = 0.010;
uniform vec3 sky_reflection_color : source_color = vec3(0.22, 0.31, 0.36);
uniform vec3 sun_direction_world = vec3(0.3, 0.6, 0.7);
uniform vec3 sun_color : source_color = vec3(1.0, 0.75, 0.48);
uniform float surface_lift = 0.018;

varying vec3 world_position;


void vertex() {
	VERTEX.y += surface_lift;
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


float view_distance_at(vec2 uv, mat4 inverse_projection) {
	float depth = textureLod(depth_texture, uv, 0.0).r;
	vec4 view = inverse_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return -view.z / max(view.w, 0.00001);
}


vec2 project_view_position(vec3 position, mat4 projection) {
	vec4 clip = projection * vec4(position, 1.0);
	return clip.xy / max(clip.w, 0.00001) * 0.5 + 0.5;
}


vec3 screen_space_reflection(
	vec3 origin, vec3 direction, vec2 origin_uv, mat4 projection, mat4 inverse_projection,
	out float confidence
) {
	vec3 sample_position = origin;
	vec2 hit_uv = origin_uv;
	confidence = 0.0;
	for (int step = 0; step < 8; step++) {
		// Increasing step size gives good precision near the water and reaches about 12 m without
		// requiring 32–64 samples.
		float stride = 0.35 + float(step) * 0.32;
		sample_position += direction * stride;
		if (sample_position.z >= -0.03) {
			break;
		}
		vec2 uv = project_view_position(sample_position, projection);
		if (any(lessThan(uv, vec2(0.003))) || any(greaterThan(uv, vec2(0.997)))) {
			break;
		}
		float scene_distance = view_distance_at(uv, inverse_projection);
		float ray_distance = -sample_position.z;
		float separation = scene_distance - ray_distance;
		// The ray has just reached the first opaque surface. Tolerance increases with the step size
		// so thin walls are not missed at greater distances.
		if (separation <= 0.08 + stride * 0.18 && separation > -1.1) {
			hit_uv = uv;
			float edge = min(min(uv.x, uv.y), min(1.0 - uv.x, 1.0 - uv.y));
			confidence = smoothstep(0.0, 0.06, edge) * (1.0 - float(step) / 10.0);
			break;
		}
	}
	return textureLod(screen_texture, hit_uv, 1.0).rgb;
}


void fragment() {
	// Two oblique octaves avoid the exact 90-degree rotation that produced visible crosses/grids.
	// The normal already contains eight domain-warped frequencies, so this still takes two samples.
	vec2 flow_a = UV + vec2(0.0137, 0.0081) * TIME;
	mat2 oblique = mat2(vec2(0.798636, 0.601815), vec2(-0.601815, 0.798636));
	vec2 flow_b = oblique * UV * 1.91 + vec2(-0.0084, 0.0129) * TIME + vec2(0.37, 0.19);
	vec4 wave_a = texture(wave_normal, flow_a);
	vec4 wave_b = texture(wave_normal, flow_b);
	float authored_ripple = COLOR.a;
	float slope = mix(0.11, 0.30, authored_ripple);
	vec2 wave_slope = (wave_a.xz * 2.0 - 1.0) + (wave_b.xz * 2.0 - 1.0) * 0.46;
	vec3 world_normal = normalize(vec3(wave_slope.x * slope, 1.0, wave_slope.y * slope));
	vec3 view_normal = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
	vec3 view_to_camera = normalize(-VERTEX);
	float ndotv = max(dot(view_normal, view_to_camera), 0.0);
	float fresnel = 0.025 + 0.975 * pow(1.0 - ndotv, 5.0);

	float water_distance = max(-VERTEX.z, 0.001);
	float scene_distance = view_distance_at(SCREEN_UV, INV_PROJECTION_MATRIX);
	float thickness = clamp(scene_distance - water_distance, 0.0, 18.0);
	vec2 refracted_uv = clamp(
		SCREEN_UV + view_normal.xy * refraction_strength * min(thickness, 1.5),
		vec2(0.002), vec2(0.998)
	);
	// Do not pull an object across the water when it is actually in front of it.
	if (view_distance_at(refracted_uv, INV_PROJECTION_MATRIX) <= water_distance + 0.015) {
		refracted_uv = SCREEN_UV;
	}
	vec3 scene_color = textureLod(screen_texture, refracted_uv, min(thickness * 0.12, 2.0)).rgb;
	float visibility = max(UV2.y, 0.2);
	float absorption = 1.0 - exp(-thickness / visibility);
	vec3 deep_color = COLOR.rgb;
	vec3 refracted = mix(scene_color, deep_color, clamp(absorption * 0.88, 0.0, 0.94));

	// Lee's sky is deliberately sepia. Mild spectral absorption preserves that reflection while
	// preventing all the water from looking muddy when SSR finds no geometry.
	vec3 fallback_reflection = mix(
		sky_reflection_color, deep_color * 2.0 + vec3(0.015, 0.05, 0.055), 0.20
	);
	vec3 reflected = fallback_reflection;
	float reflection_confidence = 0.0;
	if (reflections_enabled && fresnel > 0.035) {
		vec3 ray_direction = normalize(reflect(normalize(VERTEX), view_normal));
		reflected = screen_space_reflection(
			VERTEX + view_normal * 0.04, ray_direction, SCREEN_UV, PROJECTION_MATRIX,
			INV_PROJECTION_MATRIX, reflection_confidence
		);
		reflected = mix(fallback_reflection, reflected, reflection_confidence);
	}
	vec3 view_direction_world = normalize(CAMERA_POSITION_WORLD - world_position);
	vec3 reflected_sun = reflect(-normalize(sun_direction_world), world_normal);
	float sun_glint = pow(max(dot(reflected_sun, view_direction_world), 0.0), 220.0);
	reflected += sun_color * sun_glint * 1.45;

	vec3 water_color = mix(refracted, reflected, clamp(fresnel * reflection_strength, 0.0, 0.96));
	// A subtle blue-green transmission keeps the water clear at head-on angles without removing the
	// authored dark color of the ponds or washing out the reflection at the surface.
	water_color += vec3(0.0, 0.016, 0.019) * (1.0 - fresnel) * (0.25 + absorption * 0.75);
	// Shoreline foam from the depth already sampled. The normal's alpha adds breakup without another
	// texture; foam appears neither over the sky nor over backgrounds deeper than 45 cm.
	float foam_noise = mix(wave_a.a, wave_b.a, 0.41);
	float foam = (1.0 - smoothstep(0.025, 0.58, thickness))
		* smoothstep(0.43, 0.76, foam_noise + wave_slope.x * 0.08);
	water_color = mix(water_color, vec3(0.72, 0.84, 0.83), foam * 0.62);

	ALBEDO = water_color;
	// ALPHA makes Godot draw this after the opaque scene. The color already contains the refracted
	// background, so output one rather than blending it a second time.
	ALPHA = 1.0;
}
