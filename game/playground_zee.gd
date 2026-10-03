extends RefCounted

const PlaygroundPaths := preload("playground_paths.gd")
const PlaygroundWeaponDef := preload("weapons/playground_weapon_def.gd")

## zee-dot-weapons in the sandbox: twenty-seven real weapons beside the three toys.
##
## [b]A second kind of weapon, not a SWEP with a gun painted on.[/b] `PlaygroundWeapon` is a
## prop tool: two edge-triggered buttons and a float delta, run where the input is. A zee
## weapon is dot-weapon's: a held-button command per integer tick, its own cadence, reload
## and ammunition, and an outcome full of shots that the game resolves. Wrapping one in the
## other would throw away the cadence and run the shot on the client, which is a client
## deciding what it hit. So the menu, the shop and the loadout see one list of
## [PlaygroundWeaponDef]s, and `meta.zee` says which machinery is behind an entry.
##
## [b]Named by class, not by path, and that is not the rule broken.[/b] The path rule is for
## this game's OWN scripts, whose `class_name`s a mounted pack never registers. `Zee*` and
## `DotWeapon*` are addons compiled into the host — the client shell carries both — so they
## are registered wherever this runs. mg-smash-copter names them the same way.
##
## [b]A shot hurts only when the arena is on.[/b] A sandbox is not a deathmatch, and a
## weapon pack is not a reason to make it one: with `pg_arena 0` a shot shoves the prop it
## hits — something to do with a gun in a sandbox — and touches nobody. The arena's
## dot-combat resolves the same shot when it is on, through [member PlaygroundNetBridge.shot_fn].

const CHANNEL := "playground.zee"

## Prefixed, because two weapon lists share one id space here and both have a `launcher`.
const ID_PREFIX := "zee_"

## What one point of damage is worth in impulse, against a prop. A pistol's 26 shoves a crate
## about the way a gravity gun's punt does; a sniper's 90 throws a beach ball across the plate.
const IMPULSE_PER_DAMAGE := 0.9

## The menu's categories, from dot-weapon's slots.
const SLOT_CATEGORIES := {
	1: &"melee",
	2: &"sidearms",
	3: &"primaries",
	4: &"heavy",
	5: &"thrown",
}

## One colour per slot, for the generated icon: there is no thumbnail in the pack.
const SLOT_COLOURS := {
	1: Color(0.70, 0.56, 0.40),
	2: Color(0.56, 0.66, 0.80),
	3: Color(0.48, 0.72, 0.52),
	4: Color(0.82, 0.48, 0.40),
	5: Color(0.84, 0.74, 0.36),
}

## The catalogue, built once. Every rig is handed this one rather than building its own.
static var _catalogue: DotWeaponCatalogue = null


static func catalogue() -> DotWeaponCatalogue:
	if _catalogue == null:
		_catalogue = ZeeWeaponPack.catalogue()
	return _catalogue


## The pack, as this game's weapon definitions. Read off the catalogue, so a weapon the pack
## adds arrives in the menu without a line here.
static func defs() -> Array[PlaygroundWeaponDef]:
	var out: Array[PlaygroundWeaponDef] = []
	var cat := catalogue()

	for id: StringName in ZeeWeaponIds.all():
		var weapon := cat.get_def(id)

		if weapon == null:
			continue

		var def := PlaygroundWeaponDef.make(
			StringName(ID_PREFIX + String(id)), weapon.display_name, ""
		)
		def.description = weapon.description
		def.category = SLOT_CATEGORIES.get(weapon.slot, &"zee")
		def.colour = SLOT_COLOURS.get(weapon.slot, Color(0.62, 0.68, 0.78))
		def.meta = {"zee": String(id), "slot": weapon.slot}
		out.append(def)

	return out


static func is_zee(def: PlaygroundWeaponDef) -> bool:
	return def != null and def.meta.has("zee")


static func zee_id(def: PlaygroundWeaponDef) -> StringName:
	return StringName(str(def.meta.get("zee", ""))) if def != null else &""


## Puts a rig on [param player] holding [param def], replacing whatever rig was there.
##
## [param role] is the rig's: SERVER draws nothing, LOCAL draws into [param view_model].
## [param authority] is false only on a connected client, whose rig animates the hands and
## decides nothing — the server's rig is the one whose shots land.
static func arm(
	player: Node3D,
	def: PlaygroundWeaponDef,
	role: ZeeWeaponRig.Role,
	authority: bool,
	tick_rate: int,
	tick: int,
	view_model: Node3D = null
) -> ZeeWeaponRig:
	disarm(player)

	var rig := ZeeWeaponRig.new()
	rig.name = "ZeeWeapons"
	rig.role = role
	rig.authority = authority
	rig.tick_rate = tick_rate
	rig.catalogue = catalogue()
	rig.player_ref = DotNodeRef.of_path(player.get_path())

	if view_model != null:
		rig.view_model_ref = DotNodeRef.of_path(view_model.get_path())

	player.add_child(rig)

	var ready_now := rig.setup()

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "a weapon rig would not set up", {
			"weapon": String(def.id), "why": ready_now.error.message,
		})
		player.remove_child(rig)
		rig.free()
		return null

	var id := zee_id(def)
	var given := rig.give(id)

	if not given.ok:
		DotLog.warn(CHANNEL, "the rig refused a weapon", {
			"weapon": String(id), "why": given.error.message,
		})

	var weapon := rig.arsenal.catalogue.get_def(id)

	if weapon != null:
		var _selected := rig.arsenal.select(weapon.slot, tick)

	player.set("zee_rig", rig)
	return rig


## Takes the rig off [param player], if there is one.
static func disarm(player: Node) -> void:
	if player == null:
		return

	var rig: Variant = player.get("zee_rig")

	if rig is Node and is_instance_valid(rig):
		var node := rig as Node
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		node.queue_free()

	player.set("zee_rig", null)


## A tick's buttons and view as a weapon command.
##
## The same three bits every tool here rides on: USER_0 is fire, USER_1 the alt (a bash),
## USER_2 reload. The slot is the one the rig already holds; this game switches weapons by
## asking for one, not by a slot key. Buttons rather than a [DotFpsCommand] so the offline
## client, which has no command until its controller samples one, builds it the same way.
static func command_for(buttons: int, yaw: float, pitch: float, slot: int) -> DotWeaponCommand:
	var command := DotWeaponCommand.new()
	command.set_button(DotWeaponCommand.BUTTON_ATTACK, (buttons & DotFpsCommand.BUTTON_USER_0) != 0)
	command.set_button(DotWeaponCommand.BUTTON_ALT, (buttons & DotFpsCommand.BUTTON_USER_1) != 0)
	command.set_button(DotWeaponCommand.BUTTON_RELOAD, (buttons & DotFpsCommand.BUTTON_USER_2) != 0)
	command.yaw = yaw
	command.pitch = pitch
	command.slot = slot
	return command


## The slot of the weapon a rig holds, or 0.
static func slot_of(rig: ZeeWeaponRig) -> int:
	if rig == null:
		return 0
	var def := rig.current_def()
	return def.slot if def != null else 0


## Shoves the prop each shot hits. Returns how many it moved.
##
## [b]Through the gravity gun's own ray and ownership test[/b], so a shot can move exactly
## what a punt could: nothing frozen, nothing another player owns unless the server lets
## players touch each other's props. A second answer to "may I move that crate" would be
## a server where you cannot pick somebody's crate up and can shoot it across the map.
static func shove_props(
	player: Node, outcome: DotWeaponOutcome, may_touch_others: bool
) -> int:
	if outcome == null or player == null or not (player is Node3D):
		return 0

	var gun: DotGravGun = player.get("grav_gun")

	if gun == null or not (player as Node3D).is_inside_tree():
		return 0

	var space := (player as Node3D).get_world_3d().direct_space_state
	var moved := 0

	for shot: DotShot in outcome.shots:
		var direction := shot.direction.normalized()
		var reach := gun.reach
		gun.reach = shot.max_range
		var prop := gun.target(space, shot.origin, direction)
		gun.reach = reach

		if prop == null or not gun.may_act_on(prop, may_touch_others).ok:
			continue
		if prop.frozen or not (prop.node is RigidBody3D):
			continue

		var body := prop.node as RigidBody3D
		var damage := maxf(shot.total_damage(), shot.damage * float(maxi(shot.pellet_count, 1)))
		body.apply_central_impulse(direction * damage * IMPULSE_PER_DAMAGE)
		moved += 1

	return moved


## Points zee's art at this game's copy of it: `res://assets/` built in, the mount in a pack.
static func use_this_games_art() -> void:
	ZeeModelCache.set_asset_root(PlaygroundPaths.root())


## Puts zee's art back where a built-in game keeps it, for whatever the shell loads next.
static func release_art() -> void:
	ZeeModelCache.set_asset_root("res://")
