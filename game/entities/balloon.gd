extends "playground_entity.gd"

## A balloon: a light sphere that pulls upward with [member lift] newtons, forever.
##
## A force rather than negative gravity, so the lift is the same number whatever the
## balloon weighs and "enough of them lift a car" is arithmetic a player can do — a car of
## 900 kg needs about 9000 N of balloons. Its string is a rope in [PlaygroundConstraints].

var lift: float = 400.0


func _entity_ready() -> void:
	lift = tune(&"lift", lift)
	# The script arrives after the body is in the tree, so physics processing is not switched on
	# by the engine the way it is for a script that was there at `_ready`.
	set_physics_process(true)
	linear_damp = 0.6
	angular_damp = 2.0


func _physics_process(_delta: float) -> void:
	if not freeze:
		apply_central_force(Vector3.UP * lift)
