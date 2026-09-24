extends Node

const Playground := preload("../game/playground.gd")
const PlaygroundClient := preload("../game/playground_client.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundNetBridge := preload("../game/net/playground_net_bridge.gd")
const PlaygroundPlayer := preload("../game/playground_player.gd")
const PlaygroundPlayerNet := preload("../game/net/playground_player_net.gd")

## Renders a CONNECTED client looking at another player, and measures how smoothly that
## player moves on screen. The view `tools/screenshot_views.sh` cannot give: offline there is
## nobody else, and the bugs this exists for were all in what a client draws of a player it
## is only told about.
##
## [codeblock]
## tools/screenshot_net.sh                # four consecutive frames, screenshots/net_0..3.png
## tools/screenshot_net.sh --no-interp    # the same with the client's interpolation off
## [/codeblock]
##
## A server and a client in one process, joined by the loopback `headless_net` uses: the
## server's world is in a SubViewport with its own physics space that is never drawn, and
## the client's is the one on screen. Every frame calls `PlaygroundClient.present_frame`,
## the function the real client's `_process` calls.
##
## [b]The probe.[/b] Once a rendered frame, the other player's drawn position is divided by
## that frame's delta: the apparent speed. Running flat out in a straight line it should be
## the same every frame, and the share of frames far from the typical one is the judder.
## `--no-interp` shows what that share is when it is wrong, because a number with nothing
## to compare it to proves nothing.
##
## xvfb-run, never --headless: headless gives a null renderer and saves a frame of nothing.

const SESSION := 7
const CLIENT_PEER := 2
const OTHER_SESSION := 8
const OTHER_PEER := 3
const INPUT_LEAD := 2

## A screen faster than the tick; the interpolation fraction only matters between ticks.
const RENDER_FPS := 144

## How far in front of the watcher the other player crosses, and how far either side.
const AHEAD := 7.0
const SWING := 5.0

var _server_game: Playground = null
var _client_game: Playground = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: PlaygroundNetBridge = null
var _client_bridge: PlaygroundNetBridge = null
var _to_client: Array = []
var _to_server: Array = []
var _tick := 0

var _camera: Camera3D = null
var _interp := true
var _placed := false
var _heading := -90.0
var _settle := 0
var _speeds: Array[float] = []
var _last_drawn := Vector3.INF
var _home := Vector3.ZERO


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	Engine.max_fps = RENDER_FPS
	_run.call_deferred()


func _run() -> void:
	var seconds := 6.0
	var out := "res://screenshots/net.png"

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seconds="):
			seconds = float(arg.substr(10))
		elif arg.begins_with("--out="):
			out = arg.substr(6)
		elif arg == "--no-interp":
			_interp = false

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://screenshots"))
	await _build()

	var elapsed := 0.0
	while elapsed < seconds:
		elapsed += get_process_delta_time()
		await get_tree().process_frame

	var base := out.get_basename()
	for i in range(4):
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		var path := "%s_%d.png" % [base, i]
		image.save_png(ProjectSettings.globalize_path(path))
		print("saved %s" % path)

	_report()
	# Stalls and extrapolations are frames the interpolator had nothing newer than its render
	# time to blend toward and guessed instead. Every frame here, as of 2026-09-24: dot-net's
	# buffer is counted in SNAPSHOTS and subtracted from a timeline in TICKS, so at 128 ticks
	# and 20 snapshots the delay is a sixth of what it says. See this repo's CLAUDE.md.
	print("interpolator: ", _client_net.interpolator.describe())
	get_tree().quit()


func _build() -> void:
	var server_view := SubViewport.new()
	server_view.name = "ServerView"
	server_view.own_world_3d = true
	server_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(server_view)

	var server_side := Node.new()
	server_side.name = "ServerSide"
	server_view.add_child(server_side)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	add_child(client_side)

	_server_game = _make_game(true, &"server", server_side)
	_client_game = _make_game(false, &"client", client_side)

	for _i in range(240):
		await get_tree().process_frame
		if _server_game.maps.current != null and _client_game.maps.current != null:
			break

	_server_net = _make_manager(true, &"server", 1, server_side, _server_game.tick_rate)
	_client_net = _make_manager(false, &"client", CLIENT_PEER, client_side, _client_game.tick_rate)

	_server_bridge = PlaygroundNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)
	_client_bridge = PlaygroundNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	var _a := _server_bridge.attach(_server_game, _server_net, _server_net)
	var _b := _client_bridge.attach(_client_game, _client_net, _client_net)
	_server_net.messages.seal()
	_client_net.messages.seal()
	_server_bridge.link.loopback = func(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
		if peer_id == 0 or peer_id == CLIENT_PEER:
			_to_client.append([method, payload])
	_client_bridge.link.loopback = func(method: StringName, _peer: int, payload: PackedByteArray) -> void:
		_to_server.append([method, payload])
	# The loopback delivers within the frame, so the honest round trip is next to nothing;
	# the suite's 40 ms is a clock-lead test, and here it would only push the render time
	# further past the newest snapshot.
	_client_bridge.rtt_source = func() -> float: return 1.0
	var _s := _server_net.start()
	var _c := _client_net.start()

	var _ada := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_client_bridge.ask_ready()
	var _bea := _server_bridge.add_player(OTHER_PEER, OTHER_SESSION, "Bea")

	_camera = Camera3D.new()
	_camera.fov = 75.0
	_camera.current = true
	add_child(_camera)


func _make_game(server: bool, scope: StringName, parent: Node) -> Playground:
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = &"pg_lobby"
	config.authoritative = server

	var game := Playground.new()
	game.name = "Game"
	game.config = config
	game.service_scope = scope
	parent.add_child(game)
	return game


func _make_manager(
	server: bool, scope: StringName, peer_id: int, parent: Node, tick_rate: int
) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = scope
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = tick_rate
	config.enable_lag_compensation = false
	config.enable_prediction = true
	config.world_extent = 512.0
	manager.config = config

	parent.add_child(manager)
	manager.setup()
	return manager


func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()

	for entry in to_client:
		_client_bridge.link.deliver(entry[0], 1, entry[1])
	for entry in to_server:
		_server_bridge.link.deliver(entry[0], CLIENT_PEER, entry[1])


## One tick per physics frame, which is what a client on the server's rate does: the bridge
## puts the engine there on HELLO.
func _physics_process(delta: float) -> void:
	if _server_bridge == null or _client_net == null:
		return

	_drive_other()

	_tick += 1
	var _ticks := _client_net.clock.advance(delta)
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(_tick + INPUT_LEAD, DotFpsCommand.new())
	_flush()


## Bea runs back and forth across Ada's view, driven the way her client would drive her: the
## command her input would have carried, applied by the server.
func _drive_other() -> void:
	var ada: PlaygroundPlayer = _server_game.players.get(&"u%d" % SESSION)
	var bea: PlaygroundPlayer = _server_game.players.get(&"u%d" % OTHER_SESSION)

	if ada == null or bea == null:
		return

	if not _placed:
		_home = ada.controller.state.position
		ada.teleport(_home, 0.0)
		bea.teleport(_home + Vector3(-SWING, 0.0, -AHEAD), -90.0)
		_placed = true
		_settle = 30

	var offset := bea.controller.state.position.x - _home.x
	if offset > SWING:
		_heading = 90.0
	elif offset < -SWING:
		_heading = -90.0

	var run := DotFpsCommand.new()
	run.move = Vector2(0.0, 1.0)
	run.yaw = _heading
	(bea.get_node("Net") as PlaygroundPlayerNet).last_move = run


func _process(delta: float) -> void:
	if _client_game == null or _client_net == null:
		return

	var mine: PlaygroundPlayer = _client_game.players.get(&"u%d" % SESSION)

	if mine != null and not mine.samples_input:
		# What `PlaygroundClient._build_view_switch` does the moment the client knows which
		# player is its own: that one is looked out of, so its body is hidden.
		mine.samples_input = true
		var _switch := mine.build_view_switch()

	var _shown := PlaygroundClient.present_frame(_client_net if _interp else null, _client_game)

	if mine != null:
		var eye := mine.eye_position()
		_camera.global_position = eye
		_camera.look_at(eye + Vector3(0.0, -0.2, -1.0), Vector3.UP)

	var theirs: PlaygroundPlayer = _client_game.players.get(&"u%d" % OTHER_SESSION)
	var bea: PlaygroundPlayer = _server_game.players.get(&"u%d" % OTHER_SESSION)

	if theirs == null or theirs.character == null or bea == null or delta <= 0.0:
		return

	var at := theirs.character.rig.global_position
	# Only while the SERVER has her running flat out: the turn at each end is supposed to
	# slow her down, and a frame across a teleport is not motion.
	var server_speed := Vector2(bea.controller.state.velocity.x, bea.controller.state.velocity.z).length()

	if _settle > 0:
		_settle -= 1
	elif _last_drawn != Vector3.INF and server_speed > 5.0:
		_speeds.append(at.distance_to(_last_drawn) / delta)

	_last_drawn = at


func _report() -> void:
	if _speeds.is_empty():
		print("probe: nothing sampled")
		return

	var sorted := _speeds.duplicate()
	sorted.sort()
	var median: float = sorted[sorted.size() / 2]

	var still := 0
	var off := 0
	var worst := 0.0
	for v in _speeds:
		if v < 0.01:
			still += 1
		var ratio := absf(v - median) / maxf(median, 0.001)
		worst = maxf(worst, ratio)
		if ratio > 0.2:
			off += 1

	print("probe (%s): %d frames at full speed, median %.2f m/s, %d standing still, %d more than 20%% off (%.0f%%), worst %.0f%% off" % [
		"interpolated" if _interp else "NOT interpolated",
		_speeds.size(), median, still, off, 100.0 * off / float(_speeds.size()), 100.0 * worst,
	])
