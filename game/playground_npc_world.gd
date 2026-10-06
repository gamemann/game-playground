extends Node

## What a sandbox NPC's brain asks the world: the time, where somebody is, who is near.
##
## [b]A director without a spawner.[/b] dot-npc-ai's brain is written to be bound to a
## `DotNpcSpawner` and asks it four things by name — `now`, `candidate_position`,
## `npcs_near`, `path_toward` — never by type. The sandbox's NPCs are props first (budgeted,
## undoable, punt-able) and are deliberately not spawned by dot-npc, so this answers the
## same four questions from the Playground instead. The squads, the sounds and the server's
## NPC skill hang off it as metadata, where the brain looks for them.

var game: Node = null

var _now: float = 0.0


func advance(delta: float) -> void:
	_now += delta


func now() -> float:
	return _now


## Where candidate [param id] is — a player (`u3`) or an armed NPC (`n…`) — or
## [param fallback] when it is gone.
func candidate_position(id: StringName, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	return game.call("candidate_position", id, fallback) if game != null else fallback


## The armed NPCs within [param radius] of [param point], as dot-npc instances.
func npcs_near(point: Vector3, radius: float) -> Array:
	var out: Array = []

	if game == null:
		return out

	for entity in game.get("armed_npcs"):
		if not is_instance_valid(entity):
			continue

		var npc: Variant = entity.get("npc")

		if npc is DotNpcInstance and (entity as Node3D).global_position.distance_to(point) <= radius:
			out.append(npc)

	return out
