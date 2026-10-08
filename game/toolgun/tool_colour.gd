extends "playground_tool.gd"

## Paints a prop. Right click copies a prop's colour into the tool; reload takes the paint
## off and gives the prop back its catalogue colour.


const PALETTE := [
	"e05252", "e0a052", "e0d452", "6fbf5a", "4fb8c4", "5276e0", "9a5ae0", "e05ab4",
	"f2f2f2", "9a9a9a", "3a3a3a", "8a5a32",
]


func _init() -> void:
	id = &"colour"
	display_name = "Colour"
	description = "Paints a prop. Right click picks up a prop's colour."
	help_primary = "paint"
	help_secondary = "copy its colour"
	help_reload = "take the paint off"
	super()


func schema() -> Array[Dictionary]:
	return [{
		"key": "colour", "label": "Colour", "type": "colour",
		"default": "5276e0", "options": PALETTE,
	}]


func primary(_gun: Object, hit: Dictionary) -> DotResult:
	var body := prop_body(hit)

	if body == null:
		return nothing_there()

	body.call("set_tint", Color.html(str(setting("colour"))))
	return DotResult.success(setting("colour"))


func secondary(_gun: Object, hit: Dictionary) -> DotResult:
	var body := prop_body(hit)

	if body == null:
		return nothing_there()

	var tint: Color = body.get("tint")
	var colour: Color = tint if tint.a > 0.0 else _own_colour(body)
	settings["colour"] = colour.to_html(false)
	return DotResult.success(settings["colour"])


func reload(_gun: Object, hit: Dictionary) -> DotResult:
	var body := prop_body(hit)

	if body == null:
		return nothing_there()

	body.call("set_tint", Color(0, 0, 0, 0))
	return DotResult.success(null)


static func _own_colour(body: Node) -> Color:
	var def: Variant = body.get("def")

	if def is DotPropDef:
		var raw := str((def as DotPropDef).meta.get("colour", ""))
		if Color.html_is_valid(raw):
			return Color.html(raw)

	return Color.WHITE
