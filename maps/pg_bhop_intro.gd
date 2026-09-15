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
## Both tracks carry [constant DotTimerZone.Kind.STAGE] splits, because a map with one
## start and one finish exercises none of dot-timer's per-stage machinery.

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


## The gap after block [param index], in metres.
static func gap_at(index: int) -> float:
	return lerpf(FIRST_GAP, LAST_GAP, float(index) / float(maxi(BLOCKS - 1, 1)))


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
