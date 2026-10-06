extends "playground_tool.gd"

## Welds two props into one: left click the first, left click the second. Right click welds
## a prop to the world where it stands. Reload undoes every weld on a prop.


func _init() -> void:
	id = &"weld"
	display_name = "Weld"
	description = "Joins two props rigidly. Right click fixes one to the world."
	help_primary = "first prop, then the second"
	help_secondary = "weld it to the world"
	help_reload = "remove its welds"
	super()


func primary(gun: Object, hit: Dictionary) -> DotResult:
	var body := rigid_body(hit)

	if pending.is_empty():
		if body == null:
			return nothing_there()

		pending = {"body": body, "point": hit["point"]}
		return DotResult.success("first")

	var first: RigidBody3D = pending.get("body")
	pending = {}

	if not is_instance_valid(first):
		return DotResult.fail(DotError.CODE_STATE, "The first prop has gone.")

	if body == first:
		return DotResult.fail(DotError.CODE_INVALID, "Pick a different prop to weld it to.")

	var allowed: DotResult = gun.call("may_constrain")

	if not allowed.ok:
		return allowed

	# The world, if the second click hit the map rather than a prop.
	return gun.call("constraints").weld(gun.get("wielder"), first, body, hit["point"])


func secondary(gun: Object, hit: Dictionary) -> DotResult:
	var body := rigid_body(hit)

	if body == null:
		return nothing_there()

	var allowed: DotResult = gun.call("may_constrain")

	if not allowed.ok:
		return allowed

	return gun.call("constraints").weld(gun.get("wielder"), body, null, hit["point"])


func reload(gun: Object, hit: Dictionary) -> DotResult:
	var body := rigid_body(hit)

	if body == null:
		return nothing_there()

	return DotResult.success(gun.call("constraints").remove_on(body, 0))
