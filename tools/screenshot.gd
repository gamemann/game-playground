extends SceneTree

## Renders a playground map to PNGs so a person can look at it.
##
## [b]A map is a rendered thing, and this family has shipped a 0 x 0 Control twice and a
## black screen once.[/b] Every other check on a map here is an assertion about a list of
## boxes, and a list of boxes passes just as happily when they are all in the same place
## — or when a pillar is standing where the player spawns, which is a real bug this map
## had and which no count caught.
##
##   xvfb-run -a godot --path . --script tools/screenshot.gd -- --map pg_lobby
##
## Needs a real rendering context, so it does NOT run under `--headless`; `xvfb-run` is
## how it runs on a machine with no display. It writes into `screenshots/`, which is
## gitignored — the frame is evidence for a review, not an asset.

const OUT_DIR := "screenshots"

const MAPS := {
	"pg_lobby": "res://maps/pg_lobby.tscn",
	"pg_surf_intro": "res://maps/pg_surf_intro.tscn",
	"pg_bhop_intro": "res://maps/pg_bhop_intro.tscn",
}

var _shots: Array[Dictionary] = []
var _index := 0
var _camera: Camera3D = null


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--map")
	var id := args[index + 1] if index >= 0 and index + 1 < args.size() else "pg_lobby"

	if not MAPS.has(id):
		push_error("no such map: %s. Known: %s" % [id, str(MAPS.keys())])
		quit(1)
		return

	var scene: Resource = load(MAPS[id])

	if not (scene is PackedScene):
		push_error("%s is not a PackedScene" % MAPS[id])
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	root.add_child((scene as PackedScene).instantiate())

	# The map builds its own sun, but not a sky or any ambient light — a server has no
	# use for either. Without them every surface facing away from the sun is pure black,
	# which is a screenshot that says nothing about the shape of anything.
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = Sky.new()
	environment.sky.sky_material = ProceduralSkyMaterial.new()
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.6
	env.environment = environment
	root.add_child(env)

	_camera = Camera3D.new()
	_camera.fov = 70.0
	_camera.far = 800.0
	root.add_child(_camera)

	_shots = _shots_for(id)


## Angles per map, because a 200 m sandbox with two courses in opposite corners has
## nothing useful to say from one camera.
func _shots_for(id: String) -> Array[Dictionary]:
	if id == "pg_bhop_intro":
		# Two routes, and the frames have to show they ARE two: the main run down x = 0
		# and the narrows six metres up at x = 28. An overview from straight above shows
		# neither the height between them nor the narrowing, so both of these are shot
		# from off to one side and low.
		return [
			# Both routes at once, from beside and above the start. The one angle that
			# shows the narrows to be a separate course rather than a wider shoulder of
			# the main one.
			{
				"name": "pg_bhop_intro_overview",
				"from": Vector3(108.0, 54.0, 52.0),
				"at": Vector3(14.0, -2.0, -62.0),
			},
			# Down the narrows from behind its start pad, at a player's height. This is
			# the frame that says whether the narrowing reads: ten blocks going away
			# from the camera, each one a little less wide than the last.
			{
				"name": "pg_bhop_intro_narrows",
				"from": Vector3(28.0, 9.5, 26.0),
				"at": Vector3(28.0, 5.0, -46.0),
			},
			# Square across both routes, from just above the narrows' height. Nearly
			# perpendicular on purpose: from any angle down the length the two courses
			# overlap in the frame and the higher one reads as the far side of the
			# lower. This is the frame that shows there are six metres between them.
			{
				"name": "pg_bhop_intro_both",
				"from": Vector3(86.0, 11.0, -34.0),
				"at": Vector3(0.0, 3.0, -38.0),
			},
			# Bonus 2, the switchback: three legs climbing west-east-west up to the
			# finish at 9 m. From the south and well above, looking down at forty
			# degrees. [b]The first attempt was from the south-west at twenty
			# degrees and 47 m out[/b], and a 3 m block at that range and angle is a
			# sliver on the horizon: the route was a smudge beside the main run's
			# much bigger blocks. Down at it is the only angle where the three legs
			# and both turns are separate things.
			{
				"name": "pg_bhop_intro_switchback",
				"from": Vector3(-36.0, 27.0, -12.0),
				"at": Vector3(-36.5, 4.0, 4.0),
			},
			# The first turn from beside it, at the height of the leg it turns onto:
			# the frame that says whether a turning block reads as a turn rather than
			# as one more block in a line.
			{
				"name": "pg_bhop_intro_switchback_turn",
				"from": Vector3(-58.0, 9.0, 18.0),
				"at": Vector3(-42.0, 4.0, 4.0),
			},
			# Bonus 3, the ascent: four jumps onto blocks and four ramps up off them,
			# climbing from 2 m to 10 m along z at x = 60. From square beside it and a
			# little above the top, because the thing the frame has to show is the
			# PROFILE — each ramp steeper than the last — and from any angle down the
			# route the ramps foreshorten into the blocks.
			{
				"name": "pg_bhop_intro_ascent",
				"from": Vector3(100.0, 8.0, -22.0),
				"at": Vector3(60.0, 6.0, -22.0),
			},
			# And from behind the pad at a player's height: what a player sees before
			# the first jump, a green pad, a gap, and the first ramp going up.
			{
				"name": "pg_bhop_intro_ascent_start",
				"from": Vector3(60.0, 5.5, 17.0),
				"at": Vector3(60.0, 4.0, -20.0),
			},
		]

	if id == "pg_surf_intro":
		# Two routes, and they are at right angles to each other in what they ask for:
		# the main valley runs 220 m down x = 0 with its descent in the floor between
		# the ramps, and the plunge is one 48 m face at x = 60 that drops 61 m. An
		# overview from above shows the valley and makes the plunge read as a wall, so
		# two of these three are shot from beside it and low.
		return [
			# Both routes at once, from beside and above the start pads.
			{
				"name": "pg_surf_intro_overview",
				"from": Vector3(148.0, 78.0, 84.0),
				"at": Vector3(20.0, -6.0, -78.0),
			},
			# Square across the plunge, from the height of its middle. The frame that
			# says whether a 52° face reads as something you fall DOWN rather than
			# something you fall OFF — from any angle along the run it is a line.
			{
				"name": "pg_surf_intro_plunge",
				"from": Vector3(138.0, 44.0, -20.0),
				"at": Vector3(60.0, 2.0, -30.0),
			},
			# Over the shoulder of somebody on the pad, looking down the route. NOT
			# from eye height ON the pad: a face that falls away in front of you is
			# invisible from standing on the lip, so that frame is a green rectangle
			# and says nothing about the map. Raised and set back instead, which is
			# the angle that shows the pad, the lip and the whole descent at once.
			{
				"name": "pg_surf_intro_plunge_eye",
				"from": Vector3(96.0, 50.0, 30.0),
				"at": Vector3(60.0, 9.0, -30.0),
			},
			# Bonus 2, the cascade: eleven jumps down a slalom of blocks at x = -60,
			# from 40 m to 26 m over 70 m of Z. Square beside it from the west, a little
			# above its middle, because the thing this frame has to show is the PROFILE
			# — every block lower than the last — from above at forty-five degrees, so the
			# block tops read too. [b]The first angle was from above and
			# behind the pad[/b], which put the main run's 220 m ramp across the whole
			# background and made the staircase a scatter of tiles in front of it.
			{
				"name": "pg_surf_intro_cascade",
				"from": Vector3(-94.0, 62.0, -28.0),
				"at": Vector3(-60.0, 30.0, -28.0),
			},
			# From over the backstop and above a player's head: the staircase falling
			# away in front of them, which is the first thing a player on bonus 2 sees.
			# Over the backstop, not behind it — from behind it the frame is a wall.
			{
				"name": "pg_surf_intro_cascade_start",
				"from": Vector3(-60.0, 48.0, 16.0),
				"at": Vector3(-60.0, 30.0, -30.0),
			},
		]

	if id != "pg_lobby":
		return [
			{"name": "%s_overview" % id, "from": Vector3(-90, 70, 90), "at": Vector3(0, 8, 0)},
			{"name": "%s_eye" % id, "from": Vector3(-20, 4, 30), "at": Vector3(0, 6, 0)},
		]

	# The middle of the jump course, which moved when the course grew from nine
	# platforms to twelve: it now runs from z = 56 to z = -20 and climbs to 16 m, so a
	# camera aimed at the old midpoint looked at the first third of it and cut the
	# climb off at the top of the frame.
	var course := Vector3(60.0, 11.0, 14.0)
	var tower := Vector3(-60.0, 7.0, 60.0)

	return [
		# The whole plate, so the two courses can be seen to be in opposite corners and
		# the middle can be seen to be empty, which is what a sandbox is for.
		{"name": "pg_lobby_overview", "from": Vector3(-150, 130, 150), "at": Vector3(0, 4, 0)},
		# Eye level in the middle, which is where a player actually stands.
		{"name": "pg_lobby_eye", "from": Vector3(-10, 2.0, 20), "at": Vector3(20, 6, -10)},
		# Bonus 1: the jump course, along its length.
		{"name": "pg_lobby_course", "from": Vector3(86, 26, 72), "at": course},
		# Bonus 2: the tower, from above its top and well out from it.
		#
		# [b]Both parts matter and the first attempt got both wrong.[/b] From below, the
		# spiral's far side is hidden behind the pillar and the sandbox wall cuts the
		# frame in half at exactly the height the platforms are; from close in, a 70
		# degree lens puts the top of the tower off the top of the picture. Looking
		# DOWN at it from outside is the only angle that shows a spiral to be a spiral
		# rather than a scattering of slabs.
		{"name": "pg_lobby_tower", "from": Vector3(-36, 21, 84), "at": tower},
		# The tower's base at eye height, from just off the pad.
		#
		# Shot from BESIDE it rather than from the spawn point looking along the course.
		# From the spawn, a dev-textured spiral is a few identical slabs against the sky
		# with nothing to give them a scale — which is honestly what a player sees and
		# is useless as evidence. From the side, the pad, the pillar and the first turn
		# are all in one frame and a person can tell whether the first jump is a jump.
		{"name": "pg_lobby_tower_eye", "from": Vector3(-72, 5.0, 48), "at": Vector3(-59, 6.0, 61)},

		# Bonus 3, the circuit. Two angles, because the two things worth looking at are
		# opposite: whether the lap reads as a closed loop round the whole plate (from
		# high above the corner), and whether the road reads as a road at a driver's
		# height (down the start/finish straight, from the grid).
		{"name": "pg_lobby_circuit", "from": Vector3(-120, 105, 130), "at": Vector3(0, 0, 30)},
		{"name": "pg_lobby_circuit_grid", "from": Vector3(-26, 3.0, 82), "at": Vector3(40, 2.0, 82)},

		# Bonus 4, the stepping stones: ten columns at z = -56 from x 15 to 54, shrinking
		# from 2 m across to 1 m. From the north and above, square to the line, so the
		# shrinking and the sway either side of the line both read; and from behind the
		# pad and off to one side at a little over head height: straight down the line the
		# columns stand behind each other and read as one.
		{"name": "pg_lobby_stones", "from": Vector3(34, 16, -34), "at": Vector3(34, 3.0, -56)},
		{"name": "pg_lobby_stones_start", "from": Vector3(5, 9.0, -49), "at": Vector3(30, 4.0, -57)},
	]


var _wait := 0
var _armed := false


## [b]Frame-counted rather than awaited.[/b] `SceneTree._process` is expected to return a
## bool synchronously; making it a coroutine returns a signal object instead, which is
## truthy, so the tree quits on the first frame and writes nothing. That is what
## game-arena's first version of this file did and the reason its comment says so.
func _process(_delta: float) -> bool:
	if _index >= _shots.size():
		return true

	if _wait > 0:
		_wait -= 1
		return false

	if not _armed:
		var shot: Dictionary = _shots[_index]
		_camera.position = shot["from"]
		_camera.look_at(shot["at"], Vector3.UP)
		_armed = true
		# Three frames before grabbing. The viewport's texture is the last COMPLETED
		# frame, so grabbing in the same frame the camera moved saves the previous shot
		# under the new shot's name — which looks exactly like a camera that did not
		# move.
		_wait = 3
		return false

	var image := root.get_texture().get_image()
	var path := OUT_DIR.path_join("%s.png" % _shots[_index]["name"])
	image.save_png(path)
	print("wrote %s (%d x %d)" % [path, image.get_width(), image.get_height()])

	_index += 1
	_armed = false
	return false
