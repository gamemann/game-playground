extends "playground_tool.gd"

const PlaygroundZee := preload("../playground_zee.gd")

## Hands an NPC a weapon, or takes it away. Only an NPC that can hold one — a soldier or a
## rebel — and only a weapon an NPC can use: the zee pack's guns and melee, not its thrown
## or explosive ones, which this game does not fly.


func _init() -> void:
	id = &"npc_weapon"
	display_name = "NPC weapon"
	description = "Gives the NPC you point at a weapon. Right click disarms it."
	help_primary = "give it the chosen weapon"
	help_secondary = "take its weapon away"
	super()


func schema() -> Array[Dictionary]:
	var choices := npc_weapon_ids()
	return [{
		"key": "weapon", "label": "Weapon", "type": "choice",
		"default": choices[0] if not choices.is_empty() else "", "options": choices,
	}]


## The weapons an NPC may hold, by the game's weapon id. Read off the pack, so a weapon the
## pack adds is offered without a line here.
static func npc_weapon_ids() -> Array:
	var out: Array = []

	for def in PlaygroundZee.defs():
		if PlaygroundZee.npc_can_use(def):
			out.append(String(def.id))

	return out


func primary(_gun: Object, hit: Dictionary) -> DotResult:
	var body: Variant = hit.get("body")

	if not (body is Node) or not (body as Node).has_method("arm_with"):
		return DotResult.fail(DotError.CODE_STATE, "Point at an NPC that can hold a weapon.")

	return (body as Node).call("arm_with", StringName(str(setting("weapon"))))


func secondary(_gun: Object, hit: Dictionary) -> DotResult:
	var body: Variant = hit.get("body")

	if not (body is Node) or not (body as Node).has_method("arm_with"):
		return DotResult.fail(DotError.CODE_STATE, "Point at an NPC that can hold a weapon.")

	return (body as Node).call("arm_with", &"")
