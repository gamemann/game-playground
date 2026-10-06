extends "playground_tool.gd"

## Removes what it points at. Right click removes it and everything welded or roped to it —
## a whole contraption in one click, which is what anybody who built one wants when it is
## time for it to go.


func _init() -> void:
	id = &"remover"
	display_name = "Remover"
	description = "Removes a prop. Right click removes it and everything tied to it."
	help_primary = "remove"
	help_secondary = "remove it and everything tied to it"
	help_reload = "remove its constraints only"
	super()


func primary(gun: Object, hit: Dictionary) -> DotResult:
	var prop: Variant = hit.get("prop")

	if not (prop is DotPropInstance):
		return nothing_there()

	gun.get("spawner").remove((prop as DotPropInstance).instance_id, DotPropSpawner.REASON_PLAYER)
	return DotResult.success(1)


func secondary(gun: Object, hit: Dictionary) -> DotResult:
	var prop: Variant = hit.get("prop")

	if not (prop is DotPropInstance):
		return nothing_there()

	var spawner: DotPropSpawner = gun.get("spawner")
	var removed := 0

	for body in gun.call("constraints").joined_to((prop as DotPropInstance).node):
		var other := spawner.prop_for_node(body)

		# Only what the wielder may touch: a contraption tied to somebody else's crate
		# loses its own half, not theirs.
		if other != null and bool(gun.call("may_touch", other)):
			if spawner.remove(other.instance_id, DotPropSpawner.REASON_PLAYER):
				removed += 1

	return DotResult.success(removed)


func reload(gun: Object, hit: Dictionary) -> DotResult:
	var body := rigid_body(hit)

	if body == null:
		return nothing_there()

	return DotResult.success(gun.call("constraints").remove_on(body))
