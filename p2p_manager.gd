class_name P2PManager
extends Node

signal status_changed(msg: String)
signal local_code_ready(code: String)
signal peer_connected()
signal action_received(data: Dictionary)

var rtc_peer: WebRTCPeerConnection
var data_channel: WebRTCDataChannel
var is_host: bool = false
var local_candidates: Array[Dictionary] = []
var local_sdp: Dictionary = {}
var ice_gather_timer: Timer
var gist_poll_timer: Timer

var github_token: String = ""
var active_gist_id: String = ""
var http_req: HTTPRequest

func _ready() -> void:
	http_req = HTTPRequest.new()
	add_child(http_req)
	http_req.request_completed.connect(_on_http_completed)
	
	ice_gather_timer = Timer.new()
	ice_gather_timer.one_shot = true
	ice_gather_timer.wait_time = 2.0 # Wait 2s to bundle all STUN ICE candidates
	ice_gather_timer.timeout.connect(_on_ice_gathering_finished)
	add_child(ice_gather_timer)
	
	gist_poll_timer = Timer.new()
	gist_poll_timer.wait_time = 3.0
	gist_poll_timer.timeout.connect(_poll_gist_for_answer)
	add_child(gist_poll_timer)

func _process(_delta: float) -> void:
	if rtc_peer:
		rtc_peer.poll()
	if data_channel and data_channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		while data_channel.get_available_packet_count() > 0:
			var pkt = data_channel.get_packet().get_string_from_utf8()
			var parsed = JSON.parse_string(pkt)
			if typeof(parsed) == TYPE_DICTIONARY:
				action_received.emit(parsed)

func _init_webrtc(as_host: bool) -> void:
	is_host = as_host
	local_candidates.clear()
	rtc_peer = WebRTCPeerConnection.new()
	rtc_peer.initialize({
		"iceServers": [{"urls": ["stun:stun.l.google.com:19302"]}]
	})
	rtc_peer.session_description_created.connect(_on_sdp_created)
	rtc_peer.ice_candidate_created.connect(_on_ice_candidate)
	
	if is_host:
		data_channel = rtc_peer.create_data_channel("se_logic", {"negotiated": true, "id": 1})
		rtc_peer.create_offer()
		status_changed.emit("Gathering STUN ICE candidates (2s)...")
	else:
		data_channel = rtc_peer.create_data_channel("se_logic", {"negotiated": true, "id": 1})

func _on_sdp_created(type: String, sdp: String) -> void:
	rtc_peer.set_local_description(type, sdp)
	local_sdp = {"type": type, "sdp": sdp}
	ice_gather_timer.start()

func _on_ice_candidate(media: String, index: int, sdp_name: String) -> void:
	local_candidates.append({"media": media, "index": index, "name": sdp_name})

func _on_ice_gathering_finished() -> void:
	var payload = JSON.stringify({"sdp": local_sdp, "ice": local_candidates})
	var b64_bundle = Marshalls.utf8_to_base64(payload)
	
	if github_token != "":
		if is_host:
			_create_github_gist(b64_bundle)
		else:
			_post_github_gist_comment(b64_bundle)
	else:
		# Direct P2P copy-paste mode
		local_code_ready.emit(b64_bundle)
		status_changed.emit("Direct P2P Code Ready! Copy & send to peer.")

# --- DIRECT P2P METHODS ---
func start_direct_host() -> void:
	github_token = ""
	_init_webrtc(true)

func accept_remote_code(b64_code: String) -> void:
	var json_str = Marshalls.base64_to_utf8(b64_code.strip_edges())
	var data = JSON.parse_string(json_str)
	if typeof(data) != TYPE_DICTIONARY or not data.has("sdp"):
		status_changed.emit("Invalid P2P Code!")
		return
		
	if data["sdp"]["type"] == "offer":
		_init_webrtc(false)
		rtc_peer.set_remote_description("offer", data["sdp"]["sdp"])
		status_changed.emit("Offer accepted! Generating Answer (2s)...")
		
		# Wait 2 frames so rtc_peer.poll() processes the remote offer and triggers the answer
		await get_tree().process_frame
		await get_tree().process_frame
		for c in data["ice"]:
			rtc_peer.add_ice_candidate(c["media"], int(c["index"]), c["name"])
			
	elif data["sdp"]["type"] == "answer":
		rtc_peer.set_remote_description("answer", data["sdp"]["sdp"])
		await get_tree().process_frame
		for c in data["ice"]:
			rtc_peer.add_ice_candidate(c["media"], int(c["index"]), c["name"])
		status_changed.emit("P2P Connected!")
		peer_connected.emit()

# --- GITHUB GIST SIGNALING METHODS ---
func start_github_host(token: String) -> void:
	github_token = token.strip_edges()
	_init_webrtc(true)

func join_github_gist(token: String, gist_id: String) -> void:
	github_token = token.strip_edges()
	active_gist_id = gist_id.strip_edges()
	status_changed.emit("Fetching Offer from GitHub Gist...")
	var headers = ["Accept: application/vnd.github+json", "User-Agent: SE-Logic-App"]
	if github_token != "":
		headers.append("Authorization: Bearer " + github_token)
	http_req.set_meta("req_type", "fetch_offer")
	http_req.request("https://api.github.com/gists/" + active_gist_id, headers, HTTPClient.METHOD_GET)

func _create_github_gist(b64_offer: String) -> void:
	status_changed.emit("Creating GitHub Gist Lobby...")
	var headers = [
		"Accept: application/vnd.github+json",
		"Authorization: Bearer " + github_token,
		"User-Agent: SE-Logic-App"
	]
	var body = JSON.stringify({
		"description": "SE Logic Editor P2P Signaling Lobby",
		"public": false,
		"files": {"se_offer.txt": {"content": b64_offer}}
	})
	http_req.set_meta("req_type", "create_gist")
	http_req.request("https://api.github.com/gists", headers, HTTPClient.METHOD_POST, body)

func _post_github_gist_comment(b64_answer: String) -> void:
	status_changed.emit("Posting Answer to GitHub Gist...")
	var headers = [
		"Accept: application/vnd.github+json",
		"Authorization: Bearer " + github_token,
		"User-Agent: SE-Logic-App"
	]
	var body = JSON.stringify({"body": b64_answer})
	http_req.set_meta("req_type", "post_answer")
	http_req.request("https://api.github.com/gists/%s/comments" % active_gist_id, headers, HTTPClient.METHOD_POST, body)

func _poll_gist_for_answer() -> void:
	var headers = [
		"Accept: application/vnd.github+json",
		"Authorization: Bearer " + github_token,
		"User-Agent: SE-Logic-App"
	]
	http_req.set_meta("req_type", "poll_comments")
	http_req.request("https://api.github.com/gists/%s/comments" % active_gist_id, headers, HTTPClient.METHOD_GET)

func _on_http_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var req_type = http_req.get_meta("req_type", "")
	var json = JSON.parse_string(body.get_string_from_utf8())
	
	if response_code >= 300:
		status_changed.emit("GitHub API Error (%d)" % response_code)
		return
		
	match req_type:
		"create_gist":
			active_gist_id = json["id"]
			local_code_ready.emit(active_gist_id)
			status_changed.emit("Gist Lobby Ready! Share Gist ID. Polling for peer...")
			gist_poll_timer.start()
		"fetch_offer":
			var offer_b64 = json["files"]["se_offer.txt"]["content"]
			accept_remote_code(offer_b64)
		"post_answer":
			status_changed.emit("Answer posted to Gist! P2P Connecting...")
			peer_connected.emit()
		"poll_comments":
			if typeof(json) == TYPE_ARRAY and not json.is_empty():
				gist_poll_timer.stop()
				var answer_b64 = json[0]["body"]
				accept_remote_code(answer_b64)

func broadcast_action(action: Dictionary) -> void:
	if data_channel and data_channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		data_channel.put_packet(JSON.stringify(action).to_utf8_buffer())
