extends RefCounted

## One mode of the tool gun: what left click, right click and reload do, and its settings.
##
## [b]A mode is a script, named by path, for the reason a weapon and an entity are[/b] — a
## mounted pack's `class_name` globals do not exist in the host, so anything a pack adds has
## to be found by where it is. The tool gun holds one of each and swaps between them; a
## mode keeps no state of its own beyond a pending first click, so swapping is free.
##
## [b]A mode never decides who may touch what.[/b] The gun has already asked the host's
## ownership question before a mode sees a hit — the same division dot-props' tools make.
##
## Settings are a schema the menu draws controls from and a dictionary the client sends.
## The server takes only keys the schema names and clamps every number to it, because
## settings arrive from a client and a resize step of a million is a crashed server.

# No CHANNEL: a mode reports through the DotResult it returns, which the gun shows the
# player. What a mode changes in the world is logged where the world changes.

## Stable id: what the client sends and the menu files it under.
var id: StringName = &""
var display_name: String = ""
var description: String = ""

## One line per button, for the HUD. Empty means the button does nothing.
var help_primary: String = ""
var help_secondary: String = ""
var help_reload: String = ""

## The current values, by key. Filled from [method schema]'s defaults on construction.
var settings: Dictionary = {}

## A first click waiting for a second — a weld or a rope is two clicks. Empty when none.
var pending: Dictionary = {}


func _init() -> void:
	for field in schema():
		settings[field["key"]] = field["default"]


## The settings this mode has, as
## `[{key, label, type: "float" | "bool" | "colour" | "choice", default, min, max, step, options}]`.
func schema() -> Array[Dictionary]:
	return []


## Takes [param incoming] where the schema allows it, clamped; ignores the rest.
func apply_settings(incoming: Dictionary) -> void:
	for field in schema():
		var key: String = field["key"]

		if not incoming.has(key):
			continue

		var value: Variant = incoming[key]

		match str(field["type"]):
			"float":
				if value is float or value is int:
					settings[key] = clampf(float(value), float(field["min"]), float(field["max"]))
			"bool":
				settings[key] = bool(value)
			"colour":
				if str(value) != "" and Color.html_is_valid(str(value)):
					settings[key] = str(value)
			"choice":
				if (field["options"] as Array).has(str(value)):
					settings[key] = str(value)


func setting(key: String) -> Variant:
	return settings.get(key)


## Left click. [param hit] is the gun's trace — see `swep_toolgun.gd`.
func primary(_gun: Object, _hit: Dictionary) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This tool does nothing on left click.")


func secondary(_gun: Object, _hit: Dictionary) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This tool does nothing on right click.")


func reload(_gun: Object, _hit: Dictionary) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This tool does nothing on reload.")


## Forgets a half-made two-click action. Called when the mode is swapped away from.
func cancel() -> void:
	pending = {}


func help_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if help_primary != "":
		out.append("LMB  %s" % help_primary)
	if help_secondary != "":
		out.append("RMB  %s" % help_secondary)
	if help_reload != "":
		out.append("R    %s" % help_reload)

	return out


func describe() -> Dictionary:
	return {"tool": String(id), "settings": settings.duplicate(), "pending": not pending.is_empty()}


# --- Helpers for modes ----------------------------------------------------------

## The playground prop a hit landed on, if it is one — a crate, an NPC, a balloon; not a
## vehicle, which is built differently and refuses a resize or a paint.
static func prop_body(hit: Dictionary) -> RigidBody3D:
	var body: Variant = hit.get("body")

	if body is RigidBody3D and is_instance_valid(body) and (body as Node).has_method("set_size_scale"):
		return body

	return null


## Any rigid body a hit landed on, vehicles included. What a weld or a rope ties.
static func rigid_body(hit: Dictionary) -> RigidBody3D:
	var body: Variant = hit.get("body")
	return body if body is RigidBody3D and is_instance_valid(body) else null


static func nothing_there() -> DotResult:
	return DotResult.fail(DotError.CODE_STATE, "Point at a prop.")
