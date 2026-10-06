extends "playground_tool.gd"

## Ties a balloon to whatever it points at — a prop, or the world — that pulls up with the
## lift setting. Right click lets one go untied. Each one counts against `balloons`.


const PALETTE := ["e05252", "e0d452", "6fbf5a", "5276e0", "e05ab4", "f2f2f2"]


func _init() -> void:
	id = &"balloon"
	display_name = "Balloon"
	description = "Ties a balloon on. Enough of them lift a car."
	help_primary = "tie a balloon here"
	help_secondary = "let one go"
	super()


func schema() -> Array[Dictionary]:
	return [
		{"key": "lift", "label": "Lift", "type": "float", "default": 400.0, "min": 50.0, "max": 3000.0, "step": 50.0},
		{"key": "length", "label": "String (m)", "type": "float", "default": 3.0, "min": 0.5, "max": 12.0, "step": 0.5},
		{"key": "colour", "label": "Colour", "type": "colour", "default": "e05252", "options": PALETTE},
	]


func primary(gun: Object, hit: Dictionary) -> DotResult:
	if not hit.has("point"):
		return nothing_there()

	var point: Vector3 = hit["point"]
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	var at := point + normal * 0.4 + Vector3.UP * float(setting("length"))
	var made: DotResult = gun.call("spawn_balloon", at, float(setting("lift")), str(setting("colour")))

	if not made.ok:
		return made

	var balloon: RigidBody3D = made.value
	var body := rigid_body(hit)

	# Tied to the prop, or to the point in the world it was aimed at. Not counted against
	# the constraint limit: the string is part of the balloon, and the balloon is counted.
	return gun.call("constraints").rope(
		gun.get("wielder"), balloon, balloon.global_position - Vector3.UP * 0.6,
		body, point, float(setting("length")) * 0.15, false
	)


func secondary(gun: Object, hit: Dictionary) -> DotResult:
	if not hit.has("point"):
		return nothing_there()

	var point: Vector3 = hit["point"]
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	return gun.call("spawn_balloon", point + normal * 1.0, float(setting("lift")), str(setting("colour")))
