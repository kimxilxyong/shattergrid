shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_disabled,
	shadows_disabled;

// Teardown-style smoke puff; the game uses it as a reference and does not render smoke as cubes.
// There, each particle is a hollow pyramid facing the camera with interpolated normals: the
// geometry is hidden and only a shaded sphere is visible. This does the same with a single quad,
// calculating the spherical normal in the fragment shader for less cost and the same result.
//
// The texture is domain-warped fBm—f(p + f(p)), which turns flat noise into streaks and swirls.
// It serves three purposes at once: breaking up the silhouette, varying internal density (a puff
// with uniform density looks like a sticker), and perturbing the normal to give real smoke its
// characteristic cauliflower-like appearance.
//
// It also erodes with age: instead of lowering the overall opacity, raise the threshold so only
// the densest cores remain. The puff unravels into wisps instead of disappearing all at once.

uniform float emissive = 0.0;
// How strongly to soften the edge. Higher values fade smoke well before the silhouette, making it
// look soft. Fire uses a lower value because flames have defined edges.
uniform float edge_softness = 1.8;
uniform float noise_scale = 2.2;
uniform float erosion = 0.75;
uniform float bump_strength = 1.6;
// Distance over which the puff fades into geometry. Without this, the dust curtain is cut off by a
// straight line at the ground and becomes very noticeable.
uniform float soft_distance = 1.2;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear;

varying float seed;
varying float age;


float hash13(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}


float value_noise(vec2 x, float z) {
	vec2 i = floor(x);
	vec2 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash13(vec3(i, z)), hash13(vec3(i + vec2(1.0, 0.0), z)), f.x),
		mix(hash13(vec3(i + vec2(0.0, 1.0), z)), hash13(vec3(i + vec2(1.0, 1.0), z)), f.x),
		f.y
	);
}


float fbm(vec2 x, float z) {
	return value_noise(x, z) * 0.53 + value_noise(x * 2.1, z) * 0.29
		+ value_noise(x * 4.4, z) * 0.18;
}


void vertex() {
	// Billboard while preserving per-axis scale: each puff's size comes from MODEL_MATRIX, which is
	// how `emit_particle` carries per-particle scale.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		normalize(INV_VIEW_MATRIX[0]) * length(MODEL_MATRIX[0].xyz),
		normalize(INV_VIEW_MATRIX[1]) * length(MODEL_MATRIX[1].xyz),
		normalize(INV_VIEW_MATRIX[2]) * length(MODEL_MATRIX[2].xyz),
		MODEL_MATRIX[3]
	);
	// Per-particle seed from its birth position. Without it, every puff shares a silhouette and the
	// cloud looks stamped out.
	seed = hash13(floor(MODEL_MATRIX[3].xyz * 7.0)) * 40.0;
	// `CUSTOM.y` is the lifetime fraction written by the process material.
	age = INSTANCE_CUSTOM.y;
}


void fragment() {
	vec2 disc = UV * 2.0 - 1.0;
	// Rotate each puff's noise independently; otherwise the same pattern repeats across the cloud.
	float turn = seed * 1.7;
	vec2 sample_uv = mat2(vec2(cos(turn), -sin(turn)), vec2(sin(turn), cos(turn))) * disc;

	// Domain warping: sample noise at coordinates displaced by the noise itself.
	vec2 warp = vec2(
		value_noise(sample_uv * 1.6 + 11.0, seed), value_noise(sample_uv * 1.6 - 7.0, seed)
	) - 0.5;
	float billow = fbm(sample_uv * noise_scale + warp * 1.3, seed);

	float radius = length(disc) / (0.68 + billow * 0.62);
	if (radius > 1.0) {
		discard;
	}
	// Sphere thickness at this pixel: in a gas, opacity literally represents how much matter the
	// ray passes through.
	float thickness = pow(1.0 - radius * radius, 0.5 * edge_softness);
	// Erosion: the threshold rises with age, leaving only dense clumps.
	float density = thickness * (0.45 + billow * 0.95);
	density *= smoothstep(age * erosion, age * erosion + 0.35, density + 0.15);

	// Perturb the normal with the noise gradient. One octave is enough: smoke relief is broad, and
	// this takes three samples instead of nine.
	float step_uv = 0.06;
	vec2 gradient = vec2(
		value_noise((sample_uv + vec2(step_uv, 0.0)) * noise_scale, seed) - billow,
		value_noise((sample_uv + vec2(0.0, step_uv)) * noise_scale, seed) - billow
	) / step_uv;
	vec3 normal = normalize(vec3(disc.x, -disc.y, sqrt(max(1.0 - radius * radius, 0.0)))
		+ vec3(gradient.x, -gradient.y, 0.0) * bump_strength);
	// Teardown's trick: shade every other pixel using the back face of the sphere. This makes light
	// appear to pass through the puff instead of bouncing off an opaque shell.
	if (mod(FRAGCOORD.x + FRAGCOORD.y, 2.0) < 1.0) {
		normal.z = -normal.z;
	}
	NORMAL = normal;

	ALBEDO = COLOR.rgb;
	EMISSION = COLOR.rgb * emissive;
	float alpha = COLOR.a * density;

	// Soft particles: fade into whatever is behind instead of cutting it off.
	float scene_depth = texture(depth_texture, SCREEN_UV).x;
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene_depth, 1.0);
	float scene_distance = -scene_view.z / scene_view.w;
	alpha *= clamp((scene_distance + VERTEX.z) / soft_distance, 0.0, 1.0);

	ALPHA = alpha;
}
