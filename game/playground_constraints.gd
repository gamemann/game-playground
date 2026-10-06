extends Node

## Welds, no-collides and ropes between props: what the tool gun builds things with.
##
## [b]Three different mechanisms, chosen for what each has to do.[/b]
##
## - A **weld** is a [Generic6DOFJoint3D] with every axis locked, which is what Godot's
##   solver means by "these two are one body". Welded to the world, it is a joint with only
##   one body in it.
## - A **no-collide** is not a joint at all: a pair of collision exceptions, both ways,
##   because an exception one way still lets the other body's contacts push.
## - A **rope** is a maximum distance, enforced here with impulses every physics step.
##   Godot has no distance joint, and a [PinJoint3D] is a rigid rod — a balloon on a rod
##   is a lollipop. Impulses also give a rope the slack a hand-tied one has, which a joint
##   cannot.
##
## Every constraint has an owner and counts against their `constraints` limit — except a
## balloon's own string, which is part of the balloon and counted as one. A constraint goes
## when either of its props goes; [method forget_body] is called from the prop's removal.

const CHANNEL := "playground.constraints"

const RopeView := preload("playground_rope_view.gd")

enum Kind { WELD, NOCOLLIDE, ROPE }

const KIND_NAMES := {Kind.WELD: "weld", Kind.NOCOLLIDE: "nocollide", Kind.ROPE: "rope"}

## How hard a stretched rope pulls back, as a fraction of the error per step. Below 1 so a
## rope settles rather than snapping a crate back and forth across its length.
const ROPE_BIAS := 0.25


class Constraint:
	extends RefCounted

	var id: int = 0
	var kind: int = 0
	var owner: StringName = &""
	var a: RigidBody3D = null
	## Null when tied to the world.
	var b: RigidBody3D = null
	## On [member a], local.
	var a_local: Vector3 = Vector3.ZERO
	## On [member b], local; or a world point when [member b] is null.
	var b_local: Vector3 = Vector3.ZERO
	var length: float = 0.0
	## Whether it counts against its owner's limit. A balloon's own string does not.
	var counted: bool = true
	var joint: Node = null
	var view: Node = null

	func a_point() -> Vector3:
		return a.to_global(a_local)

	func b_point() -> Vector3:
		return b.to_global(b_local) if b != null else b_local

	func touches(body: Node) -> bool:
		return a == body or b == body


var _items: Dictionary = {}
var _next_id: int = 1

## Whether ropes are drawn here. Off on a server with no display, where nobody looks.
var draw_ropes: bool = DisplayServer.get_name() != "headless"


# --- Making them ----------------------------------------------------------------

## Welds [param a] to [param b] — or to the world when [param b] is null — at [param at].
func weld(owner: StringName, a: RigidBody3D, b: RigidBody3D, at: Vector3) -> DotResult:
	if a == null or a == b:
		return DotResult.fail(DotError.CODE_INVALID, "Weld what to what?")

	var joint := Generic6DOFJoint3D.new()
	joint.name = "Weld"
	# Every linear and angular axis locked at zero, which is the joint's own default and
	# written out because "the default happens to be a weld" is a thing a Godot upgrade
	# is allowed to change.
	for axis in ["x", "y", "z"]:
		joint.set("linear_limit_%s/enabled" % axis, true)
		joint.set("linear_limit_%s/upper_distance" % axis, 0.0)
		joint.set("linear_limit_%s/lower_distance" % axis, 0.0)
		joint.set("angular_limit_%s/enabled" % axis, true)
		joint.set("angular_limit_%s/upper_angle" % axis, 0.0)
		joint.set("angular_limit_%s/lower_angle" % axis, 0.0)

	var host := a.get_parent()
	host.add_child(joint)
	joint.global_position = at
	joint.node_a = joint.get_path_to(a)
	joint.node_b = joint.get_path_to(b) if b != null else NodePath("")

	# A frozen body in a weld is the world to the solver, and a welded thing frozen in
	# mid-air by a physics gun is how a builder makes a fixed point. Wake both, so a weld
	# to a sleeping crate takes effect without the crate being nudged first.
	a.sleeping = false
	if b != null:
		b.sleeping = false

	var c := _add(Kind.WELD, owner, a, b, a.to_local(at), b.to_local(at) if b != null else at, 0.0)
	c.joint = joint
	return DotResult.success(c)


## Stops [param a] and [param b] colliding with each other.
func nocollide(owner: StringName, a: RigidBody3D, b: RigidBody3D) -> DotResult:
	if a == null or b == null or a == b:
		return DotResult.fail(DotError.CODE_INVALID, "No-collide needs two different props.")

	for c in _items.values():
		if (c as Constraint).kind == Kind.NOCOLLIDE and (c as Constraint).touches(a) and (c as Constraint).touches(b):
			return DotResult.fail(DotError.CODE_CONFLICT, "Those two already pass through each other.")

	a.add_collision_exception_with(b)
	b.add_collision_exception_with(a)
	return DotResult.success(_add(Kind.NOCOLLIDE, owner, a, b, Vector3.ZERO, Vector3.ZERO, 0.0))


## Ties [param a] at [param a_at] to [param b] at [param b_at] — or to the world point
## [param b_at] when [param b] is null — with [param slack] metres more than the distance
## between them.
func rope(
	owner: StringName, a: RigidBody3D, a_at: Vector3, b: RigidBody3D, b_at: Vector3,
	slack: float = 0.0, counted: bool = true
) -> DotResult:
	if a == null or a == b:
		return DotResult.fail(DotError.CODE_INVALID, "Tie what to what?")

	var length := a_at.distance_to(b_at) + maxf(slack, 0.0)
	var c := _add(
		Kind.ROPE, owner, a, b, a.to_local(a_at), b.to_local(b_at) if b != null else b_at, length
	)
	c.counted = counted
	_describe_rope_on_props(c)
	return DotResult.success(c)


func _add(
	kind: int, owner: StringName, a: RigidBody3D, b: RigidBody3D,
	a_local: Vector3, b_local: Vector3, length: float
) -> Constraint:
	var c := Constraint.new()
	c.id = _next_id
	_next_id += 1
	c.kind = kind
	c.owner = owner
	c.a = a
	c.b = b
	c.a_local = a_local
	c.b_local = b_local
	c.length = length
	_items[c.id] = c
	DotLog.debug(CHANNEL, "constraint made", {
		"kind": KIND_NAMES[kind], "owner": String(owner), "id": c.id,
	})
	return c


## The rope a client is told about: on the first of its two props with a slot free.
func _describe_rope_on_props(c: Constraint) -> void:
	if _has_rope_slot(c.a):
		_ropes_of(c.a).append({"id": c.id, "peer": c.b, "a": c.a_local, "b": c.b_local, "length": c.length})
	elif c.b != null and _has_rope_slot(c.b):
		_ropes_of(c.b).append({"id": c.id, "peer": c.a, "a": c.b_local, "b": c.a_local, "length": c.length})


## The prop's own list, so appending to it changes the prop. Empty and detached for a body
## that keeps none (a vehicle), which then simply describes nothing.
static func _ropes_of(body: Node) -> Array:
	var value: Variant = body.get("ropes") if body != null else null
	return value if value is Array else []


static func _has_rope_slot(body: Node) -> bool:
	var slots: Variant = body.get("ROPE_SLOTS") if body != null else null
	return body != null and body.get("ropes") is Array and _ropes_of(body).size() < (int(slots) if slots != null else 1)


# --- Taking them away -----------------------------------------------------------

## Removes one constraint.
func remove(c: Constraint) -> void:
	if c == null or not _items.has(c.id):
		return

	_items.erase(c.id)

	if c.joint != null and is_instance_valid(c.joint):
		c.joint.queue_free()

	if c.view != null and is_instance_valid(c.view):
		c.view.queue_free()

	if c.kind == Kind.NOCOLLIDE and is_instance_valid(c.a) and is_instance_valid(c.b):
		c.a.remove_collision_exception_with(c.b)
		c.b.remove_collision_exception_with(c.a)

	if c.kind == Kind.ROPE:
		for body in [c.a, c.b]:
			if body == null or not is_instance_valid(body):
				continue
			var listed := _ropes_of(body)
			for i in range(listed.size() - 1, -1, -1):
				if int((listed[i] as Dictionary).get("id", -1)) == c.id:
					listed.remove_at(i)


## Removes every constraint on [param body], or only those of [param kind] (-1 for all).
## Returns how many went.
func remove_on(body: Node, kind: int = -1) -> int:
	var gone := 0

	for c in _items.values().duplicate():
		var con := c as Constraint

		if con.touches(body) and (kind < 0 or con.kind == kind):
			remove(con)
			gone += 1

	return gone


## Removes everything [param owner] made.
func remove_owned(owner: StringName) -> int:
	var gone := 0

	for c in _items.values().duplicate():
		if (c as Constraint).owner == owner:
			remove(c)
			gone += 1

	return gone


## A prop is going: everything tied to it goes first, while the node is still valid.
func forget_body(body: Node) -> void:
	var _gone := remove_on(body)


# --- Asking ---------------------------------------------------------------------

## How many constraints [param owner] has that count against their limit.
func count_owned(owner: StringName) -> int:
	var total := 0

	for c in _items.values():
		if (c as Constraint).owner == owner and (c as Constraint).counted:
			total += 1

	return total


## The bodies [param body] is joined to by welds and ropes, itself included. What a remover
## clears in one go.
func joined_to(body: Node) -> Array[Node]:
	var out: Array[Node] = [body]
	var queue: Array[Node] = [body]

	while not queue.is_empty():
		var next: Node = queue.pop_back()

		for c in _items.values():
			var con := c as Constraint

			if con.kind == Kind.NOCOLLIDE or not con.touches(next):
				continue

			for other in [con.a, con.b]:
				if other != null and is_instance_valid(other) and not out.has(other):
					out.append(other)
					queue.append(other)

	return out


## Every constraint, each a [Constraint]. A copy: what a saved build reads.
func all_items() -> Array:
	return _items.values()


func on(body: Node, kind: int = -1) -> Array:
	var out: Array = []

	for c in _items.values():
		if (c as Constraint).touches(body) and (kind < 0 or (c as Constraint).kind == kind):
			out.append(c)

	return out


func size() -> int:
	return _items.size()


# --- The ropes ------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	for c in _items.values().duplicate():
		var con := c as Constraint

		if not is_instance_valid(con.a) or (con.b != null and not is_instance_valid(con.b)):
			remove(con)
			continue

		if con.kind != Kind.ROPE:
			continue

		_hold_rope(con, delta)

		if draw_ropes:
			if con.view == null:
				con.view = RopeView.new()
				add_child(con.view)

			(con.view as RopeView).draw_between(con.a_point(), con.b_point(), con.length)


## Pulls the ends of a stretched rope back toward its length. Nothing at all while slack.
##
## Velocity first — whatever the two ends are doing to separate is taken away — then a
## fraction of the stretch as a bias, so a rope that was already too long comes back
## without the whole error landing in one step and flinging the crate.
func _hold_rope(con: Constraint, delta: float) -> void:
	var pa := con.a_point()
	var pb := con.b_point()
	var span := pa - pb
	var distance := span.length()

	if distance <= con.length or distance < 0.0001:
		return

	var along := span / distance
	var inv_a := 0.0 if con.a.freeze else 1.0 / maxf(con.a.mass, 0.001)
	var inv_b := 0.0 if con.b == null or con.b.freeze else 1.0 / maxf(con.b.mass, 0.001)

	if inv_a + inv_b <= 0.0:
		return

	var va := con.a.linear_velocity + con.a.angular_velocity.cross(pa - con.a.global_position)
	var vb := Vector3.ZERO

	if con.b != null:
		vb = con.b.linear_velocity + con.b.angular_velocity.cross(pb - con.b.global_position)

	var separating := (va - vb).dot(along)
	var stretch := distance - con.length
	var wanted := maxf(separating, 0.0) + stretch * ROPE_BIAS / maxf(delta, 0.0001)
	var impulse := wanted / (inv_a + inv_b)

	if inv_a > 0.0:
		con.a.apply_impulse(-along * impulse, pa - con.a.global_position)

	if inv_b > 0.0:
		con.b.apply_impulse(along * impulse, pb - con.b.global_position)


func describe_lines() -> PackedStringArray:
	var counts := {}

	for c in _items.values():
		var name := String(KIND_NAMES[(c as Constraint).kind])
		counts[name] = int(counts.get(name, 0)) + 1

	return PackedStringArray(["constraints: %s" % (str(counts) if not counts.is_empty() else "none")])
