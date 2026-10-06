extends "playground_tool.gd"

## A prop's physics: whether gravity pulls it, how heavy it is, how slippery. Left click
## applies the settings, reload puts the prop's own back.


func _init() -> void:
	id = &"physprop"
	display_name = "Physical properties"
	description = "Gravity on or off, heavier or lighter, grippy or slippery."
	help_primary = "apply"
	help_reload = "back to its own"
	super()


func schema() -> Array[Dictionary]:
	return [
		{"key": "gravity", "label": "Gravity", "type": "bool", "default": true},
		{"key": "weight", "label": "Weight ×", "type": "float", "default": 1.0, "min": 0.1, "max": 10.0, "step": 0.1},
		{"key": "friction", "label": "Friction", "type": "float", "default": 1.0, "min": 0.0, "max": 2.0, "step": 0.1},
		{"key": "bounce", "label": "Bounce", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0, "step": 0.05},
	]


func primary(_gun: Object, hit: Dictionary) -> DotResult:
	var body := prop_body(hit)

	if body == null:
		return nothing_there()

	_apply(body, bool(setting("gravity")), float(setting("weight")), float(setting("friction")), float(setting("bounce")))
	return DotResult.success(null)


func reload(_gun: Object, hit: Dictionary) -> DotResult:
	var body := prop_body(hit)

	if body == null:
		return nothing_there()

	_apply(body, true, 1.0, 1.0, 0.0)
	return DotResult.success(null)


static func _apply(body: RigidBody3D, gravity: bool, weight: float, friction: float, bounce: float) -> void:
	body.gravity_scale = 1.0 if gravity else 0.0
	body.set("mass_multiplier", weight)
	body.call("set_size_scale", float(body.get("size_scale")))
	body.call("refresh_mass")

	# Its own material, never the shared default: editing a prop's slipperiness must not
	# edit every other prop's that happens to share the resource.
	var material := PhysicsMaterial.new()
	material.friction = friction
	material.bounce = bounce
	body.physics_material_override = material
	body.sleeping = false
