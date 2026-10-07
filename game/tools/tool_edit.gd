extends "playground_tool.gd"

## Select a prop, then change it: left click picks one, and from then on the Q menu's
## settings ARE that prop — its size, its paint, whether it is frozen, its gravity, weight,
## friction and bounce. Moving a slider changes the prop as it moves. Right click lets go of
## it; reload puts all of it back to the catalogue's own.
##
## [b]The settings are read off the prop when it is picked, and sent back to the client.[/b]
## The menu sends the whole settings dictionary on every change, not the one key that moved,
## so a menu still holding the last prop's numbers (or the defaults) would write all of them
## over the new prop the first time any slider was touched. Picking answers with the prop's
## real values ([method selection_report]), and the client puts them into the menu first.
##
## [b]Every other mode's settings say what the NEXT click will do; this one's say what the
## selected prop IS.[/b] That is why it overrides [method apply_settings] rather than reading
## its settings in [method primary]: a change is applied when it arrives. Swapping to another
## mode lets go of the selection ([method cancel]), so settings sent while switching back to
## this mode never land on a prop picked minutes ago.
##
## Freezing asks the same two questions the physics gun's right click does — the
## definition's `can_freeze` and the spawner's `may_freeze` limit — and unfreezing asks
## neither, as there. A refusal leaves the prop as it was and is said in the report, so
## the client's tick box springs back.

const PlaygroundProp := preload("../playground_prop.gd")
const ToolColour := preload("tool_colour.gd")
const ToolPhysprop := preload("tool_physprop.gd")

## The prop being edited, or null.
var selected: DotPropInstance = null

## The gun that picked it, weakly: the gun holds this mode, so a strong reference back
## would be a cycle neither ever frees.
var _gun_ref: WeakRef = null

## Why the last change was not made in full, or empty. Read once by [method selection_report].
var _refused: String = ""


func _init() -> void:
	id = &"edit"
	display_name = "Edit properties"
	description = "Click a prop, then change it here: size, colour, freeze, gravity, weight, friction, bounce."
	help_primary = "select"
	help_secondary = "deselect"
	help_reload = "back to its own"
	super()


func schema() -> Array[Dictionary]:
	return [
		{"key": "size", "label": "Size ×", "type": "float", "default": 1.0,
			"min": PlaygroundProp.MIN_SCALE, "max": PlaygroundProp.MAX_SCALE, "step": 0.05},
		{"key": "colour", "label": "Colour", "type": "colour", "default": "", "options": _palette()},
		{"key": "frozen", "label": "Frozen", "type": "bool", "default": false},
		{"key": "gravity", "label": "Gravity", "type": "bool", "default": true},
		{"key": "weight", "label": "Weight ×", "type": "float", "default": 1.0, "min": 0.1, "max": 10.0, "step": 0.1},
		{"key": "friction", "label": "Friction", "type": "float", "default": 1.0, "min": 0.0, "max": 2.0, "step": 0.1},
		{"key": "bounce", "label": "Bounce", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0, "step": 0.05},
	]


func primary(gun: Object, hit: Dictionary) -> DotResult:
	var body := prop_body(hit)
	var prop: Variant = hit.get("prop")

	if body == null or not (prop is DotPropInstance):
		return nothing_there()

	selected = prop
	_gun_ref = weakref(gun)
	_refused = ""
	settings = read_from(body)
	return DotResult.success(selection_report())


func secondary(_gun: Object, _hit: Dictionary) -> DotResult:
	cancel()
	return DotResult.success(selection_report())


func reload(gun: Object, hit: Dictionary) -> DotResult:
	# Reload on a prop that is not the selected one picks it first: "put that back" means
	# the thing under the crosshair.
	var prop: Variant = hit.get("prop")

	if prop is DotPropInstance and prop != selected:
		var picked := primary(gun, hit)
		if not picked.ok:
			return picked

	if not _alive():
		return nothing_there()

	var own := {}
	for field in schema():
		own[field["key"]] = field["default"]

	# Its own colour and its own frozen state: reload undoes the edits, it does not drop a
	# pinned wall out of the air.
	own["colour"] = _own_colour(selected.node).to_html(false)
	own["frozen"] = settings.get("frozen", false)
	apply_settings(own)
	return DotResult.success(selection_report())


func cancel() -> void:
	super()
	selected = null
	_gun_ref = null


## Takes the settings as every mode does, then writes them onto the selected prop.
func apply_settings(incoming: Dictionary) -> void:
	super(incoming)

	if not _alive():
		return

	var gun: Object = _gun_ref.get_ref() if _gun_ref != null else null

	# Ownership is asked again on every change, not only when it was picked: the owner may
	# have gone creative since, or the server stopped letting people touch others' props.
	if gun == null or (gun.has_method("may_touch") and not bool(gun.call("may_touch", selected))):
		_refused = "That is not yours any more."
		cancel()
		return

	write_to(selected.node as RigidBody3D, gun)


## What the client is told: which prop (its node, for the bridge to name by net id), what
## it is called, and its settings as they now are. `node` is null when nothing is selected.
func selection_report() -> Dictionary:
	var out := {
		"node": selected.node if _alive() else null,
		"name": selected.def.name_or_id() if _alive() and selected.def != null else "",
		"settings": settings.duplicate(),
		"refused": _refused,
	}
	_refused = ""
	return out


## The prop's properties as this mode's settings.
static func read_from(body: RigidBody3D) -> Dictionary:
	var tint: Color = body.get("tint")
	var material := body.physics_material_override
	return {
		"size": float(body.get("size_scale")),
		"colour": (tint if tint.a > 0.0 else _own_colour(body)).to_html(false),
		"frozen": body.freeze,
		"gravity": body.gravity_scale != 0.0,
		"weight": float(body.get("mass_multiplier")),
		"friction": material.friction if material != null else 1.0,
		"bounce": material.bounce if material != null else 0.0,
	}


## Writes what differs. A resize rebuilds the prop's shape, so a slider dragged over the
## colour row must not rebuild it once per frame.
func write_to(body: RigidBody3D, gun: Object) -> void:
	if body == null or not is_instance_valid(body):
		return

	var now := read_from(body)

	if not is_equal_approx(float(now["size"]), float(settings["size"])):
		settings["size"] = float(body.call("set_size_scale", float(settings["size"])))

	if str(now["colour"]) != str(settings["colour"]) and Color.html_is_valid(str(settings["colour"])):
		var colour := Color.html(str(settings["colour"]))
		# The catalogue's own colour takes the paint off rather than painting it on, so a
		# reload leaves the prop exactly as spawned.
		body.call("set_tint", Color(0, 0, 0, 0) if colour.is_equal_approx(_own_colour(body)) else colour)

	if bool(now["frozen"]) != bool(settings["frozen"]):
		var froze := _may_freeze(gun) if bool(settings["frozen"]) else DotResult.success(null)
		if froze.ok:
			DotPhysGun.set_frozen(selected, bool(settings["frozen"]))
		else:
			_refused = froze.error.message
			settings["frozen"] = now["frozen"]

	var physics_changed := bool(now["gravity"]) != bool(settings["gravity"]) \
		or not is_equal_approx(float(now["weight"]), float(settings["weight"])) \
		or not is_equal_approx(float(now["friction"]), float(settings["friction"])) \
		or not is_equal_approx(float(now["bounce"]), float(settings["bounce"]))

	if physics_changed:
		ToolPhysprop._apply(
			body, bool(settings["gravity"]), float(settings["weight"]),
			float(settings["friction"]), float(settings["bounce"])
		)


func describe() -> Dictionary:
	var out := super.describe()
	out["selected"] = selected.instance_id if _alive() else 0
	return out


func _alive() -> bool:
	return selected != null and selected.is_alive() and selected.node is RigidBody3D \
		and is_instance_valid(selected.node)


func _may_freeze(gun: Object) -> DotResult:
	if selected.def != null and not selected.def.can_freeze:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That cannot be frozen.")

	var spawner: Variant = gun.get("spawner") if gun != null else null
	var wielder: Variant = gun.get("wielder") if gun != null else null

	if spawner is DotPropSpawner and wielder != null:
		return (spawner as DotPropSpawner).may_freeze(StringName(str(wielder)))

	return DotResult.success(null)


static func _own_colour(body: Node) -> Color:
	return ToolColour._own_colour(body)


static func _palette() -> Array:
	return ToolColour.PALETTE

