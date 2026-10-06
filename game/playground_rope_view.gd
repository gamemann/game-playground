extends MeshInstance3D

## A rope, drawn: a line between two points, redrawn when either end moves.
##
## One drawer for both ends of the wire. The server's [PlaygroundConstraints] draws the ropes
## it simulates — which is all an offline game or a listen server ever sees — and a
## connected client's [PlaygroundPropNet] draws the ones it is told about. Two drawers would
## be two ropes that disagree about where a rope is.
##
## Top level, so the line is in world space whatever it is parented under: the endpoints
## are world points and a mesh inheriting a rotating crate's transform would draw the rope
## spinning with the crate.

const COLOUR := Color(0.85, 0.80, 0.62)

var _drawn: ImmediateMesh = ImmediateMesh.new()


func _init() -> void:
	name = "Rope"
	top_level = true
	mesh = _drawn
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = COLOUR
	material_override = material


## Draws the rope from [param a] to [param b], with a little sag on a slack one.
func draw_between(a: Vector3, b: Vector3, length: float = 0.0) -> void:
	_drawn.clear_surfaces()
	global_transform = Transform3D.IDENTITY

	var span := a.distance_to(b)
	var slack := maxf(length - span, 0.0)
	var segments := 8 if slack > 0.05 else 1

	_drawn.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)

	for i in segments + 1:
		var t := float(i) / float(segments)
		var point := a.lerp(b, t)
		# A parabola under the straight line, as deep as half the slack. Not a catenary,
		# and nobody can tell at a rope's thickness.
		point.y -= sin(t * PI) * slack * 0.5
		_drawn.surface_add_vertex(point)

	_drawn.surface_end()
