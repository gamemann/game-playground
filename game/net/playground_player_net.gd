extends DotNetBehaviour

const PlaygroundNetBridge := preload("playground_net_bridge.gd")
const PlaygroundNetCommand := preload("playground_net_command.gd")
const PlaygroundPlayer := preload("../playground_player.gd")

## What a networked playground player replicates: the movement state, and an
## administrator's two marks.
##
## The timer is not replicated per tick. A client runs its own [DotTimer] over its own
## copy of the zones and reaches the same answer a tick earlier than any packet could,
## which is the whole reason the timer is deterministic; the server sends run identities
## and finishes as reliable events instead. Same division [G2GPlayerNet] makes, for the
## same reason.
##
## The props a player spawns are NOT here either. They are their own entities with their
## own behaviour, because a prop outlives the player who spawned it and a barrel punted
## across the map is not part of anybody's movement state.

var player: PlaygroundPlayer = null
var bridge: PlaygroundNetBridge = null

var net_position: Vector3 = Vector3.ZERO
var net_velocity: Vector3 = Vector3.ZERO
var net_yaw: float = 0.0
var net_pitch: float = 0.0
var net_crouch: float = 0.0
var net_flags: int = 0
var net_modifiers: int = 0

# --- An administrator's marks, from PlaygroundModTools ---

## `PlaygroundPlayer.blinded`. Owner only: see [method _register_net_vars].
var net_blind: bool = false

## `PlaygroundPlayer.beacon`. Everybody's.
var net_beacon: bool = false

## Retained, not cleared: a player whose packet was lost keeps moving in a straight line
## rather than stopping dead. The controller says the same of its own command.
var last_move: DotFpsCommand = DotFpsCommand.new()
var last_state_tick: int = -1


func _register_net_vars() -> void:
	for spec in DotFpsNetSync.state_specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])
		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))
		if bool(spec["interpolated"]):
			declaration.interpolated()
		if spec["property"] == &"net_crouch":
			declaration.range_of(0.0, 1.0)

	# [b]Per-player state rather than an event, and that is what makes both of these
	# survive what an event does not.[/b] A client that joins after the admin typed
	# `beacon`, a snapshot lost on the way, a map change: each is a baseline the next
	# snapshot corrects, where an event sent once is simply missed. Two bits, and nothing
	# at all on a tick where neither changed.
	#
	# The blind goes to its owner alone. Nobody else's screen changes, and with the arena
	# on an opponent who received it would know the moment somebody could not see them.
	#
	# [b]No relevance change for the beacon, unlike the reference game's.[/b] Every player
	# here is already `always_relevant` (`PlaygroundNetBridge._build_entity`), so a beaconed
	# one reaches every client however far away they are with nothing added — and a beacon
	# that switched relevance off when it was lifted would cut every player it had ever
	# marked out of everybody else's world.
	replicate(&"net_blind", DotNetVar.Type.BOOL).to_owner_only()
	replicate(&"net_beacon", DotNetVar.Type.BOOL)


func _net_apply_input(input: DotNetInput, _tick: int) -> void:
	var command := input as PlaygroundNetCommand
	if command != null:
		last_move = command.move


## On the authority the whole game ticks as one — every entity moves, then every player,
## then every timer sees the positions those moves produced — so the first behaviour
## through drives the game and the rest find it done. On a predicting client there is one
## predicted player, and simulating it directly is the whole of what a client may
## compute: the props are rigid bodies and a client cannot reproduce them.
func _net_simulate(tick: int, delta: float) -> void:
	if player == null:
		return

	if identity != null and identity.is_authoritative:
		if bridge != null:
			bridge.ensure_game_ticked(tick)
	elif player.riding:
		# A rider is not predicted, because a rider is not walking. The controller is the
		# thing that would be predicting, and while its owner is in a vehicle it has no
		# answer to predict: the vehicle's position comes from the server, it is not
		# reproducible across machines, and a controller simulating on top of it fights
		# every snapshot at a metre a time. The command is still applied so the driver's
		# keys are in the input the predictor sends — which is the whole of what a
		# driving client does.
		player.controller.apply_command(last_move.duplicate_command())
	else:
		player.controller.apply_command(last_move.duplicate_command())
		player.controller.simulate_tick(tick, delta)

	pull()


func pull() -> void:
	if player != null:
		DotFpsNetSync.pull(player.controller.state, self)
		net_blind = player.blinded
		net_beacon = player.beacon


## The server's answer, adopted wholesale. On the owner it is the rewind half of
## reconciliation and the predictor replays every unacknowledged command on top.
func _net_state_applied(tick: int) -> void:
	if player == null:
		return
	last_state_tick = tick
	DotFpsNetSync.push(self, player.controller.state)
	player.blinded = net_blind
	player.beacon = net_beacon
	# NOT the node, on a predicted entity: receive_snapshot calls this before the
	# predictor reconciles, and reconcile's first act is to read the node as "what the
	# client is showing". Moving it here makes the measured error the whole replay
	# distance and the correction rate reads as if every snapshot snapped. Both
	# HungryPieceNet and G2GPlayerNet shipped with that line.
	# ...unless they are riding, when there is no replay to spoil: nothing was predicted,
	# so the server's answer IS what the client should be showing. Without this the local
	# player's node — and the camera under it — stays where they got in, and the player
	# watches the car drive away from inside their own head.
	if identity == null or not identity.is_predicted() or player.riding:
		player.global_position = player.controller.state.position


## Every frame on a remote player. Without this the interpolator's work sits in a
## property nothing reads and the remote player moves in snapshot-sized steps.
func _net_interpolated(_tick: int) -> void:
	if player == null:
		return
	DotFpsNetSync.push(self, player.controller.state)
	player.global_position = player.controller.state.position
