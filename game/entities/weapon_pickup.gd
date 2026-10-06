extends "playground_entity.gd"

## A weapon lying in the world. Walk over it and it is yours.
##
## Spawned from the Q menu's weapons tab (right click a weapon) and counted against the
## spawner's `weapons` limit, or dropped by an NPC that died holding one. Either way it is a
## prop, so a physics gun can throw it to somebody.

## Seconds before it can be picked up, so whoever spawned it at their feet does not pick it
## straight back up, and a dropped one does not land in its killer's hands mid-fight.
const ARM_SECONDS := 0.75

const REACH := 1.4

## The game's weapon id this gives.
var weapon_id: StringName = &""

## Seconds until it is cleaned up, or 0 for never. A dropped weapon is; a spawned one is not.
var lifetime: float = 0.0


func _entity_ready() -> void:
	weapon_id = StringName(tune_string(&"weapon", ""))


func _entity_tick(_delta: float) -> void:
	if game == null or instance == null or weapon_id == &"":
		return

	if lifetime > 0.0 and age >= lifetime:
		game.props.remove(instance.instance_id, DotPropSpawner.REASON_CLEANUP)
		return

	if age < ARM_SECONDS:
		return

	for id in game.players:
		var player: Node3D = game.players[id]

		if player.global_position.distance_to(global_position) <= REACH:
			game.pick_up_weapon(id, weapon_id)
			game.props.remove(instance.instance_id, DotPropSpawner.REASON_PLAYER)
			return
