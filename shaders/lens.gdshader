shader_type canvas_item;
// Бочкообразная предкоррекция под линзы очков в стиле Cardboard.

uniform float k1 = 0.20;
uniform float k2 = 0.08;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r2 = dot(p, p);
	vec2 q = p * (1.0 + k1 * r2 + k2 * r2 * r2);
	vec2 s = q * 0.5 + 0.5;
	if (s.x < 0.0 || s.x > 1.0 || s.y < 0.0 || s.y > 1.0) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		COLOR = texture(TEXTURE, s);
	}
}
