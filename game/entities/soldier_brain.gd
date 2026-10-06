extends "res://addons/dot_npc_ai/runtime/dot_npc_ai_brain.gd"

## How an armed sandbox NPC decides: dot-npc-ai's tactical layer, with whatever it is holding.
##
## [codeblock]
## selector (reactive)
##   flee danger
##   sequence (reactive)  has a target?
##     selector
##       sequence (reactive)  melee weapon?          -> the attack slot -> close in, swing
##       sequence (reactive)  badly hurt?            -> cover, still shooting
##       sequence (reactive)  the squad's flank role -> round its side, shooting
##       suppress                                    -> hold the range band, shooting
##   search where it probably went
##   follow the owner (a friendly one)
##   patrol where players go
##   hold
## [/codeblock]
##
## [b]The brain decides; the body fires.[/b] Every leaf that may shoot sets [member wants_fire]
## and an aim point; the soldier entity turns that into a held trigger on its zee rig, so
## fire rate, magazine, reload and spread are the weapon's own — a shotgun NPC fires like a
## shotgun because it IS one, and nothing here knows what a shotgun is.
##
## [b]Extended by PATH.[/b] A brain inside a mounted pack cannot name a `class_name`.

const ROLE_FLANK_TACTICS := 0.5

## Set by a leaf when every fire gate is open this tick. Read and cleared by the soldier.
var wants_fire: bool = false

## Where to aim, when [member wants_fire].
var aim_at: Vector3 = Vector3.ZERO

## The entity this brain drives. Set before bind.
var body: Node3D = null

var _cover_until: float = -INF


func _build() -> void:
	tree = DotNpcAiSelector.new(&"root", [
		DotNpcAiLeaf.Action.new(&"flee", func(c: DotNpcAiContext) -> int: return flee_danger(c, _speed() * 1.3)),
		DotNpcAiSequence.reactive_with(&"fight", [
			DotNpcAiLeaf.Condition.new(&"has a target", func(_c: DotNpcAiContext) -> bool: return npc.has_target()),
			DotNpcAiSelector.new(&"engage", [
				DotNpcAiSequence.reactive_with(&"melee", [
					DotNpcAiLeaf.Condition.new(&"melee weapon", func(_c: DotNpcAiContext) -> bool:
						return _is_melee() and claim_attack_slot()),
					DotNpcAiLeaf.Action.new(&"close in", _close_in),
				] as Array[DotNpcAiNode]),
				DotNpcAiSequence.reactive_with(&"break off", [
					DotNpcAiLeaf.Condition.new(&"badly hurt", _should_break_off),
					DotNpcAiLeaf.Action.new(&"to cover", _to_cover),
				] as Array[DotNpcAiNode]),
				DotNpcAiSequence.reactive_with(&"flank", [
					DotNpcAiLeaf.Condition.new(&"flank role", func(_c: DotNpcAiContext) -> bool:
						return not _is_melee() and tactics() >= ROLE_FLANK_TACTICS and claim_role(ROLE_FLANK, 1)),
					DotNpcAiLeaf.Action.new(&"go round", _flank),
				] as Array[DotNpcAiNode]),
				DotNpcAiLeaf.Action.new(&"suppress", _suppress),
			] as Array[DotNpcAiNode]),
		] as Array[DotNpcAiNode]),
		DotNpcAiLeaf.Action.new(&"search", func(c: DotNpcAiContext) -> int: return search(c, _speed() * 0.7)),
		DotNpcAiLeaf.Action.new(&"follow", _follow_owner),
		DotNpcAiLeaf.Action.new(&"patrol", func(c: DotNpcAiContext) -> int: return patrol_hot(c, _speed() * 0.5)),
		DotNpcAiLeaf.Action.new(&"hold", func(_c: DotNpcAiContext) -> int:
			halt()
			return DotNpcAiNode.Status.RUNNING),
	] as Array[DotNpcAiNode])


func _speed() -> float:
	return tune(&"speed", 4.5)


func _is_melee() -> bool:
	return body != null and bool(body.call("holds_melee"))


func _muzzle() -> Vector3:
	return body.call("muzzle") if body != null else npc.position()


## Opens the trigger for this tick if every gate in `ready_to_fire` is open.
func _consider_firing() -> void:
	if body == null or not bool(body.call("is_armed")):
		return

	var muzzle := _muzzle()

	if ready_to_fire(muzzle, 14.0):
		wants_fire = true
		aim_at = aim_solution(muzzle)


func _close_in(ctx: DotNpcAiContext) -> int:
	var at := target_position(Vector3.INF)

	if at == Vector3.INF:
		return DotNpcAiNode.Status.FAILURE

	var flat := at - npc.position()
	flat.y = 0.0

	if flat.length() > tune(&"reach", 1.6):
		if has_reacted():
			steer_with_spacing(at, _speed(), ctx.delta)
		else:
			halt()
	else:
		halt()

	face(at - npc.position())

	if flat.length() <= tune(&"reach", 1.6) + 0.4:
		_consider_firing()

	return DotNpcAiNode.Status.RUNNING


func _should_break_off(ctx: DotNpcAiContext) -> bool:
	var careful := character.self_preservation if character != null else 0.5

	if ctx.has_condition(DotNpcAiConditions.HEAVY_DAMAGE) and careful >= 0.3:
		_cover_until = ctx.now + 3.0

	return ctx.now < _cover_until


func _to_cover(ctx: DotNpcAiContext) -> int:
	var status := take_cover(ctx, _speed())
	_consider_firing()
	return DotNpcAiNode.Status.RUNNING if status != DotNpcAiNode.Status.FAILURE else status


func _flank(ctx: DotNpcAiContext) -> int:
	var center := target_position(Vector3.INF)

	if center == Vector3.INF:
		return DotNpcAiNode.Status.FAILURE

	var here := npc.position()
	var radius := (tune(&"near", 8.0) + tune(&"far", 16.0)) * 0.5
	var point := DotNpcAiTactics.ring_point(center, here, radius, _enemy_facing(center), flank_lead)
	var flat := point - here
	flat.y = 0.0

	if flat.length() > 1.0:
		steer_with_spacing(point, _speed(), ctx.delta)
	else:
		halt()

	face(center - here)
	_consider_firing()
	return DotNpcAiNode.Status.RUNNING


func _suppress(ctx: DotNpcAiContext) -> int:
	var status := hold_range(ctx, _speed(), tune(&"near", 8.0), tune(&"far", 16.0))
	_consider_firing()
	return status


## A friendly NPC keeps near the player who spawned it when there is nobody to fight.
## FAILURE for a hostile one, or one with nobody to follow, which hands on to the patrol.
func _follow_owner(ctx: DotNpcAiContext) -> int:
	if tune(&"follow", 0.0) <= 0.0 or npc.owner_id == &"":
		return DotNpcAiNode.Status.FAILURE

	var owner_at := target_position_of(npc.owner_id)

	if owner_at == Vector3.INF:
		return DotNpcAiNode.Status.FAILURE

	var flat := owner_at - npc.position()
	flat.y = 0.0

	if flat.length() > 4.0:
		steer_with_spacing(owner_at, _speed(), ctx.delta)
	else:
		halt()
		face(flat)

	return DotNpcAiNode.Status.RUNNING


func target_position_of(id: StringName) -> Vector3:
	if director == null or not director.has_method(&"candidate_position"):
		return Vector3.INF

	var found: Variant = director.call(&"candidate_position", id, Vector3.INF)
	return found if found is Vector3 else Vector3.INF
