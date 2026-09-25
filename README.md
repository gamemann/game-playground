This is a **sandbox game** built on TMC's **Dot** collection, rather than a piece of it. Spawn things, break things, and find out how much a server puts up with before it complains.

The **Dot** collection is a set of open source Godot 4 assets that provide modular building blocks for games and applications in the TMC ecosystem, covering core functionality, networking, authentication, cloud integration, and more. This project is built out of them, so it doubles as a worked example of what they look like in a real game rather than in a demo.

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## A Sandbox, and Where the Movement Half Meets
**A Godot 4 sandbox in the classic physics-sandbox shape.** Hold Q, pick a prop, an NPC or a weapon, click it and it is yours; pick props up with a physics gun, freeze them, throw them, undo them. Plus map support, and a timer that is not only for surf and bunny-hop maps.

It is two things at once: a game you can play, and the only place the movement half of the `dot-*` family runs together.

## What it uses

| | |
| --- | --- |
| [dot-player-controller](https://github.com/modcommunity/dot-player-controller) | Classic strafe movement: air-strafing, surf, bunny-hopping, styles |
| [dot-timer](https://github.com/modcommunity/dot-timer) | Zones, tracks, stages, styles, records, replays |
| [dot-map](https://github.com/modcommunity/dot-map) | Three maps in one game, with a rotation |
| [dot-props](https://github.com/modcommunity/dot-props) | Spawnable props, a physics gun, a gravity gun |
| [dot-leaderboard](https://github.com/modcommunity/dot-leaderboard) | Boards, ranking points, player statistics |
| [dot-server](https://github.com/modcommunity/dot-server) | A dedicated server: console, RCON, permissions, modules |
| [dot-net](https://github.com/modcommunity/dot-net) | Replication, prediction and the wire every networked system here rides on |
| [dot-inventory](https://github.com/modcommunity/dot-inventory) | The bag: what a player has bought and not yet placed, validated by the server |
| [dot-core](https://github.com/modcommunity/dot-core) | The foundation all of them share |

## Playing it

```bash
godot --path .
```

| | |
| --- | --- |
| **Q** | The spawn menu. **Hold** it to browse and release to close; **tap** it to pin it open |
| **Mouse 1** | The tool's primary: grab and hold with the physics gun, punt with the gravity gun |
| **Mouse 2** | The tool's secondary: freeze what is held, or pull and carry |
| **Wheel** | How far out the physics gun holds a prop |
| **Shift + mouse** | Turn the prop the physics gun is holding |
| **1** / **2** / **3** | Physics gun / gravity gun / cycle the weapons you have |
| **E** | Spawn the prop the menu last armed, again |
| **R** | Unfreeze everything you have frozen |
| **Z** | Undo your last spawn |
| **WASD** | Move, including while the menu is open |
| **Space** | Jump (hold it; auto-hop is on) |
| **Ctrl** | Crouch |
| **T** | Switch track: the sandbox, or the course in the corner of it |
| **Tab** | Cycle style: normal, sideways, half-sideways, backwards, low gravity, prebhop |
| **M** | Next map |
| **C** / **V** | Save a practice checkpoint / go back to one |
| **X** / **B** | Cycle which checkpoint / forget them all |
| **Esc** | Close the menu, or release the mouse |

**Clicking a prop in the menu spawns it**, rather than arming a separate spawn key, and the menu stays open, so a wall is nine clicks rather than nine open-and-closes. Three tabs, `/` to search, and icons drawn from each definition because this project ships no art:

| Tab | |
| --- | --- |
| **Props** | Fourteen, in three categories. Planks, panels, beams and pillars to build with; crates and barrels; balls from a 2 kg beach ball to a 900 kg boulder |
| **Entities** | Four NPCs with scripts: one wanders, one chases you, one hops, one spins and shoves whatever comes near. They are props too, so you can pick one up with the physics gun and punt it |
| **Weapons** | A launcher that fires whatever you have armed, a remover, and an impulse gun that shoves everything nearby |

Entities and weapons are **scripts named by path in the catalogue**, which is what lets a downloaded content pack ship its own, because a mounted `.pck` cannot use `class_name`. See [`CLAUDE.md`](CLAUDE.md).

Saving a checkpoint is free. *Restoring* one costs you the run, and the HUD says **PRACTICE** once it has, which is much better than finding out at the finish line.

## The maps

- **pg_lobby** is the sandbox. A 200-metre plate to build on, a staircase, a walkable ramp and one steep enough to learn to surf on, and out in one corner a twelve-platform jump course with a start line, two splits and a finish. The course is on **bonus 1**, a spiral tower is on **bonus 2**, a driving circuit round the plate is on **bonus 3** and the main track has no timer at all, so building is never timed and the minigame is one **T** away. It is also what says the timer is not a surf-and-bhop thing: nothing about a jump course is a movement genre.
- **pg_surf_intro** is two ramps meeting in a valley. Drop in, hold a strafe, keep your speed to the bottom.
- **pg_bhop_intro** is blocks with gaps that widen. The later ones need the speed you kept from the earlier ones. **The narrows** on bonus 1 keeps the gap and takes the blocks away sideways; **the switchback** on bonus 2 climbs a hillside in three legs joined by two turning blocks, so every leg ends in a quarter turn you have to jump out of; **the ascent** on bonus 3 climbs 8 m in four sections of a jump onto a block and a walk up a ramp too tall to jump, each ramp steeper than the last, from 16 degrees to 40.

## Setting up

Every `dot-*` addon is its own repository. For local development, symlink them:

```bash
for pair in dot_core:dot-core dot_player_controller:dot-player-controller \
            dot_timer:dot-timer dot_map:dot-map dot_props:dot-props \
            dot_leaderboard:dot-leaderboard dot_ui:dot-ui dot_server:dot-server; do
  ln -s "../../${pair##*:}/addons/${pair%%:*}" "addons/${pair%%:*}"
done
```

A shipped build copies them in instead.

## Running it as a dedicated server

```bash
godot --headless --path . res://examples/dedicated.tscn
```

`server.cfg`:

```
sv_tickrate 100
hostname "surf | playground"
pg_map_seconds 1800
```

The tick rate is the server's, and it reaches the timer and every record filed. See [`CLAUDE.md`](CLAUDE.md). Once connected, an admin draws zones on a map whose author never used this engine the way they always have:

```
pg_zone start          // pick a kind
pg_zone_mark           // stand on one corner
pg_zone_mark           // and the other
pg_zone_save
```

## Configuring the map vote

The vote for the next map is [dot-vote](https://github.com/modcommunity/dot-vote), and the rules in `game/playground_vote.gd` are only this game's defaults. A server owner overrides any of dot-vote's settings without touching code, in `user://cfg/playground_vote.json`, then `DOT_VOTE_*`, then `--vote-*` — later wins — or, on a TMC server, under `metadata: map_vote:` in the game's `game.yml`. A file that does not validate is refused whole and the defaults stand, with the reason in the log.

The end-of-map vote and the option to extend the current map:

```json
{ "end_vote": true, "vote_lead_sec": 120, "include_extend": true, "extend_seconds": 900, "max_extends": 4 }
```

`end_vote: false` turns the end-of-map ballot off (the map still ends, on the rotation); `include_extend: false` takes "extend" off the ballot; `extend_seconds` is how much one extension adds and `max_extends` how many there may be. Every setting is in dot-vote's README, and its `docs/parity.md` maps the long-standing community map-chooser plugins' settings onto them.

## What you carry

With `pg_shop 1` on, a server has prices, and the bag is what sits between the spawn menu and the shop: a 10 × 6 grid with a 400 kg limit, one cell per small prop. Buying into it charges once; spawning something you carry is free and takes it out; a purchase that would not fit, by weight or by room, is refused before anybody is charged. Spawning something you do not carry is charged only once it exists, so a spawn the prop limit refuses costs nothing. An admin can put things in it with `pg_give <player> <prop> [count]` and read it with `pg_inv <player>`.

It is networked the way every inventory should be and few are: the client moves things in its own bag at once, sends each move as an op with a sequence number, and the server says yes or no. A no springs that move back and keeps every move made after it; a move the network lost is rolled back too, and a client with an answer overdue asks for the whole bag. What the server changes — a purchase, a spawn, an admin's give — arrives as the whole bag, to the owner and nobody else. A player who reconnects gets it back whole, when the server has an identity stack to recognise them by. [`CLAUDE.md`](CLAUDE.md) says why each piece is shaped the way it is.

**There is no screen for it yet**, and no key that buys into it: the wire, the server's rules and the client's copy are all in place and checked over a real socket, and dot-inventory's `DotInvPanel` is the grid that would sit on top.

## Validating

```bash
godot --headless --path . --import
godot --headless --path . --script tools/export_zones.gd
godot --headless --path . res://examples/headless_playground.tscn   # 382 checks
godot --headless --path . res://examples/headless_net.tscn          # 255 checks over 27 sections
godot --headless --path . res://examples/dedicated.tscn             # 214 checks over 24 sections
godot --headless --path . res://examples/headless_presentation.tscn #  89 checks
godot --headless --path . res://examples/headless_stack.tscn        #  40 checks
```

An administrator's `blind <player> [on|off|seconds]` blacks out that player's own screen and nobody else's, and `beacon <player> [on|off]` puts a pulsing ring, a column through walls and a ping on every screen until it is turned off. Both outlive a respawn. `tools/screenshot_views.sh` renders both.

The headless suite boots the whole game, drives a bot down the surf map, finishes and files a run, ranks it, spawns props and builds their bodies from their definitions, spawns NPCs and watches one walk toward the player, fires a weapon loaded from a script path, opens the spawn menu on a real screen stack and clicks through all three tabs, runs the sandbox's course, falls off it, and changes the map underneath all of it. It has found nine real bugs, three of them in other repositories; a screenshot found three more that no assertion could have. See [`CLAUDE.md`](CLAUDE.md).

## Licence

MIT. See [LICENSE](LICENSE).
