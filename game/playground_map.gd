extends Node3D

## Base class for the playground's built-in maps.
##
## [b]A map carries its own zones here, and a delivered map would ship a JSON
## file.[/b] Both routes are real and dot-map supports both: `DotMapDef.zones_path`
## points at a file, and a map that ships inside the game's own build can instead
## answer [method timer_zones] directly. This project uses the second for its own
## maps and keeps a written-out copy of one of them in `maps/` — with a check in the
## headless suite that the two agree, because a zone file that has drifted from the
## geometry it was drawn against is a leaderboard nobody can compare.
##
## Subclasses override [method _build] and [method timer_zones].

## Where players appear if the map has no spawn zone.
@export var fallback_spawn: Vector3 = Vector3(0.0, 2.0, 0.0)

# --- What the movement can do ----------------------------------------------
#
# [b]The three numbers every jump on every built-in map is sized against, copied from
# `PlaygroundPlayer._tunables` deliberately.[/b] A map is content: it is loaded by
# `DotMapDef` from a catalogue, it has no player in front of it when `build_zones` is
# called from a tool, and reaching into the game's player class from here would make a
# map depend on the game rather than the other way round. The family's answer to a
# deliberate copy is a check that the copies agree, and `headless_playground` asserts
# these three against the tunables the server actually applies.
#
# They lived in `pg_lobby` until a second map needed them. Here rather than a second
# copy in `pg_bhop_intro`, because two copies of one number is this tree's most
# repeated bug and the base class is the one place every built-in map already reads.

## Ground speed, m/s. `DotFpsTunables.max_speed`.
const MOVE_SPEED := 7.0

## Metres. `DotFpsTunables.jump_height`. NOT the addon's default, which is 1.1.
const JUMP_HEIGHT := 1.15

## m/s². `DotFpsTunables.gravity`. Not Godot's project default, which is 9.8.
const MOVE_GRAVITY := 20.0


## The clear air a player running at [constant MOVE_SPEED] crosses in one jump, landing
## [param rise] metres higher than they left.
##
## [b]The landing height is the whole point of this function.[/b] Time to fall back to
## the height you jumped from is the number everybody writes down, and it is the wrong
## one for any course that climbs: at 1.15 m of jump height a player is airborne for
## 0.68 s flat and 0.53 s onto a step 0.8 m up, which is 4.8 m against 3.7. A course
## sized with the first number is 30% longer than the movement can do, and every check
## over it passes, because nothing in a zone set knows how far a player can jump.
##
## Returns 0.0 for a rise the jump cannot reach at all.
static func jump_reach(rise: float) -> float:
	var launch := sqrt(2.0 * MOVE_GRAVITY * JUMP_HEIGHT)
	var inside := launch * launch - 2.0 * MOVE_GRAVITY * rise

	if inside < 0.0:
		return 0.0

	# The LATER root: the way back down through that height, not the way up.
	var airborne := (launch + sqrt(inside)) / MOVE_GRAVITY

	return MOVE_SPEED * airborne


## The clear air between two standable boxes, seen from above, in metres. 0.0 when
## they touch or overlap.
##
## [b]Box to box, not centre to centre minus a width.[/b] The second is what
## `pg_lobby`'s tower was checked with, and it is a different number in every
## direction: two axis-aligned squares 45 degrees apart round a circle are closer at
## their corners than their centres say, and a square pad beside a square platform
## diagonally off its corner is 0.2 m of air that a centre distance calls 3.8.
##
## A route on a built-in map is a list of these boxes, in the order a player lands on
## them — see `PgLobby.tower_route` — so the gap and the rise of every jump are read off
## the geometry rather than kept beside it as a table that can drift.
static func gap_between(from: AABB, to: AABB) -> float:
	var dx := maxf(
		0.0, maxf(to.position.x - from.end.x, from.position.x - to.end.x)
	)
	var dz := maxf(
		0.0, maxf(to.position.z - from.end.z, from.position.z - to.end.z)
	)

	return Vector2(dx, dz).length()


## A standable box as an [AABB], from its centre and full size — the convention
## `PlaygroundGeometry.box` takes, so a route can be written with the same arguments
## the geometry was.
static func standable(centre: Vector3, size: Vector3) -> AABB:
	return AABB(centre - size * 0.5, size)


func _ready() -> void:
	_build()


## Builds the geometry. Called once, from [method Node._ready].
func _build() -> void:
	pass


## The map's timer zones, or null for a map with no timer.
func timer_zones() -> DotTimerZoneSet:
	return null


## Where a player on [param track] starts.
func spawn_for(track: int) -> Vector3:
	var zones := timer_zones()

	if zones != null:
		var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)

		if spawn != null:
			return spawn.destination

	return fallback_spawn


## The yaw a player faces when they spawn on [param track], in degrees.
func spawn_yaw_for(track: int) -> float:
	var zones := timer_zones()

	if zones != null:
		var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)

		if spawn != null:
			return spawn.destination_yaw

	return 0.0


## Standable places on this map that no spawn is MEANT to reach, each as
## `{box: AABB, why: String}`.
##
## Read by `PlaygroundMapSurvey` (`headless_playground`'s survey section), which fails on
## any standable area it cannot reach from a spawn unless it is declared here. The top of
## a wall, a backstop, the crest of a face nobody can climb: places only a noclip goes,
## said once where the geometry is rather than discovered by a player who got there some
## other way. [b]A declaration is a claim, and the reason is the part worth reading[/b] —
## "the survey complained" is not one.
func survey_declared() -> Array:
	return []


## Whether [param track] is meant to be driven rather than run.
##
## [b]Default false, which is every map that existed before there were cars.[/b]
## [code]Playground._on_seated[/code] cancels a run when a player gets into a vehicle,
## because a foot course driven round in a buggy is not a time anybody can compare with
## one that was jumped — and dot-timer has no idea a vehicle exists, so nothing below
## this can tell the difference.
##
## A circuit inverts that: the car is the point, and getting OUT of it mid-lap is the
## thing that should end the run. A map says which of its tracks are which, because the
## map is the only thing that knows. See `pg_lobby`'s bonus 3.
func track_is_driven(_track: int) -> bool:
	return false
