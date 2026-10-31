# ==============================================================================
# FILE: res://ship_preview_3d.gd
# PURPOSE: High-Performance 3D Ship Preview Renderer.
#          - Backface-culled 3D block face letters (#14): Only renders letters on
#            faces whose outward normal points toward the camera, plus opaque
#            depth-buffer occlusion so rear faces never bleed through.
#          - 3D Wire Click Selection (#18): Screen-space ray/segment projection
#            allows clicking any 3D wire to select & highlight it in 3D and 2D.
#          - Dedicated toggle for 3D Wire Letters (#19, off by default).
# ==============================================================================
class_name ShipPreview3D
extends Node3D

signal block_clicked_in_3d(entity_id: String, ctrl_held: bool)
signal wire_clicked_in_3d(wire_info: Dictionary)

var armor_multimesh: MultiMeshInstance3D
var logic_multimesh: MultiMeshInstance3D
var dummy_multimesh: MultiMeshInstance3D

var highlights_root: Node3D
var block_letters_root: Node3D
var wire_letters_root: Node3D
var selected_labels_root: Node3D
var wires_mesh: ImmediateMesh
var wires_instance: MeshInstance3D
var thick_wires_mesh: ImmediateMesh
var thick_wires_instance: MeshInstance3D

var camera_pivot: Node3D
var camera: Camera3D
var model_center: Vector3 = Vector3.ZERO

var rot_x := -0.45
var rot_y := 0.55
var zoom := 18.0

var auto_spin_enabled := true
var is_dragging_orbit := false
var angular_velocity := Vector2(0.25, 0.0)
var last_drag_velocity := Vector2.ZERO
var lmb_press_pos := Vector2.ZERO

# Cached pickable blocks & 3D wire polylines for instant 3D click selection (#5, #18)
var pickable_blocks: Array[Dictionary] = [] # {id: String, aabb: AABB}
var pickable_wires_3d: Array[Dictionary] = [] # {pts: PackedVector3Array, src: String, dst: String, slot: int, action: String, is_monitor: bool}
var face_letter_items: Array[Dictionary] = [] # {lbl: Label3D, world_pos: Vector3, normal: Vector3}
var pulse_meshes_root: Node3D
var callout_2d_overlay: Control
var current_bp_ref: SEBlueprint
var current_cfg_ref: AppConfig
var active_selected_ids: Dictionary = {}
var connected_neighbor_ids: Dictionary = {} # 1-hop neighbors of selected blocks (#23)
var active_3d_pulses: Array[Dictionary] = [] # {pts: PackedVector3Array, col: Color, freq: float, count: int}

# ==============================================================================
# SECTION: INITIALIZATION
# ==============================================================================
func _ready() -> void:
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.06, 0.07, 0.10)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.68, 0.70, 0.78)
	var world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	
	var dir_light = DirectionalLight3D.new()
	dir_light.rotation_degrees = Vector3(-50, 40, 0)
	add_child(dir_light)
	
	camera_pivot = Node3D.new()
	add_child(camera_pivot)
	camera = Camera3D.new()
	camera.far = 2500.0
	camera_pivot.add_child(camera)
	
	armor_multimesh = _create_multimesh(Color(0.48, 0.52, 0.60, 0.12), true, 0.98, false)
	dummy_multimesh = _create_multimesh(Color(0.1, 0.85, 1.0, 0.45), true, 0.85, false)
	# Logic blocks use opaque depth-draw so they properly occlude letters on rear blocks (#14)
	logic_multimesh = _create_multimesh(Color.WHITE, false, 0.92, true)
	
	highlights_root = Node3D.new()
	add_child(highlights_root)
	
	block_letters_root = Node3D.new()
	add_child(block_letters_root)
	
	wire_letters_root = Node3D.new()
	add_child(wire_letters_root)
	
	selected_labels_root = Node3D.new()
	add_child(selected_labels_root)
	
	wires_mesh = ImmediateMesh.new()
	wires_instance = MeshInstance3D.new()
	wires_instance.mesh = wires_mesh
	var w_mat = StandardMaterial3D.new()
	w_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	w_mat.vertex_color_use_as_albedo = true
	w_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wires_instance.material_override = w_mat
	add_child(wires_instance)
	
	thick_wires_mesh = ImmediateMesh.new()
	thick_wires_instance = MeshInstance3D.new()
	thick_wires_instance.mesh = thick_wires_mesh
	var tw_mat = StandardMaterial3D.new()
	tw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tw_mat.vertex_color_use_as_albedo = true
	tw_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	thick_wires_instance.material_override = tw_mat
	add_child(thick_wires_instance)
	
	pulse_meshes_root = Node3D.new()
	add_child(pulse_meshes_root)
	
	# 2D Overlay inside the SubViewport that draws peripheral callout boxes + leader lines to 3D blocks (#23)
	callout_2d_overlay = Control.new()
	callout_2d_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	callout_2d_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	callout_2d_overlay.draw.connect(_draw_2d_peripheral_callouts)
	add_child(callout_2d_overlay)
	
	_update_camera()

func _process(delta: float) -> void:
	if not is_dragging_orbit:
		if angular_velocity.length_squared() > 0.0001:
			rot_y += angular_velocity.x * delta
			rot_x = clamp(rot_x + angular_velocity.y * delta, -1.45, 1.45)
			if not auto_spin_enabled:
				angular_velocity = angular_velocity.move_toward(Vector2.ZERO, 1.8 * delta)
			else:
				angular_velocity = angular_velocity.move_toward(Vector2(0.22, 0.0), 1.2 * delta)
			_update_camera()
	_update_3d_flow_pulses()
	if callout_2d_overlay:
		callout_2d_overlay.queue_redraw()

func reset_camera_to_center() -> void:
	camera_pivot.position = model_center
	angular_velocity = Vector2(0.22, 0.0)
	auto_spin_enabled = true
	_update_camera()

func _create_multimesh(col: Color, transparent: bool, scale_factor: float, use_instance_colors: bool) -> MultiMeshInstance3D:
	var mmi = MultiMeshInstance3D.new()
	var mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = use_instance_colors
	var box = BoxMesh.new()
	box.size = Vector3.ONE * scale_factor
	var mat = StandardMaterial3D.new()
	if transparent:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	else:
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	if use_instance_colors:
		mat.vertex_color_use_as_albedo = true
	mat.albedo_color = col
	box.material = mat
	mm.mesh = box
	mmi.multimesh = mm
	add_child(mmi)
	return mmi

# ==============================================================================
# SECTION: GPU-INSTANCED SHIP & CAMERA-FACING-ONLY FACE LETTERS (#14)
# ==============================================================================
func rebuild_mesh(
	bp: SEBlueprint,
	cfg: AppConfig,
	selected_ids: Dictionary = {},
	hovered_id: String = "",
	hovered_wire: Dictionary = {},
	disabled_block_types: Dictionary = {},
	disabled_actions: Dictionary = {}
) -> void:
	var armor_coords: Array[Vector3] = []
	var logic_transforms: Array[Transform3D] = []
	var logic_colors: Array[Color] = []
	var all_positions: Array[Vector3] = []
	pickable_blocks.clear()
	face_letter_items.clear()
	
	for child in block_letters_root.get_children(): child.queue_free()
	for child in wire_letters_root.get_children(): child.queue_free()
	
	for id in bp.blocks:
		var b = bp.blocks[id]
		var w_pos: Vector3 = b.get("world_pos", Vector3(b["min"].x, b["min"].y, b["min"].z))
		var span: Vector3 = b.get("cell_span", Vector3.ONE)
		all_positions.append(w_pos)
		
		var is_used = bp.is_block_used_in_logic(id)
		var is_logic_candidate = (b["xsi_type"] in SEBlueprint.LOGIC_TYPES) or (is_used and not str(id).begins_with("armor_"))
		
		if is_logic_candidate:
			if cfg.hide_unused_blocks and not is_used:
				armor_coords.append(w_pos)
				continue
			var is_type_filtered_out = disabled_block_types.get(b["xsi_type"], false)
			if is_type_filtered_out:
				armor_coords.append(w_pos)
				continue
			var col = cfg.get_block_color(b["xsi_type"])
			logic_transforms.append(Transform3D(Basis().scaled(span), w_pos))
			logic_colors.append(col)
			pickable_blocks.append({
				"id": id,
				"aabb": AABB(w_pos - span * 0.5, span)
			})
			if cfg.show_3d_block_letters:
				_spawn_6_sided_block_letters(w_pos, span, cfg.get_block_initial(b["xsi_type"]))
		else:
			armor_coords.append(w_pos)
			
	if not all_positions.is_empty():
		var sum := Vector3.ZERO
		for p in all_positions: sum += p
		model_center = sum / float(all_positions.size())
		
	armor_multimesh.multimesh.instance_count = armor_coords.size()
	for i in armor_coords.size():
		armor_multimesh.multimesh.set_instance_transform(i, Transform3D(Basis(), armor_coords[i]))
		
	logic_multimesh.multimesh.instance_count = logic_transforms.size()
	for i in logic_transforms.size():
		logic_multimesh.multimesh.set_instance_transform(i, logic_transforms[i])
		logic_multimesh.multimesh.set_instance_color(i, logic_colors[i])
		
	dummy_multimesh.multimesh.instance_count = bp.dummy_pool.size()
	for i in bp.dummy_pool.size():
		var d_pos = bp.dummy_pool[i].get("world_pos", Vector3(bp.dummy_pool[i]["min"].x, bp.dummy_pool[i]["min"].y, bp.dummy_pool[i]["min"].z))
		dummy_multimesh.multimesh.set_instance_transform(i, Transform3D(Basis(), d_pos))
		
	_update_face_letters_visibility()
	update_highlights_only(bp, cfg, selected_ids, hovered_id, hovered_wire, disabled_block_types, disabled_actions)

func _spawn_6_sided_block_letters(center: Vector3, span: Vector3, letter: String) -> void:
	var half: Vector3 = span * 0.468
	var face_configs = [
		{"pos": Vector3(0, 0, half.z), "rot": Vector3(0, 0, 0), "normal": Vector3(0, 0, 1)},
		{"pos": Vector3(0, 0, -half.z), "rot": Vector3(0, 180, 0), "normal": Vector3(0, 0, -1)},
		{"pos": Vector3(half.x, 0, 0), "rot": Vector3(0, 90, 0), "normal": Vector3(1, 0, 0)},
		{"pos": Vector3(-half.x, 0, 0), "rot": Vector3(0, -90, 0), "normal": Vector3(-1, 0, 0)},
		{"pos": Vector3(0, half.y, 0), "rot": Vector3(-90, 0, 0), "normal": Vector3(0, 1, 0)},
		{"pos": Vector3(0, -half.y, 0), "rot": Vector3(90, 0, 0), "normal": Vector3(0, -1, 0)}
	]
	for fc in face_configs:
		var lbl := Label3D.new()
		lbl.text = letter
		lbl.double_sided = false
		lbl.pixel_size = 0.012
		lbl.font_size = 34
		lbl.modulate = Color.WHITE
		lbl.outline_modulate = Color(0, 0, 0, 0.85)
		lbl.outline_size = 6
		var w_pos: Vector3 = center + fc["pos"]
		lbl.position = w_pos
		lbl.rotation_degrees = fc["rot"]
		block_letters_root.add_child(lbl)
		face_letter_items.append({"lbl": lbl, "world_pos": w_pos, "normal": fc["normal"]})

func _update_face_letters_visibility() -> void:
	if not camera or not is_inside_tree():
		return
	var cam_pos: Vector3 = camera.global_position
	for item in face_letter_items:
		var lbl: Label3D = item["lbl"]
		if is_instance_valid(lbl):
			var to_cam: Vector3 = (cam_pos - item["world_pos"]).normalized()
			lbl.visible = (item["normal"].dot(to_cam) > 0.08)

func update_highlights_only(
	bp: SEBlueprint,
	cfg: AppConfig,
	selected_ids: Dictionary = {},
	hovered_id: String = "",
	hovered_wire: Dictionary = {},
	disabled_block_types: Dictionary = {},
	disabled_actions: Dictionary = {}
) -> void:
	current_bp_ref = bp
	current_cfg_ref = cfg
	active_selected_ids = selected_ids.duplicate()
	connected_neighbor_ids.clear()
	active_3d_pulses.clear()
	
	for child in highlights_root.get_children(): child.queue_free()
	for child in selected_labels_root.get_children(): child.queue_free()
	for child in wire_letters_root.get_children(): child.queue_free()
	for child in pulse_meshes_root.get_children(): child.queue_free()
	pickable_wires_3d.clear()
	
	# 1. Identify all blocks directly connected to any selected block (#23)
	for id in bp.blocks:
		var b = bp.blocks[id]
		for s in b["slots"]:
			var tid = s["target_id"]
			if selected_ids.has(id) and bp.blocks.has(tid) and not selected_ids.has(tid):
				connected_neighbor_ids[tid] = true
			elif selected_ids.has(tid) and not selected_ids.has(id):
				connected_neighbor_ids[id] = true
		for mb_id in b.get("monitored_blocks", []):
			if selected_ids.has(id) and bp.blocks.has(mb_id) and not selected_ids.has(mb_id):
				connected_neighbor_ids[mb_id] = true
			elif selected_ids.has(mb_id) and not selected_ids.has(id):
				connected_neighbor_ids[id] = true
				
	# 2. Highlight Selected Blocks (Bright Green), Connected Neighbors (Subtle Cyan-Green #23), & Hovered Blocks (Gold)
	for id in bp.blocks:
		var is_selected = selected_ids.has(id) or (hovered_wire.get("src", "") == id and hovered_wire.get("selected_wire", false))
		var is_neighbor = connected_neighbor_ids.has(id)
		var is_hovered = (id == hovered_id) or (hovered_wire.get("src", "") == id) or (hovered_wire.get("dst", "") == id)
		if is_selected or is_neighbor or is_hovered:
			var b = bp.blocks[id]
			var w_pos: Vector3 = b.get("world_pos", Vector3(b["min"].x, b["min"].y, b["min"].z))
			var span: Vector3 = b.get("cell_span", Vector3.ONE)
			var h_mi = MeshInstance3D.new()
			var h_bm = BoxMesh.new()
			h_bm.size = span * (1.25 if is_hovered else (1.17 if is_selected else 1.09))
			var h_mat = StandardMaterial3D.new()
			h_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			h_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			if is_hovered:
				h_mat.albedo_color = Color(1.0, 0.92, 0.2, 0.60)
			elif is_selected:
				h_mat.albedo_color = Color(0.2, 1.0, 0.45, 0.52)
			else:
				h_mat.albedo_color = Color(0.25, 0.85, 0.95, 0.26) # Connected block highlighted slightly less (#23)
			h_bm.material = h_mat
			h_mi.mesh = h_bm
			h_mi.position = w_pos
			highlights_root.add_child(h_mi)
			
	# 3. Build Patterned Dual-Color 3D Wires + Selected Wire Labels (#23, #28, #29)
	wires_mesh.clear_surfaces()
	thick_wires_mesh.clear_surfaces()
	var has_any_wire := false
	var has_any_thick := false
	var wire_counter := 0
	
	for id in bp.blocks:
		var src = bp.blocks[id]
		var p1: Vector3 = src.get("world_pos", Vector3(src["min"].x, src["min"].y, src["min"].z))
		
		for s in src["slots"]:
			var tid = s["target_id"]
			if not bp.blocks.has(tid): continue
			if not has_any_wire:
				wires_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
				has_any_wire = true
			var dst = bp.blocks[tid]
			var p2: Vector3 = dst.get("world_pos", Vector3(dst["min"].x, dst["min"].y, dst["min"].z))
			var act: String = s["action"]
			var disp_act: String = cfg.get_action_display_name(act)
			var is_filtered = disabled_actions.get(act, false) or disabled_block_types.get(src["xsi_type"], false) or disabled_block_types.get(dst["xsi_type"], false)
			var is_sel_wire = selected_ids.has(id) or selected_ids.has(tid)
			var is_hov_wire = (hovered_id == id or hovered_id == tid) or (hovered_wire.get("src", "") == id and hovered_wire.get("dst", "") == tid and int(hovered_wire.get("slot", -1)) == int(s["index"]))
			if (is_sel_wire or is_hov_wire) and not has_any_thick:
				thick_wires_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
				has_any_thick = true
			var c1 = cfg.get_dimmed_color() if (is_filtered and not is_sel_wire and not is_hov_wire) else cfg.get_action_color(act)
			var c2 = cfg.get_dimmed_color() if (is_filtered and not is_sel_wire and not is_hov_wire) else cfg.get_action_secondary_color(act)
			var st = cfg.get_action_style(act)
			var pts3d = _add_curved_3d_wire(p1, p2, c1, c2, str(st.get("pattern", "Solid")), wire_counter, is_sel_wire, is_hov_wire, disp_act, cfg.get_action_initial(act), cfg.show_3d_selected_wire_labels, cfg.show_3d_wire_letters and not is_filtered)
			if not is_filtered:
				pickable_wires_3d.append({"pts": pts3d, "src": id, "dst": tid, "slot": s["index"], "action": act, "is_monitor": false})
				if cfg.show_data_flow_pulses:
					active_3d_pulses.append({"pts": pts3d, "col": c1.lightened(0.35), "freq": float(st.get("pulse_freq", 1.8)), "count": int(st.get("pulse_count", 3))})
			wire_counter += 1
			
		for mb_id in src.get("monitored_blocks", []):
			if not bp.blocks.has(mb_id): continue
			if not has_any_wire:
				wires_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
				has_any_wire = true
			var mon = bp.blocks[mb_id]
			var p_mon: Vector3 = mon.get("world_pos", Vector3(mon["min"].x, mon["min"].y, mon["min"].z))
			var raw_rule: String = src.get("event_rule", "Block On/Off")
			var rule_lbl = "Watch: " + cfg.get_event_display_name(raw_rule)
			var is_filtered = disabled_actions.get("EventMonitor", false) or disabled_block_types.get(src["xsi_type"], false) or disabled_block_types.get(mon["xsi_type"], false)
			var is_sel_wire = selected_ids.has(id) or selected_ids.has(mb_id)
			var is_hov_wire = (hovered_id == id or hovered_id == mb_id) or (hovered_wire.get("src", "") == mb_id and hovered_wire.get("dst", "") == id)
			if (is_sel_wire or is_hov_wire) and not has_any_thick:
				thick_wires_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
				has_any_thick = true
			var c1 = cfg.get_dimmed_color() if (is_filtered and not is_sel_wire and not is_hov_wire) else cfg.get_action_color("EventMonitor")
			var c2 = cfg.get_dimmed_color() if (is_filtered and not is_sel_wire and not is_hov_wire) else cfg.get_action_secondary_color("EventMonitor")
			var st = cfg.get_action_style("EventMonitor")
			var pts3d = _add_curved_3d_wire(p_mon, p1, c1, c2, str(st.get("pattern", "DashDot")), wire_counter, is_sel_wire, is_hov_wire, rule_lbl, "W", cfg.show_3d_selected_wire_labels, cfg.show_3d_wire_letters and not is_filtered)
			if not is_filtered:
				pickable_wires_3d.append({"pts": pts3d, "src": mb_id, "dst": id, "slot": 0, "action": "EventMonitor", "is_monitor": true})
				if cfg.show_data_flow_pulses:
					active_3d_pulses.append({"pts": pts3d, "col": c1.lightened(0.35), "freq": float(st.get("pulse_freq", 2.2)), "count": int(st.get("pulse_count", 3))})
			wire_counter += 1
			
	if has_any_wire:
		wires_mesh.surface_end()
	if has_any_thick:
		thick_wires_mesh.surface_end()
	_spawn_3d_pulse_nodes()
	if callout_2d_overlay:
		callout_2d_overlay.queue_redraw()

func _add_curved_3d_wire(
	p1: Vector3, p2: Vector3, col1: Color, col2: Color, pattern: String, wire_idx: int,
	is_selected: bool, is_hovered: bool, label_text: String, initial_letter: String,
	show_3d_label: bool, show_wire_initial_letter: bool
) -> PackedVector3Array:
	var mid: Vector3 = (p1 + p2) * 0.5
	var outward: Vector3 = (mid - model_center)
	if outward.length_squared() < 0.01:
		outward = Vector3.UP
	else:
		outward = outward.normalized()
	var side_axis: Vector3 = outward.cross(Vector3.UP)
	if side_axis.length_squared() < 0.01:
		side_axis = Vector3.RIGHT
	else:
		side_axis = side_axis.normalized()
	var spread: float = float((wire_idx % 9) - 4) * 0.32
	var dist: float = p1.distance_to(p2)
	var ctrl_pt: Vector3 = mid + (outward + Vector3(0, 0.55, 0)).normalized() * max(1.4, dist * 0.42) + side_axis * spread
	
	var steps: int = 18
	var prev: Vector3 = p1
	var apex: Vector3 = mid
	var pts3d := PackedVector3Array([p1])
	for i in range(1, steps + 1):
		var t: float = float(i) / float(steps)
		var omt: float = 1.0 - t
		var pt: Vector3 = (omt * omt * p1) + (2.0 * omt * t * ctrl_pt) + (t * t * p2)
		pts3d.append(pt)
		if i == steps / 2:
			apex = pt
		var seg_col: Color = _eval_pattern_color(col1, col2, pattern, i)
		wires_mesh.surface_set_color(seg_col)
		wires_mesh.surface_add_vertex(prev)
		wires_mesh.surface_set_color(seg_col)
		wires_mesh.surface_add_vertex(pt)
		
		if is_selected or is_hovered:
			var r_col: Color = seg_col.lightened(0.38 if is_hovered else 0.18)
			var half_w: float = 0.12 if is_hovered else 0.07
			for offset_vec in [Vector3.UP * half_w, side_axis * half_w]:
				thick_wires_mesh.surface_set_color(r_col)
				thick_wires_mesh.surface_add_vertex(prev - offset_vec)
				thick_wires_mesh.surface_add_vertex(prev + offset_vec)
				thick_wires_mesh.surface_add_vertex(pt + offset_vec)
				thick_wires_mesh.surface_add_vertex(prev - offset_vec)
				thick_wires_mesh.surface_add_vertex(pt + offset_vec)
				thick_wires_mesh.surface_add_vertex(pt - offset_vec)
		prev = pt
		
	# Show floating 3D action/event label above wires connected to selected/hovered nodes (#23)
	if (is_selected or is_hovered) and show_3d_label and label_text != "":
		var lbl3d := Label3D.new()
		lbl3d.text = label_text
		lbl3d.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl3d.no_depth_test = true
		lbl3d.fixed_size = true
		lbl3d.pixel_size = 0.0016
		lbl3d.font_size = 24
		lbl3d.modulate = col1.lightened(0.38)
		lbl3d.outline_modulate = Color(0, 0, 0, 0.95)
		lbl3d.outline_size = 6
		lbl3d.position = apex + Vector3(0, 0.35, 0)
		selected_labels_root.add_child(lbl3d)
	elif show_wire_initial_letter and initial_letter != "":
		var init_lbl := Label3D.new()
		init_lbl.text = initial_letter
		init_lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		init_lbl.pixel_size = 0.009
		init_lbl.font_size = 26
		init_lbl.modulate = Color.WHITE
		init_lbl.outline_modulate = Color(0, 0, 0, 0.90)
		init_lbl.position = apex
		wire_letters_root.add_child(init_lbl)
	return pts3d

func _eval_pattern_color(c1: Color, c2: Color, pattern: String, seg_idx: int) -> Color:
	match pattern:
		"Dashed": return c1 if (seg_idx % 2 == 0) else c2
		"Dotted": return c1 if (seg_idx % 3 == 0) else c2
		"DashDot": return c1 if (seg_idx % 4 in [0, 1]) else c2
		"LongDash": return c1 if (seg_idx % 4 != 3) else c2
		_: return c1

# ==============================================================================
# SECTION: 3D BLOCK & 3D WIRE CLICK SELECTION (#5, #18)
# ==============================================================================
func handle_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				lmb_press_pos = event.position
			elif event.position.distance_to(lmb_press_pos) < 6.0:
				_pick_block_or_wire_at_screen_pos(event.position, Input.is_key_pressed(KEY_CTRL))
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				is_dragging_orbit = true
				auto_spin_enabled = false
				angular_velocity = Vector2.ZERO
				last_drag_velocity = Vector2.ZERO
			else:
				is_dragging_orbit = false
				if last_drag_velocity.length() > 0.15:
					angular_velocity = last_drag_velocity
				else:
					angular_velocity = Vector2.ZERO
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom = max(1.5, zoom * 0.88)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom = min(450.0, zoom * 1.14)
			_update_camera()
			
	elif event is InputEventMouseMotion:
		if is_dragging_orbit:
			var dx = -event.relative.x * 0.009
			var dy = -event.relative.y * 0.009
			rot_y += dx
			rot_x = clamp(rot_x + dy, -1.45, 1.45)
			last_drag_velocity = Vector2(dx, dy) * 35.0
			_update_camera()
		elif Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			var pan_speed = zoom * 0.0018
			var right_vec = camera_pivot.global_transform.basis.x
			var up_vec = camera_pivot.global_transform.basis.y
			camera_pivot.position += (-right_vec * event.relative.x + up_vec * event.relative.y) * pan_speed
			_update_face_letters_visibility()

func _pick_block_or_wire_at_screen_pos(local_pos: Vector2, ctrl_held: bool) -> void:
	if not camera:
		return
	var ray_origin: Vector3 = camera.project_ray_origin(local_pos)
	var ray_dir: Vector3 = camera.project_ray_normal(local_pos)
	var best_id := ""
	var best_dist := INF
	for item in pickable_blocks:
		var aabb: AABB = item["aabb"]
		var hit = aabb.intersects_ray(ray_origin, ray_dir)
		if hit != null:
			var d = ray_origin.distance_to(hit)
			if d < best_dist:
				best_dist = d
				best_id = item["id"]
	if best_id != "":
		block_clicked_in_3d.emit(best_id, ctrl_held)
		return
	
	var best_wire := {}
	var best_screen_dist := 12.0
	for w in pickable_wires_3d:
		var pts: PackedVector3Array = w["pts"]
		for i in range(pts.size() - 1):
			if camera.is_position_behind(pts[i]) or camera.is_position_behind(pts[i + 1]):
				continue
			var s1: Vector2 = camera.unproject_position(pts[i])
			var s2: Vector2 = camera.unproject_position(pts[i + 1])
			var closest: Vector2 = Geometry2D.get_closest_point_to_segment(local_pos, s1, s2)
			var d: float = local_pos.distance_to(closest)
			if d < best_screen_dist:
				best_screen_dist = d
				best_wire = w
	if not best_wire.is_empty():
		wire_clicked_in_3d.emit(best_wire)

func _update_camera() -> void:
	if not camera_pivot or not camera:
		return
	camera_pivot.rotation = Vector3(rot_x, rot_y, 0)
	camera.position = Vector3(0, 0, zoom)
	_update_face_letters_visibility()

func _spawn_3d_pulse_nodes() -> void:
	for child in pulse_meshes_root.get_children():
		child.queue_free()
	if not current_cfg_ref or not current_cfg_ref.show_data_flow_pulses:
		return
	var sphere := BoxMesh.new()
	sphere.size = Vector3.ONE * 0.16
	for p_info in active_3d_pulses:
		var count: int = clampi(p_info["count"], 1, 8)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = p_info["col"]
		var instances: Array[MeshInstance3D] = []
		for i in count:
			var mi := MeshInstance3D.new()
			mi.mesh = sphere
			mi.material_override = mat
			pulse_meshes_root.add_child(mi)
			instances.append(mi)
		p_info["instances"] = instances

func _update_3d_flow_pulses() -> void:
	if not current_cfg_ref or not current_cfg_ref.show_data_flow_pulses:
		return
	var t_sec: float = float(Time.get_ticks_msec()) * 0.001
	for p_info in active_3d_pulses:
		if not p_info.has("instances"): continue
		var pts: PackedVector3Array = p_info["pts"]
		if pts.size() < 2: continue
		var instances: Array = p_info["instances"]
		var freq: float = max(0.1, float(p_info["freq"]))
		var count: int = instances.size()
		for i in count:
			var mi: MeshInstance3D = instances[i]
			if not is_instance_valid(mi): continue
			var phase: float = fposmod(t_sec * freq * 0.35 + float(i) / float(count), 1.0)
			var f_idx: float = phase * float(pts.size() - 1)
			var idx0: int = clampi(int(floor(f_idx)), 0, pts.size() - 2)
			var frac: float = f_idx - float(idx0)
			mi.position = pts[idx0].lerp(pts[idx0 + 1], frac)

# Draws selected & connected block names on the 2D periphery (left/right/top/bottom margins)
# of the 3D model and connects each 2D label to its 3D block position with a crisp leader line (#23)!
func _draw_2d_peripheral_callouts() -> void:
	if not camera or not current_bp_ref or (active_selected_ids.is_empty() and connected_neighbor_ids.is_empty()):
		return
	var vp_size: Vector2 = callout_2d_overlay.size
	if vp_size.x < 40 or vp_size.y < 40:
		return
	var font: Font = ThemeDB.fallback_font
	var screen_center: Vector2 = vp_size * 0.5
	var callout_items: Array[Dictionary] = []
	
	for id in active_selected_ids.keys():
		if current_bp_ref.blocks.has(id):
			callout_items.append({"id": id, "is_primary": true})
	for id in connected_neighbor_ids.keys():
		if current_bp_ref.blocks.has(id):
			callout_items.append({"id": id, "is_primary": false})
			
	var left_y := 48.0
	var right_y := 48.0
	for item in callout_items:
		var b: Dictionary = current_bp_ref.blocks[item["id"]]
		var w_pos: Vector3 = b.get("world_pos", Vector3(b["min"].x, b["min"].y, b["min"].z))
		if camera.is_position_behind(w_pos):
			continue
		var proj_2d: Vector2 = camera.unproject_position(w_pos)
		var name_txt: String = b["custom_name"]
		var is_prim: bool = item["is_primary"]
		var font_sz: int = 12 if is_prim else 10
		var str_sz: Vector2 = font.get_string_size(name_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz)
		var box_sz := Vector2(str_sz.x + 14.0, str_sz.y + 6.0)
		
		var place_on_left: bool = (proj_2d.x <= screen_center.x)
		var box_pos: Vector2
		var anchor_pt: Vector2
		if place_on_left:
			box_pos = Vector2(14.0, left_y)
			left_y += box_sz.y + 8.0
			anchor_pt = Vector2(box_pos.x + box_sz.x, box_pos.y + box_sz.y * 0.5)
		else:
			box_pos = Vector2(vp_size.x - box_sz.x - 14.0, right_y)
			right_y += box_sz.y + 8.0
			anchor_pt = Vector2(box_pos.x, box_pos.y + box_sz.y * 0.5)
			
		var col: Color = Color(0.25, 1.0, 0.48, 0.95) if is_prim else Color(0.35, 0.85, 0.98, 0.78)
		var elbow := Vector2(anchor_pt.x + (18.0 if place_on_left else -18.0), anchor_pt.y)
		
		# Leader line from 2D callout pill to projected 3D block center
		callout_2d_overlay.draw_polyline(PackedVector2Array([anchor_pt, elbow, proj_2d]), Color(0, 0, 0, 0.75), 3.2, true)
		callout_2d_overlay.draw_polyline(PackedVector2Array([anchor_pt, elbow, proj_2d]), col, 1.6, true)
		callout_2d_overlay.draw_circle(proj_2d, 3.5, col)
		
		var rect := Rect2(box_pos, box_sz)
		callout_2d_overlay.draw_rect(rect, Color(0.06, 0.07, 0.10, 0.88 if is_prim else 0.72), true)
		callout_2d_overlay.draw_rect(rect, col, false, 2.0 if is_prim else 1.0)
		callout_2d_overlay.draw_string(font, box_pos + Vector2(7.0, box_sz.y - 5.0), name_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, col.lightened(0.2))
