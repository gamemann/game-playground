extends Node3D

## Where an NPC holds its weapon: the `attachment(mount)` a zee world model hangs from.
##
## A player's weapon hangs off its character rig's hand. An NPC here is a coloured box with
## no rig, so this is a point at its right side, chest high, facing where it faces — and
## every mount the world model might ask for is that one point.


func attachment(_mount: Variant = null) -> Node:
	return self
