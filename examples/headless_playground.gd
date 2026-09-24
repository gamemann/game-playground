extends Node

const Playground := preload("../game/playground.gd")
const PlaygroundBrowser := preload("../game/client/playground_browser.gd")
const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundEntity := preload("../game/entities/playground_entity.gd")
const PlaygroundIcons := preload("../game/playground_icons.gd")
const PlaygroundPlayer := preload("../game/playground_player.gd")
const PlaygroundProp := preload("../game/playground_prop.gd")
const PlaygroundSpawnMenu := preload("../game/playground_spawn_menu.gd")
const PlaygroundSpawnables := preload("../game/playground_spawnables.gd")
const PgBhopIntro := preload("../maps/pg_bhop_intro.gd")
const PgSurfIntro := preload("../maps/pg_surf_intro.gd")
const PlaygroundVehicle := preload("../game/playground_vehicle.gd")
const PlaygroundWeaponDef := preload("../game/weapons/playground_weapon_def.gd")
const PlaygroundWeapons := preload("../game/playground_weapons.gd")

## Runs the whole playground: a bot surfs a map from start to finish, its run is
## timed and filed, props are spawned and moved, and the map is changed underneath.
##
## [codeblock]
## godot --headless --path . res://examples/headless_playground.tscn
## [/codeblock]
##
## [b]This is the only thing in the family that runs the joins between these five
## addons.[/b] Each has its own suite and each passes with the others absent, and the
## family's own history says that proves very little: every bug that has cost a day
## here was in a seam — a bridge reconciling on top of another bridge, a client
## message keyed on the wrong id, a value computed and consumed by nothing. So this
## test is about the joins, not about the parts:
##
## - the timer is ticked from the movement loop, with the position the move produced;
## - a style change moves both halves together;
## - a zone's effect reaches the player through the game and not through the timer;
## - a record is filed, scored, and reaches the leaderboard;
## - a map change tears down runs, props and geometry in an order that survives;
## - a prop can be spawned, held, and freed without leaking a node.
##
## The bot's input is a scripted [DotFpsCommand] rather than a device, which is the
## whole reason [DotFpsSampler] is a separate object.

const TICK := 1.0 / 128.0

## Preloaded rather than named: the built-in maps have no `class_name`, deliberately
## — they are content, and a map that reserved a global identifier in every consuming
## project is the thing dot-map exists to avoid.
const PgLobby := preload("res://maps/pg_lobby.gd")

const CHECKS := 361

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total above is the other half — see docs/testing.md.
const SECTIONS := 21

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var playground: Playground = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("playground — headless integration")
	print("")

	playground = Playground.new()

	var config := PlaygroundConfig.new()
	# Records in memory: a headless run must not write into the user's data
	# directory, and a suite that did could not be run twice with the same result.
	config.records_directory = ""
	# No map on boot: the tests below load their own and would race a boot load.
	config.initial_map = &"pg_lobby"
	config.map_seconds = 0.0
	playground.config = config

	add_child(playground)

	# Two frames: the playground's own `_ready` awaits its first map change, so one
	# is not enough for it to have finished booting.
	await get_tree().process_frame
	await get_tree().process_frame

	await _test_boots()
	await _test_tick_rate_comes_from_the_engine()
	await _test_zone_file_matches_the_map()
	await _test_surf_run()
	await _test_styles()
	await _test_leaderboards()
	await _test_checkpoints()
	await _test_props()
	await _test_map_change()
	await _test_map_time_limit()
	await _test_props_are_built_from_their_definitions()
	await _test_entities_run_their_scripts()
	await _test_weapons()
	await _test_spawn_menu()
	await _test_the_sandbox_and_its_course()
	await _test_vehicles()
	await _test_the_narrows()
	await _test_the_plunge()
	await _test_the_jump_course()
	await _test_the_switchback()
	await _test_the_client_boots()

	print("")
	print("%d passed, %d failed, %d of %d sections ran to their last line" % [
		_passed, _failed, _completed, _entered
	])

	for line in _failures:
		print("  FAIL  %s" % line)

	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return

	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)


func _check_near(
	value: float, expected: float, epsilon: float, what: String
) -> void:
	_check(
		absf(value - expected) <= epsilon, what,
		"%.4f vs %.4f" % [value, expected]
	)


## Runs the simulation for [param ticks], driving [param id] with [param command].
##
## Commands are applied per tick and the physics is stepped per tick, which is what
## makes this reproducible: a test that awaited frames would run a different number of
## simulation ticks on a loaded machine.
func _drive(
	id: StringName, command: DotFpsCommand, ticks: int
) -> void:
	var player: PlaygroundPlayer = playground.players[id]

	for _i in range(ticks):
		player.controller.apply_command(command.duplicate_command())
		await get_tree().physics_frame


# --- Boot ------------------------------------------------------------------

func _test_boots() -> void:
	_section("booting")

	_check(playground.maps != null, "the map session exists")
	_check(playground.timers != null, "the timer manager exists")
	_check(playground.props != null, "the prop spawner exists")
	_check(playground.boards != null, "the leaderboards exist")

	# Four: the sandbox, two courses, and `pg_generated` -- the one map in this family
	# that is not written down. The count is asserted rather than the ids because a map
	# added and not registered is the failure this is here to catch, and a list of ids
	# would be a second copy of `Playground.map_catalogue()`.
	_check(
		playground.maps.catalogue.size() == 4,
		"four maps are in the catalogue, one of them generated",
		"%d" % playground.maps.catalogue.size()
	)
	_check(
		playground.maps.catalogue.has(&"pg_generated"),
		"including the generated one, which is a map def like any other -- a rotation, a "
		+ "ballot and a cooldown work on it without anything opening the scene"
	)
	_check(
		playground.maps.catalogue.problems().is_empty(),
		"and none of them has a problem",
		", ".join(playground.maps.catalogue.problems())
	)
	_check(
		playground.props.catalogue.problems().is_empty(),
		"and neither does the prop catalogue"
	)

	var loaded: DotResult = await playground.change_map(&"pg_surf_intro")
	_check(loaded.ok, "the surf map loads",
		loaded.error.message if not loaded.ok else "")
	_check(playground.current_map_node() != null, "and is a PlaygroundMap")

	var player := playground.add_player(&"bot", "Bot")
	_check(player != null, "a player joins")
	_check(player.timer != null, "and gets a timer")
	_check(
		player.timer.zones != null and player.timer.zones.map_id == &"pg_surf_intro",
		"bound to the map's zones"
	)

	# The zones themselves. A start with no end is the commonest thing wrong with a
	# hand-drawn zone file, and it is playable and unfinishable.
	var zones := player.timer.zones
	_check(zones.problems().is_empty(), "the map's zones are well formed",
		", ".join(zones.problems()))
	_check(
		zones.playable_tracks() == PackedInt32Array(
			[DotTimerTrack.MAIN, DotTimerTrack.BONUS_FIRST]
		),
		"and both of its tracks can be run",
		str(zones.playable_tracks())
	)

	# The thin-zone check, at the speed a surfer actually reaches on this map.
	var thin := zones.thin_zones(40.0, playground.tick_rate)
	_check(
		thin.is_empty(),
		"and no zone is thin enough for a fast player to pass through",
		"%d thin" % thin.size()
	)

	await get_tree().physics_frame

	_check(
		player.global_position.distance_to(
			playground.current_map_node().spawn_for(DotTimerTrack.MAIN)
		) < 1.0,
		"and the player is at the map's spawn"
	)
	_done()


func _test_tick_rate_comes_from_the_engine() -> void:
	_section("the tick rate comes from the engine, which is what a server sets")

	# The chain: an operator writes `sv_tickrate` in server.cfg; dot-server writes
	# `Engine.physics_ticks_per_second`; the playground reads it; the timer manager
	# adopts it; and it lands on every record filed.
	#
	# Getting it wrong does not fail loudly — a timer counting 128 a second on a
	# server stepping 64 reports every run at twice its length, and nothing about
	# the run looks unusual — which is why this is a test rather than a comment.
	_check(
		playground.tick_rate == Engine.physics_ticks_per_second,
		"the playground counts in the engine's rate",
		"%d vs %d" % [playground.tick_rate, Engine.physics_ticks_per_second]
	)
	_check(
		playground.timers.tick_rate == playground.tick_rate,
		"and so does the timer manager",
		"%d vs %d" % [playground.timers.tick_rate, playground.tick_rate]
	)
	_check(
		playground.timers.tick_rate_matches_engine(),
		"so the two agree, which is the misconfiguration that is otherwise silent"
	)

	# And the record carries it, which is what settles a dispute afterwards.
	var run := DotTimerRun.make(0, &"normal", playground.timers.timer_for(&"bot").tick_interval()
		if playground.players.has(&"bot") else 1.0 / float(playground.tick_rate))
	run.begin(0.0)
	run.ticks = playground.tick_rate
	run.finish(0.0)

	var record := DotTimerRecord.from_run(run, &"m", &"p", "P")

	_check(
		record.tick_rate == playground.tick_rate,
		"a record is stamped with the rate it was measured at",
		"%d" % record.tick_rate
	)
	_check_near(record.time, 1.0, 0.01, "and its time is that rate's worth of ticks")
	_done()


func _test_zone_file_matches_the_map() -> void:
	_section("the shipped zone files match the geometry")

	# A map's zones and its geometry are built from the same constants here, and a
	# written-out copy of them lives in maps/ to demonstrate the file route that a
	# DELIVERED map has to use. This is the check that the two have not drifted —
	# because a zone file drawn against geometry that has since moved is a
	# leaderboard nobody can compare, and nothing else would ever notice.
	#
	# [b]Every map that builds zones, discovered, and not `pg_surf_intro` alone.[/b]
	# This asked one map's file for as long as it existed, so `pg_lobby`'s and
	# `pg_bhop_intro`'s could drift from their maps with nothing said — game-g2gfast's
	# `_test_zone_files_match` carried the same one-map-short list until it discovered.
	var ids := _zone_map_ids()
	_check(ids.size() == 3, "three maps build zones", str(ids))

	for id in ids:
		var loaded := DotTimerZoneSet.load_json("res://maps/%s.zones.json" % id)
		var built: DotTimerZoneSet = (load("res://maps/%s.gd" % id) as GDScript).build_zones()
		var shipped: DotTimerZoneSet = loaded.value if loaded.ok else null

		_check(
			shipped != null and shipped.fingerprint() == built.fingerprint(),
			"%s's shipped file matches what the map builds" % id,
			loaded.error.message if not loaded.ok
				else "%s vs %s" % [shipped.fingerprint(), built.fingerprint()]
		)

		# `[track-zone-1]`: every route on every map, per track — a start, a finish, a
		# spawn and a pit of its own. Asked of the SHIPPED file as well as the map,
		# because a pitless declaration lives in `meta`, which the fingerprint ignores:
		# a file exported before one was added matches and is still incomplete.
		var incomplete := built.route_problems()
		if shipped != null:
			incomplete.append_array(shipped.route_problems())
		_check(
			shipped != null and incomplete.is_empty(),
			"%s's every route has a start, a finish, a spawn and a pit" % id,
			", ".join(incomplete)
		)
	_done()


## The maps that build their own zones: a script in res://maps with `build_zones`.
##
## The question `tools/export_zones.gd` answers with a list, asked the other way, so
## that a map added to one and not the other is a failure rather than a file nobody
## wrote. `pg_generated` has no zones and is not in it.
func _zone_map_ids() -> Array[String]:
	var out: Array[String] = []

	for file in DirAccess.get_files_at("res://maps"):
		if not file.ends_with(".gd"):
			continue

		var script := load("res://maps/" + file) as GDScript

		for method in script.get_script_method_list():
			if method.name == "build_zones":
				out.append(file.get_basename())
				break

	out.sort()
	return out


# --- A run -----------------------------------------------------------------

func _test_surf_run() -> void:
	_section("a surf run, start to finish")

	var player: PlaygroundPlayer = playground.players[&"bot"]

	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var started := [0]
	var finished: Array[DotTimerRun] = []

	player.timer.run_started.connect(func(_run: DotTimerRun) -> void: started[0] += 1)
	player.timer.run_finished.connect(
		func(run: DotTimerRun) -> void: finished.append(run)
	)

	# Walk off the start platform and down the valley. The bot holds forward and
	# strafes, which on a surf ramp is what gains speed — see
	# DotFpsMotor.accelerate.
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	forward.yaw = 0.0

	await _drive(&"bot", forward, 200)

	_check(started[0] >= 1, "leaving the start zone begins a run", "%d" % started[0])
	_check(player.timer.run.is_running(), "and it is running")

	# Down the ramps. Not grounded, because the ramps are steeper than the player
	# can stand on — which is the whole of surf.
	var airborne := 0
	var top_speed := 0.0
	var entry_z := player.controller.state.position.z
	var deepest_z := entry_z
	var deepest_y := player.controller.state.position.y
	var deepest_x := player.controller.state.position.x

	for i in range(1400):
		var command := DotFpsCommand.new()
		# Strafe alternately, turning with it, which is what a surfer does.
		var phase := (i / 90) % 2
		command.move = Vector2(1.0 if phase == 0 else -1.0, 0.0)
		command.yaw = wrapf(
			(-1.0 if phase == 0 else 1.0) * float(i % 90) * 0.35
			+ (0.0 if phase == 0 else -31.5),
			-180.0, 180.0
		)

		player.controller.apply_command(command)
		await get_tree().physics_frame

		if not player.controller.state.is_grounded():
			airborne += 1

		top_speed = maxf(top_speed, player.speed())

		if player.controller.state.position.z < deepest_z:
			deepest_z = player.controller.state.position.z
			deepest_y = player.controller.state.position.y
			deepest_x = player.controller.state.position.x

		if finished.size() > 0:
			break

	_check(
		airborne > 400,
		"most of the descent is spent not grounded, which is what surf is",
		"%d airborne ticks" % airborne
	)
	_check(top_speed > 12.0, "and the player reaches surf speed",
		"%.1f m/s" % top_speed)

	# What the scripted strafe pattern actually achieves, PRINTED rather than only
	# asserted — see game-arena's "what a bot actually travels at" group and
	# `[bot-drive-1]`. A check's detail line shows only when it fails, so a figure
	# that is merely asserted is a figure nobody reads again once it passes, and
	# every question about how a map should be shaped is a question about this
	# number. The route is %.0f m long; anything short of that is where a bot
	# stops being evidence about the map.
	var travelled := entry_z - deepest_z
	var route := absf(PgSurfIntro.END_Z - PgSurfIntro.START_Z)

	print(
		"        the scripted surfer covered %.1f m of %.1f m (%.0f%%), "
		% [travelled, route, 100.0 * travelled / route]
		+ "ending at x %.1f y %.1f, %d splits crossed"
		% [deepest_x, deepest_y, player.timer.run.splits.size()]
	)

	# Whether the bot happened to reach the finish is not the point — a scripted
	# strafe pattern is not a player. What has to be true is that the run was timed,
	# the statistics were folded in, and the machinery did not fall over.
	_check(
		player.controller.stats.jumps >= 0
			and player.controller.stats.ticks > 1000,
		"the movement statistics accumulated over the run",
		"%d ticks" % player.controller.stats.ticks
	)
	_check(player.controller.motor.stuck_ticks == 0,
		"and the collide-and-slide never ran out of iterations",
		"%d stuck" % player.controller.motor.stuck_ticks)
	_check(
		is_finite(player.controller.state.position.length()),
		"and the position stayed finite"
	)

	# Now finish it deliberately, by putting the player in the finish zone. The
	# route down is a movement question and is tested in dot-player-controller; what is
	# under test HERE is that a crossing produces a timed, filed run.
	if finished.is_empty():
		var zones := player.timer.zones
		var finish := zones.first_of_kind(DotTimerZone.Kind.END, DotTimerTrack.MAIN)

		player.controller.state.position = finish.centre() + Vector3.UP * 0.5
		player.controller.state.velocity = Vector3(0.0, 0.0, -6.0)

		await _drive(&"bot", forward, 4)

	_check(finished.size() == 1, "the run finishes exactly once",
		"%d" % finished.size())

	if finished.size() == 1:
		_check(finished[0].time() > 0.0, "with a positive time",
			finished[0].formatted_time())
		_check(
			finished[0].status == DotTimerRun.Status.FINISHED,
			"and the run is in the finished state"
		)
		_check(
			finished[0].stats.has("jumps"),
			"and the movement statistics were folded into it",
			str(finished[0].stats.keys())
		)
	_done()


func _test_styles() -> void:
	_section("styles move both halves together")

	var player: PlaygroundPlayer = playground.players[&"bot"]

	_check(playground.set_player_style(&"bot", &"sideways"), "a style can be set")
	_check(
		player.movement_style != null and player.movement_style.id == &"sideways",
		"the movement half is on"
	)
	_check(
		player.timer.style != null and player.timer.style.id == &"sideways",
		"and so is the ranking half"
	)
	_check(
		player.controller.style != null
			and player.controller.style.id == &"sideways",
		"and the controller has it, which assigning the property alone would not do"
	)

	# The command filter is the visible half: sideways removes the forward key, and
	# it has to happen before the motor sees the command.
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)

	player.controller.apply_command(forward)

	_check_near(
		player.controller.current_command.move.y, 0.0, 0.0001,
		"and the forward key is filtered out of the command"
	)

	# A style change abandons a run, because half a run on each is a run on neither.
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	playground.set_player_style(&"bot", &"low_gravity")

	_check(
		not player.timer.run.is_active(),
		"and changing style leaves no run in progress"
	)
	_check_near(
		player.controller.tunables.gravity, 10.0, 0.01,
		"low gravity halves the gravity the motor reads"
	)

	# Back to normal, and the base is restored rather than compounded — the reason
	# the controller keeps `_base_tunables`.
	playground.set_player_style(&"bot", &"normal")
	_check_near(
		player.controller.tunables.gravity, 20.0, 0.01,
		"and switching back restores it rather than halving it again"
	)
	_done()


func _test_leaderboards() -> void:
	_section("records reach the leaderboards")

	var scope := {
		"map": "pg_surf_intro",
		"track": "0",
		"style": "normal",
	}

	var page: DotResult = await playground.boards.page(&"fastest", scope)
	var rows: Array = page.value

	# The run above may or may not have been fast enough to clear the style's
	# minimum time, so this files one directly — what is under test is the path from
	# a record to a board, not the bot's driving.
	if rows.is_empty():
		await playground.boards.submit(
			&"fastest", scope, &"bot", "Bot", 42.5
		)
		page = await playground.boards.page(&"fastest", scope)
		rows = page.value

	_check(rows.size() >= 1, "there is a time on the board")

	if rows.size() >= 1:
		_check((rows[0] as DotLeaderboardEntry).rank == 1, "ranked first")

	# Faster than whatever is on top, rather than a fixed number: the bot's own time
	# depends on how the run above went, and a hard-coded 20 seconds made this test
	# pass or fail on the bot's driving instead of on the board's ordering.
	var beat := (rows[0] as DotLeaderboardEntry).value - 1.0

	await playground.boards.submit(&"fastest", scope, &"other", "Other", beat)

	page = await playground.boards.page(&"fastest", scope)
	rows = page.value

	_check(
		(rows[0] as DotLeaderboardEntry).player_id == &"other",
		"a faster time takes the top",
		String((rows[0] as DotLeaderboardEntry).player_id)
	)
	_check(
		(rows[1] as DotLeaderboardEntry).rank == 2,
		"and the ranks are rewritten"
	)

	# A different scope is a different board — the thing a canonical scope key
	# exists to guarantee.
	var other_scope := scope.duplicate()
	other_scope["style"] = "sideways"

	var other: DotResult = await playground.boards.page(&"fastest", other_scope)
	_check(
		(other.value as Array).is_empty(),
		"and another style's board is separate"
	)

	# The same scope built in a different order must be the SAME board.
	var reordered := {
		"style": "normal", "map": "pg_surf_intro", "track": "0",
	}
	var same: DotResult = await playground.boards.page(&"fastest", reordered)
	_check(
		(same.value as Array).size() == rows.size(),
		"while the same scope in a different order is the same board",
		"%d vs %d" % [(same.value as Array).size(), rows.size()]
	)
	_done()


# --- Props -----------------------------------------------------------------

func _test_checkpoints() -> void:
	_section("practice checkpoints, through the game")

	var player: PlaygroundPlayer = playground.players[&"bot"]
	var checkpoints := playground.timers.checkpoints_for(&"bot")

	_check(checkpoints != null, "a player has a checkpoint set")

	if checkpoints == null:
		return

	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _drive(&"bot", forward, 120)

	var somewhere := player.controller.state.position

	checkpoints.save(
		somewhere,
		player.controller.state.velocity,
		player.controller.state.yaw,
		player.controller.state.pitch,
		player.controller.state.is_grounded()
	)

	_check(checkpoints.count() == 1, "a checkpoint is saved")

	await _drive(&"bot", forward, 120)

	_check(
		player.controller.state.position.distance_to(somewhere) > 1.0,
		"the player moves on"
	)

	var restored := checkpoints.load_current()
	_check(restored != null, "and the checkpoint can be restored")

	if restored != null:
		player.teleport(restored.position, restored.yaw)
		player.controller.state.velocity = restored.velocity

		await get_tree().physics_frame

		_check(
			player.controller.state.position.distance_to(somewhere) < 1.0,
			"putting them back where they saved it",
			"%.2f m away" % player.controller.state.position.distance_to(somewhere)
		)
	_done()


func _test_props() -> void:
	_section("props")

	var player: PlaygroundPlayer = playground.players[&"bot"]

	playground.props.limits.spawn_interval = 0.0

	var at := player.global_position + Vector3(0.0, 3.0, -4.0)
	var crate := playground.props.spawn(&"crate", &"bot", at)

	_check(crate != null, "a crate spawns")
	_check(playground.props.world_count() == 1, "and is counted")
	_check(
		crate != null and crate.node.get_parent() == playground.world,
		"under the world node the map is in"
	)

	# The physics gun. Grabbed directly rather than through a ray, because what is
	# under test here is the join — the gun, the spawner and the world — and not
	# Godot's raycast, which dot-props covers.
	player.phys_gun.held = crate
	crate.held_by = &"bot"
	player.phys_gun.hold_distance = 4.0

	var origin := player.eye_position()
	var aim := player.aim_direction()

	for _i in range(90):
		player.phys_gun.hold(origin, aim, Basis.IDENTITY, TICK)
		await get_tree().physics_frame

	var goal := origin + aim * player.phys_gun.hold_distance
	_check(
		crate.position().distance_to(goal) < 2.0,
		"a held crate follows the aim",
		"%.2f m away" % crate.position().distance_to(goal)
	)

	player.phys_gun.freeze_held()
	_check(crate.frozen, "and can be frozen in place")
	_check(player.phys_gun.held == null, "which lets go of it")

	# Undo, and then cleanup on leave.
	playground.props.spawn(&"barrel", &"bot", at)
	_check(playground.props.world_count() == 2, "a second prop spawns")
	_check(playground.props.undo(&"bot"), "and can be undone")
	_check(playground.props.world_count() == 1, "leaving the first")

	var node := crate.node

	playground.props.player_left(&"bot")

	_check(playground.props.world_count() == 0, "a departing player's props go")

	await get_tree().process_frame
	await get_tree().process_frame

	_check(not is_instance_valid(node), "and the node is actually freed")
	_done()


# --- Changing maps ---------------------------------------------------------

func _test_map_change() -> void:
	_section("changing map under a live player")

	var player: PlaygroundPlayer = playground.players[&"bot"]

	playground.spawn_player(&"bot")
	playground.props.limits.spawn_interval = 0.0
	playground.props.spawn(
		&"crate", &"bot", player.global_position + Vector3.UP * 3.0
	)

	# Start a run, so the change happens with everything in flight — a run in
	# progress, a prop in the world, and geometry about to be freed under both.
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _drive(&"bot", forward, 200)

	var was_running := player.timer.run.is_active()
	var props_before := playground.props.world_count()

	_check(props_before == 1, "a prop is in the world")

	var changed: DotResult = await playground.change_map(&"pg_bhop_intro")

	_check(changed.ok, "the map changes",
		changed.error.message if not changed.ok else "")
	_check(
		playground.maps.current.id == &"pg_bhop_intro",
		"and the session is on the new one"
	)
	_check(
		not player.timer.run.is_active(),
		"a run in progress is abandoned rather than carried across",
		"was running: %s" % was_running
	)
	_check(
		playground.props.world_count() == 0,
		"and the props are cleared with the geometry they stood on"
	)
	_check(
		player.timer.zones != null
			and player.timer.zones.map_id == &"pg_bhop_intro",
		"the timer is rebound to the new map's zones"
	)

	await get_tree().physics_frame

	_check(
		player.global_position.distance_to(
			playground.current_map_node().spawn_for(DotTimerTrack.MAIN)
		) < 2.0,
		"and the player is at the new map's spawn"
	)

	# And the bhop map is actually runnable: hold jump and forward, and the player
	# should hop rather than walk.
	var hopping := DotFpsCommand.new()
	hopping.move = Vector2(0.0, 1.0)
	hopping.set_button(DotFpsCommand.BUTTON_JUMP, true)

	player.controller.stats.reset()
	await _drive(&"bot", hopping, 400)

	_check(
		player.controller.stats.jumps >= 3,
		"holding jump on the bhop map produces hops",
		"%d jumps" % player.controller.stats.jumps
	)
	_check(
		player.controller.stats.perfect_jumps > 0,
		"and auto-hop makes them perfect",
		"%d/%d" % [
			player.controller.stats.perfect_jumps,
			player.controller.stats.measured_jumps
		]
	)
	_done()


func _test_map_time_limit() -> void:
	_section("a map that ends on its own")

	# A server that never changes map is not a server. The session says the map is
	# over; the playground decides what happens next — which here is the rotation.
	playground.maps.time_limit.duration = 60.0
	playground.maps.time_limit.warn_at = 10.0
	playground.maps.time_limit.start()

	var was := playground.maps.current.id

	var warned := [0]
	playground.maps.time_warning.connect(func(_left: float) -> void: warned[0] += 1)

	# Advanced through the game's own loop, so this exercises the wiring rather than
	# the time limit in isolation — which dot-map's own suite covers.
	for _i in range(70):
		playground.maps.advance(1.0)

	_check(warned[0] == 1, "the warning fires once", "%d" % warned[0])

	# The change is a coroutine started from a signal, so it lands a frame later.
	for _i in range(10):
		await get_tree().process_frame

	_check(
		playground.maps.current.id != was,
		"and the map changes when the clock runs out",
		"%s -> %s" % [String(was), String(playground.maps.current.id)]
	)
	_check(
		playground.maps.time_limit.running,
		"with the clock restarted on the new one"
	)

	# Rocking the vote.
	playground.maps.time_limit.duration = 3600.0
	playground.maps.time_limit.rtv_min_players = 1
	playground.maps.time_limit.rtv_fraction = 1.0
	playground.maps.time_limit.start()

	var before := playground.maps.current.id

	_check(
		playground.rock_the_vote(&"bot"),
		"one player of one carries a unanimous vote"
	)

	for _i in range(10):
		await get_tree().process_frame

	_check(
		playground.maps.current.id != before,
		"and the map changes",
		"%s -> %s" % [String(before), String(playground.maps.current.id)]
	)

	# A player who leaves takes their vote with them.
	playground.maps.time_limit.start()
	playground.maps.time_limit.rtv_fraction = 0.6
	playground.maps.time_limit.rtv_min_players = 2

	playground.maps.time_limit.rock_the_vote(&"ghost", 4)
	_check(playground.maps.time_limit.rtv_votes() == 1, "a vote is counted")

	playground.remove_player(&"ghost")
	_check(
		playground.maps.time_limit.rtv_votes() == 1,
		"removing somebody who was not playing changes nothing"
	)

	playground.add_player(&"ghost", "Ghost")
	playground.maps.time_limit.rock_the_vote(&"ghost", 4)
	playground.remove_player(&"ghost")

	_check(
		not playground.maps.time_limit.has_rocked(&"ghost"),
		"and a player who leaves takes their vote with them"
	)

	playground.maps.time_limit.duration = 0.0
	playground.maps.time_limit.start()
	_done()


## Every prop this build ships is one scene, and the definition is what differs.
##
## [b]The mass column is the one that matters.[/b] `DotPropDef.mass` is read by
## exactly one thing in dot-props — a physics gun's `grab_mass_limit` — so before the
## spawner put it on the body, a catalogue that said 900 kg and a scene saved at 20 kg
## gave a prop that was refused for being too heavy and then punted like a beach ball.
## Nothing errored, and the two numbers were only ever compared by a player wondering
## why.
func _test_props_are_built_from_their_definitions() -> void:
	_section("props built from their definitions")

	var at := Vector3(0.0, 40.0, 0.0)

	playground.props.limits.spawn_interval = 0.0

	var ball := playground.props.spawn(&"beach_ball", &"bot", at)
	var boulder := playground.props.spawn(
		&"boulder", &"bot", at + Vector3(6.0, 0.0, 0.0)
	)

	_check(ball != null and boulder != null, "two props spawn")

	if ball == null or boulder == null:
		return

	var ball_body := ball.node as PlaygroundProp
	var boulder_body := boulder.node as PlaygroundProp

	_check(
		ball_body != null and boulder_body != null,
		"and both are the project's own configurable body"
	)

	_check_near(ball_body.mass, 2.0, 0.01, "a beach ball weighs what it says")
	_check_near(boulder_body.mass, 900.0, 0.01, "and a boulder weighs what it says")

	# The whole reason for that check: they are the same scene file, so the only
	# thing that can make them different masses is the definition reaching the body.
	_check(
		ball.def.scene_path == boulder.def.scene_path,
		"from one scene, which is why the mass had to come from the definition"
	)

	var ball_shape := (ball_body.get_node("Collision") as CollisionShape3D).shape
	var boulder_shape := (
		boulder_body.get_node("Collision") as CollisionShape3D
	).shape

	_check(ball_shape is SphereShape3D, "a ball is round")
	_check(
		ball_shape is SphereShape3D
		and is_equal_approx((ball_shape as SphereShape3D).radius, 1.2),
		"at the radius its extent asks for"
	)
	_check(
		boulder_shape is SphereShape3D
		and (boulder_shape as SphereShape3D).radius > (
			ball_shape as SphereShape3D
		).radius,
		"and the boulder is bigger than it while weighing 450 times as much"
	)

	var plank := playground.props.spawn(&"plank", &"bot", at + Vector3.UP * 4.0)
	var plank_shape := (
		(plank.node as PlaygroundProp).get_node("Collision") as CollisionShape3D
	).shape

	_check(
		plank_shape is BoxShape3D
		and (plank_shape as BoxShape3D).size.is_equal_approx(
			Vector3(3.0, 0.15, 0.6)
		),
		"and a plank is a plank"
	)

	# The catalogue itself, because the menu is built out of it and a category with
	# nothing in it is a tab that does nothing.
	var catalogue := playground.props.catalogue
	var categories := catalogue.categories()

	_check(catalogue.size() >= 12, "the catalogue has enough in it to build with",
		"%d props" % catalogue.size())
	_check(categories.size() >= 3, "in at least three categories",
		"%s" % ", ".join(categories))

	for category in categories:
		_check(
			not catalogue.in_category(StringName(category)).is_empty(),
			"category '%s' has props in it" % category
		)

	_check(catalogue.problems().is_empty(), "and nothing is wrong with it",
		"; ".join(catalogue.problems()))

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	_done()


## Bonus 2: the spiral, and the two things about it that a count cannot check.
##
## [b]Its gaps are checked against the MOVEMENT, not against a number somebody liked.[/b]
## A spiral re-tuned to a larger radius or fewer platforms is a course that cannot be
## finished, and nothing about it looks wrong: the platforms are still there, still
## evenly spaced, still rising. The only thing that says it is broken is a jump arc, so
## that is what this asserts — the same reasoning `dm_atrium`'s stair height needed, one
## dimension over.
func _test_the_tower(playground: Playground, zones: DotTimerZoneSet) -> void:
	var track := DotTimerTrack.BONUS_FIRST + 1

	_check(
		zones.of_kind(DotTimerZone.Kind.START, track).size() == 1,
		"the tower on bonus 2 has one start"
	)
	_check(
		zones.of_kind(DotTimerZone.Kind.END, track).size() == 1,
		"and one finish"
	)
	_check(
		zones.of_kind(DotTimerZone.Kind.STAGE, track).size() == 2,
		"and two splits"
	)
	_check(
		zones.route_tracks().has(track) and zones.route_problems().is_empty(),
		"and a spawn and somewhere to land when you come off it, like every route here",
		", ".join(zones.route_problems())
	)

	# [b]Every jump on the spiral, measured box to box against the CLIMBING reach.[/b]
	#
	# What stood here until 2026-09-23 was the error `[reach-1]` found on the jump course
	# two days earlier, one corner over and never asked about: it took the reach from a
	# FLAT jump (airborne 2v/g) off a `DotFpsTunables.new()` — the addon's defaults, with
	# a jump height of 1.1 where the server applies 1.15 — and called 4.64 m a jump on a
	# course that climbs 0.6 m a step, where the real number is 4.02. Then it measured
	# the pad-to-first-platform step centre to centre minus a width, which called 0.2 m
	# of air 3.8 m, and stopped at the sixteenth platform, so the inward jump onto the
	# finish cap — the widest gap on the tower — was never measured by anything. The
	# geometry happened to be fine. The check would have passed a 4.5 m gap nobody can
	# cross, and `_the_old_tower_rule_passes_an_unjumpable_gap` below says so.
	_check_route_reach(PgLobby.tower_route(), "the tower")
	_the_old_tower_rule_passes_an_unjumpable_gap()

	# The splits are HEIGHT bands, and the reason is that a vertical line across a
	# spiral is crossed twice per turn. Two bands at the same height would be the same
	# bug wearing a different hat, so they have to be apart by more than their own
	# thickness.
	var stages := zones.of_kind(DotTimerZone.Kind.STAGE, track)
	var heights: Array[float] = []

	for stage in stages:
		# `centre()`, not an AABB: [DotTimerZone] has no `aabb()` and the first version
		# of this called one. It did not fail the suite — the script error aborted this
		# function and the two checks below it never ran, so the run reported 201 passed
		# and 0 failed while being two checks short. The same hazard as an un-awaited
		# coroutine, reached from a different direction, and the reason a suite's own
		# stderr is worth reading even when it exits 0.
		heights.append(stage.centre().y)

	_check(
		heights.size() == 2 and absf(heights[0] - heights[1]) > 1.0,
		"and its two splits are at different heights",
		"%s; a vertical line across a spiral is crossed twice per turn" % str(heights)
	)

	# The finish is above the pillar, so the last jump is inward rather than round.
	var finish := PgLobby.tower_finish_centre()
	_check(
		absf(finish.x - PgLobby.TOWER_X) < 0.01
			and absf(finish.z - PgLobby.TOWER_Z) < 0.01,
		"and it finishes in the middle, so the last jump is a different jump"
	)


## Whether a jump of [param gap] metres of clear air, landing [param rise] higher, is one
## the movement makes. The one rule every route sweep below asks.
static func _jump_is_inside(gap: float, rise: float) -> bool:
	return rise < PgLobby.JUMP_HEIGHT and gap <= PgLobby.jump_reach(rise)


## Sweeps every jump on a route — a list of the boxes a player lands on, in order — and
## asserts each is inside [method _jump_is_inside]. Two checks, and it PRINTS the worst
## jump whether it passes or not, because a check's detail line shows only on failure and
## the number is the thing a person re-tuning the course needs.
##
## Also asserts the rule itself: a jump halfway between the climbing reach and what a
## flat jump off the addon's default tunables says is refused. That is the arithmetic the
## tower was checked with until 2026-09-23, so this is the check that fails if the rule is
## ever "simplified" back to it.
func _check_route_reach(route: Array[AABB], name: String) -> void:
	var worst := -INF
	var worst_at := -1
	var worst_gap := 0.0
	var worst_rise := 0.0
	var tallest := 0.0
	var inside := true

	for i in range(1, route.size()):
		var gap := PgLobby.gap_between(route[i - 1], route[i])
		var rise := route[i].end.y - route[i - 1].end.y
		tallest = maxf(tallest, rise)

		if not _jump_is_inside(gap, rise):
			inside = false

		# The tightest jump, as a fraction of the reach it has to be made in.
		var reach := PgLobby.jump_reach(rise)
		var used := gap / reach if reach > 0.0 else INF

		if used > worst:
			worst = used
			worst_at = i
			worst_gap = gap
			worst_rise = rise

	print("    %s: %d jumps, the tightest is #%d, %.2f m of air %.2f m up against a %.2f m reach (%.0f%%)" % [
		name, route.size() - 1, worst_at, worst_gap, worst_rise,
		PgLobby.jump_reach(worst_rise), worst * 100.0,
	])

	_check(
		inside,
		"every jump on %s is inside the climbing reach, box to box" % name,
		"jump #%d is %.2f m of air %.2f m up against a %.2f m reach"
			% [worst_at, worst_gap, worst_rise, PgLobby.jump_reach(worst_rise)]
	)
	_check(
		tallest < PgLobby.JUMP_HEIGHT,
		"and no step on %s is also a wall" % name,
		"tallest %.2f m against a %.2f m jump apex" % [tallest, PgLobby.JUMP_HEIGHT]
	)


## The old tower rule, kept only to be refused: flat airtime, addon default tunables.
func _the_old_tower_rule_passes_an_unjumpable_gap() -> void:
	var defaults := DotFpsTunables.new()
	var launch := sqrt(2.0 * defaults.gravity * defaults.jump_height)
	var old_reach := defaults.max_speed * 2.0 * launch / defaults.gravity
	var real_reach := PgLobby.jump_reach(PgLobby.TOWER_RISE)
	var between := (old_reach + real_reach) * 0.5

	_check(
		between < old_reach and not _jump_is_inside(between, PgLobby.TOWER_RISE),
		"a %.2f m gap a tower step up, which the old flat-jump rule passed, is refused" % between,
		"old reach %.2f, climbing reach %.2f" % [old_reach, real_reach]
	)


## Drives a bot along a route of standable boxes, steering by yaw every tick.
##
## [b]This is what the spiral needed, and it is not air-strafing.[/b] The written reason
## bonus 2 had no drive was that "a spiral is finished by air-strafing round a corner",
## and that was a description of the BOT, not of the course: every bot here held one yaw
## for its whole run, so a course that turned was one it could only ever fall off. A
## course whose gaps are half a reach needs no carried speed at all — it needs a player
## who faces the next platform before jumping at it, and a scripted bot can do that
## exactly, reading the route off the map.
##
## Three rules, and each is a thing a player does:
##
## - **Face the next box's centre, every tick, in the air too.** On the ground that
##   turns the run; in the air it is a brake as much as a steer — `air_accelerate` is
##   100 with a 1 m/s wish cap, so a wish pointed back at a centre the bot has passed
##   takes its speed off within a few ticks, and it lands near the middle rather than
##   off the far side.
## - **Jump on the last grounded tick before the edge**, judged by a point
##   [param look_ahead] metres ahead along the heading leaving the box it stands on.
##   Not jump held: see `_jumping_at` for why that gets a bot nowhere.
## - **What it stands on is decided by where it is**, not by a counter. A bot that falls
##   onto a lower turn of a spiral simply resumes from there, which is how a respawn
##   and a missed landing both come out right without a special case.
##
## Returns `{started, finished, splits, reached, ticks, respawns}`; `reached` is the
## highest box index stood on, reported so a failure names the jump.
func _drive_route(
	player: PlaygroundPlayer, route: Array[AABB], max_ticks: int,
	look_ahead: float = 0.3
) -> Dictionary:
	# Arrays, not locals: a GDScript lambda captures by value.
	var started: Array[bool] = [false]
	var finished: Array[bool] = [false]
	var splits: Array[int] = []
	var respawns: Array[int] = [0]

	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_stage := func(number: int, _split: float) -> void: splits.append(number)
	var on_finish := func(_run: DotTimerRun) -> void: finished[0] = true
	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == player.player_id and zone.kind == DotTimerZone.Kind.RESPAWN:
			respawns[0] += 1

	player.timer.run_started.connect(on_start)
	player.timer.stage_reached.connect(on_stage)
	player.timer.run_finished.connect(on_finish)
	playground.timers.effect_requested.connect(on_effect)

	var on := 0
	var reached := 0
	var ticks := 0

	for tick in range(max_ticks):
		ticks = tick
		var at := player.global_position
		var grounded := player.controller.state.is_grounded()

		if grounded:
			# Highest first: on a spiral a box is directly under another one.
			for i in range(route.size() - 1, -1, -1):
				if _standing_on(at, route[i]):
					on = i
					break

		reached = maxi(reached, on)

		var target := route[mini(on + 1, route.size() - 1)]
		var aim := target.get_center()
		var heading := Vector3(aim.x - at.x, 0.0, aim.z - at.z)

		# Wish along the ERROR, not along the heading: the velocity it wants minus the
		# one it has. On the ground that turns a run 45 degrees in a few ticks instead
		# of carrying the last jump's direction into this one — which is how the first
		# version of this fell off platform 4 every time. In the air it is the only
		# steer there is: a wish along the velocity adds nothing once the speed is past
		# `max_air_wish_speed`, and a wish across it is what air control is for.
		var velocity := player.controller.state.velocity
		var flat := Vector3(velocity.x, 0.0, velocity.z)
		var want := heading.normalized() * PgLobby.MOVE_SPEED
		var wish := want - flat

		if wish.length() < 0.2:
			wish = heading

		var command := DotFpsCommand.new()
		command.move = Vector2(0.0, 1.0)
		command.yaw = rad_to_deg(atan2(-wish.x, -wish.z))

		# Jump on the last grounded tick before the edge, judged along where the bot is
		# actually going rather than where it is facing — OR once the next box is
		# within a body's reach, whichever comes first.
		#
		# The second half is the tower's first jump. The pad's corner is 0.2 m from the
		# first platform's and that platform's UNDERSIDE is 0.2 m above the pad, so a
		# jump taken at the lip puts the body into the platform's side face on the way
		# up and kills every bit of horizontal speed: the first version of this bot
		# bonked on it, dropped off the corner, and was respawned. A player jumps a
		# ledge like that from a stride back, and so does this.
		if grounded and on < route.size() - 1:
			var going := flat if flat.length() > 0.5 else heading
			var ahead := at + going.normalized() * look_ahead
			var close := PgLobby.gap_between(AABB(at, Vector3.ZERO), target) < 1.0
			if close or not _over(ahead, route[on]):
				command.set_button(DotFpsCommand.BUTTON_JUMP, true)

		player.controller.apply_command(command)
		await get_tree().physics_frame

		if finished[0]:
			# The finish zone reaches a metre under the pad, so a run can end in the
			# air over it before the bot has ever stood there.
			reached = route.size() - 1
			break

	player.timer.run_started.disconnect(on_start)
	player.timer.stage_reached.disconnect(on_stage)
	player.timer.run_finished.disconnect(on_finish)
	playground.timers.effect_requested.disconnect(on_effect)

	# And stop driving. A bot keeps the last command it was given — this file has been
	# bitten by that once already — so a route drive leaves it standing still.
	player.controller.apply_command(DotFpsCommand.new())

	return {
		"started": started[0],
		"finished": finished[0],
		"splits": splits,
		"reached": reached,
		"ticks": ticks,
		"respawns": respawns[0],
	}


## Whether a point is over a box seen from above.
static func _over(at: Vector3, box: AABB) -> bool:
	return (
		at.x >= box.position.x and at.x <= box.end.x
		and at.z >= box.position.z and at.z <= box.end.z
	)


## Whether a grounded player at [param at] is standing on [param box]: over it, with a
## margin for the body's radius past the edge, and at its top surface.
static func _standing_on(at: Vector3, box: AABB) -> bool:
	var margin := 0.4
	return (
		at.x >= box.position.x - margin and at.x <= box.end.x + margin
		and at.z >= box.position.z - margin and at.z <= box.end.z + margin
		and absf(at.y - box.end.y) < 0.35
	)


## The chaser goes through dot-npc's perception, not "the nearest player this tick".
##
## [b]Every check here fails on the version this replaced.[/b] The old chaser called
## `nearest_player()` on every one of the 128 ticks a second this game runs at, and both
## of the failures below are what that produces: two players a metre apart make it turn
## back and forth for ever, and one who steps out of range makes it forget mid-stride.
##
## Driven by hand rather than by letting the simulation run, because the thing being
## tested is the decision and not the walking — and a suite that moved real players
## around would be measuring the movement code.
func _test_a_chaser_commits(playground: Playground) -> void:
	var at := Vector3(0.0, 2.0, 0.0)
	var spawned := playground.props.spawn(&"npc_chaser", &"bot", at)

	if spawned == null:
		_check(false, "a chaser spawns for the commitment check")
		return

	var chaser := spawned.node as PlaygroundEntity

	_check(chaser.npc != null, "an entity has a dot-npc row")
	_check(
		chaser.npc.def.sight_range == 40.0,
		"whose perception comes from the catalogue rather than from the script",
		"%.0f m" % chaser.npc.def.sight_range
	)

	# Two candidates a fraction of a metre apart, swapping which is marginally nearer
	# every tick. This is the shape the old chaser flickered on.
	var near := DotNpcSenses.Candidate.new(&"one", Vector3(0, 2, -10), &"player")
	var also := DotNpcSenses.Candidate.new(&"two", Vector3(0, 2, -10.4), &"player")

	playground.npc_candidates = [near, also]

	var first := playground.npc_senses.update_target(
		chaser.npc, playground.npc_candidates, 0.0, 8
	)
	var switches := 0
	var last := first

	for tick in 40:
		near.position = Vector3(0, 2, -10.0 - (0.5 if tick % 2 == 0 else 0.0))
		also.position = Vector3(0, 2, -10.0 - (0.0 if tick % 2 == 0 else 0.5))

		var now := playground.npc_senses.update_target(
			chaser.npc, playground.npc_candidates, float(tick) * 0.1, 8
		)

		if now != last:
			switches += 1

		last = now

	_check(first != &"", "a chaser commits to somebody")
	_check(
		switches == 0,
		"and does not flicker between two players standing together",
		"%d switches in 40 ticks; the old chaser switched on most of them" % switches
	)

	# The target walks out of sight. The chaser must keep going for the grace period
	# rather than turning away mid-stride.
	playground.npc_candidates = []

	_check(
		playground.npc_senses.update_target(chaser.npc, [], 5.0, 8) != &"",
		"and keeps chasing one that stepped out of sight",
		"a doorway would otherwise be a perfect escape"
	)
	_check(
		playground.npc_senses.update_target(chaser.npc, [], 20.0, 8) == &"",
		"and gives up once the grace has expired"
	)

	# A target that disconnects. The grace would otherwise walk the NPC to an empty
	# corner for two and a half seconds, steering at a position nobody is at.
	playground.npc_candidates = [
		DotNpcSenses.Candidate.new(&"ghost", Vector3(0, 2, -6), &"player")
	]
	playground.npc_senses.update_target(chaser.npc, playground.npc_candidates, 21.0, 8)

	_check(chaser.npc.target_id == &"ghost", "a chaser can commit to anybody it sees")
	_check(
		chaser.target() == null and chaser.npc.target_id == &"",
		"and drops one that is not a player in this game any more",
		"or it walks to an empty corner for the whole grace period"
	)

	playground.props.remove(spawned.instance_id)
	playground.npc_candidates = []

	_test_a_hunter_decides(playground)


## The same NPC with a **decision** instead of an `if`: dot-npc-ai's state machine and
## the arena shooters' characteristics table.
##
## [b]`npc_chaser` is still in the catalogue and is still correct.[/b] What this one adds
## is a reaction time, a character per NPC, and a machine whose transitions are the design
## — and keeping both is the only honest way to say what the addon actually bought.
func _test_a_hunter_decides(playground: Playground) -> void:
	var spawned := playground.props.spawn(&"npc_hunter", &"bot", Vector3(0.0, 2.0, 0.0))

	if spawned == null:
		_check(false, "a hunter spawns")
		return

	var hunter := spawned.node as PlaygroundEntity

	_check(hunter.npc != null, "a hunter has a dot-npc row too")
	_check(
		hunter.get("machine") != null,
		"and a state machine rather than a hand-written if"
	)
	_check(
		hunter.get("character") != null,
		"and a character, which is what a difficulty setting is instead of"
	)

	var character: DotNpcAiCharacter = hunter.get("character")

	# [b]Seeded from the instance, and this is the check that matters.[/b] A preset is one
	# resource, and twenty NPCs sharing it share a seed — so every one of them reacts at
	# the same moment, which reads as a firing squad rather than as a fight.
	var second := playground.props.spawn(&"npc_hunter", &"bot", Vector3(4.0, 2.0, 0.0))

	if second != null:
		var other: DotNpcAiCharacter = (second.node as PlaygroundEntity).get("character")
		_check(
			other != null and other.seed_value != character.seed_value,
			"two hunters do not share a seed",
			"%d against %d" % [
				other.seed_value if other != null else -1, character.seed_value
			]
		)
		playground.props.remove(second.instance_id)

	# It starts patrolling, not chasing. A machine whose initial state was wrong would be
	# an NPC that sprinted at somebody it had not seen.
	var machine: DotNpcAiMachine = hunter.get("machine")
	_check(
		machine.current() == &"patrol",
		"a hunter starts on patrol (%s)" % String(machine.current())
	)

	# Somebody walks into view. [b]It must NOT go straight to chasing[/b] — the reaction
	# time is spent in ALERT, and an NPC that skipped it is one no player can surprise.
	#
	# [b]A REAL player, and that is not incidental.[/b] `PlaygroundEntity.target` resolves
	# a candidate id back through `game.players` and clears the target when it finds
	# nothing — deliberately, because a disconnected player has no position and steering at
	# their last one walks the NPC to an empty corner for the whole grace period. A test
	# with a candidate and no player is therefore a test of that clearing, not of this.
	var seen := playground.add_player(&"seen", "Seen")
	seen.teleport(Vector3(0.0, 2.0, -8.0))

	playground.npc_candidates = [
		DotNpcSenses.Candidate.new(&"seen", Vector3(0, 2, -8), &"player")
	]
	playground.npc_senses.update_target(
		hunter.npc, playground.npc_candidates, 0.0, 8
	)
	hunter.entity_tick(1.0 / 128.0)

	_check(
		machine.current() == &"alert",
		"and turns to look before it commits (%s)" % String(machine.current()),
		"reaction time is what makes it an opponent rather than a target"
	)

	# And then it does commit, once the reaction time has passed.
	for _step in range(int(128.0 * 1.5)):
		hunter.entity_tick(1.0 / 128.0)

	_check(
		machine.current() == &"chase",
		"and chases once its reaction time has passed (%s)" % String(machine.current())
	)

	# The target leaves. It searches where they were rather than stopping dead — an NPC
	# you escape by stepping behind a crate is one nobody has to run from.
	playground.npc_candidates = []
	hunter.npc.target_id = &""

	hunter.entity_tick(1.0 / 128.0)
	_check(
		machine.current() == &"lost",
		"and goes looking when it loses them (%s)" % String(machine.current())
	)

	playground.props.remove(spawned.instance_id)
	playground.npc_candidates = []
	playground.remove_player(&"seen")


## An entity is a prop with a script, and the script is loaded by path.
##
## [b]This is the whole "spawning things that carry code" mechanism.[/b] The scene is a
## bare `RigidBody3D`; the script comes from `meta`, is loaded by PATH rather than by
## class, and is attached by `Playground._configure_entity`. The path matters: a
## mounted dot-cloud pack's `class_name` globals are not registered in the host, so an
## entity named by class could only ever ship inside the build.
func _test_entities_run_their_scripts() -> void:
	_section("entities that run their own scripts")

	# On the sandbox, deliberately. The previous tests leave the game on whichever map
	# they finished with, and an NPC walking about on the bhop map's blocks-with-gaps
	# falls off one — so "does the chaser close the distance" would be measuring the
	# terrain rather than the script. Flat ground is the only surface on which the
	# answer is about the entity.
	var loaded: DotResult = await playground.change_map(&"pg_lobby")
	_check(loaded.ok, "the sandbox loads")

	playground.spawn_player(&"bot")

	# Driven with an EMPTY command for a moment, which is not busywork.
	# `DotFpsController.apply_command` sets the pending command and it stays set: the
	# bot arrives here still holding forward and jump from the bhop test several
	# tests ago, so it auto-hops across the sandbox for the whole of this one — and
	# "does the chaser close the distance" then measures a player who is running
	# away. It also gives them the third of a second it takes to fall the metre from
	# the spawn onto the floor.
	await _drive(&"bot", DotFpsCommand.new(), 60)

	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	var at := Vector3(0.0, 1.2, 0.0)
	var npc := playground.props.spawn(&"npc_wanderer", &"bot", at)

	_check(npc != null, "an entity spawns")

	if npc == null:
		return

	var body := npc.node as PlaygroundEntity

	_check(body != null, "and its body is a PlaygroundEntity, not a plain prop")
	_check(
		body != null and body.get_script() != null
		and body.get_script().resource_path
			== PlaygroundSpawnables.script_of(npc.def),
		"running exactly the script its definition names",
		body.get_script().resource_path if body != null else "none"
	)
	_check(
		playground.entities.has(body),
		"and it is on the list the simulation ticks"
	)

	# `_ready` has already run by the time the script is attached — the spawner adds
	# the body to the world before it emits — so `bind` is what an entity gets
	# instead, and an entity whose world never arrived would sit there being a crate.
	_check(body != null and body.game == playground, "it knows its world")
	_check(body != null and body.instance == npc, "and its own row in the spawner")

	# It moves. Everything above is satisfied by an entity that does nothing at all.
	var before := body.global_position
	var ticks := 0
	var moved := 0.0

	while ticks < 240:
		await get_tree().physics_frame
		ticks += 1
		moved = maxf(moved, before.distance_to(body.global_position))

	_check(moved > 1.0, "and it walks about", "%.2f m" % moved)
	_check(body.age > 0.0, "counting simulated time, not wall time",
		"%.2f s" % body.age)

	# A held entity is furniture. Without that, the NPC fights the physics gun's
	# spring — the gun writes a velocity toward the goal and the NPC writes one
	# toward wherever it was walking — and the prop shudders between them.
	npc.held_by = &"bot"

	var held_at := body.global_position
	body.linear_velocity = Vector3.ZERO

	for _i in range(30):
		await get_tree().physics_frame

	_check(
		held_at.distance_to(body.global_position) < 0.6,
		"a held entity stops driving itself",
		"%.2f m" % held_at.distance_to(body.global_position)
	)

	npc.held_by = &""

	# A chaser goes toward somebody. The bot is at the origin-ish; put the chaser
	# out and check the distance closes, which is the one thing that distinguishes
	# this script from the wanderer.
	var player: PlaygroundPlayer = playground.players[&"bot"]
	var chaser := playground.props.spawn(
		&"npc_chaser", &"bot", player.global_position + Vector3(14.0, 1.2, 0.0)
	)

	_check(chaser != null, "a chaser spawns")

	if chaser != null:
		var opening := chaser.position().distance_to(
			player.global_position
		)

		for _i in range(300):
			await get_tree().physics_frame

		var closing := chaser.position().distance_to(
			player.global_position
		)

		_check(
			closing < opening - 3.0,
			"and walks toward the player",
			"%.1f m -> %.1f m" % [opening, closing]
		)

	_test_a_chaser_commits(playground)

	# A definition whose script is missing does not leave a body in the world. One
	# that did would sit there being a crate, which is indistinguishable from an NPC
	# with nothing to do — and "the NPC does not move" sends the next person to the
	# movement code.
	var broken := DotPropDef.make(&"npc_broken", PlaygroundSpawnables.SCENE_ENTITY)
	broken.meta = {"kind": "entity", "script": "res://game/entities/nope.gd"}
	playground.props.catalogue.add(broken)

	var before_count := playground.props.world_count()
	var refused := playground.props.spawn(&"npc_broken", &"bot", at)

	await get_tree().process_frame

	_check(
		playground.props.world_count() == before_count,
		"an entity whose script is missing leaves nothing in the world",
		"%d -> %d" % [before_count, playground.props.world_count()]
	)
	_check(
		refused == null or not refused.is_alive(),
		"and its row is dead rather than counted against a budget"
	)

	# One that points at a real script which is not an entity is the same failure by
	# a different route, and it is the one a copy-paste actually produces.
	var wrong := DotPropDef.make(&"npc_wrong", PlaygroundSpawnables.SCENE_ENTITY)
	wrong.meta = {"kind": "entity", "script": "res://game/playground_config.gd"}
	playground.props.catalogue.add(wrong)

	before_count = playground.props.world_count()
	playground.props.spawn(&"npc_wrong", &"bot", at)

	await get_tree().process_frame

	_check(
		playground.props.world_count() == before_count,
		"and so does one whose script is not an entity"
	)

	playground.props.catalogue.remove(&"npc_broken")
	playground.props.catalogue.remove(&"npc_wrong")
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	await get_tree().process_frame

	_check(playground.entities.is_empty(), "clearing the world empties the tick list")
	_done()


## Weapons: a script loaded by path, held rather than spawned.
func _test_weapons() -> void:
	_section("weapons")

	var defs := PlaygroundWeapons.built_in()

	_check(defs.size() >= 3, "the build ships an arsenal", "%d" % defs.size())
	_check(
		playground.weapons.size() == defs.size(),
		"and the game offers it"
	)

	for def in defs:
		_check(def.validate().ok, "'%s' is a usable definition" % def.id)

	var launcher := PlaygroundWeapons.make(
		PlaygroundWeapons.find(defs, &"launcher")
	)

	_check(launcher != null, "a weapon is built from its definition")
	_check(
		launcher != null and launcher.get_script().resource_path
			== PlaygroundWeapons.find(defs, &"launcher").script_path,
		"running exactly the script it names"
	)

	# The two ways a catalogue entry is wrong, and neither may hand back a working-
	# looking weapon: a base `PlaygroundWeapon` whose buttons do nothing is
	# indistinguishable from a weapon that is fine and pointed at nothing.
	var missing := PlaygroundWeaponDef.make(&"x", "X", "res://game/weapons/nope.gd")
	_check(
		PlaygroundWeapons.make(missing) == null,
		"a weapon whose script is missing is refused"
	)

	var not_a_weapon := PlaygroundWeaponDef.make(
		&"y", "Y", "res://game/playground_config.gd"
	)
	_check(
		PlaygroundWeapons.make(not_a_weapon) == null,
		"and so is one whose script is not a weapon"
	)

	# The launcher fires whatever the menu armed, which is what saves it having a
	# second list of ammunition and a second way to choose from it.
	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	launcher.equip(playground, PlaygroundWeapons.find(defs, &"launcher"))
	launcher.wielder = &"bot"
	launcher.armed = &"beach_ball"

	var fired := launcher.primary(null, Vector3(0.0, 6.0, 0.0), Vector3.FORWARD)

	_check(fired.ok, "the launcher fires")

	if fired.ok:
		var shot := fired.value as DotPropInstance

		_check(shot.def.id == &"beach_ball", "the prop the menu armed")
		_check(
			shot.body().linear_velocity.length() > 10.0,
			"at a muzzle velocity",
			"%.1f m/s" % shot.body().linear_velocity.length()
		)

		# A muzzle velocity, not an impulse. An impulse is divided by the mass, which
		# is right for a punt and exactly wrong here: a launcher whose boulder leaves
		# at a fortieth of the speed of its ball is one nobody can aim.
		launcher.armed = &"boulder"

		var heavy := launcher.primary(null, Vector3(0.0, 6.0, 0.0), Vector3.FORWARD)

		_check(
			heavy.ok and is_equal_approx(
				(heavy.value as DotPropInstance).body().linear_velocity.length(),
				shot.body().linear_velocity.length()
			),
			"and a 900 kg prop leaves as fast as a 2 kg one"
		)

	# Armed with something the catalogue no longer has — a map change can do that —
	# it falls back rather than being refused with "no such prop", which reads as the
	# weapon being broken rather than as the ammunition being gone.
	launcher.armed = &"nothing_like_this"

	var fallback := launcher.primary(null, Vector3(0.0, 6.0, 0.0), Vector3.FORWARD)

	_check(fallback.ok, "an armed prop that no longer exists falls back")

	# The impulse gun shoves what is near it, and leaves frozen props alone: freezing
	# is how a builder says "this is finished", and a blast that undid it would make
	# the two tools fight.
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	var loose := playground.props.spawn(&"crate", &"bot", Vector3(2.0, 1.0, 0.0))
	var stuck := playground.props.spawn(&"crate", &"bot", Vector3(-2.0, 1.0, 0.0))

	DotPhysGun.set_frozen(stuck, true)

	var impulse := PlaygroundWeapons.make(PlaygroundWeapons.find(defs, &"impulse"))
	impulse.equip(playground, PlaygroundWeapons.find(defs, &"impulse"))
	impulse.wielder = &"bot"

	loose.body().linear_velocity = Vector3.ZERO

	var blast := impulse.primary(null, Vector3.ZERO, Vector3.FORWARD)

	# Two steps, not one. `apply_central_impulse` is not readable in
	# `linear_velocity` until the step that consumes it has run — dot-props' own
	# suite found the same thing and says so — and awaiting a physics frame lands
	# before that step rather than after it.
	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(blast.ok and int(blast.value) >= 1, "the impulse gun moves something")
	_check(
		loose.body().linear_velocity.length() > 1.0,
		"a loose prop is shoved",
		"%.1f m/s" % loose.body().linear_velocity.length()
	)
	_check(
		stuck.body().linear_velocity.length() < 0.5,
		"and a frozen one is left alone",
		"%.1f m/s" % stuck.body().linear_velocity.length()
	)

	# The remover's right click clears what you own, and goes through the spawner so
	# the budget it frees is real.
	var remover := PlaygroundWeapons.make(PlaygroundWeapons.find(defs, &"remover"))
	remover.equip(playground, PlaygroundWeapons.find(defs, &"remover"))
	remover.wielder = &"bot"

	var cleared := remover.secondary(null, Vector3.ZERO, Vector3.FORWARD)

	_check(cleared.ok and int(cleared.value) >= 2, "the remover clears your props")
	_check(playground.props.player_count(&"bot") == 0, "and the budget goes with them")

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)
	_done()


## The spawn menu, driven the way a player drives it.
##
## [b]dot-ui's suite cannot reach this and neither can dot-props'.[/b] A menu built
## out of a catalogue is exactly the seam this project exists to run: the screen stack
## is one addon, the catalogue is another, and the code joining them is here. It is
## also a `Control` built entirely in code, which is the shape that produced the
## family's `set_anchors_preset` bug — so the sizes are checked, not just the
## contents.
func _test_spawn_menu() -> void:
	_section("the spawn menu")

	var menu := PlaygroundSpawnMenu.new()
	menu.catalogue = playground.props.catalogue
	menu.weapons = playground.weapons
	add_child(menu)

	# Registered on a real stack rather than shown directly: pushing is what calls
	# `_on_push`, and `_on_push` is what fills the grid.
	var stack := DotScreenStack.new()
	add_child(stack)

	var ready := stack.setup()
	_check(ready.ok, "the screen stack sets up")

	var registered := stack.register(menu)
	_check(registered.ok, "and the menu registers on it")

	var pushed := stack.push(menu.screen_id())
	_check(pushed.ok, "and opens")
	_check(stack.any_open(), "and the stack knows a menu is up")

	await get_tree().process_frame

	_check(
		menu.size.x > 100.0 and menu.size.y > 100.0,
		"the menu has a size, which a Control built in code does not get for free",
		"%.0f x %.0f" % [menu.size.x, menu.size.y]
	)

	# [b]The server browser, on the same stack and measured the same way.[/b] It is the
	# second screen this game has built in code, and the failure it can have is the one
	# dot-ui had five of: `set_anchors_preset` describes how a rectangle FOLLOWS its
	# parent and changes nothing until something resizes it, so a Control keeps the zero
	# size it was created with — and every child then lays out inside nothing while being,
	# by every property, correctly configured. Only a size says so.
	var servers := PlaygroundBrowser.new()
	add_child(servers)

	var browser_registered := stack.register(servers)
	_check(browser_registered.ok, "the server browser registers too")

	var browser_open := stack.push(servers.screen_id())
	_check(browser_open.ok, "and opens")

	await get_tree().process_frame

	_check(
		servers.size.x > 100.0 and servers.size.y > 100.0,
		"and has a size rather than being an invisible 0 x 0",
		"%.0f x %.0f" % [servers.size.x, servers.size.y]
	)
	_check(
		servers.browser != null and servers.browser.count() > 0,
		"with something on the list, so a first run is not an empty box",
		"%d" % (servers.browser.count() if servers.browser != null else -1)
	)

	# [b]Filtering is local and always will be.[/b] A server that decided which of its own
	# properties to report is a server that reports whatever gets it listed — so the
	# filter lives on the model, and a screen that filtered its own rows would be a second
	# filter that disagrees with the one favourites are pinned by.
	_check(
		servers.browser.filter != null,
		"and a filter the client owns rather than one the server answers"
	)

	stack.pop()
	servers.queue_free()

	# --- Props tab -----------------------------------------------------------

	var props_shown := menu.shown()
	var prop_count := 0

	for def in playground.props.catalogue.props:
		if PlaygroundSpawnables.kind_of(def) == PlaygroundSpawnables.Kind.PROP:
			prop_count += 1

	_check(
		props_shown.size() == prop_count,
		"the props tab shows every prop and no entities",
		"%d of %d" % [props_shown.size(), prop_count]
	)
	_check(
		not props_shown.has(&"npc_wanderer"),
		"and an entity is not among them"
	)
	_check(menu.card_for(&"crate") != null, "each one has a card that names it")

	# Icons. Nothing here ships art, so every card is drawn from the definition —
	# and a card with no icon at all is the failure that looks like a working menu
	# right up until somebody opens it.
	var crate_card := menu.card_for(&"crate")
	var ball_card := menu.card_for(&"ball")

	_check(
		crate_card != null and crate_card.icon != null
		and crate_card.icon.get_width() == PlaygroundIcons.SIZE,
		"with an icon on it"
	)
	_check(
		crate_card != null and ball_card != null
		and crate_card.icon != ball_card.icon,
		"and a box and a sphere do not get the same one"
	)

	# The cache is keyed on the drawing, not on the prop, so two props that draw the
	# same share a texture. That is what stops a four-hundred-prop catalogue building
	# four hundred images every time somebody presses Q.
	_check(
		PlaygroundIcons.generated(PlaygroundIcons.Glyph.BOX, 1.0, Color.RED)
		== PlaygroundIcons.generated(PlaygroundIcons.Glyph.BOX, 1.0, Color.RED),
		"an icon drawn twice is one texture"
	)

	# Clicking spawns. The menu never spawns anything itself — it emits, and the
	# client asks the server — which is what lets this file work unchanged when the
	# spawn becomes a dot-net message.
	var chosen: Array[StringName] = []
	menu.prop_chosen.connect(
		func(id: StringName) -> void: chosen.append(id)
	)

	menu.card_for(&"barrel").pressed.emit()

	_check(chosen.size() == 1 and chosen[0] == &"barrel",
		"clicking a prop asks for that prop")
	_check(menu.selected == &"barrel", "and arms it for the spawn key")

	# Search reaches across every category on the tab, because a player who types
	# "barrel" wants the barrel and not "no such prop, you are on the Toys tab".
	menu._on_search_changed("boulder")
	await get_tree().process_frame

	var found := menu.shown()
	_check(found.has(&"boulder"), "searching finds a prop by name")
	_check(found.size() < props_shown.size(), "and narrows the grid")

	menu._on_search_changed("zzzz")
	await get_tree().process_frame

	_check(
		menu.shown().is_empty(),
		"a search that matches nothing shows nothing"
	)

	menu._on_search_changed("")
	await get_tree().process_frame

	# --- Entities tab --------------------------------------------------------

	menu.show_tab(PlaygroundSpawnMenu.Tab.ENTITIES)
	await get_tree().process_frame

	var entities_shown := menu.shown()

	_check(not entities_shown.is_empty(), "the entities tab has entities on it")
	_check(
		entities_shown.has(&"npc_wanderer") and not entities_shown.has(&"crate"),
		"and no props"
	)

	# --- Weapons tab ---------------------------------------------------------

	menu.show_tab(PlaygroundSpawnMenu.Tab.WEAPONS)
	await get_tree().process_frame

	var weapons_shown := menu.shown()

	_check(
		weapons_shown.size() == playground.weapons.size(),
		"the weapons tab shows every weapon",
		"%d of %d" % [weapons_shown.size(), playground.weapons.size()]
	)

	var equipped: Array[StringName] = []
	menu.weapon_chosen.connect(
		func(id: StringName) -> void: equipped.append(id)
	)

	menu.card_for(&"launcher").pressed.emit()

	_check(
		equipped.size() == 1 and equipped[0] == &"launcher",
		"and clicking one asks to equip it rather than to spawn it"
	)

	# Switching tabs clears the filter. Carrying "containers" onto the weapons tab
	# would show nothing and read as the tab being broken.
	menu.show_tab(PlaygroundSpawnMenu.Tab.PROPS)
	await get_tree().process_frame

	_check(
		menu.shown().size() == prop_count,
		"and going back to props shows all of them again"
	)

	_check(
		PlaygroundSpawnMenu.name_of_tool(&"phys") == "physics gun"
		and PlaygroundSpawnMenu.name_of_tool(&"") == "nothing",
		"a tool id has a name, and an empty one is not silently a gravity gun"
	)

	var popped := stack.pop(menu.screen_id())
	_check(popped.ok and not stack.any_open(), "the menu closes")

	stack.queue_free()
	_done()


# --- The sandbox, and the course in the corner of it ------------------------

## `pg_lobby` is a sandbox on the main track and a jump course on bonus 1.
##
## [b]Both halves are the test.[/b] The main track still has no start and no end, so
## everything the game does works with no timer running — which is what `pg_lobby`
## has always been for. The bonus track is a real course with a start, a finish, a
## split and a reset volume, which is what proves the timer is not a surf-and-bhop
## thing: nothing about a jump course is a movement genre.
func _test_the_sandbox_and_its_course() -> void:
	_section("the sandbox and its course")

	var changed: DotResult = await playground.change_map(&"pg_lobby")
	_check(changed.ok, "the sandbox loads")

	var player: PlaygroundPlayer = playground.players[&"bot"]
	var zones := playground.timers.zones

	_check(zones != null and not zones.zones.is_empty(), "and it has zones")

	if zones == null:
		return

	_check(
		zones.of_kind(DotTimerZone.Kind.START, DotTimerTrack.MAIN).is_empty()
		and zones.of_kind(DotTimerZone.Kind.END, DotTimerTrack.MAIN).is_empty(),
		"the main track has no start and no end: it is somewhere to build"
	)
	_check(
		zones.of_kind(
			DotTimerZone.Kind.START, DotTimerTrack.BONUS_FIRST
		).size() == 1,
		"and the course on bonus 1 has one start"
	)
	_check(
		zones.of_kind(
			DotTimerZone.Kind.END, DotTimerTrack.BONUS_FIRST
		).size() == 1,
		"and one finish"
	)
	_check(zones.problems().is_empty(), "with nothing wrong with the set",
		"; ".join(zones.problems()))

	var tracks := playground.tracks_on_this_map()
	_check(
		tracks == [
			DotTimerTrack.MAIN,
			DotTimerTrack.BONUS_FIRST,
			DotTimerTrack.BONUS_FIRST + 1,
			PgLobby.CIRCUIT_TRACK,
		],
		"the game can see all four tracks without being told about them",
		str(tracks)
	)

	_test_the_tower(playground, zones)
	_test_the_circuit(playground, zones)

	# The main track, exactly as before: walking about starts nothing.
	player.timer.set_track(DotTimerTrack.MAIN)
	playground.spawn_player(&"bot")

	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)

	await _drive(&"bot", forward, 200)

	_check(
		not player.timer.run.is_active(),
		"no run starts on the track with no start zone"
	)
	_check(
		player.controller.state.is_grounded(),
		"and the player walks on it normally"
	)

	playground.props.limits.spawn_interval = 0.0
	var crate := playground.props.spawn(
		&"crate", &"bot", player.global_position + Vector3.UP * 3.0
	)
	_check(crate != null, "and can still spawn props")

	# The course. Switching track moves the player to its spawn, which is the only
	# way onto it — the start pad is six metres up on a pillar.
	_check(player.timer.set_track(DotTimerTrack.BONUS_FIRST), "the track switches")
	playground.spawn_player(&"bot")

	var spawn := PgLobby.build_zones().first_of_kind(
		DotTimerZone.Kind.SPAWN, DotTimerTrack.BONUS_FIRST
	)

	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the player on the course's start pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	# Walking off the pad starts the run, and falling off the course puts the player
	# back on the pad. Driven as one stretch and watched through the signals rather
	# than sampled between two short drives: a bot walking off a platform is at the
	# mercy of where in a tick it left the edge, and a test that checked "has it
	# started yet" after a fixed number of ticks would be timing-sensitive for no
	# reason.
	var started: Array[bool] = [false]
	var respawns: Array[int] = []

	# An Array, not a counter: a GDScript lambda captures locals by value, so an int
	# incremented in a handler reads zero outside it and the test reports a failure
	# for a signal that fired perfectly.
	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			respawns.append(zone.id)

	player.timer.run_started.connect(on_start)
	playground.timers.effect_requested.connect(on_effect)

	# [b]Driven until the respawn happens rather than for a fixed 400 ticks, and the
	# difference is the whole reason this comment is here.[/b] A bot holding forward
	# off a start pad falls, is put back on the pad, walks off it again and starts a
	# SECOND run — so "is a run active at tick 400" is a question about how many times
	# that cycle fitted into 400 ticks, which is a function of where the first gap is.
	# Widening or narrowing one gap on a course fifty metres away changed the answer,
	# and the check failed while reporting nothing about what it was written to prove.
	#
	# Stopping at the respawn and then standing still is deterministic: a player who is
	# not walking cannot leave the pad, so a run that is still active after this is a
	# run the respawn did not abandon, which is the thing being asked.
	for _tick in range(400):
		player.controller.apply_command(forward.duplicate_command())
		await get_tree().physics_frame

		if not respawns.is_empty():
			break

	var still := DotFpsCommand.new()
	for _tick in range(8):
		player.controller.apply_command(still.duplicate_command())
		await get_tree().physics_frame

	player.timer.run_started.disconnect(on_start)
	playground.timers.effect_requested.disconnect(on_effect)

	_check(started[0], "walking off the pad starts a run on the bonus track")

	# This is the check that would have failed for as long as this family has
	# existed. `DotTimer.effect_requested` was declared, forwarded by the manager and
	# connected by both games — and emitted by NOTHING, so every RESPAWN zone in the
	# family did exactly nothing and a player who fell off a surf map fell for ever.
	# Fixed in dot-timer; this is the join it was missing from.
	_check(
		not respawns.is_empty(),
		"falling off the course asks the game to put the player back"
	)

	# And the game actually did it: six metres up, on the course, rather than on the
	# sandbox floor the course is built over.
	_check(
		player.global_position.y > 5.0,
		"which puts them back on the course rather than under it",
		"y = %.2f" % player.global_position.y
	)
	_check(
		not player.timer.run.is_active(),
		"and the run they were on is abandoned rather than left running"
	)

	# The same volume, on the main track, must do nothing: somebody building under
	# the course would otherwise be teleported onto it every few seconds.
	player.timer.set_track(DotTimerTrack.MAIN)

	var under := Vector3(PgLobby.COURSE_X, 1.0, PgLobby.COURSE_START_Z)
	player.teleport(under, 0.0)

	await _drive(&"bot", still, 60)

	_check(
		player.global_position.distance_to(under) < 3.0,
		"a sandbox player standing under the course is left alone",
		"%.2f m away" % player.global_position.distance_to(under)
	)

	await _walk_the_tower(player)
	await _drive_the_circuit()

	playground.remove_player(&"bot")
	_check(playground.players.is_empty(), "a player can leave cleanly")
	_check(
		playground.props.world_count() == 0,
		"and their props go with them"
	)
	_done()


## A bot climbs bonus 2 from its pad to the cap on top of the pillar.
##
## [b]Until 2026-09-23 this was "only the first jump, and that is the honest limit of a
## bot here", and the limit was the bot's.[/b] The written reason was that a spiral is
## finished by air-strafing round a corner. Measured, it is not: every gap on the tower
## is 2.04 m of air against a 4.02 m climbing reach, so nobody has to carry any speed
## round anything — they have to FACE the next platform before jumping at it, which is
## a thing a scripted bot can do exactly and which no bot in this family had ever been
## written to do. Every one held a single yaw for its whole run. See [method _drive_route].
##
## What this still proves before it drives, and both are invisible to every count: the
## spawn faces the course, and it is outside the pillar.
func _walk_the_tower(player: PlaygroundPlayer) -> void:
	var track := DotTimerTrack.BONUS_FIRST + 1

	_check(player.timer.set_track(track), "the tower's track switches")
	playground.spawn_player(&"bot")

	var spawn := PgLobby.build_zones().first_of_kind(DotTimerZone.Kind.SPAWN, track)

	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the player on the tower's pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	_check(
		Vector3(
			player.global_position.x - PgLobby.TOWER_X,
			0.0,
			player.global_position.z - PgLobby.TOWER_Z
		).length() > PgLobby.TOWER_PILLAR * 0.5,
		"outside the pillar rather than inside it",
		"a spawn inside a pillar is a player who cannot move, and every count passes"
	)

	var first := PgLobby.tower_platform_centre(0)
	var facing := player.aim_direction()
	var toward := Vector3(
		first.x - player.global_position.x, 0.0, first.z - player.global_position.z
	).normalized()

	_check(
		facing.dot(toward) > 0.9,
		"facing the first platform rather than the pillar",
		"dot %.2f; a spiral has no obvious forward and finding it costs a second"
			% facing.dot(toward)
	)

	var route := PgLobby.tower_route()

	# 16 platforms and a cap at roughly a second a jump is ~2,200 ticks; 4,000 leaves
	# room for a fall onto a lower turn and the climb back, without being so long that a
	# stuck bot takes a minute to say so.
	var drive: Dictionary = await _drive_route(player, route, 4000)

	print("    the tower: platform %d of %d, splits %s, finish %s, %d ticks, %d respawns" % [
		int(drive["reached"]), route.size() - 1, str(drive["splits"]),
		str(drive["finished"]), int(drive["ticks"]), int(drive["respawns"]),
	])

	_check(drive["started"], "leaving the tower's pad starts a run on bonus 2")
	_check(
		int(drive["reached"]) >= 1,
		"and a bot running off the pad reaches the first platform",
		"never got onto one; the spawn faces it and the gap is 0.2 m"
	)
	_check(
		drive["splits"] == [1, 2],
		"it climbs through both height bands, in order",
		str(drive["splits"])
	)
	_check(
		drive["finished"],
		"and reaches the cap on the pillar: bonus 2 run end to end",
		"got to box %d of %d at y %.1f in %d ticks"
			% [int(drive["reached"]), route.size() - 1,
				player.global_position.y, int(drive["ticks"])]
	)
	_check(
		int(drive["respawns"]) == 0,
		"without once being put back on the pad",
		"%d respawns; a drive that finishes on its third attempt is a drive that is lucky"
			% int(drive["respawns"])
	)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)


# --- The narrows -----------------------------------------------------------

## `pg_bhop_intro`'s bonus route, driven start to finish.
##
## [b]This is the first bonus track in this family that anything has ever run.[/b]
## Every other bonus here is checked by switching onto it, looking at the spawn and
## switching back — which is why they went for as long as they did with no respawn
## zone on them at all. A route nothing has completed is a route nobody knows is
## completable.
##
## [b]The driver is the interesting part, and it is not "hold forward and jump".[/b]
## That is what the rest of this suite does and it produces a player travelling at
## **one** metre a second: with `auto_hop` on and jump held, the player leaves the
## ground on the tick it lands, so `accelerate` (7 m/s on the ground) never gets a
## tick to work in, and air acceleration cannot make up the difference because
## `max_air_wish_speed` is 1.0 — that cap is the whole reason air-strafing is a skill
## rather than a button. A real player gains speed by turning into the strafe; a bot
## that holds one direction cannot, and it bleeds back to the cap.
##
## So this bot jumps **at the gaps** instead of continuously, which keeps it on the
## ground long enough to hold 7 m/s and is why the narrows has a constant
## [constant PgBhopIntro.BONUS_GAP]: 3.5 m is 0.5 s of flight at that speed against
## the 0.68 s a 1.15 m jump buys, so the route is clearable without ever gaining any.
## The main run deliberately is not — its last gap is 7 m and only a player who has
## been strafing can cross it, which is what that route is for.
func _test_the_narrows() -> void:
	print("")
	_section("the narrows — pg_bhop_intro's bonus route")

	var loaded: DotResult = await playground.change_map(&"pg_bhop_intro")
	_check(loaded.ok, "the bhop map loads",
		loaded.error.message if not loaded.ok else "")

	var zones := PgBhopIntro.build_zones()

	_check(zones.problems().is_empty(), "its zones are well formed",
		", ".join(zones.problems()))
	_check(
		zones.playable_tracks() == PackedInt32Array(
			[
				DotTimerTrack.MAIN, DotTimerTrack.BONUS_FIRST,
				PgBhopIntro.SWITCHBACK_TRACK,
			]
		),
		"and all three of its routes can be run, the switchback included",
		str(zones.playable_tracks())
	)

	# The splits, on both routes. A map with one start and one finish exercises none
	# of dot-timer's per-stage machinery, which is the reason these were added.
	_check(
		zones.of_kind(DotTimerZone.Kind.STAGE, DotTimerTrack.MAIN).size() == 3,
		"the main run has three splits"
	)

	var track := DotTimerTrack.BONUS_FIRST

	_check(
		zones.of_kind(DotTimerZone.Kind.START, track).size() == 1
			and zones.of_kind(DotTimerZone.Kind.END, track).size() == 1,
		"the narrows has one start and one finish"
	)
	_check(
		zones.of_kind(DotTimerZone.Kind.STAGE, track).size() == 3,
		"and three splits"
	)
	_check(
		zones.route_tracks().has(track) and zones.route_problems().is_empty(),
		"and a spawn and a respawn volume, which no bonus track in this family had until one was run",
		", ".join(zones.route_problems())
	)

	# The course narrows, which is the whole difficulty. Asserted against the map's own
	# arithmetic rather than against numbers copied here: a second description of where
	# a block is and how wide it is, is a second thing that can disagree with the
	# geometry — and on a timer map that is a leaderboard nobody can compare.
	_check(
		is_equal_approx(PgBhopIntro.bonus_width_at(0), PgBhopIntro.BONUS_FIRST_WIDTH)
			and is_equal_approx(
				PgBhopIntro.bonus_width_at(PgBhopIntro.BONUS_BLOCKS - 1),
				PgBhopIntro.BONUS_LAST_WIDTH
			),
		"its blocks run from the full width down to the last one"
	)

	var thin := zones.thin_zones(12.0, playground.tick_rate)
	_check(thin.is_empty(),
		"and no zone is thin enough for a hopping player to pass through",
		"%d thin" % thin.size())

	var player := playground.add_player(&"bot", "Bot")
	_check(player.timer.set_track(track), "the track switches")
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the player on the narrows' start pad, six metres above the main run",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	# Arrays rather than counters: a GDScript lambda captures locals by value, so an
	# int incremented in a handler reads zero outside it and the test reports a
	# failure for a signal that fired perfectly.
	var started: Array[bool] = [false]
	var finished: Array[bool] = [false]
	var splits: Array[int] = []

	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_stage := func(number: int, _split: float) -> void: splits.append(number)
	var on_finish := func(_run: DotTimerRun) -> void: finished[0] = true

	player.timer.run_started.connect(on_start)
	player.timer.stage_reached.connect(on_stage)
	player.timer.run_finished.connect(on_finish)

	var command := DotFpsCommand.new()
	command.move = Vector2(0.0, 1.0)

	var ticks := 0

	# Capped well above the ~1890 ticks the route takes, and broken out of on the
	# finish rather than run to the end: a drive that keeps going past the finish pad
	# walks the bot off the far side of it.
	for i in range(2400):
		command.set_button(
			DotFpsCommand.BUTTON_JUMP,
			_jumping_at(player.global_position.z)
		)
		player.controller.apply_command(command.duplicate_command())
		await get_tree().physics_frame
		ticks = i

		if finished[0]:
			break

	player.timer.run_started.disconnect(on_start)
	player.timer.stage_reached.disconnect(on_stage)
	player.timer.run_finished.disconnect(on_finish)

	_check(started[0], "leaving the start pad starts a run on the narrows")

	var speed := Vector2(
		player.controller.state.velocity.x, player.controller.state.velocity.z
	).length()
	_check(
		speed > 6.0,
		"the bot holds its ground speed the whole way rather than bleeding to the air cap",
		"%.2f m/s" % speed
	)

	_check(
		splits == [1, 2, 3],
		"it crosses all three splits, in order",
		str(splits)
	)

	# The check this whole section exists for.
	_check(
		finished[0],
		"and reaches the finish: a bonus route completed end to end, which nothing "
		+ "in this family had ever done",
		"gave up at tick %d, z = %.1f" % [ticks, player.global_position.z]
	)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)

	playground.remove_player(&"bot")
	_done()


## Whether the bot should be holding jump at [param z] on the narrows.
##
## The gaps are where a jump is needed and nowhere else — see the note on
## [method _test_the_narrows] for why holding it continuously is the thing that does
## not work. Read off the map's own block arithmetic so that moving a block moves the
## jump with it.
static func _jumping_at(z: float) -> bool:
	for i in range(PgBhopIntro.BONUS_BLOCKS):
		var edge: float = (
			PgBhopIntro.bonus_block_near_z(i) - PgBhopIntro.BONUS_BLOCK_LENGTH
		)

		if z <= edge + 0.8 and z > edge - 0.2:
			return true

	return false


## The plunge — `pg_surf_intro`'s bonus route, driven from its pad to its finish.
##
## [b]The reason this route exists is the measurement in [method _test_surf_run].[/b]
## The main run's two ramps are level along their length, so the whole descent comes
## from the stepped floor between them and the ramps never give the player anything;
## a scripted strafer covers 5% of that route and crosses none of its splits. The
## plunge is one face pitched past [code]max_slope_angle[/code] and descending along
## the run, so gravity accelerates the player ALONG it — which is the thing the map
## was supposed to be about and was not.
##
## It is straight, and that is deliberate for the reason
## [method _test_the_narrows] gives about a constant gap: a scripted bot cannot
## air-strafe, so a route that needs turning is a route no suite runs end to end.
## Here the bot holds forward and nothing else. No jump pattern is needed at all —
## on a face nobody can stand on there is no ground to leave.
func _test_the_plunge() -> void:
	print("")
	_section("the plunge — pg_surf_intro's bonus route")

	var loaded: DotResult = await playground.change_map(&"pg_surf_intro")
	_check(loaded.ok, "the surf map loads again",
		loaded.error.message if not loaded.ok else "")

	var zones := PgSurfIntro.build_zones()
	var track := DotTimerTrack.BONUS_FIRST

	_check(zones.problems().is_empty(), "its zones are well formed",
		", ".join(zones.problems()))
	_check(
		zones.playable_tracks() == PackedInt32Array(
			[DotTimerTrack.MAIN, DotTimerTrack.BONUS_FIRST]
		),
		"and the surf map has two routes now rather than one",
		str(zones.playable_tracks())
	)

	# Asked per track rather than of whichever one happened to be current — see
	# `[track-zone-1]`. A zone carries a track, so a set that is complete for track 0
	# and partial for track 1 passes `problems()` while being an unfinishable route.
	# This was four checks walking this track's kinds by name; it is dot-timer's
	# `route_problems()` now, which asks the same of every route.
	_check(
		zones.route_tracks().has(track) and zones.route_problems().is_empty(),
		"the plunge has its own start, finish, spawn and pit",
		", ".join(zones.route_problems())
	)

	_check(
		zones.of_kind(DotTimerZone.Kind.STAGE, track).size()
			== PgSurfIntro.CHUTE_SPLITS.size(),
		"and a split for each fraction the map names"
	)

	# A player on this route is the fastest thing on the map, so it is the one where
	# a thin line is certain to be passed through rather than merely likely.
	var thin := zones.thin_zones(30.0, playground.tick_rate)
	_check(thin.is_empty(),
		"and no zone is thin enough for a player at 30 m/s to cross without entering",
		"%d thin" % thin.size())

	var player := playground.add_player(&"bot", "Bot")

	# The face has to be unstandable or none of this is surf. Asked of the tunables
	# this game actually runs a player with, rather than of a number written down a
	# second time here — the angle is the one thing about this route that cannot be
	# changed without changing what the route IS.
	var max_slope: float = player.controller.tunables.max_slope_angle
	_check(
		PgSurfIntro.CHUTE_PITCH > max_slope,
		"the face is steeper than a player can stand on",
		"%.0f° against %.0f°" % [PgSurfIntro.CHUTE_PITCH, max_slope]
	)

	_check(player.timer.set_track(track), "the track switches to the plunge")
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the player on the plunge's pad, beside the main run rather than on it",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	# Arrays, because a GDScript lambda captures locals by value.
	var started: Array[bool] = [false]
	var finished: Array[bool] = [false]
	var splits: Array[int] = []

	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_stage := func(number: int, _split: float) -> void: splits.append(number)
	var on_finish := func(_run: DotTimerRun) -> void: finished[0] = true

	player.timer.run_started.connect(on_start)
	player.timer.stage_reached.connect(on_stage)
	player.timer.run_finished.connect(on_finish)

	var command := DotFpsCommand.new()
	command.move = Vector2(0.0, 1.0)
	command.yaw = 0.0

	var ticks := 0
	var airborne := 0
	var top_speed := 0.0

	for i in range(2000):
		player.controller.apply_command(command.duplicate_command())
		await get_tree().physics_frame
		ticks = i

		if not player.controller.state.is_grounded():
			airborne += 1

		top_speed = maxf(top_speed, player.speed())

		if finished[0]:
			break

	player.timer.run_started.disconnect(on_start)
	player.timer.stage_reached.disconnect(on_stage)
	player.timer.run_finished.disconnect(on_finish)

	_check(started[0], "leaving the start pad starts a run on the plunge")

	# The whole difference between the two routes, stated as a number. PRINTED as
	# well as asserted, because a detail line shows only on failure and this is the
	# figure every future question about this map is really about.
	print(
		"        the plunge: %.1f m/s top speed, %d airborne ticks of %d, "
		% [top_speed, airborne, ticks + 1]
		+ "finished %s" % ("yes" if finished[0] else "no")
	)

	_check(
		top_speed > 20.0,
		"the face makes the player fast, which the main run's ramps never do",
		"%.1f m/s" % top_speed
	)
	_check(
		splits == [1, 2],
		"it crosses both splits, in order",
		str(splits)
	)
	_check(
		finished[0],
		"and reaches the finish holding nothing but forward",
		"gave up at tick %d, z = %.1f, y = %.1f"
			% [ticks, player.global_position.z, player.global_position.y]
	)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)

	playground.remove_player(&"bot")
	_done()


# --- The client -------------------------------------------------------------

## A real `PlaygroundClient` boots and ends up with a player, a camera and a menu.
##
## [b]The one path in this project no other test touches, and it broke silently.[/b]
## Everything above drives `Playground` directly, because that is the half that runs
## headless — so the client's own boot sequence was covered by nothing, and when it
## started waiting for a signal that had already been emitted it simply stopped
## halfway through `_ready`. No error, no failed load, nothing in the log: a black
## screen with a `Playground` ticking behind it. Only a screenshot showed it.
##
## `change_map` completes without ever suspending when the map is a scene already in
## the build, which is every map here — so this test exercises exactly the case that
## broke. It would deadlock, not fail, without `booted` being checked before the
## await; the suite's own `timeout` is what turns that into a red run.
# --- Vehicles --------------------------------------------------------------

## A car spawned from the prop catalogue, driven, ridden in and got out of.
##
## [b]The whole point of this test is that a vehicle here is BOTH things at once.[/b]
## dot-vehicle's own 122 checks drive real bodies through real physics, and every one of
## them spawns through [method DotVehicleSpawner.spawn] into a world with nothing else in
## it. What has never run anywhere is a vehicle that is also a [DotPropInstance] — on a
## prop budget, on an undo stack, adopted rather than spawned, with its wheels built by
## the game after the body was created by somebody else.
func _test_vehicles() -> void:
	_section("vehicles")

	var changed: DotResult = await playground.change_map(&"pg_lobby")
	_check(changed.ok, "the sandbox loads")

	# The sandbox test above lets its player leave, so this one brings the bot back.
	var driver := playground.add_player(&"bot", "Bot")
	playground.props.limits.spawn_interval = 0.0

	# The corner of the plate opposite the jump course and the tower, which is the one
	# part of this map that is flat and empty for sixty metres in every direction. A car
	# is not a player: it covers the width of the sandbox in a few seconds, and the first
	# version of this test drove into the scenery and measured a stationary car.
	var at := Vector3(-60.0, 1.2, -60.0)
	driver.teleport(at + Vector3(2.5, 0.0, 0.0), 0.0)

	var spawned := playground.props.spawn(&"buggy", &"bot", at)

	_check(spawned != null, "a buggy spawns out of the PROP catalogue")

	if spawned == null:
		return

	_check(
		PlaygroundSpawnables.kind_of(spawned.def) == PlaygroundSpawnables.Kind.VEHICLE,
		"and the catalogue says it is a vehicle"
	)

	var vehicle := playground.vehicles.vehicle_for_node(spawned.node)

	_check(vehicle != null, "and it was adopted by the vehicle spawner")

	if vehicle == null:
		return

	_check(vehicle.chassis is DotVehicleWheeled, "with Godot's raycast wheels under it")

	var body := spawned.node as PlaygroundVehicle
	_check(body != null and body.wheel_count() == 4, "and four wheels actually built")
	_check(
		body != null and is_equal_approx(body.mass, vehicle.def.tuning().mass),
		"and one mass, read off the tunables by both catalogues",
		"%.1f vs %.1f" % [
			body.mass if body != null else -1.0, vehicle.def.tuning().mass
		]
	)

	# Let it settle onto its suspension before anything is measured. A raycast vehicle
	# spawned in the air is falling, and a "did it drive forward" measured through the
	# drop is measuring the drop.
	for _i in range(40):
		await get_tree().physics_frame

	_check(
		playground.use_vehicle(&"bot").ok,
		"the bot standing beside it gets in"
	)
	_check(driver.riding, "and stops being a player who walks")
	_check(vehicle.driver() == &"bot", "in the driving seat")
	_check(
		driver.get_parent() != playground and driver.is_inside_tree(),
		"with the rider's node carried by the vehicle",
		"which is what puts a rider's camera on it without a line about cameras"
	)

	# Forward. `move.y` is forward for a walking player and it is forward here.
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)

	var before := vehicle.position()
	await _drive(&"bot", forward, 200)

	var travelled := vehicle.position() - before

	_check(travelled.length() > 4.0, "it drives", "%.2f m" % travelled.length())
	_check(
		vehicle.forward_speed() > 0.5,
		"FORWARDS, which is the one dot-vehicle says a car gets wrong",
		"%.2f m/s along its own -Z" % vehicle.forward_speed()
	)
	_check(
		driver.controller.state.position.distance_to(vehicle.position()) < 4.0,
		"and the driver's replicated position went with it",
		"a passenger drawn where they got in is invisible in one process"
	)

	# Steering. Both directions, because a check that only measured "it turned" would
	# pass for a car that turns the wrong way — which is exactly the bug dot-vehicle
	# found in itself.
	var right := DotFpsCommand.new()
	right.move = Vector2(1.0, 1.0)

	var heading_before := -(vehicle.node as Node3D).global_basis.z
	await _drive(&"bot", right, 160)
	var heading_after := -(vehicle.node as Node3D).global_basis.z

	# Positive Y in a cross product of before × after means the turn was to the LEFT in
	# Godot's left-handed-looking convention, so a right turn is negative.
	var turn := heading_before.cross(heading_after).y

	_check(turn < -0.05, "steering right turns it right", "cross.y = %.3f" % turn)

	# A passenger, which is the case that only breaks with two people in it.
	var passenger := playground.add_player(&"rider", "Rider")
	passenger.teleport(vehicle.position() + Vector3(0.0, 0.0, 4.0))

	_check(
		playground.vehicles.ride.enter(vehicle, &"rider", passenger).ok,
		"a second player gets in as a passenger"
	)
	_check(vehicle.occupant_count() == 2, "and the car has two people in it")
	_check(vehicle.driver() == &"bot", "with the driver unchanged")

	var passenger_before := passenger.controller.state.position
	await _drive(&"bot", forward, 120)

	_check(
		passenger.controller.state.position.distance_to(passenger_before) > 1.0,
		"the passenger is carried too",
		"%.2f m" % passenger.controller.state.position.distance_to(passenger_before)
	)

	# Getting out, which is the half dot-vehicle says the bugs are in.
	#
	# Asserted on the SPEED first. A refusal test run against a car that happens to be
	# stationary passes without testing anything, which is how the first version of this
	# read: "not ok, or slow enough" is true for a car nobody managed to move.
	# Put back on a clean patch and pointed down the plate before anything about SPEED is
	# measured. Not tidiness: everything up to here has been steering it, and a test that
	# measures a speed at the end of a drive it did not control is a test that measures
	# whatever it happened to hit.
	(vehicle.node as Node3D).global_transform = Transform3D(Basis.IDENTITY, at)
	vehicle.body().linear_velocity = Vector3.ZERO
	vehicle.body().angular_velocity = Vector3.ZERO

	for _i in range(30):
		await get_tree().physics_frame

	await _drive(&"bot", forward, 220)

	_check(
		vehicle.speed() > vehicle.def.tuning().max_exit_speed,
		"the car is going fast enough for the exit rule to have something to say",
		"%.2f m/s vs %.1f" % [vehicle.speed(), vehicle.def.tuning().max_exit_speed]
	)

	var moving := playground.vehicles.ride.exit(vehicle, &"rider")
	_check(
		not moving.ok,
		"and getting out at that speed is refused",
		"speed %.1f, limit %.1f" % [vehicle.speed(), vehicle.def.tuning().max_exit_speed]
	)

	var stop := DotFpsCommand.new()
	stop.set_button(DotFpsCommand.BUTTON_CROUCH, true)
	await _drive(&"bot", stop, 200)

	_check(vehicle.speed() < 2.0, "the brake stops it", "%.2f m/s" % vehicle.speed())

	var out := playground.vehicles.ride.exit(vehicle, &"rider")
	_check(out.ok, "and then the passenger can get out", str(out.error) if not out.ok else "")
	_check(not passenger.riding, "and is walking again")
	_check(
		passenger.global_position.distance_to(vehicle.position()) > 0.9,
		"put down beside the car rather than inside it",
		"%.2f m" % passenger.global_position.distance_to(vehicle.position())
	)
	_check(
		passenger.get_parent() == playground,
		"and handed back to whoever had them before"
	)

	# The hovercraft, which is the only thing proving the chassis is a subclass point
	# rather than a promise.
	var skiff_prop := playground.props.spawn(&"skiff", &"bot", Vector3(-24.0, 1.5, 24.0))
	_check(skiff_prop != null, "a skiff spawns")

	if skiff_prop != null:
		var skiff := playground.vehicles.vehicle_for_node(skiff_prop.node)
		_check(skiff != null and skiff.chassis is DotVehicleHover, "on the hover chassis")
		_check(
			(skiff_prop.node as PlaygroundVehicle).wheel_count() == 0,
			"with no wheels built for it"
		)

		for _i in range(120):
			await get_tree().physics_frame

		_check(
			skiff != null and skiff.position().y > 0.55,
			"and it is still off the ground a second later",
			# Above its own half-height plus a margin: a skiff whose hover did nothing
			# would come to rest with its box on the floor at exactly 0.35.
			"y = %.2f" % (skiff.position().y if skiff != null else -1.0)
		)

	# Deleting the car with somebody in it. A rider left inside a freed vehicle is a
	# player parented to nothing: invisible, unkillable, and unable to enter anything
	# else for the rest of the round, with no error anywhere.
	_check(playground.use_vehicle(&"rider").ok, "the passenger gets back in")

	playground.props.remove(spawned.instance_id, DotPropSpawner.REASON_ADMIN)
	await get_tree().physics_frame

	_check(
		not playground.vehicles.ride.is_riding(&"rider")
		and not playground.vehicles.ride.is_riding(&"bot"),
		"removing the PROP evacuates everybody in the vehicle"
	)
	_check(not driver.riding, "and the driver is a walking player again")
	_check(
		playground.vehicles.world_count() == 1,
		"and the vehicle spawner has let go of it, leaving only the skiff",
		"%d left" % playground.vehicles.world_count()
	)

	playground.remove_player(&"rider")
	_done()



# --- The jump course -------------------------------------------------------

## `pg_lobby`'s bonus 1, driven from its start pad to its finish.
##
## [b]Nothing had ever run this course.[/b] Every check over it until now switched onto
## the track, looked at the spawn and switched back — which proves a player can be put
## at the bottom of it and nothing at all about whether they can get to the top. That is
## the whole of `[bonus-run-2]`, and the reason it is worth doing on this course in
## particular is that bonus 1 is the one route in this map a bot genuinely can run: it
## is a straight line, so the skill in it is timing rather than turning, and a bot
## holding forward that jumps at each leading edge is doing what a player does.
##
## The gaps are read off [PgLobby]'s own arithmetic rather than copied here, for the
## reason every map in this family says: a second description of where a platform is, is
## a second thing that can disagree with the geometry.
func _test_the_jump_course() -> void:
	print("")
	_section("the jump course — pg_lobby's bonus 1, run end to end")

	var loaded: DotResult = await playground.change_map(&"pg_lobby")
	_check(loaded.ok, "the lobby loads",
		loaded.error.message if not loaded.ok else "")

	var track := DotTimerTrack.BONUS_FIRST
	var zones := PgLobby.build_zones()

	var player := playground.add_player(&"bot", "Bot")

	# [b]The map's copy of the movement is the movement.[/b] `PgLobby` sizes its gaps
	# against three numbers it declares itself, because a map is content and cannot
	# reach into the game's player class — so the copy is deliberate and this is the
	# other half of that bargain. A course tuned against a jump height the server no
	# longer uses is a course that quietly stops being finishable, which is the exact
	# failure this section was written to find.
	var tunables := player.controller.tunables
	_check(
		is_equal_approx(tunables.max_speed, PgLobby.MOVE_SPEED)
			and is_equal_approx(tunables.jump_height, PgLobby.JUMP_HEIGHT)
			and is_equal_approx(tunables.gravity, PgLobby.MOVE_GRAVITY),
		"the map's movement constants are the ones the server applies",
		"map %.2f/%.2f/%.2f against %.2f/%.2f/%.2f"
			% [PgLobby.MOVE_SPEED, PgLobby.JUMP_HEIGHT, PgLobby.MOVE_GRAVITY,
				tunables.max_speed, tunables.jump_height, tunables.gravity]
	)

	# [b]And the rule the course lives under, which is the honest fix.[/b] Every gap
	# here has to be inside what the movement can actually cross while climbing
	# COURSE_RISE — measured off the map's own arithmetic, so re-tuning the ramp cannot
	# move the geometry past the rule. Before this course was driven the widest gap was
	# 5.65 m against a 3.68 m reach, and nothing anywhere said so: a zone set does not
	# know how far a player can jump, and every count over the course passed.
	var reach := PgLobby.jump_reach(PgLobby.COURSE_RISE)
	_check(
		PgLobby.widest_gap() <= reach,
		"no gap on the course is wider than a jump crosses while climbing a step",
		"widest %.2f m against a reach of %.2f m"
			% [PgLobby.widest_gap(), reach]
	)

	# And box to box, pad and finish pad included. `widest_gap` above reads the ramp
	# the platforms are placed by; this reads the platforms, so a pad resized or a
	# finish moved is asked about too.
	_check_route_reach(PgLobby.course_route(), "the jump course")

	_check(player.timer.set_track(track), "the course's track switches")
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the bot on the start pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	var started: Array[bool] = [false]
	var finished: Array[bool] = [false]
	var splits: Array[int] = []

	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_stage := func(number: int, _split: float) -> void: splits.append(number)
	var on_finish := func(_run: DotTimerRun) -> void: finished[0] = true

	player.timer.run_started.connect(on_start)
	player.timer.stage_reached.connect(on_stage)
	player.timer.run_finished.connect(on_finish)

	var command := DotFpsCommand.new()
	command.move = Vector2(0.0, 1.0)
	command.yaw = spawn.destination_yaw

	# How far along it got, in platforms. Reported whether it finishes or not, because
	# "it fell off" is worth nothing as a result and "it fell off at the sixth gap"
	# names the gap.
	var reached := -1
	var ticks := 0

	# Capped above the ~1700 ticks the course takes at walking pace. It was 1200 while
	# the course was nine platforms and unfinishable, which is a cap that reports the
	# same failure as a bot stuck at a gap: at twelve platforms a bot on the last third
	# ran out of ticks rather than out of route.
	for i in range(2400):
		command.set_button(
			DotFpsCommand.BUTTON_JUMP, _jumping_on_the_course(player.global_position.z)
		)
		player.controller.apply_command(command.duplicate_command())
		await get_tree().physics_frame
		ticks = i

		for step in range(PgLobby.COURSE_STEPS):
			var at := PgLobby.platform_centre(step)
			var over := (
				absf(player.global_position.x - at.x) < PgLobby.PLATFORM.x * 0.5
				and absf(player.global_position.z - at.z) < PgLobby.PLATFORM.z * 0.5
				and player.global_position.y >= at.y
			)
			if over and step > reached:
				reached = step

		if finished[0]:
			break

	player.timer.run_started.disconnect(on_start)
	player.timer.stage_reached.disconnect(on_stage)
	player.timer.run_finished.disconnect(on_finish)

	_check(started[0], "leaving the start pad starts a run on the course")
	_check(
		reached >= 0,
		"the bot makes the first platform",
		"never got onto one"
	)
	_check(
		splits == [1, 2],
		"it crosses both splits, in order",
		str(splits)
	)
	_check(
		finished[0],
		"and reaches the finish pad: bonus 1 run end to end",
		"gave up at tick %d on platform %d of %d, z = %.1f, y = %.1f"
			% [ticks, reached, PgLobby.COURSE_STEPS - 1,
				player.global_position.z, player.global_position.y]
	)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)

	playground.remove_player(&"bot")
	_done()


## Whether the bot should be holding jump at [param z] on the jump course.
##
## Pressed just before each leading edge and nowhere else. The course runs toward -Z, so
## the edge a player leaves from is the platform's near side in that direction, and the
## pad is eight metres deep where a platform is three — both are read off the map rather
## than written down again.
static func _jumping_on_the_course(z: float) -> bool:
	var edges: Array[float] = [PgLobby.COURSE_START_Z - PgLobby.PAD.z * 0.5]

	for i in range(PgLobby.COURSE_STEPS):
		edges.append(PgLobby.platform_centre(i).z - PgLobby.PLATFORM.z * 0.5)

	for edge in edges:
		if z <= edge + 0.7 and z > edge - 0.3:
			return true

	return false


# --- The switchback ---------------------------------------------------------

## `pg_bhop_intro`'s bonus 2, driven start to finish by a bot that turns.
##
## [b]The first route in this family built to be turned round and run by a bot.[/b] The
## narrows, the plunge and `the needle` in game-g2gfast are all straight, and each says
## so as a design decision: a bot that holds one yaw cannot run a route that turns. The
## tower on `pg_lobby` showed that was a limit of the bots rather than of routes, and
## this is the first route designed after that was known: three legs joined by two
## quarter turns, climbing 7 m, driven by [method _drive_route] reading the map's own
## [method PgBhopIntro.switchback_route].
##
## The zones are walked on this track by NAME rather than by trusting `problems()` —
## `[track-zone-1]`: a set complete for one track and partial for another passes a
## per-zone check while being a route nobody can finish.
func _test_the_switchback() -> void:
	print("")
	_section("the switchback — pg_bhop_intro's bonus 2, run end to end")

	var loaded: DotResult = await playground.change_map(&"pg_bhop_intro")
	_check(loaded.ok, "the bhop map loads",
		loaded.error.message if not loaded.ok else "")

	var track := PgBhopIntro.SWITCHBACK_TRACK
	var zones := PgBhopIntro.build_zones()
	var kinds := {
		"start": zones.of_kind(DotTimerZone.Kind.START, track).size(),
		"end": zones.of_kind(DotTimerZone.Kind.END, track).size(),
		"spawn": zones.of_kind(DotTimerZone.Kind.SPAWN, track).size(),
		"respawn": zones.of_kind(DotTimerZone.Kind.RESPAWN, track).size(),
		"stage": zones.of_kind(DotTimerZone.Kind.STAGE, track).size(),
	}

	_check(
		kinds == {"start": 1, "end": 1, "spawn": 1, "respawn": 1, "stage": 2},
		"bonus 2 has a start, a finish, a spawn, a respawn and two splits, on its own track",
		str(kinds)
	)
	_check(
		playground.tracks_on_this_map() == [
			DotTimerTrack.MAIN, DotTimerTrack.BONUS_FIRST, track,
		],
		"and the game sees three tracks on the map without being told",
		str(playground.tracks_on_this_map())
	)

	var route := PgBhopIntro.switchback_route()
	_check_route_reach(route, "the switchback")

	var player := playground.add_player(&"bot", "Bot")

	_check(player.timer.set_track(track), "the switchback's track switches")
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the bot on its pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	await _the_spawn_yaw_survives_a_tick(player, spawn)

	var first := route[1].get_center()
	var toward := Vector3(
		first.x - player.global_position.x, 0.0, first.z - player.global_position.z
	).normalized()
	_check(
		player.aim_direction().dot(toward) > 0.9,
		"facing the first block",
		"dot %.2f; yaw %.1f, the spawn says %.1f"
			% [player.aim_direction().dot(toward), player.controller.state.yaw,
				spawn.destination_yaw]
	)

	# Fourteen jumps at about a second each is ~1,800 ticks.
	var drive: Dictionary = await _drive_route(player, route, 4000)

	print("    the switchback: box %d of %d, splits %s, finish %s, %d ticks, %d respawns" % [
		int(drive["reached"]), route.size() - 1, str(drive["splits"]),
		str(drive["finished"]), int(drive["ticks"]), int(drive["respawns"]),
	])

	_check(drive["started"], "leaving the pad starts a run on bonus 2")
	_check(
		drive["splits"] == [1, 2],
		"it turns through both turning blocks' splits, in order",
		str(drive["splits"])
	)
	_check(
		drive["finished"],
		"and reaches the finish pad: the switchback run end to end",
		"got to box %d of %d at (%.1f, %.1f, %.1f) in %d ticks"
			% [int(drive["reached"]), route.size() - 1,
				player.global_position.x, player.global_position.y,
				player.global_position.z, int(drive["ticks"])]
	)
	_check(
		int(drive["respawns"]) == 0,
		"without once being put back on the pad",
		"%d respawns" % int(drive["respawns"])
	)
	_check(
		not player.timer.run.is_active(),
		"and the run is over rather than still running"
	)

	playground.remove_player(&"bot")
	_done()


## A spawn's yaw, read after the simulation has run rather than before it.
##
## [b]Every spawn-yaw check in this file used to read the yaw on the tick it was set,
## and that is the only tick it was ever true.[/b] `PlaygroundPlayer.teleport` wrote
## `controller.state.yaw` directly, and a command carries absolute view angles — so the
## next tick set it back to whatever the command said. A client's sampler had never been
## told and still faced where the mouse last left it; a bot with no command got the
## controller's starved-tick substitute, a fresh command facing yaw 0. Both are asked
## here, and both failed before the fix: this section's own "facing the first block"
## read `yaw 0.0, the spawn says 90.0` once the bot had been standing on a map for a
## while, and passed on a freshly-added one only because its controller had not started
## ticking yet.
func _the_spawn_yaw_survives_a_tick(
	player: PlaygroundPlayer, spawn: DotTimerZone
) -> void:
	var still := 8

	# A bot: nothing samples it and nothing is applied for eight ticks.
	playground.spawn_player(player.player_id)
	for _i in range(still):
		await get_tree().physics_frame

	_check(
		absf(angle_difference(
			deg_to_rad(player.controller.state.yaw), deg_to_rad(spawn.destination_yaw)
		)) < 0.01,
		"a bot's spawn yaw is still the spawn's %d ticks later" % still,
		"yaw %.1f, the spawn says %.1f"
			% [player.controller.state.yaw, spawn.destination_yaw]
	)

	# A client: a sampler that last faced somewhere else, applied every tick the way
	# `PlaygroundPlayer.simulate` applies a real one.
	var sampler := DotFpsSampler.new(player.controller.tunables)
	DotFpsSampler.register_default_actions(sampler)
	sampler.look_at_angles(spawn.destination_yaw - 90.0, 0.0)
	player.sampler = sampler

	playground.spawn_player(player.player_id)
	for _i in range(still):
		await get_tree().physics_frame

	_check(
		absf(angle_difference(
			deg_to_rad(player.controller.state.yaw), deg_to_rad(spawn.destination_yaw)
		)) < 0.01,
		"and so is a client's, whose sampler was facing 90 degrees away",
		"yaw %.1f, the spawn says %.1f"
			% [player.controller.state.yaw, spawn.destination_yaw]
	)

	player.sampler = null
	playground.spawn_player(player.player_id)
	await get_tree().physics_frame


func _test_the_client_boots() -> void:
	_section("the client boots")

	var client := PlaygroundClient.new()
	client.name = "Client"

	# Its own config, records in memory. A test must not write into the user's data
	# directory, and this is the only reason `PlaygroundClient.config` exists.
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.record_replays = false
	client.config = config

	add_child(client)

	for _i in range(4):
		await get_tree().process_frame

	_check(client.playground != null, "the client builds a playground")
	_check(
		client.playground != null and client.playground.booted,
		"which finishes booting"
	)
	_check(
		client.playground != null and client.playground.maps.current != null,
		"with a map up",
		String(client.playground.maps.current.id)
			if client.playground != null and client.playground.maps.current != null
			else "none"
	)

	# The four things that are all missing together when `_ready` stops halfway.
	_check(client.player != null, "the client has a player")
	_check(client.camera != null, "and a camera")
	_check(client.hud != null, "and a HUD")
	_check(
		client.screens != null and client.menu != null,
		"and a spawn menu registered on a stack"
	)

	_check(
		client.menu != null and client.screens != null
		and client.screens.screen(client.menu.screen_id()) == client.menu,
		"which the stack can find by id"
	)
	_check(
		client.player != null and client.player.samples_input
		and client.player.sampler != null,
		"and the player samples input, with a sampler actually built"
	)

	# [b]The mouse, end to end.[/b] Nothing in this family had ever delivered an
	# `InputEventMouseMotion` to a client and looked at what happened, which is how a
	# dead mouse survived: `_on_mouse_motion` fed `player.sampler` and `_net_physics`
	# sampled `_sampler`, two different objects, and `DotFpsSampler.sample` polls the
	# `InputMap` for movement so everything except the view kept working.
	var before_yaw: float = (
		client.player.controller.state.yaw if client.player != null else 0.0
	)

	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(120.0, 0.0)

	# [b]Captured, because a look input is only a look input while it is.[/b] Headless
	# starts VISIBLE, which is the state a player is in after one press of Escape, and
	# the guard in `_on_mouse_motion` is what stops a free cursor from turning the view
	# under itself. Setting it here makes this check model somebody playing rather than
	# somebody with a menu key stuck down.
	client.mouse_capture_override = true
	client._unhandled_input(motion)

	# The sampler accumulates and spends it on the next simulated tick, so the view has
	# not turned yet -- that is the point of accumulating it. Let the game tick.
	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(
		client.player != null
		and not is_equal_approx(client.player.controller.state.yaw, before_yaw),
		"a mouse motion turns the view",
		"yaw %.3f -> %.3f" % [
			before_yaw,
			client.player.controller.state.yaw if client.player != null else 0.0
		]
	)

	# [b]And the other half: a released cursor turns nothing.[/b] Escape frees the
	# pointer with no screen open, so `_menu_is_open` is false and every check above
	# still passes while the view spins under a cursor the player is aiming at a
	# spawn menu with. Same event, same client, one property different.
	#
	# Driven through `mouse_capture_override` because `Input.mouse_mode` is a no-op
	# under the dummy display server -- it reads VISIBLE however it is written, so a
	# suite that set it directly would prove nothing and pass anyway.
	var released_yaw: float = client.player.controller.state.yaw

	client.mouse_capture_override = false

	var free_motion := InputEventMouseMotion.new()
	free_motion.relative = Vector2(120.0, 0.0)
	client._unhandled_input(free_motion)

	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(
		is_equal_approx(client.player.controller.state.yaw, released_yaw),
		"and a motion with the cursor released turns nothing",
		"yaw %.3f -> %.3f" % [released_yaw, client.player.controller.state.yaw]
	)

	client.mouse_capture_override = true

	# And the routing rule itself, for the deployment this suite does not build. A
	# networked client's mouse must reach `_sampler`, because that is the sampler
	# `_net_physics` stamps a command from; `player.sampler` is null on one and the
	# events went there. Asserted on the accessor rather than by standing a whole
	# networked client up, because the bug was the disagreement between two lines and
	# an accessor both of them go through is what fixed it.
	_check(
		client.active_sampler() == client.player.sampler,
		"a local client's mouse feeds the player's own sampler"
	)

	var networked := PlaygroundClient.new()
	networked.link = Node.new()
	networked._sampler = DotFpsSampler.new(DotFpsTunables.new())

	_check(
		networked.active_sampler() == networked._sampler,
		"and a networked client's feeds the one its tick stamps commands from"
	)

	networked.link.free()
	networked.free()

	# [b]A connected client's HUD holds the vote's clock.[/b] The netcode comes up before
	# the HUD in `_ready`, and the hand-over used to sit with the netcode, where it found
	# no HUD — so every connected client counted its own map session's clock through
	# every extend while `headless_net`, which checks the bridge and not the client, said
	# the clock arrived. Booted for real here, with a bare node for a link: the bridge
	# needs one and the client asks every method of it before calling.
	var connected := PlaygroundClient.new()
	connected.name = "ConnectedClient"
	connected.link = Node.new()
	add_child(connected)
	for _i in range(4):
		await get_tree().process_frame
	_check(
		connected.hud != null and connected.bridge != null
			and connected.hud.clock_view == connected.bridge.clock_view,
		"a connected client's HUD draws the clock its bridge adopts from the server",
		"hud %s, bridge %s" % [connected.hud != null, connected.bridge != null]
	)
	var stub_link: Node = connected.link
	connected.queue_free()
	stub_link.queue_free()
	await get_tree().process_frame

	# [b]The client makes a noise when something happens, through the game and not
	# through the hooks.[/b] headless_presentation calls `on_prop_spawned` itself, which
	# proved every hook correct while nothing in the game called one and the playable
	# client was silent. This goes through the client's own spawn, the spawner's own
	# refusal and a real map change.
	var sink := client.presentation.audio.sink as DotAudioSinkNull \
		if client.presentation != null and client.presentation.audio != null else null
	_check(sink != null, "the headless client's presentation has a null sink to count on")

	if sink != null:
		sink.forget()
		client.selected_prop = &"crate"
		client._spawn()
		_check(
			sink.count_of(&"prop_spawn") == 1,
			"a prop the client spawns through the game makes a noise",
			"%d" % sink.count_of(&"prop_spawn")
		)

		sink.forget()
		client.playground.props.spawn(&"no_such_prop", client.player_id, Vector3.ZERO)
		_check(
			sink.count_of(&"refused") == 1,
			"and a spawn the spawner refuses makes the refusal noise",
			"%d" % sink.count_of(&"refused")
		)

		# An administrator's beacon and blind, through the client's OWN frame hooks rather
		# than the player's method: the marker and the ping are presentation, and a hook
		# nothing in the client calls is this file's oldest bug. Stepped by hand, a quarter
		# of a second at a time, so the count is the ripple's and not the frame rate's.
		client.player.beacon = true
		sink.forget()
		for _i in range(8):
			client._present_beacons(0.25)
		_check(
			sink.count_of(&"beacon") == 3,
			"a beacon pings as it comes on and once a second after, not once a frame",
			"%d pings in two seconds" % sink.count_of(&"beacon")
		)
		var marker := client.player.beacon_marker
		_check(
			marker != null and marker.is_inside_tree()
			and marker.global_position.is_equal_approx(client.player.controller.state.position),
			"its marker stands where the player is simulated"
		)
		_check(
			marker != null and not marker.column_shown(),
			"with no column on the player's own first-person view, which would smear the screen"
		)
		client.player.beacon = false
		client._present_beacons(0.25)
		_check(client.player.beacon_marker == null, "and it goes when the flag does")

		# And through real frames, because the checks above call the hook by hand and would
		# pass with `_process` never calling it — which is the shape every presentation hook
		# in this game once had.
		client.player.beacon = true
		await get_tree().process_frame
		await get_tree().process_frame
		_check(
			client.player.beacon_marker != null,
			"the client's own frame draws a beacon, not only a test calling the hook"
		)
		client.player.beacon = false
		await get_tree().process_frame
		await get_tree().process_frame
		_check(client.player.beacon_marker == null, "and its own frame takes it away")

		client.player.blinded = true
		client.hud.present_blind(0.5)
		var blind := client.hud.blind_overlay
		var viewport := client.hud.get_viewport_rect().size
		_check(
			blind != null and blind.visible and is_equal_approx(blind.modulate.a, 1.0),
			"a blind comes down over the HUD's player"
		)
		# The whole viewport. Headless it is 64 x 64 (docs/testing.md), which is still a
		# real size to compare against: an overlay never sized is 0 x 0 at any resolution.
		_check(
			blind != null and blind.get_global_rect().position.is_equal_approx(Vector2.ZERO)
			and blind.get_global_rect().size.is_equal_approx(viewport),
			"and covers the whole viewport",
			"%s against %s" % [str(blind.get_global_rect()) if blind != null else "-", str(viewport)]
		)
		_check(
			blind != null and blind.get_index() < client.hud.timer_hud.get_index(),
			"under the HUD's own widgets, so the clock still says the server is going on"
		)
		client.player.blinded = false
		client.hud.present_blind(0.5)
		_check(blind != null and not blind.visible, "and lifts when the flag does")

		client.presentation.fx.shake.add(1.0)
		_check(client.presentation.fx.shake.active(), "a shake is live before a map change")
		await client.playground.change_map(&"pg_bhop_intro")
		_check(
			not client.presentation.fx.shake.active(),
			"and a map change clears it, because the effects' world has gone"
		)

	client.queue_free()

	await get_tree().process_frame
	await get_tree().process_frame
	_done()



# --- The circuit -----------------------------------------------------------


## Bonus 3, the driving track.
##
## [b]This is the first thing in the family that puts a VEHICLE through the timer, and
## the first map built at a car's scale.[/b] Two halves, and the second is the one that
## could not have been written before tonight: the geometry, which is checked the same
## way the tower's is, and a real buggy driven a real lap under throttle and steering,
## through every stage, to a finish.
func _test_the_circuit(playground: Playground, zones: DotTimerZoneSet) -> void:
	var track := PgLobby.CIRCUIT_TRACK

	_check(
		zones.of_kind(DotTimerZone.Kind.START, track).size() == 1
		and zones.of_kind(DotTimerZone.Kind.END, track).size() == 1,
		"the circuit on bonus 3 has one grid and one finish line"
	)

	var stages := zones.of_kind(DotTimerZone.Kind.STAGE, track)
	_check(stages.size() == 3, "and three splits", "%d" % stages.size())

	# The trick the whole track depends on: a loop whose start and finish are the same
	# place finishes on the tick it starts. A check that only counted the zones would
	# pass for exactly that map.
	var grid: Array = zones.of_kind(DotTimerZone.Kind.START, track)
	var line: Array = zones.of_kind(DotTimerZone.Kind.END, track)
	var grid_zone: DotTimerZone = grid[0]
	var line_zone: DotTimerZone = line[0]
	var grid_box := AABB(
		grid_zone.centre() - grid_zone.size() * 0.5, grid_zone.size()
	)
	var line_box := AABB(
		line_zone.centre() - line_zone.size() * 0.5, line_zone.size()
	)

	_check(
		not grid_box.intersects(line_box),
		"and the finish line does NOT overlap the grid, which is what makes a LAP",
		"a loop timed from one box to itself finishes on the tick it starts"
	)

	# Every zone on the road, not beside it. The road is 12 m wide and the zones are
	# built from the same `circuit_point`, so a zone off the tarmac means the two
	# descriptions have come apart — which is the failure this project builds maps in
	# code to make impossible, and is worth asserting rather than assuming.
	var off := 0

	var on_road: Array[DotTimerZone] = []
	on_road.append_array(zones.of_kind(DotTimerZone.Kind.START, track))
	on_road.append_array(zones.of_kind(DotTimerZone.Kind.END, track))
	on_road.append_array(zones.of_kind(DotTimerZone.Kind.STAGE, track))

	for zone in on_road:
		var centre: Vector3 = zone.centre()
		var nearest := _nearest_circuit_distance(Vector3(centre.x, 0.0, centre.z))

		if nearest > PgLobby.CIRCUIT_WIDTH * 0.5:
			off += 1

	_check(off == 0, "and every zone sits on the road it was drawn from",
		"%d off the tarmac" % off)

	# The lap is long enough to be a lap. A circuit a car crosses in four seconds is a
	# roundabout.
	_check(
		PgLobby.circuit_length() > 350.0,
		"the lap is a lap",
		"%.0f m" % PgLobby.circuit_length()
	)

	# Clear of everything else on the plate. The jump course, the tower and the
	# staircase all live inside the inner kerb, and a circuit that clipped one of them
	# would be a car driving through a leaderboard.
	var inner := PgLobby.CIRCUIT_HALF - PgLobby.CIRCUIT_WIDTH * 0.5 \
		- PgLobby.CIRCUIT_KERB_WIDTH

	_check(
		absf(PgLobby.COURSE_X) < inner and absf(PgLobby.TOWER_X) - PgLobby.TOWER_RADIUS < inner,
		"and it runs round the jump course and the tower rather than through them",
		"inner edge %.1f m" % inner
	)


## How far [param at] is from the nearest point on the centreline.
##
## Sampled rather than solved. The centreline is four straights and four arcs and a
## closed-form nearest point is more arithmetic than this test is worth; 512 samples
## over a 387 m lap is 76 cm apart, which is well inside the 6 m half-width being
## asserted against.
func _nearest_circuit_distance(at: Vector3) -> float:
	var length := PgLobby.circuit_length()
	var best := INF

	for i in range(512):
		var point: Array = PgLobby.circuit_point(length * float(i) / 512.0)
		best = minf(best, at.distance_to(point[0] as Vector3))

	return best


## A buggy actually drives the lap.
##
## [b]Autopiloted along the centreline rather than driven in a straight line.[/b] A
## test that held the throttle down would prove the road exists and nothing else: it is
## the CORNERS that say whether the radius is one the steering can hold, whether the
## kerbs are drivable, and whether the segments meet without a seam a wheel catches on.
## The autopilot is nine lines because [method PgLobby.circuit_point] is the same
## function the road was built from, which is the whole argument for building maps in
## code.
func _drive_the_circuit() -> void:
	var track := PgLobby.CIRCUIT_TRACK
	var driver: PlaygroundPlayer = playground.players[&"bot"]

	_check(driver.timer.set_track(track), "the circuit's track switches")

	playground.spawn_player(&"bot")

	var grid: Array = PgLobby.circuit_point(0.0)
	var at: Vector3 = grid[0]

	_check(
		driver.controller.state.position.distance_to(at) < 6.0,
		"and puts the driver on the grid",
		"%.1f m off" % driver.controller.state.position.distance_to(at)
	)

	var spawned := playground.props.spawn(
		&"buggy", &"bot", at + Vector3(0.0, 1.2, 0.0)
	)

	_check(spawned != null, "a buggy spawns on the line")

	if spawned == null:
		return

	var car := playground.vehicles.vehicle_for_node(spawned.node)

	if car == null:
		_check(false, "and is a vehicle")
		return

	# Point it down the road. A car dropped onto the grid keeps whatever rotation the
	# prop spawner gave it, and a lap that starts by reversing into the kerb measures
	# the autopilot rather than the track.
	var forward: Vector3 = grid[1]
	(car.node as Node3D).global_transform = Transform3D(
		Basis.looking_at(forward, Vector3.UP),
		at + Vector3(0.0, 1.2, 0.0)
	)

	for _i in range(30):
		await get_tree().physics_frame

	_check(playground.use_vehicle(&"bot").ok, "the bot gets in")

	# The rule this map needed: getting in must NOT cancel the run on a driven track.
	# It is asserted before the lap because a lap that never started would look
	# identical to one that was never timed.
	_check(
		playground.current_map_node().track_is_driven(track),
		"the map says bonus 3 is driven"
	)
	_check(
		not playground.current_map_node().track_is_driven(DotTimerTrack.BONUS_FIRST),
		"and that bonus 1 is not, which is what stops a jump course being driven round"
	)

	var seen: Array[int] = []
	driver.timer.stage_reached.connect(
		func(number: int, _split: float) -> void: seen.append(number)
	)

	var finished: Array[float] = []
	driver.timer.run_finished.connect(
		func(run: DotTimerRun) -> void: finished.append(run.time())
	)

	var command := DotFpsCommand.new()
	var progress := 0.0
	var stalled := 0

	# Twelve thousand ticks is roughly ninety simulated seconds, which is three times
	# what a clean lap takes. The loop exits on the finish, so the ceiling only ever
	# bounds a car that got stuck.
	for _i in range(12000):
		var here := car.position()
		progress = _circuit_progress(here, progress)

		# Aim fifteen metres up the road. Far enough that the car is not sawing at the
		# wheel on a straight, near enough that it turns in before the corner rather
		# than after it.
		var target: Array = PgLobby.circuit_point(progress + 15.0)
		var to_target: Vector3 = ((target[0] as Vector3) - here).normalized()
		var heading := -(car.node as Node3D).global_basis.z
		var right := (car.node as Node3D).global_basis.x

		# A positive `move.x` steers right, the same axis a walking player strafes on.
		command.move = Vector2(
			clampf(to_target.dot(right) * 3.0, -1.0, 1.0),
			1.0 if heading.dot(to_target) > 0.2 else 0.4
		)

		driver.controller.apply_command(command.duplicate_command())
		await get_tree().physics_frame

		if not finished.is_empty():
			break

		if car.speed() < 0.5:
			stalled += 1
		else:
			stalled = 0

		if stalled > 600:
			break

	_check(
		not finished.is_empty(),
		"a buggy drives the whole lap and crosses the line",
		"%.1f m round the centreline" % progress
	)
	_check(
		seen == [1, 2, 3],
		"through all three splits, in order",
		str(seen)
	)
	_check(
		not finished.is_empty() and finished[0] > 8.0,
		"and the lap took a lap's worth of time",
		"%.2f s" % (finished[0] if not finished.is_empty() else -1.0)
	)

	# Getting out mid-lap ends the run, which is the mirror of the rule above and the
	# half that would otherwise let somebody walk the last corner.
	# The bot is still sitting in the car it just finished in, so put it down first.
	# `use_vehicle` is a toggle and calling it on a rider is how a player gets out.
	if playground.vehicles.ride.is_riding(&"bot"):
		var park := DotFpsCommand.new()
		park.set_button(DotFpsCommand.BUTTON_CROUCH, true)
		await _drive(&"bot", park, 300)
		playground.use_vehicle(&"bot")
		await get_tree().physics_frame

	# Both back on the grid, stationary, pointing down the road.
	var line_up: Array = PgLobby.circuit_point(0.0)
	var start_at: Vector3 = line_up[0]
	(car.node as Node3D).global_transform = Transform3D(
		Basis.looking_at(line_up[1] as Vector3, Vector3.UP),
		start_at + Vector3(0.0, 1.2, 0.0)
	)
	car.body().linear_velocity = Vector3.ZERO
	car.body().angular_velocity = Vector3.ZERO

	driver.timer.set_track(track)
	playground.spawn_player(&"bot")

	for _i in range(30):
		await get_tree().physics_frame

	_check(playground.use_vehicle(&"bot").ok, "the bot gets back in")

	var rolling := DotFpsCommand.new()
	rolling.move = Vector2(0.0, 1.0)
	await _drive(&"bot", rolling, 200)

	_check(
		driver.timer.run != null and driver.timer.run.is_running(),
		"a second lap is under way"
	)

	var stop := DotFpsCommand.new()
	stop.set_button(DotFpsCommand.BUTTON_CROUCH, true)
	await _drive(&"bot", stop, 300)

	# `use_vehicle` is a toggle: in when out, out when in. The same key a player presses.
	# It is refused above `max_exit_speed`, which is why the brake above is not
	# decoration.
	var got_out := playground.use_vehicle(&"bot")
	_check(got_out.ok, "the bot gets out", "%.2f m/s" % car.speed())
	await get_tree().physics_frame

	_check(
		driver.timer.run == null or not driver.timer.run.is_running(),
		"and getting out of the car ends it"
	)

	# Out of the car, upright: a ride writes the car's whole basis onto the body, and
	# facing afterwards wrote only the yaw, so whatever pitch and roll the car had at the
	# moment of getting out stayed on the rig for good. Tilted by hand here, as a car on a
	# bank would leave it.
	var body: Variant = driver.get("character")
	var upright := false
	if body != null and body.get("rig") != null and (body.get("rig") as Node3D).is_inside_tree():
		body.call("face_basis", Basis.from_euler(Vector3(0.3, 1.0, -0.2)))
		body.call("face", 0.5)
		var r: Vector3 = (body.get("rig") as Node3D).rotation
		upright = is_zero_approx(r.x) and is_zero_approx(r.z) and is_equal_approx(r.y, 0.5)
	_check(upright, "and the body stands upright again, with none of the car's tilt",
		"no body drawn for the bot" if body == null else "")


## Where [param at] is round the lap, searched forward from [param from].
##
## Forward-only, which matters: a car on the +Z straight is metres from BOTH the first
## and the last leg, and a nearest-point search over the whole lap snaps a car about to
## finish back to the grid it left. The window is generous enough to survive a spin.
func _circuit_progress(at: Vector3, from: float) -> float:
	var best := from
	var best_distance := INF

	for i in range(120):
		var s := from + float(i) * 0.5
		var point: Array = PgLobby.circuit_point(s)
		var distance := at.distance_to(point[0] as Vector3)

		if distance < best_distance:
			best_distance = distance
			best = s

	return best
