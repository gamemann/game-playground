extends Node3D

## What an administrator's `beacon` looks like: a ring on the floor under a player that
## sends out a ripple once a second, and a thin column above them that shows through walls.
##
## [b]Drawn on every client, from one replicated flag.[/b] The server decides who is
## beaconed (`PlaygroundPlayer.beacon`, carried as `PlaygroundPlayerNet.net_beacon`) and
## nothing about the picture travels: the ripple's phase is each client's own, because two
## screens a quarter of a second apart in a ripple is not something anybody can see, and
## sending a phase would be a message a second per beaconed player for nothing.
##
## [b]Through walls, on purpose.[/b] A beacon exists so that everybody can find somebody,
## and a sandbox is the game where that is hardest: anybody can build a box round
## themselves in ten seconds, and a marker a player's own crates can hide is a marker that
## fails in exactly the spot it is used for. So the column is drawn with no depth test. The
## ring is not: it is on the floor, and a ring showing through the floor of a course above
## would put the player somewhere they are not.
##
## [b]No column on your own beacon.[/b] A first-person camera stands inside it, and a
## no-depth-test cylinder seen from inside is a translucent smear over the whole screen.
## The beaconed player still sees the ring at their feet and hears the ping, which is how
## they know.
##
## Top level, so it is placed where the player is DRAWN rather than inheriting a transform
## the tick writes — the same reason the client's camera follows the simulated eye rather
## than being parented to the body.
##
## Copied from game-arena's `ArenaBeacon` rather than shared with it: these are separate
## repositories, and that is the family's rule. The colour is the one thing that differs in
## intent — see [constant COLOUR].

## Seconds between ripples, and between pings.
const PERIOD_SEC := 1.0

## How far a ripple spreads before it has faded, as a multiple of the ring.
const RIPPLE_SCALE := 3.5

## Red-orange, the colour nothing in a grey dev-textured sandbox is. The props a player
## spawns are tinted per definition and several are warm, so this is also brighter and more
## saturated than any of them: a beacon has to read as a mark, not as one more crate.
const COLOUR := Color(1.0, 0.24, 0.14)

const COLUMN_HEIGHT := 14.0

## Whether this is the beaconed player's own view. Hides the column; see above.
var local_view: bool = false:
	set(value):
		local_view = value
		if _column != null:
			_column.visible = not value

var _ring: MeshInstance3D = null
var _ripple: MeshInstance3D = null
var _column: MeshInstance3D = null
var _ripple_material: StandardMaterial3D = null
var _ring_material: StandardMaterial3D = null

## Seconds into the current period. Starts at the end of one, so the first advance pings:
## an admin who turns a beacon on should hear it start, not a second later.
var _phase: float = PERIOD_SEC


func _init() -> void:
	top_level = true

	_ring_material = _material(0.95, false)
	_ring = _torus(0.62, 0.78, _ring_material)
	_ring.name = "Ring"
	add_child(_ring)

	_ripple_material = _material(0.8, false)
	_ripple = _torus(0.66, 0.74, _ripple_material)
	_ripple.name = "Ripple"
	add_child(_ripple)

	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.07
	cylinder.bottom_radius = 0.07
	cylinder.height = COLUMN_HEIGHT
	cylinder.radial_segments = 8
	cylinder.rings = 1
	_column = MeshInstance3D.new()
	_column.name = "Column"
	_column.mesh = cylinder
	_column.material_override = _material(0.45, true)
	_column.position = Vector3(0.0, COLUMN_HEIGHT * 0.5 + 2.1, 0.0)
	_column.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_column.visible = not local_view
	add_child(_column)


## Moves the time on by [param delta] and redraws. Returns true when a new ripple starts,
## which is when the caller plays the ping.
func advance(delta: float) -> bool:
	_phase += maxf(delta, 0.0)
	var pinged := false

	if _phase >= PERIOD_SEC:
		_phase = fmod(_phase, PERIOD_SEC)
		pinged = true

	var t := _phase / PERIOD_SEC
	var spread := lerpf(1.0, RIPPLE_SCALE, t)
	_ripple.scale = Vector3(spread, 0.25, spread)
	_ripple_material.albedo_color.a = 0.8 * (1.0 - t) * (1.0 - t)

	# The ring itself breathes with the ripple rather than holding still, so a beacon seen
	# from across the sandbox — a few pixels of ring — still reads as something alive.
	_ring_material.albedo_color.a = lerpf(0.95, 0.55, t)

	return pinged


## The fraction of a period the ripple is through, for a check.
func phase() -> float:
	return _phase / PERIOD_SEC


## Whether the through-walls column is drawn. For a check: it is the one part that must
## be missing on the beaconed player's own view and present on everybody else's.
func column_shown() -> bool:
	return _column != null and _column.visible


func _torus(inner: float, outer: float, material: StandardMaterial3D) -> MeshInstance3D:
	var torus := TorusMesh.new()
	torus.inner_radius = inner
	torus.outer_radius = outer
	torus.rings = 48
	torus.ring_segments = 8
	var mesh := MeshInstance3D.new()
	mesh.mesh = torus
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Flattened to a band on the floor. A torus's tube is round, and a round tube at a
	# player's feet reads as a lifebuoy rather than a mark.
	mesh.scale = Vector3(1.0, 0.25, 1.0)
	mesh.position = Vector3(0.0, 0.06, 0.0)
	return mesh


func _material(alpha: float, through_walls: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(COLOUR.r, COLOUR.g, COLOUR.b, alpha)
	material.no_depth_test = through_walls
	return material
