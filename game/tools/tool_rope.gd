extends "playground_tool.gd"

## Ties two points together: left click one end, left click the other — a prop or the world.
## The rope is as long as the gap between the clicks plus the slack setting. Reload unties
## every rope on a prop.


func _init() -> void:
	id = &"rope"
	display_name = "Rope"
	description = "Ties two points together with a rope that goes slack and pulls taut."
	help_primary = "first end, then the second (a prop or the world)"
	help_reload = "untie its ropes"
	super()


func schema() -> Array[Dictionary]:
	return [{
		"key": "slack", "label": "Slack (m)", "type": "float",
		"default": 0.5, "min": 0.0, "max": 10.0, "step": 0.25,
	}]


func primary(gun: Object, hit: Dictionary) -> DotResult:
	var body := rigid_body(hit)

	if pending.is_empty():
		if body == null:
			# The first end must be a prop: two ends in the world tie nothing.
			return nothing_there()

		pending = {"body": body, "point": hit["point"]}
		return DotResult.success("first")

	var first: RigidBody3D = pending.get("body")
	var first_point: Vector3 = pending.get("point")
	pending = {}

	if not is_instance_valid(first):
		return DotResult.fail(DotError.CODE_STATE, "The first prop has gone.")

	if body == first:
		return DotResult.fail(DotError.CODE_INVALID, "Tie it to something else.")

	var allowed: DotResult = gun.call("may_constrain")

	if not allowed.ok:
		return allowed

	return gun.call("constraints").rope(
		gun.get("wielder"), first, first_point, body, hit["point"], float(setting("slack"))
	)


func reload(gun: Object, hit: Dictionary) -> DotResult:
	var body := rigid_body(hit)

	if body == null:
		return nothing_there()

	return DotResult.success(gun.call("constraints").remove_on(body, 2))
