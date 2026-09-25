extends Node

const PlaygroundEvents := preload("playground_events.gd")
const PlaygroundInventory := preload("../playground_inventory.gd")

## dot-inventory over dot-net: a client predicts an op, the server decides, and the client
## is told yes or no. Both halves in one file, because each is exactly the other's inverse
## and a reader has to be able to hold both at once.
##
## [b]Before this, no inventory in the family had ever crossed a wire.[/b] `DotInvManager`
## has `send_fn`, `confirm` and `rollback`, and all three had only ever been called by the
## addon's own suite, in one process, with the "server" a second manager in the same scene.
##
## [b]What crosses, and why each piece is shaped the way it is.[/b]
##
## [b]A client sends ops, never state.[/b] dot-inventory's central decision: a diff cannot
## tell "this crate moved" from "this crate was destroyed and an identical one appeared".
## Only MOVE, SPLIT, MERGE and DROP are accepted from a client; an ADD is a client giving
## itself something and a USE is what spawning does, which is the server's to do.
##
## [b]Every op carries a sequence number, and the manager's own matching is not trusted to
## tell two ops apart.[/b] `DotInvManager.confirm` and `rollback` find an op by comparing its
## dictionary, and two ops can be the same dictionary — "drop one of #3", twice. The wire
## needs an identity the content does not have, and a sequence number is also what makes an
## answer CUMULATIVE: acks come back in order on a reliable channel, so an ack for #6 when #5
## is still waiting says #5 never arrived. dot-net drops a request past its per-peer message
## rate without telling anybody, and a predicted op nobody answers would otherwise sit in
## the client's bag for ever, neither confirmed nor rolled back.
##
## [b]A refusal rewinds everything in flight, newest first, and replays what this client
## still believes in.[/b] The rewind is this file's, not `DotInvManager.rollback`'s, and
## that is on purpose rather than a workaround. `rollback(op)` undoes one op and re-applies
## everything predicted after it — which is right for a refusal with nothing lost before it,
## and not for the other case an answer can carry: an answer to #6 while #4 and #5 wait says
## #4 and #5 never arrived, and the client has to take those out and keep #6. Which ops to
## keep is a question about sequence numbers, which the manager has never seen; it names an
## op by its dictionary, and "drop one of #3", twice, is two identical dictionaries. So the
## whole flight is rewound (newest first, which undoes everything whatever the matching
## picks) and the survivors are re-applied here, where each one's number is known.
##
## [b]A change the SERVER makes arrives as the whole bag, not as the op.[/b] dot-inventory
## can now apply a server's op to a predicting manager (`apply_authoritative`, which lands it
## underneath the predictions in flight), and the document is still the better message here:
## it CONVERGES. Every one puts right whatever the client got wrong since the last — an op
## the transport dropped, a replay that diverged — where an op stream carries a divergence
## forward for ever, and nothing on the wire would say so. It coalesces a tick's burst into
## one message. And the join and the resync need the document anyway, so ops would be a
## second path to the same state. It carries the newest sequence number it already includes,
## and the client replays whatever it has sent since on top, so a purchase landing mid-drag
## does not snap the drag back.
##
## [b]Only ever to the owner.[/b] An inventory is private: what somebody has bought and not
## yet placed is a plan, and in an arena it is a loadout. Nothing here is a replicated field
## — so dot-net's interest management never sees it and cannot leak it — and every message
## goes through [method PlaygroundNetBridge._tell], which refuses peer 0 because peer 0 is the
## broadcast address. A bot has a bag and no peer, and is told nothing.
##
## [b]A bag belongs to a person, not to a connection.[/b] dot-server's userid is sequential,
## so a player who reconnects comes back under a new one. The server keys bags by
## [member bag_key_fn] — the pseudonymous per-scope id when there is an identity stack — and
## keeps them across a disconnect; with no identity there is nothing that outlasts a
## session, and the bag goes with it.

const CHANNEL := "pg.net.inventory"

## How long the oldest op may go unanswered before the client asks for the whole bag.
##
## An ack that never comes is a request dot-net dropped at the tail — nothing after it will
## ever say so, because there is nothing after it. Generous, because a slow link answering
## late is not a problem and the cost of guessing wrong is only one extra document.
const RESYNC_AFTER_MS := 3000

## Past this many ops in flight a refusal asks for the bag rather than rolling back.
## `DotInvManager` keeps 64 snapshots, and a rollback that reaches past the oldest finds
## nothing and restores nothing, silently.
const MAX_ROLLBACK := 48

## What a client may ask for. Everything else changes what somebody HAS, and that is the
## server's to decide.
const CLIENT_KINDS: Array[int] = [
	DotInvOp.Kind.MOVE, DotInvOp.Kind.SPLIT, DotInvOp.Kind.MERGE, DotInvOp.Kind.DROP,
]

## Client side: an op this client predicted was refused and has been rolled back.
signal refused(reason: String)

## Client side: the local bag changed — predicted, confirmed, rolled back or replaced.
signal changed()

var inventory: PlaygroundInventory = null
var is_server: bool = false

# --- Server ----------------------------------------------------------------

## [code](peer_id: int, body: PackedByteArray) -> void[/code]. One peer, never peer 0.
var tell_fn: Callable = Callable()

## [code](peer_id: int, text: String) -> void[/code]. A line of text for one player.
var notice_fn: Callable = Callable()

## [code](player_id: StringName, thing_id: StringName) -> DotResult[/code]. The shop.
var charge_fn: Callable = Callable()

## [code](session_id: int) -> String[/code]: who this session IS, for a bag that outlasts it.
## Empty means nobody the server can recognise next time, and the bag is the session's.
var bag_key_fn: Callable = Callable()

## Server-originated changes counted, for a test and for `describe`.
var docs_sent: int = 0
var acks_sent: int = 0

## peer -> the newest sequence number it has sent that the server has processed.
var _last_seq: Dictionary = {}

## bag key -> the peer holding it, while somebody holding it is connected.
var _peer_of_bag: Dictionary = {}

## peer -> the bag key it was admitted with.
##
## [b]Remembered, not recomputed on the way out.[/b] [member bag_key_fn] asks dot-server for
## the session, and by the time a disconnect is being handled the session may already be
## gone — so a key recomputed then comes back as the session's own, the real bag's peer
## mapping is never cleared, and a later change to it is sent to whoever is given that peer
## id next.
var _bag_of_peer: Dictionary = {}

## bag key -> true: changed by the server since its owner was last sent it.
var _dirty: Dictionary = {}

## Set while a CLIENT's op is being applied, so the change it makes is answered with an ack
## and not echoed back as a whole document as well.
var _applying_client := false

# --- Client ----------------------------------------------------------------

## [code](body: PackedByteArray) -> void[/code]. To the server.
var ask_fn: Callable = Callable()

## Milliseconds. A seam so a test can age an op without waiting three seconds.
var now_fn: Callable = func() -> int: return Time.get_ticks_msec()

var _bag_key: StringName = &""
var _seq: int = 0

## What this client has sent and not yet heard about, oldest first:
## [code]{seq, op: Dictionary, at: int, lost: bool}[/code]. [code]lost[/code] marks an op
## that no longer applies locally after a correction — the server will refuse it too, and
## rolling back something that was never applied would restore the wrong snapshot.
var _in_flight: Array[Dictionary] = []
var _replaying := false
var _last_resync_at: int = -RESYNC_AFTER_MS

## Counted, for a test and for `describe`.
var confirmed_count: int = 0
var rolled_back_count: int = 0
var resyncs_asked: int = 0


func bind_server(p_inventory: PlaygroundInventory) -> void:
	inventory = p_inventory
	is_server = true
	if inventory != null:
		inventory.changed.connect(_on_bag_changed)


func bind_client(p_inventory: PlaygroundInventory) -> void:
	inventory = p_inventory
	is_server = false


# --- Server ----------------------------------------------------------------

## The key the bag of [param session_id] is held under.
func bag_key(session_id: int) -> StringName:
	if bag_key_fn.is_valid():
		var key := str(bag_key_fn.call(session_id))
		if key != "":
			return StringName(key)
	return _session_key(session_id)


static func _session_key(session_id: int) -> StringName:
	return StringName("u%d" % session_id)


## A peer is ready: it gets its whole bag, and nothing before that.
##
## [b]At admission and not at join.[/b] Anything sent to a peer before it has said it can
## receive lands on a scene that does not exist yet and is lost — the rule every other
## message in this bridge follows.
func admit(peer_id: int, session_id: int) -> void:
	if not is_server or inventory == null or peer_id <= 0:
		return
	var key := bag_key(session_id)
	_peer_of_bag[key] = peer_id
	_bag_of_peer[peer_id] = key
	_last_seq[peer_id] = 0
	_send_doc(peer_id, key, 0)
	_dirty.erase(key)


## A player left. Their bag is kept if it belongs to somebody the server can recognise
## again, and dropped with the session if not.
func release(peer_id: int, session_id: int) -> void:
	if not is_server or inventory == null:
		return
	var key: StringName = _bag_of_peer.get(peer_id, bag_key(session_id))
	if int(_peer_of_bag.get(key, -1)) == peer_id:
		_peer_of_bag.erase(key)
	_bag_of_peer.erase(peer_id)
	_last_seq.erase(peer_id)
	_dirty.erase(key)
	if key == _session_key(session_id):
		inventory.forget(key)


## Something a client asked about its own inventory.
func on_ask(peer_id: int, session_id: int, reader: DotNetReader) -> void:
	if not is_server or inventory == null or peer_id <= 0 or session_id == 0:
		return
	var key: StringName = _bag_of_peer.get(peer_id, bag_key(session_id))
	match PlaygroundEvents.read_inv_ask(reader):
		PlaygroundEvents.InvAsk.OP:
			var got := PlaygroundEvents.read_inv_op(reader)
			if bool(got["ok"]):
				_server_op(peer_id, session_id, key, int(got["seq"]), got["op"])
		PlaygroundEvents.InvAsk.RESYNC:
			var got := PlaygroundEvents.read_inv_resync(reader)
			if bool(got["ok"]):
				# Everything this peer sent before the RESYNC has been processed — a reliable
				# channel is ordered — so the document reflects all of it, and whatever
				# never arrived is simply not in it.
				var through := maxi(int(_last_seq.get(peer_id, 0)), int(got["seq"]))
				_last_seq[peer_id] = through
				_send_doc(peer_id, key, through)
				_dirty.erase(key)
		PlaygroundEvents.InvAsk.BUY:
			var got := PlaygroundEvents.read_inv_buy(reader)
			if bool(got["ok"]):
				buy(peer_id, session_id, got["item"] as StringName)


func _server_op(peer_id: int, session_id: int, key: StringName, seq: int, op_dict: Dictionary) -> void:
	var last := int(_last_seq.get(peer_id, 0))
	if seq <= last:
		# A sequence number going backwards is a client that is broken or replaying.
		# Answered with nothing: the answer to #seq has already been sent once.
		DotLog.debug(CHANNEL, "an op arrived out of sequence", {
			"peer": peer_id, "seq": seq, "last": last,
		})
		return
	_last_seq[peer_id] = seq

	var op := DotInvOp.from_dictionary(op_dict)
	if not CLIENT_KINDS.has(int(op.kind)):
		_ack(peer_id, seq, false, "that is the server's to do")
		return

	var m := inventory.for_player(key)
	_applying_client = true
	# The actor is the SESSION's player id, from the peer the request arrived on — never
	# anything in the message, which is dot-inventory's rule about `actor`. It is also what
	# the manager's rate limit is keyed on ([constant PlaygroundInventory.OPS_PER_SECOND]),
	# so a flood is refused there and answered here like any other refusal: not dropped,
	# because the client has already applied it and is waiting to hear.
	var res := m.apply(op, _session_key(session_id))
	_applying_client = false

	_ack(peer_id, seq, res.ok, res.error.message if not res.ok and res.error != null else "")


func _ack(peer_id: int, seq: int, accepted: bool, reason: String) -> void:
	if tell_fn.is_valid():
		tell_fn.call(peer_id, PlaygroundEvents.write_inv_ack(seq, accepted, reason))
		acks_sent += 1


## Buys one [param item_id] into the bag of [param session_id].
##
## [b]Checked, then charged, then given — and the check includes room.[/b] See
## [method PlaygroundInventory.may_give]: a purchase that is charged and then refused is
## the one thing a shop must not do.
func buy(peer_id: int, session_id: int, item_id: StringName) -> DotResult:
	if not is_server or inventory == null:
		return DotResult.fail(DotError.CODE_STATE, "no inventory")
	var key: StringName = _bag_of_peer.get(peer_id, bag_key(session_id))
	var may := inventory.may_give(key, item_id)
	if may.ok and charge_fn.is_valid():
		may = charge_fn.call(_session_key(session_id), item_id) as DotResult
	if not may.ok:
		if notice_fn.is_valid() and peer_id > 0:
			notice_fn.call(peer_id, "Cannot buy %s: %s" % [item_id, may.error.message])
		return may
	return inventory.give(key, item_id)


func _on_bag_changed(key: StringName) -> void:
	if _applying_client:
		return
	_dirty[key] = true


## Sends every bag the server changed this tick to its owner. Once per tick, so a burst of
## purchases is one document rather than one each.
func flush() -> void:
	if not is_server or _dirty.is_empty():
		return
	var keys := _dirty.keys()
	_dirty.clear()
	for key: Variant in keys:
		var peer_id := int(_peer_of_bag.get(key, 0))
		if peer_id <= 0:
			# A bot, or somebody not connected. Their bag changed and there is nobody to
			# tell; they are sent the whole of it when they are admitted.
			continue
		_send_doc(peer_id, StringName(key), int(_last_seq.get(peer_id, 0)))


func _send_doc(peer_id: int, key: StringName, through: int) -> void:
	if not tell_fn.is_valid() or inventory == null:
		return
	var body := PlaygroundEvents.write_inv_doc(through, inventory.for_player(key).to_dictionary())
	if body.is_empty():
		# An ERROR and not a WARN: the player's copy of their bag is now wrong and will stay
		# wrong, which is the operation failing rather than something recoverable.
		DotLog.error(CHANNEL, "a bag is too big to send", {"bag": String(key)})
		return
	tell_fn.call(peer_id, body)
	docs_sent += 1


# --- Client ----------------------------------------------------------------

## The server said who this client is. A HELLO is a new admission, so it is a new bag:
## anything from before it — a previous connection's ops, a previous connection's bag — is
## void, and the server has just reset its sequence for this peer to zero.
##
## [b]Every HELLO, even one naming the same id.[/b] A reconnect that happens to be given the
## same userid is still a new connection, and ops in flight from the old one replayed onto
## the new bag would be applied to somebody else's layout under a sequence the server has
## forgotten.
func on_hello(session_id: int) -> void:
	if is_server or inventory == null:
		return
	var key := _session_key(session_id)
	for old in inventory.keys():
		inventory.forget(old)
	_bag_key = key
	_in_flight.clear()
	_seq = 0


## This client's own bag, or null before the server has said whose it is.
func local_manager() -> DotInvManager:
	if is_server or inventory == null or _bag_key == &"":
		return null
	var fresh := not inventory.has_bag(_bag_key)
	var m := inventory.for_player(_bag_key)
	if fresh:
		m.send_fn = _on_predicted
		m.applied.connect(func(_op: DotInvOp, _r: DotResult) -> void: changed.emit())
		m.reloaded.connect(func() -> void: changed.emit())
	return m


## Buy one of [param item_id] into the bag. Not predicted: whether it can be afforded is
## the server's, and the whole bag comes back either way.
func ask_buy(item_id: StringName) -> void:
	if ask_fn.is_valid():
		ask_fn.call(PlaygroundEvents.write_inv_buy(item_id))


## Asks for the whole bag. Also what [method poll] does when an answer is overdue.
func resync() -> void:
	if not ask_fn.is_valid():
		return
	_last_resync_at = int(now_fn.call())
	resyncs_asked += 1
	ask_fn.call(PlaygroundEvents.write_inv_resync(_seq))


## Once a tick. Asks for the bag when the oldest op has gone unanswered too long.
func poll() -> void:
	if is_server or _in_flight.is_empty():
		return
	var now := int(now_fn.call())
	if now - int(_in_flight[0]["at"]) < RESYNC_AFTER_MS:
		return
	if now - _last_resync_at < RESYNC_AFTER_MS:
		return
	resync()


func in_flight_count() -> int:
	return _in_flight.size()


## What the manager's `send_fn` calls: an op this client has just applied to its own bag.
func _on_predicted(op_dict: Dictionary) -> void:
	if _replaying:
		# A replay after a correction. It was sent the first time.
		return
	_seq += 1
	_in_flight.append({"seq": _seq, "op": op_dict, "at": int(now_fn.call()), "lost": false})
	if ask_fn.is_valid():
		ask_fn.call(PlaygroundEvents.write_inv_op(_seq, op_dict))


## Something the server said about this client's bag.
func on_tell(reader: DotNetReader) -> void:
	if is_server or inventory == null:
		return
	match PlaygroundEvents.read_inv_tell(reader):
		PlaygroundEvents.InvTell.ACK:
			var ack := PlaygroundEvents.read_inv_ack(reader)
			if bool(ack["ok"]):
				_on_ack(int(ack["seq"]), bool(ack["accepted"]), str(ack["reason"]))
		PlaygroundEvents.InvTell.DOC:
			var doc := PlaygroundEvents.read_inv_doc(reader)
			if bool(doc["ok"]):
				_on_doc(int(doc["through"]), doc["doc"] as Dictionary)
			else:
				DotLog.warn(CHANNEL, "the server sent a bag this client could not read")


func _index_of(seq: int) -> int:
	for i in range(_in_flight.size()):
		if int(_in_flight[i]["seq"]) == seq:
			return i
	return -1


func _on_ack(seq: int, accepted: bool, reason: String) -> void:
	var m := local_manager()
	var at := _index_of(seq)
	if m == null or at < 0:
		# Already settled by a document that included it.
		return

	var head: Dictionary = _in_flight[at]

	# The common case, and the only one the addon's own confirm is right for.
	if at == 0 and accepted and not bool(head["lost"]):
		m.confirm(head["op"])
		_in_flight.remove_at(0)
		confirmed_count += 1
		return

	if accepted and bool(head["lost"]):
		# The server accepted something this client could no longer apply after a
		# correction. The two have diverged, and only the server's document can say how.
		_in_flight.remove_at(at)
		resync()
		return

	if _in_flight.size() > MAX_ROLLBACK:
		resync()
		return

	# Everything before #seq was never answered, so it never arrived: dropped on the way,
	# and refused by nobody. Roll back everything this client has applied, newest first —
	# the one order in which `rollback`'s match-by-content cannot pick the wrong one of two
	# identical ops, because the newest match IS the one being undone.
	_rewind(m)

	var answered := _in_flight.slice(0, at + 1)
	var rest := _in_flight.slice(at + 1)
	_in_flight.clear()

	# The server applied #seq on a bag without the lost ones, so the client does the same.
	var diverged := false
	if accepted:
		_replaying = true
		var again := m.apply(DotInvOp.from_dictionary(head["op"]))
		_replaying = false
		if again.ok:
			m.confirm(head["op"])
			confirmed_count += 1
		else:
			diverged = true
	else:
		rolled_back_count += 1

	# The ones before it, which nobody answered.
	rolled_back_count += answered.size() - 1

	_replay(m, rest)

	if not accepted:
		DotLog.debug(CHANNEL, "an inventory op was refused and rolled back", {
			"seq": seq, "why": reason,
		})
		refused.emit(reason)
	if at > 0:
		DotLog.debug(CHANNEL, "inventory ops were never answered and were rolled back", {
			"count": at,
		})
	if diverged:
		# The server accepted what this client cannot apply once the lost ones are gone.
		resync()


## Undoes every op this client has applied and not had answered, newest first.
##
## Newest first because each `rollback` re-applies whatever was predicted after its op;
## undone from the back there is nothing after it left to re-apply, and the flight comes
## off as a whole whichever of two identical ops the manager's content match picks. An op
## marked lost is not applied, and is skipped — the manager leaves a rollback of something
## it no longer holds alone.
func _rewind(m: DotInvManager) -> void:
	for i in range(_in_flight.size() - 1, -1, -1):
		if not bool(_in_flight[i]["lost"]):
			m.rollback(_in_flight[i]["op"])


## Re-applies [param entries] on top of whatever the bag now is, without sending them again.
func _replay(m: DotInvManager, entries: Array) -> void:
	_replaying = true
	for entry: Dictionary in entries:
		var res := m.apply(DotInvOp.from_dictionary(entry["op"]))
		entry["lost"] = not res.ok
		_in_flight.append(entry)
	_replaying = false


func _on_doc(through: int, doc: Dictionary) -> void:
	var m := local_manager()
	if m == null:
		return
	var res := m.adopt(doc)
	if not res.ok:
		DotLog.warn(CHANNEL, "the server's bag would not load", {"why": res.error.message})
		return
	var rest: Array[Dictionary] = []
	for entry in _in_flight:
		if int(entry["seq"]) > through:
			rest.append(entry)
	_in_flight.clear()
	_replay(m, rest)


func describe() -> Dictionary:
	if is_server:
		return {
			"role": "server",
			"bags": inventory.keys().size() if inventory != null else 0,
			"connected": _peer_of_bag.size(),
			"docs_sent": docs_sent,
			"acks_sent": acks_sent,
		}
	return {
		"role": "client",
		"bag": String(_bag_key),
		"seq": _seq,
		"in_flight": _in_flight.size(),
		"confirmed": confirmed_count,
		"rolled_back": rolled_back_count,
		"resyncs": resyncs_asked,
	}
