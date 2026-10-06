extends "playground_tool.gd"

## Lets two props pass through each other: left click the first, then the second. Reload
## puts their collision back.


func _init() -> void:
	id = &"nocollide"
	display_name = "No-collide"
	description = "Two props stop colliding with each other, and only with each other."
	help_primary = "first prop, then the second"
	help_reload = "collide with everything again"
	super()


func primary(gun: Object, hit: Dictionary) -> DotResult:
	var body := rigid_body(hit)

	if body == null:
		pending = {}
		return nothing_there()

	if pending.is_empty():
		pending = {"body": body}
		return DotResult.success("first")

	var first: RigidBody3D = pending.get("body")
	pending = {}

	if not is_instance_valid(first):
		return DotResult.fail(DotError.CODE_STATE, "The first prop has gone.")

	var allowed: DotResult = gun.call("may_constrain")

	if not allowed.ok:
		return allowed

	return gun.call("constraints").nocollide(gun.get("wielder"), first, body)


func reload(gun: Object, hit: Dictionary) -> DotResult:
	var body := rigid_body(hit)

	if body == null:
		return nothing_there()

	return DotResult.success(gun.call("constraints").remove_on(body, 1))
