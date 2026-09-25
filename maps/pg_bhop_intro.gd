extends "../game/playground_map.gd"

const PlaygroundGeometry := preload("../game/playground_geometry.gd")

## `pg_bhop_intro` — a straight run of blocks with gaps that widen.
##
## [b]A bhop map is a speed test disguised as a platformer.[/b] Each gap is a little
## wider than the last, so the only way to clear the later ones is to have kept the
## speed from the earlier ones — which means landing and jumping on the same tick,
## every time, which is the whole skill. A player who stops between jumps loses their
## speed to friction and cannot finish.
##
## The gaps are sized against the shipped movement defaults with `auto_hop` on: a
## player who hops perfectly gains roughly a metre per second per jump, so the last
## gap needs about twice the speed the first one does.
##
## [b]Two routes, and they test opposite halves of the same skill.[/b] The main run
## above is a speed test: every gap is clearable if you kept what the last one gave
## you. The bonus — "the narrows", alongside it and six metres up — holds its gap
## constant at [constant BONUS_GAP] and takes the blocks away sideways instead, from
## [constant BONUS_FIRST_WIDTH] down to [constant BONUS_LAST_WIDTH]. Speed is free
## there and the run is lost by drifting off the side, which is what air control is
## for. A player who can clear the main run by hammering the speed usually cannot
## clear the narrows at all, and that is the point of having both.
##
## [b]A third route, and it asks the one question the other two cannot.[/b] Both of
## those are straight lines, and that was a decision rather than a shortage of ideas: a
## route a scripted bot cannot run is a route no suite ever finishes, and every bot in
## this family used to hold one yaw for its whole run. "The switchback", on bonus 2,
## climbs a hillside of floating blocks in three legs joined by two turning blocks —
## west, south, east, south, west — so every leg ends in a quarter turn and every turn
## is a jump. It asks whether a player can land, face somewhere else and go, which is
## the thing between the narrows' "hold your line" and the main run's "keep your speed".
## Its gaps widen along the route and every one is inside [method jump_reach] for the
## step it climbs.
##
## [b]A fourth route, and it is the first one a player walks part of.[/b] "The ascent", on
## bonus 3, climbs 8 m in four sections, and every section is a jump onto a block and a
## ramp up off it. Each ramp rises 2 m — nearly twice the 1.15 m apex, so there is no
## way up but to walk it — and each is steeper than the last, from 16 degrees to 40,
## against the 46 the controller can stand on. It could not exist before
## dot-player-controller's `[slope-1]` (803308f): until then the first tick on any slope
## under the limit read as airborne, and a ramp was a wall. The jumps between ramps ask
## the question the jumps on the other routes do; the ramps ask whether a player can
## carry a walk up a slope and off the crest into the next jump.
##
## All four tracks carry [constant DotTimerZone.Kind.STAGE] splits, because a map with
## one start and one finish exercises none of dot-timer's per-stage machinery.

const START_Z := 0.0
const BLOCKS := 14
const BLOCK_LENGTH := 6.0

## Gap between blocks, in metres. Grows linearly across the run.
const FIRST_GAP := 3.0
const LAST_GAP := 7.0

const BLOCK_Y := 0.0
const BLOCK_WIDTH := 8.0

## Which blocks the main run's splits come after. Three lines, four segments, so a
## player can see which third of the run they lost their speed in — which on a map
## whose whole difficulty is carrying speed is the only diagnostic that matters.
const STAGE_AFTER_BLOCKS := [3, 7, 11]

# --- The bonus: "the narrows" ----------------------------------------------

## Far enough sideways that the main run's eight-metre blocks and the bonus's widest
## are nowhere near touching, and high enough that neither route is the other's
## ceiling.
const BONUS_X := 28.0
const BONUS_Y := 6.0

const BONUS_BLOCKS := 10
const BONUS_BLOCK_LENGTH := 5.0

## Constant, unlike the main run's. The narrows does not ask for more speed as it
## goes; it asks for the same jump to land somewhere smaller each time.
const BONUS_GAP := 3.5

const BONUS_FIRST_WIDTH := 7.0
const BONUS_LAST_WIDTH := 2.0

## Which blocks the bonus's splits come after.
const BONUS_STAGE_AFTER_BLOCKS := [2, 5, 8]

# --- Bonus 2: "the switchback" -------------------------------------------------
#
# Every number below is read by `_build_the_switchback`, `switchback_route` and
# `_add_the_switchback`, and nothing else describes where a block is. The route is
# walked edge to edge from the pad — gap, then block — for the reason `pg_lobby`'s
# `platform_centre` gives: spacing by centres makes the clear air a player actually
# jumps quietly differ from the number written here.

## The track it runs on.
const SWITCHBACK_TRACK := DotTimerTrack.BONUS_FIRST + 1

## The start pad's centre, and the height of its top surface.
##
## West of the main run by twenty metres, so the whole hillside — which reaches about
## 28 m further west — is clear of both other routes, and level with the main run's
## start in Z so all three read as three ways out of one place.
const SWITCHBACK_X := -24.0
const SWITCHBACK_Z := 10.0
const SWITCHBACK_Y := 2.0

const SWITCHBACK_PAD := Vector3(6.0, 1.0, 6.0)

## Square, so a block is the same target from whichever side a leg arrives at it. A
## turning block that is long one way and short the other is a turn that is easy in one
## direction and a fall in the other.
const SWITCHBACK_BLOCK := Vector3(3.0, 0.5, 3.0)

## How much each jump climbs. Over `step_height` (0.4), so every block is a jump rather
## than a stair, and well under the 1.15 m apex, so no block is also a wall.
const SWITCHBACK_RISE := 0.5

## The legs, as a direction and a number of jumps. West four, a turning block south,
## east four, a turning block south, west four onto the finish.
##
## [b]The one-jump legs are the turns.[/b] A leg of one is a block a player lands on
## travelling south and leaves travelling east or west — a quarter turn on 3 m of
## floor, and the thing this route exists to ask. The long legs are where the widening
## gaps are felt.
const SWITCHBACK_LEGS := [
	[Vector3(-1.0, 0.0, 0.0), 4],
	[Vector3(0.0, 0.0, -1.0), 1],
	[Vector3(1.0, 0.0, 0.0), 4],
	[Vector3(0.0, 0.0, -1.0), 1],
	[Vector3(-1.0, 0.0, 0.0), 4],
]

## The first jump's clear air and the last's, in metres. Grows evenly across the route.
##
## [b]The last is sized against [method jump_reach], not against a feeling.[/b] A jump
## here climbs [constant SWITCHBACK_RISE], so the reach is `jump_reach(0.5)` = 4.16 m,
## and 3.3 is 79% of it: past the point where a player who stopped on the block before
## makes it comfortably, inside the point where only a bhop does. The first is 2.0 so
## the first leg is a lesson rather than a test.
const SWITCHBACK_FIRST_GAP := 2.0
const SWITCHBACK_LAST_GAP := 3.3

# --- Bonus 3: "the ascent" -----------------------------------------------------
#
# Every number below is read by `_build_the_ascent`, `ascent_route`, `ascent_ramps` and
# `_add_the_ascent`, and nothing else describes where a block or a ramp is.

## The track it runs on.
const ASCENT_TRACK := DotTimerTrack.BONUS_FIRST + 2

## The start pad's centre in X and Z, and the height of its top surface.
##
## East of the narrows by thirty metres, so the narrows' own reset slab (which reaches
## x = 48) is clear of this route's, and level with the other three starts in Z so all
## four read as four ways out of one place.
const ASCENT_X := 60.0
const ASCENT_Z := 10.0
const ASCENT_Y := 2.0

const ASCENT_PAD := Vector3(6.0, 1.0, 6.0)

## A block a jump lands on, or a ramp's crest a jump leaves from. 4 m wide so the route is
## about the slope and the jump, not about holding a line.
const ASCENT_BLOCK := Vector3(4.0, 0.5, 3.0)

## How much every ramp climbs, in metres.
##
## [b]Over the jump apex on purpose.[/b] 2 m against 1.15 means no crest can be jumped to
## from the block below it, so the only way up the route is to walk every ramp — which
## is the thing this route is for, and the thing `headless_playground` asserts.
const ASCENT_RAMP_RISE := 2.0

## The ramps' pitches, in degrees, first to last. One section per entry.
##
## [b]Steeper each time, and the last is six degrees inside the limit.[/b]
## `PlaygroundPlayer._tunables` sets `max_slope_angle` to 46; a ramp past that is a
## surf face a player slides down, and one AT it is a ramp that is walkable on one tick
## and not the next. 40 is steep enough to feel like a climb and far enough inside that
## nobody's floating point decides whether it is a floor.
const ASCENT_PITCHES := [16.0, 24.0, 32.0, 40.0]

## The clear air of the first jump and the last, in metres. Grows evenly.
##
## Every jump here is level — it leaves a crest and lands on a block at the crest's
## height — so the reach is `jump_reach(0.0)`, 4.75 m. 3.4 is 72% of it: a player
## walking off the crest at full speed makes it, and one who stalled on the ramp and
## jumps from a standing start does not.
const ASCENT_FIRST_GAP := 2.2
const ASCENT_LAST_GAP := 3.4


func _build() -> void:
	PlaygroundGeometry.sun(self)

	fallback_spawn = Vector3(0.0, BLOCK_Y + 1.0, START_Z + 10.0)

	# The start pad, long enough to build speed on before the first gap.
	PlaygroundGeometry.box(
		self,
		Vector3(0.0, BLOCK_Y - 0.5, START_Z + 12.0),
		Vector3(BLOCK_WIDTH, 1.0, 30.0),
		PlaygroundGeometry.COLOUR_START
	)

	var z := START_Z

	for i in range(BLOCKS):
		PlaygroundGeometry.box(
			self,
			Vector3(0.0, BLOCK_Y - 0.5, z - BLOCK_LENGTH * 0.5),
			Vector3(BLOCK_WIDTH, 1.0, BLOCK_LENGTH),
			PlaygroundGeometry.COLOUR_PLATFORM
		)

		z -= BLOCK_LENGTH + gap_at(i)

	# The finish pad.
	PlaygroundGeometry.box(
		self,
		Vector3(0.0, BLOCK_Y - 0.5, z - 8.0),
		Vector3(BLOCK_WIDTH, 1.0, 18.0),
		PlaygroundGeometry.COLOUR_END
	)

	_build_the_narrows()
	_build_the_switchback()
	_build_the_ascent()


## The bonus route, alongside the main run and six metres above it.
##
## Same arithmetic as the main run and deliberately so: [method bonus_block_near_z] and
## [method bonus_width_at] are the only description of where a block is and how wide it
## is, and both the geometry here and the zones in [method build_zones] read them. Two
## descriptions drift, and on a timer map the drift is a leaderboard nobody can compare.
func _build_the_narrows() -> void:
	# The start pad. Full width, because the run has to begin somewhere a player can
	# turn round on — the narrowing is the course, not the approach to it.
	PlaygroundGeometry.box(
		self,
		Vector3(BONUS_X, BONUS_Y - 0.5, bonus_start_z() + 9.0),
		Vector3(BONUS_FIRST_WIDTH, 1.0, 20.0),
		PlaygroundGeometry.COLOUR_START
	)

	for i in range(BONUS_BLOCKS):
		PlaygroundGeometry.box(
			self,
			Vector3(
				BONUS_X,
				BONUS_Y - 0.5,
				bonus_block_near_z(i) - BONUS_BLOCK_LENGTH * 0.5
			),
			Vector3(bonus_width_at(i), 1.0, BONUS_BLOCK_LENGTH),
			# The ramp colour rather than the platform one, so the two routes are
			# tellable apart in a single frame from anywhere on the map.
			PlaygroundGeometry.COLOUR_RAMP
		)

	# The finish pad, back at full width for the same reason the start is.
	PlaygroundGeometry.box(
		self,
		Vector3(BONUS_X, BONUS_Y - 0.5, bonus_end_z() - 7.0),
		Vector3(BONUS_FIRST_WIDTH, 1.0, 16.0),
		PlaygroundGeometry.COLOUR_END
	)


## Bonus 2, built from [method switchback_route] and nothing else.
##
## The turning blocks are the ramp colour, so the three turns of the route read from
## anywhere on the map as the places where it changes direction.
func _build_the_switchback() -> void:
	var route := switchback_route()
	var corners := switchback_corners()

	for i in range(route.size()):
		var box: AABB = route[i]
		var colour := PlaygroundGeometry.COLOUR_PLATFORM

		if i == 0:
			colour = PlaygroundGeometry.COLOUR_START
		elif i == route.size() - 1:
			colour = PlaygroundGeometry.COLOUR_END
		elif corners.has(i):
			colour = PlaygroundGeometry.COLOUR_RAMP

		PlaygroundGeometry.box(self, box.get_center(), box.size, colour)


## Bonus 3, built from [method ascent_route] and [method ascent_ramps] and nothing else.
##
## The landing blocks are the platform colour and the ramps and their crests the ramp
## colour, so from anywhere on the map the route reads as "jump, climb, jump, climb".
func _build_the_ascent() -> void:
	var route := ascent_route()

	for i in range(route.size()):
		var box: AABB = route[i]
		var colour := PlaygroundGeometry.COLOUR_PLATFORM

		if i == 0:
			colour = PlaygroundGeometry.COLOUR_START
		elif i == route.size() - 1:
			colour = PlaygroundGeometry.COLOUR_END
		elif i % 2 == 0:
			# Every even box after the pad is a crest: the top of a ramp.
			colour = PlaygroundGeometry.COLOUR_RAMP

		PlaygroundGeometry.box(self, box.get_center(), box.size, colour)

	for ramp in ascent_ramps():
		PlaygroundGeometry.ramp(
			self,
			ramp["centre"],
			ramp["size"],
			float(ramp["pitch"]),
			Vector3.RIGHT
		)


## The gap after block [param index], in metres.
static func gap_at(index: int) -> float:
	return lerpf(FIRST_GAP, LAST_GAP, float(index) / float(maxi(BLOCKS - 1, 1)))


## What `PlaygroundMapSurvey` may find unreached here: the main run from the first block
## whose gap is wider than a RUNNING jump, to the finish.
##
## [b]That is the route working, not a hole in it.[/b] The gaps widen from 3 m to 7 m and
## a standing-start running jump crosses 4.75; everything past that is reached only with
## speed carried from the blocks before, which is what the map is teaching. The survey
## models a running jump and no carried speed, so it cannot see those blocks — and a route
## a bot drives end to end is the stronger evidence for them anyway.
func survey_declared() -> Array:
	var first := BLOCKS
	for i in range(1, BLOCKS):
		if gap_at(i - 1) > jump_reach(0.0):
			first = i
			break

	var near := block_near_z(first)
	var far := end_z() - 18.0
	return [{
		"box": AABB(
			Vector3(-BLOCK_WIDTH * 0.5, BLOCK_Y - 1.0, far),
			Vector3(BLOCK_WIDTH, 2.0, near - far)
		),
		"why": "the main run past block %d: gaps wider than a running jump, crossed with bhop speed" % first,
	}]


## The Z of the near (high-Z) edge of block [param index] on the main run.
##
## The same walk [method _build] does, so a split line placed from this cannot land
## anywhere other than on the block it is named after.
static func block_near_z(index: int) -> float:
	var z := START_Z

	for i in range(index):
		z -= BLOCK_LENGTH + gap_at(i)

	return z


## Where the run's blocks end, in Z. Derived rather than stored, so the finish zone
## and the finish pad cannot disagree about where the map stops.
static func end_z() -> float:
	return block_near_z(BLOCKS)


# --- The narrows, as arithmetic ---------------------------------------------

## Where the bonus route's blocks begin. Level with the main run's first block, so the
## two courses read as two routes out of the same place rather than as two maps.
static func bonus_start_z() -> float:
	return START_Z


## The Z of the near (high-Z) edge of bonus block [param index].
static func bonus_block_near_z(index: int) -> float:
	return bonus_start_z() - float(index) * (BONUS_BLOCK_LENGTH + BONUS_GAP)


## Where the bonus route's blocks end, in Z.
static func bonus_end_z() -> float:
	return bonus_block_near_z(BONUS_BLOCKS)


## How wide bonus block [param index] is, in metres. Shrinks linearly across the run:
## this is the difficulty, and it is the only thing that changes.
static func bonus_width_at(index: int) -> float:
	return lerpf(
		BONUS_FIRST_WIDTH,
		BONUS_LAST_WIDTH,
		float(index) / float(maxi(BONUS_BLOCKS - 1, 1))
	)


# --- The switchback, as arithmetic -------------------------------------------

## Every jump's direction, in order: the legs of [constant SWITCHBACK_LEGS] flattened.
static func switchback_hops() -> Array[Vector3]:
	var hops: Array[Vector3] = []

	for leg in SWITCHBACK_LEGS:
		for _i in range(int(leg[1])):
			hops.append(leg[0])

	return hops


## The clear air before the box jump [param index] lands on, counted from 0.
static func switchback_gap(index: int) -> float:
	var last := maxi(switchback_hops().size() - 1, 1)
	return lerpf(
		SWITCHBACK_FIRST_GAP, SWITCHBACK_LAST_GAP, float(index) / float(last)
	)


## Bonus 2 as the boxes a player lands on, start pad to finish pad, in order.
##
## [b]This is the whole description of the route.[/b] The geometry is built from it,
## the splits are placed on its turning blocks, and `headless_playground` reads the gap
## and the rise of every jump off it and drives a bot along it — so a block moved here
## moves the jump, the split and the drive together.
static func switchback_route() -> Array[AABB]:
	var pad_centre := Vector3(
		SWITCHBACK_X, SWITCHBACK_Y - SWITCHBACK_PAD.y * 0.5, SWITCHBACK_Z
	)
	var route: Array[AABB] = [standable(pad_centre, SWITCHBACK_PAD)]

	var hops := switchback_hops()
	var centre := pad_centre
	var size := SWITCHBACK_PAD

	for i in range(hops.size()):
		var direction: Vector3 = hops[i]
		var next := SWITCHBACK_PAD if i == hops.size() - 1 else SWITCHBACK_BLOCK

		# Half of each box ALONG the direction of travel, so a square block and a
		# square pad are both walked edge to edge.
		var along := absf(direction.dot(size)) * 0.5 + switchback_gap(i) \
			+ absf(direction.dot(next)) * 0.5
		var top := SWITCHBACK_Y + SWITCHBACK_RISE * float(i + 1)

		centre = Vector3(
			centre.x + direction.x * along,
			top - next.y * 0.5,
			centre.z + direction.z * along
		)
		size = next
		route.append(standable(centre, size))

	return route


## The route indices of the turning blocks: every box a one-jump leg lands on.
static func switchback_corners() -> Array[int]:
	var corners: Array[int] = []
	var index := 0

	for leg in SWITCHBACK_LEGS:
		index += int(leg[1])

		if int(leg[1]) == 1:
			corners.append(index)

	return corners


# --- The ascent, as arithmetic -----------------------------------------------

## The run of ramp [param index] along the ground, in metres: what its rise and its pitch
## leave.
static func ascent_ramp_run(index: int) -> float:
	return ASCENT_RAMP_RISE / tan(deg_to_rad(float(ASCENT_PITCHES[index])))


## The clear air before the landing block of section [param index].
static func ascent_gap(index: int) -> float:
	var last := maxi(ASCENT_PITCHES.size(), 1)
	return lerpf(ASCENT_FIRST_GAP, ASCENT_LAST_GAP, float(index) / float(last))


## Bonus 3 as the boxes a player stands on, start pad to finish pad, in order: the pad,
## then per section a landing block and the crest its ramp climbs to, then the finish.
##
## [b]Two kinds of step, and [method ascent_walks] says which is which.[/b] Pad to block,
## and crest to the next block, is a jump; block to crest is a ramp, walked. The route
## runs straight along -Z, edge to edge from the pad, for the reason `switchback_route`
## gives — spacing by centres makes the air a player jumps quietly differ from the number
## written here.
static func ascent_route() -> Array[AABB]:
	var top := ASCENT_Y
	var pad_centre := Vector3(ASCENT_X, top - ASCENT_PAD.y * 0.5, ASCENT_Z)
	var route: Array[AABB] = [standable(pad_centre, ASCENT_PAD)]

	# The near (high-Z) edge of whatever comes next.
	var z := ASCENT_Z - ASCENT_PAD.z * 0.5

	for i in range(ASCENT_PITCHES.size()):
		z -= ascent_gap(i)
		route.append(standable(
			Vector3(ASCENT_X, top - ASCENT_BLOCK.y * 0.5, z - ASCENT_BLOCK.z * 0.5),
			ASCENT_BLOCK
		))
		z -= ASCENT_BLOCK.z + ascent_ramp_run(i)
		top += ASCENT_RAMP_RISE
		route.append(standable(
			Vector3(ASCENT_X, top - ASCENT_BLOCK.y * 0.5, z - ASCENT_BLOCK.z * 0.5),
			ASCENT_BLOCK
		))
		z -= ASCENT_BLOCK.z

	z -= ASCENT_LAST_GAP
	route.append(standable(
		Vector3(ASCENT_X, top - ASCENT_PAD.y * 0.5, z - ASCENT_PAD.z * 0.5), ASCENT_PAD
	))

	return route


## The route indices a player WALKS off rather than jumps from: every landing block,
## whose far edge is the foot of a ramp.
static func ascent_walks() -> Array[int]:
	var walks: Array[int] = []

	for i in range(ASCENT_PITCHES.size()):
		walks.append(1 + i * 2)

	return walks


## Each ramp as `{pitch, foot, crest, centre, size}`: the pitch in degrees, the foot and
## the crest as the middle of the ramp's top surface's two ends, and the centre and size
## of the tilted box [method PlaygroundGeometry.ramp] builds.
##
## [b]The top surface meets both blocks exactly, and that is arithmetic rather than a
## nudge.[/b] The foot is the landing block's far top edge and the crest the next block's
## near top edge; the box is dropped from the midpoint of that surface along its own
## NORMAL by half its thickness. `pg_surf_intro`'s plunge drops by half a thickness
## vertically and has to correct by 1/cos(pitch) — getting that wrong left a 0.8 m lip
## there. Along the normal, there is nothing to correct: the top face passes through
## both edges, and the box's ends sink into the blocks below their tops rather than
## standing proud of them.
static func ascent_ramps() -> Array[Dictionary]:
	var route := ascent_route()
	var ramps: Array[Dictionary] = []
	var thickness := 0.5

	for i in range(ASCENT_PITCHES.size()):
		var block: AABB = route[1 + i * 2]
		var crest_box: AABB = route[2 + i * 2]
		var pitch := float(ASCENT_PITCHES[i])
		var radians := deg_to_rad(pitch)
		var foot := Vector3(ASCENT_X, block.end.y, block.position.z)
		var crest := Vector3(ASCENT_X, crest_box.end.y, crest_box.end.z)
		# `Basis(RIGHT, +pitch)` turns the box's up to (0, cos, sin): its top faces up
		# and back toward the foot, which is what a ramp climbing toward -Z does.
		var normal := Vector3(0.0, cos(radians), sin(radians))

		ramps.append({
			"pitch": pitch,
			"foot": foot,
			"crest": crest,
			"centre": (foot + crest) * 0.5 - normal * thickness * 0.5,
			"size": Vector3(ASCENT_BLOCK.x, thickness, foot.distance_to(crest)),
		})

	return ramps


func timer_zones() -> DotTimerZoneSet:
	return build_zones()


static func build_zones() -> DotTimerZoneSet:
	var zones := DotTimerZoneSet.new()
	zones.map_id = &"pg_bhop_intro"
	zones.meta["tier"] = 3
	zones.meta["author"] = "playground"

	var start := DotTimerZone.make(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
	start.set_box(
		Vector3(-5.0, BLOCK_Y, START_Z),
		Vector3(5.0, BLOCK_Y + 5.0, START_Z + 27.0)
	)
	zones.add(start)

	var finish_z := end_z()

	var finish := DotTimerZone.make(DotTimerZone.Kind.END, DotTimerTrack.MAIN)
	finish.set_box(
		Vector3(-5.0, BLOCK_Y, finish_z - 14.0),
		Vector3(5.0, BLOCK_Y + 5.0, finish_z - 2.0)
	)
	zones.add(finish)

	# Fall off a block and you are out. A respawn volume rather than a kill volume,
	# because on a bhop map falling is the ordinary way to fail and a death animation
	# every eight seconds is intolerable.
	var pit := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, DotTimerTrack.MAIN)
	pit.set_box(
		Vector3(-200.0, BLOCK_Y - 40.0, finish_z - 200.0),
		Vector3(200.0, BLOCK_Y - 6.0, START_Z + 200.0)
	)
	zones.add(pit)

	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, DotTimerTrack.MAIN)
	spawn.destination = Vector3(0.0, BLOCK_Y + 1.0, START_Z + 22.0)
	zones.add(spawn)

	_add_main_stages(zones)
	_add_the_narrows(zones)
	_add_the_switchback(zones)
	_add_the_ascent(zones)

	return zones


## The main run's splits.
##
## Each line sits in the middle of the gap AFTER its block rather than on top of it.
## A player is guaranteed to pass through a gap — that is what a gap is — whereas at
## the speed the later blocks demand a block is six metres that can be cleared in half
## a dozen ticks, and a line over one is a line a fast player can be past before it is
## ever tested.
static func _add_main_stages(zones: DotTimerZoneSet) -> void:
	for number in range(STAGE_AFTER_BLOCKS.size()):
		var index: int = STAGE_AFTER_BLOCKS[number]
		var z := block_near_z(index) - BLOCK_LENGTH - gap_at(index) * 0.5

		var stage := DotTimerZone.make(
			DotTimerZone.Kind.STAGE, DotTimerTrack.MAIN
		)
		stage.number = float(number + 1)
		# Wider than the blocks and well above them: a player who clears a gap with a
		# metre of air still crossed the line, and one who is drifting sideways off
		# the edge as they cross it has still crossed it. A split that can be missed
		# by playing well is worse than no split.
		stage.set_box(
			Vector3(-8.0, BLOCK_Y - 1.0, z - 0.75),
			Vector3(8.0, BLOCK_Y + 8.0, z + 0.75)
		)
		zones.add(stage)


## Everything on the bonus track: a spawn, a start, three splits, a finish and the
## volume that puts a player who fell off back on the pad.
static func _add_the_narrows(zones: DotTimerZoneSet) -> void:
	var track := DotTimerTrack.BONUS_FIRST

	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, track)
	spawn.destination = Vector3(BONUS_X, BONUS_Y + 1.0, bonus_start_z() + 15.0)
	# Zero faces -Z, which is the way both routes run. Written rather than left to the
	# default because a player who spawns with their back to the course has to find it
	# before they can start it, and that is not visible from any count.
	spawn.destination_yaw = 0.0
	zones.add(spawn)

	# On the pad, so timing begins when the player LEAVES it — the jump onto the first
	# block. Timing from the moment they entered would time their run-up.
	var start := DotTimerZone.make(DotTimerZone.Kind.START, track)
	start.set_box(
		Vector3(
			BONUS_X - BONUS_FIRST_WIDTH * 0.5,
			BONUS_Y - 0.5,
			bonus_start_z() + 0.5
		),
		Vector3(
			BONUS_X + BONUS_FIRST_WIDTH * 0.5,
			BONUS_Y + 5.0,
			bonus_start_z() + 19.0
		)
	)
	zones.add(start)

	for number in range(BONUS_STAGE_AFTER_BLOCKS.size()):
		var index: int = BONUS_STAGE_AFTER_BLOCKS[number]
		var z := bonus_block_near_z(index) - BONUS_BLOCK_LENGTH - BONUS_GAP * 0.5

		var stage := DotTimerZone.make(DotTimerZone.Kind.STAGE, track)
		stage.number = float(number + 1)
		# Spanning the widest the course ever is, not the width at this block. A
		# player drifting off the side has still crossed the line; the block being
		# narrow here is the difficulty, and making the split narrow with it would
		# punish the same mistake twice.
		stage.set_box(
			Vector3(
				BONUS_X - BONUS_FIRST_WIDTH,
				BONUS_Y - 1.0,
				z - 0.75
			),
			Vector3(
				BONUS_X + BONUS_FIRST_WIDTH,
				BONUS_Y + 8.0,
				z + 0.75
			)
		)
		zones.add(stage)

	# Deep, for the reason dot-timer's `thin_zones` check exists: at 128 Hz a player
	# arriving at 12 m/s covers 9 cm in a tick, and a finish line thinner than that is
	# one the fastest players pass straight through without ever being inside it.
	var finish := DotTimerZone.make(DotTimerZone.Kind.END, track)
	finish.set_box(
		Vector3(
			BONUS_X - BONUS_FIRST_WIDTH * 0.5,
			BONUS_Y - 0.5,
			bonus_end_z() - 13.0
		),
		Vector3(
			BONUS_X + BONUS_FIRST_WIDTH * 0.5,
			BONUS_Y + 5.0,
			bonus_end_z() - 1.0
		)
	)
	zones.add(finish)

	# Falling off the narrows: a slab of air two metres under the course, wide enough
	# that nobody who leaves a block can miss it and stopping well short of the main
	# run at x = 0, so it never hangs over a player hopping along those blocks. The
	# track filter would cover that anyway — dot-timer checks the run's track before
	# acting on any zone — but a volume that only behaves because of a filter is one
	# that misbehaves the moment somebody widens it.
	#
	# A slab rather than a pit: three metres deep is ~40 ticks of falling at the speed
	# a player reaches two metres down, so it cannot be tunnelled through.
	var reset := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, track)
	reset.set_box(
		Vector3(BONUS_X - 20.0, BONUS_Y - 5.0, bonus_end_z() - 40.0),
		Vector3(BONUS_X + 20.0, BONUS_Y - 2.0, bonus_start_z() + 40.0)
	)
	zones.add(reset)


## Everything on bonus 2: a spawn, a start, a split on each turning block, a finish and
## a volume under the hillside that puts a player who fell off back on the pad.
##
## [b]All five kinds, on this track, by name.[/b] A [DotTimerZone] carries a track, and
## a set that is complete for one track and partial for another passes
## [method DotTimerZoneSet.problems] — which is a per-zone check — while being a route a
## player falls off for ever. This family has shipped that hole twice; the suite walks
## this track's zones one kind at a time rather than believing `problems()`.
static func _add_the_switchback(zones: DotTimerZoneSet) -> void:
	var track := SWITCHBACK_TRACK
	var route := switchback_route()
	var pad: AABB = route[0]
	var first_hop: Vector3 = switchback_hops()[0]

	# On the pad, set back from its leading edge by a stride, facing the first block.
	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, track)
	spawn.destination = pad.get_center() - first_hop * 1.5 \
		+ Vector3(0.0, SWITCHBACK_PAD.y * 0.5 + 1.0, 0.0)
	# `atan2(-dx, -dz)`: the two minus signs are `pg_lobby`'s tower's, and for the same
	# reason — `DotFpsMotor._view_basis` builds forward as `(-sin(yaw), 0, -cos(yaw))`.
	spawn.destination_yaw = rad_to_deg(atan2(-first_hop.x, -first_hop.z))
	zones.add(spawn)

	# Timing begins when the player leaves the pad, which is the first jump.
	var start := DotTimerZone.make(DotTimerZone.Kind.START, track)
	start.set_box(
		Vector3(pad.position.x, pad.end.y - 0.5, pad.position.z),
		Vector3(pad.end.x, pad.end.y + 5.0, pad.end.z)
	)
	zones.add(start)

	# The route's whole footprint, for the splits and the reset volume below.
	var low := pad.position
	var high := pad.end

	for box in route:
		low = low.min(box.position)
		high = high.max(box.end)

	# A split on each turning block, spanning the whole hillside east to west.
	#
	# [b]Across the route rather than on the block.[/b] A turning block shares its Z
	# with the leg it turns onto, so a slab at that Z two metres deep is the whole of
	# the next leg — and the only way into it. The legs are 2.4 to 2.9 m of air apart,
	# which reads like a jump, but everywhere except beside a turn the next leg is 1.5 m
	# or more HIGHER, over the 1.15 m apex, so it cannot be climbed onto. Beside a turn
	# it is a diagonal of 3.5 m up 1.0 against a 3.2 m reach: a corner a player carrying
	# bhop speed can cut, landing on the next leg without touching the turning block. A
	# split ON the block would be one that player skips; the slab is one nobody can.
	var corners := switchback_corners()

	for n in range(corners.size()):
		var corner: AABB = route[corners[n]]
		var z := corner.get_center().z
		var stage := DotTimerZone.make(DotTimerZone.Kind.STAGE, track)
		stage.number = float(n + 1)
		stage.set_box(
			Vector3(low.x - 2.0, corner.end.y - 1.5, z - 1.0),
			Vector3(high.x + 2.0, corner.end.y + 6.0, z + 1.0)
		)
		zones.add(stage)

	# The finish: the whole pad and the air above it, deep for `thin_zones`' reason.
	var last: AABB = route[route.size() - 1]
	var finish := DotTimerZone.make(DotTimerZone.Kind.END, track)
	finish.set_box(
		Vector3(last.position.x, last.end.y - 1.0, last.position.z),
		Vector3(last.end.x, last.end.y + 5.0, last.end.z)
	)
	zones.add(finish)

	# Falling off: a slab three to eight metres under the pad, the whole hillside wide.
	# Everything on this route is above the pad, so anybody who leaves a block passes
	# through it, and it stops well west of the main run at x = 0 so it is never under
	# a player hopping along those blocks — the track filter would cover that anyway,
	# but a volume that only behaves because of a filter misbehaves the day somebody
	# widens it.
	var reset := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, track)
	reset.set_box(
		Vector3(low.x - 10.0, SWITCHBACK_Y - 8.0, low.z - 10.0),
		Vector3(high.x + 10.0, SWITCHBACK_Y - 3.0, high.z + 10.0)
	)
	zones.add(reset)


## Everything on bonus 3: a spawn, a start, a split on each crest after the first ramp's,
## a finish, and a volume under the whole climb that puts a player who fell back on the
## pad.
##
## [b]The splits are on the crests of ramps two, three and four.[/b] A crest is the one
## place a player cannot reach but by the ramp below it, so a split there is one nobody
## skips — and it measures the climb and the jump before it together, which is the
## section. The first crest has none because the first section is a lesson.
static func _add_the_ascent(zones: DotTimerZoneSet) -> void:
	var track := ASCENT_TRACK
	var route := ascent_route()
	var pad: AABB = route[0]

	# On the pad, a stride behind its middle so there is a run-up to the first jump,
	# facing -Z — the way the route runs, which is yaw 0 by `DotFpsMotor._view_basis`'s
	# convention.
	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, track)
	spawn.destination = pad.get_center() + Vector3(0.0, ASCENT_PAD.y * 0.5 + 1.0, 1.5)
	spawn.destination_yaw = 0.0
	zones.add(spawn)

	# Timing begins when the player leaves the pad, which is the first jump.
	var start := DotTimerZone.make(DotTimerZone.Kind.START, track)
	start.set_box(
		Vector3(pad.position.x, pad.end.y - 0.5, pad.position.z),
		Vector3(pad.end.x, pad.end.y + 5.0, pad.end.z)
	)
	zones.add(start)

	# Wider than the route and tall, for the narrows' reason: a player drifting off the
	# side as they cross has still crossed.
	for n in range(1, ASCENT_PITCHES.size()):
		var crest: AABB = route[2 + n * 2]
		var stage := DotTimerZone.make(DotTimerZone.Kind.STAGE, track)
		stage.number = float(n)
		stage.set_box(
			Vector3(crest.position.x - 2.0, crest.end.y - 1.0, crest.position.z),
			Vector3(crest.end.x + 2.0, crest.end.y + 6.0, crest.end.z)
		)
		zones.add(stage)

	# The finish: the whole pad and the air above it, deep for `thin_zones`' reason.
	var last: AABB = route[route.size() - 1]
	var finish := DotTimerZone.make(DotTimerZone.Kind.END, track)
	finish.set_box(
		Vector3(last.position.x, last.end.y - 1.0, last.position.z),
		Vector3(last.end.x, last.end.y + 5.0, last.end.z)
	)
	zones.add(finish)

	# Falling off: a slab three to eight metres under the pad, the whole climb long.
	# Everything on this route is at or above the pad, so anybody who leaves it passes
	# through, and ten metres either side stops it at x = 50 — clear of the narrows'
	# own slab, which ends at 48.
	var reset := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, track)
	reset.set_box(
		Vector3(ASCENT_X - 10.0, ASCENT_Y - 8.0, last.position.z - 10.0),
		Vector3(ASCENT_X + 10.0, ASCENT_Y - 3.0, pad.end.z + 10.0)
	)
	zones.add(reset)
