# ==============================================================================
# FILE: res://main.gd
# PURPOSE: Main Application Controller & Godot-Style Dockable Workspace Manager.
#          - Implements a full Dock System (#22): Outline, Visibility Filters,
#            3D Ship Preview, and Wire Action Legend are all dockable panels that
#            can be moved between Left-Top, Left-Bottom, Right-Top, Right-Bottom
#            TabContainers or popped out into floating OS Windows.
#          - Fixes pan/zoom synchronization (#15) & adds toggle between Smart
#            AStar collision-avoiding wires and Vanilla GraphEdit lines (#15.2).
#          - Renders vibrant colored port dots (#16) and cleanly split left/right
#            node pills with an empty center channel (#17).
# ==============================================================================
extends Control

class GraphCustomOverlay extends Control:
	var main_app: Control
	var is_background: bool = false
	func _draw() -> void:
		if not main_app:
			return
		if is_background:
			main_app._draw_background_org_rects_and_comments(self)
		else:
			main_app._draw_foreground_wires_and_lasso(self)

# ==============================================================================
# SECTION: APPLICATION STATE VARIABLES
# ==============================================================================
var config: AppConfig
var blueprint: SEBlueprint
var p2p: P2PManager
var ship_3d: ShipPreview3D

# --- DOCK SYSTEM CONTAINERS (#22) ---
var main_hsplit: HSplitContainer
var left_vsplit: VSplitContainer
var right_hsplit: HSplitContainer
var right_vsplit: VSplitContainer
var dock_slots: Dictionary = {}      # "L-Top", "L-Bot", "R-Top", "R-Bot" -> TabContainer
var floating_windows: Dictionary = {} # panel_id -> Window
var dock_panels: Dictionary = {}      # panel_id -> Control

var graph_container: Control
var graph_edit: GraphEdit
var bg_overlay: GraphCustomOverlay
var fg_overlay: GraphCustomOverlay
var legend_vbox: VBoxContainer
var outline_tree: Tree
var filter_vbox: VBoxContainer
var status_label: Label
var dummy_counter_label: Label
var recent_submenu: PopupMenu

var open_file_dialog: FileDialog
var save_file_dialog: FileDialog
var quit_confirm_dialog: ConfirmationDialog
var rule_warning_dialog: ConfirmationDialog
var p2p_dialog: AcceptDialog
var settings_dialog: AcceptDialog
var text_edit_dialog: AcceptDialog
var inline_canvas_edit: LineEdit # Seamless in-canvas rename box for Rectangles & Nodes (#25, #26.2)
var inline_edit_target_type: String = "" # "rect" or "node"
var inline_edit_target_id: Variant = null
var controls_overlay_panel: PanelContainer # Top-right comprehensive controls overlay (#34)
var text_edit_box: TextEdit
var editing_box_index: int = -1
var editing_is_rect: bool = false

var token_input: LineEdit
var code_input: LineEdit

var current_file_path: String = ""
var save_without_custom_data_flag: bool = false
var has_unsaved_changes: bool = false
var quitting_after_save: bool = false
var suppress_network_sync: bool = false
var outline_dirty: bool = true
var wires_dirty: bool = true

# --- PAN/ZOOM TRACKING SO RECTANGLES & LINES ALWAYS MOVE WITH CANVAS (#15) ---
var last_scroll_offset: Vector2 = Vector2.INF
var last_zoom: float = -1.0

# --- SELECTION, HOVER & LASSO STATE ---
var selected_node_ids: Dictionary = {}
var selected_rect_indices: Dictionary = {}
var selected_wire_info: Dictionary = {} # Selected wire from 2D or 3D click (#18)
var node_last_positions: Dictionary = {}
var is_syncing_multi_move: bool = false

var hovered_node_id: String = ""
var hovered_wire_info: Dictionary = {}
var shift_held_last_frame: bool = false
var cached_graph_wires: Array[Dictionary] = []

var lasso_active: bool = false
var lasso_start_screen: Vector2 = Vector2.ZERO
var lasso_current_screen: Vector2 = Vector2.ZERO

# --- CONTINUOUS-SWEEP BLENDER CHECKBOX STATE (#21) ---
var disabled_block_types: Dictionary = {}
var disabled_actions: Dictionary = {}
var filter_checkboxes: Array[Dictionary] = []
var blender_drag_active: bool = false
var blender_drag_target_state: bool = true
var blender_drag_last_y: float = 0.0

# --- INTERACTIVE RECTANGLE / COMMENT DRAG & 8-WAY RESIZE STATE ---
var active_box_op: String = ""
var active_box_idx: int = -1
var active_resize_edges: int = 0
var box_drag_start_mouse_graph: Vector2 = Vector2.ZERO
var box_start_rect: Rect2 = Rect2()
var enclosed_nodes_at_drag_start: Dictionary = {}
var enclosed_rects_at_drag_start: Dictionary = {}
var enclosed_comments_at_drag_start: Dictionary = {}

const CLUSTER_PALETTE = [
	"#3b82f6", "#10b981", "#f59e0b", "#8b5cf6",
	"#ec4899", "#06b6d4", "#84cc16", "#f97316"
]

# ==============================================================================
# SECTION: LIFECYCLE & PAN/ZOOM SYNCHRONIZED PROCESS LOOP (#15)
# ==============================================================================
func _ready() -> void:
	get_tree().set_auto_accept_quit(false)
	
	config = AppConfig.new()
	config.load_config()
	_apply_high_dpi_compact_theme()
	
	blueprint = SEBlueprint.new()
	p2p = P2PManager.new()
	add_child(p2p)
	p2p.status_changed.connect(func(msg): _set_status("P2P: " + msg))
	p2p.local_code_ready.connect(func(code): code_input.text = code; DisplayServer.clipboard_set(code))
	p2p.action_received.connect(_on_p2p_action_received)
	
	_build_ui()
	_build_dialogs()
	_load_demo_blueprint()

func _apply_high_dpi_compact_theme() -> void:
	get_tree().root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_tree().root.content_scale_factor = config.ui_scale
	var th = Theme.new()
	th.default_font_size = 11
	self.theme = th

func _process(_delta: float) -> void:
	# Continuously force-redraw fg_overlay when animated data flow pulses (#29) are enabled
	if config.show_data_flow_pulses and config.use_smart_astar_wires:
		fg_overlay.queue_redraw()
	
	if not graph_edit or not graph_container:
		return
		
	if wires_dirty:
		wires_dirty = false
		if config.use_smart_astar_wires:
			_recompute_astar_graph_wires()
		else:
			cached_graph_wires.clear()
		bg_overlay.queue_redraw()
		fg_overlay.queue_redraw()
		
	# Immediately redraw rectangles & custom wires whenever the user pans or zooms the canvas (#15)!
	if graph_edit.scroll_offset != last_scroll_offset or graph_edit.zoom != last_zoom:
		last_scroll_offset = graph_edit.scroll_offset
		last_zoom = graph_edit.zoom
		bg_overlay.queue_redraw()
		fg_overlay.queue_redraw()
		
	var mp_local = graph_container.get_local_mouse_position()
	var mp_in_graph = Rect2(Vector2.ZERO, graph_container.size).has_point(mp_local)
	var new_hovered_node := ""
	var new_hovered_wire := {}
	
	if mp_in_graph:
		var mp_graph = (mp_local + graph_edit.scroll_offset) / graph_edit.zoom
		for child in graph_edit.get_children():
			if child is GraphNode and child.visible:
				var nid = String(child.name)
				if not blueprint.blocks.has(nid):
					continue
				if disabled_block_types.get(blueprint.blocks[nid]["xsi_type"], false):
					continue
				if Rect2(child.position_offset, child.size).has_point(mp_graph):
					new_hovered_node = nid
					break
					
		if new_hovered_node == "" and config.use_smart_astar_wires:
			var best_dist := 10.0 / graph_edit.zoom
			for w_info in cached_graph_wires:
				if w_info["is_filtered"]:
					continue
				var pts: PackedVector2Array = w_info["graph_pts"]
				for i in range(pts.size() - 1):
					var seg_pt = Geometry2D.get_closest_point_to_segment(mp_graph, pts[i], pts[i + 1])
					var d = mp_graph.distance_to(seg_pt)
					if d < best_dist:
						best_dist = d
						new_hovered_wire = w_info
						
	var hover_changed = (new_hovered_node != hovered_node_id) or (new_hovered_wire != hovered_wire_info)
	var prev_hovered_node = hovered_node_id
	hovered_node_id = new_hovered_node
	hovered_wire_info = new_hovered_wire
	
	var is_shift = Input.is_key_pressed(KEY_SHIFT)
	if is_shift != shift_held_last_frame or (is_shift and prev_hovered_node != hovered_node_id):
		shift_held_last_frame = is_shift
		if prev_hovered_node != "" and blueprint.blocks.has(prev_hovered_node):
			_rebuild_single_graph_node_slots(prev_hovered_node)
			if graph_edit.has_node(NodePath(prev_hovered_node)):
				# Shrink node height back to its minimum compact size immediately on Shift release (#30.2)!
				var p_gn: GraphNode = graph_edit.get_node(NodePath(prev_hovered_node))
				p_gn.custom_minimum_size.y = 60.0
				p_gn.size = Vector2(p_gn.size.x, 0.0)
				p_gn.reset_size()
		if hovered_node_id != "" and blueprint.blocks.has(hovered_node_id):
			_rebuild_single_graph_node_slots(hovered_node_id)
			
	if hover_changed:
		var active_wire = hovered_wire_info if not hovered_wire_info.is_empty() else selected_wire_info
		ship_3d.update_highlights_only(blueprint, config, selected_node_ids, hovered_node_id, active_wire, disabled_block_types, disabled_actions)
		fg_overlay.queue_redraw()
		
	if outline_dirty:
		outline_dirty = false
		_update_runtime_outline_tree()

# ==============================================================================
# SECTION: CONTINUOUS-SWEEP CHECKBOXES (#21), WIRE CLICK & RECTANGLE DRAG
# ==============================================================================
func _input(event: InputEvent) -> void:
	if not graph_container or not graph_edit:
		return
		
	# 1. CONTINUOUS-SWEEP BLENDER CHECKBOX TOGGLE (#21 - Never skips even at high mouse speeds!)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed:
			blender_drag_active = false
		else:
			for fc in filter_checkboxes:
				var chk: CheckBox = fc["chk"]
				if is_instance_valid(chk) and chk.is_visible_in_tree() and chk.get_global_rect().has_point(event.global_position):
					if Input.is_key_pressed(KEY_SHIFT):
						_solo_visibility_filter_item(fc["kind"], fc["key"])
					else:
						blender_drag_active = true
						blender_drag_target_state = not chk.button_pressed
						blender_drag_last_y = event.global_position.y
						_set_filter_checkbox_state(fc, blender_drag_target_state)
					get_viewport().set_input_as_handled()
					return
	elif event is InputEventMouseMotion and blender_drag_active:
		var cur_y: float = event.global_position.y
		var min_y: float = min(blender_drag_last_y, cur_y)
		var max_y: float = max(blender_drag_last_y, cur_y)
		blender_drag_last_y = cur_y
		var changed_any := false
		for fc in filter_checkboxes:
			var chk: CheckBox = fc["chk"]
			if is_instance_valid(chk) and chk.is_visible_in_tree():
				var r: Rect2 = chk.get_global_rect()
				if max_y >= r.position.y and min_y <= r.end.y and event.global_position.x >= r.position.x - 40.0 and event.global_position.x <= r.end.x + 40.0:
					if chk.button_pressed != blender_drag_target_state:
						chk.set_pressed_no_signal(blender_drag_target_state)
						if fc["kind"] == "block":
							if blender_drag_target_state: disabled_block_types.erase(fc["key"])
							else: disabled_block_types[fc["key"]] = true
						else:
							if blender_drag_target_state: disabled_actions.erase(fc["key"])
							else: disabled_actions[fc["key"]] = true
						changed_any = true
		if changed_any:
			_apply_visibility_filters_to_nodes_and_3d()
		get_viewport().set_input_as_handled()
		return
		
	# 2. KEYBOARD SHORTCUTS (DELETE ITEM & REORGANIZE GRAPH #34.2)
	if event is InputEventKey and event.pressed and not event.echo:
		var focus_owner = get_viewport().gui_get_focus_owner()
		if focus_owner is LineEdit or focus_owner is TextEdit:
			return
		var del_key: int = int(config.keybinds.get("delete_item", KEY_DELETE))
		var reorg_key: int = int(config.keybinds.get("reorganize_graph", KEY_R))
		if event.keycode == del_key:
			if not hovered_wire_info.is_empty():
				_delete_hovered_wire(hovered_wire_info)
				get_viewport().set_input_as_handled()
				return
			elif not selected_wire_info.is_empty():
				_delete_hovered_wire(selected_wire_info)
				selected_wire_info.clear()
				get_viewport().set_input_as_handled()
				return
			elif hovered_node_id != "" and blueprint.blocks.has(hovered_node_id):
				_delete_block_and_refresh(hovered_node_id)
				get_viewport().set_input_as_handled()
				return
			elif not selected_node_ids.is_empty():
				for sel_id in selected_node_ids.keys():
					blueprint.delete_block(sel_id)
				selected_node_ids.clear()
				_mark_unsaved(true)
				_refresh_views()
				get_viewport().set_input_as_handled()
				return
		elif event.keycode == reorg_key and Input.is_key_pressed(KEY_CTRL):
			_force_recompute_smart_layout()
			get_viewport().set_input_as_handled()
			return
			
	# 3. GRAPH CANVAS INTERACTION (PORTS #27, INLINE RENAME #25/#26.2, RECTANGLES & LASSO)
	var mp_local: Vector2 = graph_container.get_local_mouse_position()
	var in_graph_bounds: bool = Rect2(Vector2.ZERO, graph_container.size).has_point(mp_local)
	if not in_graph_bounds and active_box_op == "" and not lasso_active:
		return
	var mp_graph: Vector2 = (mp_local + graph_edit.scroll_offset) / graph_edit.zoom
	
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# Close inline rename box if clicking outside it
			if inline_canvas_edit and inline_canvas_edit.visible:
				if not inline_canvas_edit.get_global_rect().has_point(event.global_position):
					_commit_inline_canvas_rename()
					
			# NEVER intercept LMB if clicking near any input/output port grab circle (#27)!
			if _is_mouse_near_any_node_port(mp_graph):
				return
				
			# Seamless in-canvas double-click rename on any GraphNode (#26.2)!
			if event.double_click and hovered_node_id != "" and blueprint.blocks.has(hovered_node_id):
				var gn: GraphNode = graph_edit.get_node(NodePath(hovered_node_id))
				var sr := Rect2(gn.position_offset * graph_edit.zoom - graph_edit.scroll_offset, Vector2(gn.size.x * graph_edit.zoom, 28.0))
				_start_inline_canvas_rename("node", hovered_node_id, blueprint.blocks[hovered_node_id]["custom_name"], sr)
				get_viewport().set_input_as_handled()
				return
				
			# Clicking a hovered 2D wire selects it
			if hovered_node_id == "" and not hovered_wire_info.is_empty():
				selected_wire_info = hovered_wire_info.duplicate()
				ship_3d.update_highlights_only(blueprint, config, selected_node_ids, hovered_node_id, selected_wire_info, disabled_block_types, disabled_actions)
				fg_overlay.queue_redraw()
				return
			else:
				selected_wire_info.clear()
				
			var lasso_key: int = int(config.keybinds.get("lasso_modifier", KEY_CTRL))
			if hovered_node_id == "" and Input.is_key_pressed(lasso_key):
				lasso_active = true
				lasso_start_screen = mp_local
				lasso_current_screen = mp_local
				get_viewport().set_input_as_handled()
				return
				
			if hovered_node_id == "":
				for c_i in range(blueprint.comments.size() - 1, -1, -1):
					var c = blueprint.comments[c_i]
					var cr = Rect2(c["pos"], c["size"])
					var edges = _hit_test_rect_edges(cr, mp_graph, 12.0 / graph_edit.zoom)
					if event.double_click and cr.has_point(mp_graph):
						_open_box_text_editor(false, c_i, c["text"])
						get_viewport().set_input_as_handled()
						return
					elif edges != 0:
						active_box_op = "resize_comment"
						active_box_idx = c_i
						active_resize_edges = edges
						box_drag_start_mouse_graph = mp_graph
						box_start_rect = cr
						get_viewport().set_input_as_handled()
						return
					elif cr.has_point(mp_graph):
						active_box_op = "move_comment"
						active_box_idx = c_i
						box_drag_start_mouse_graph = mp_graph
						box_start_rect = cr
						get_viewport().set_input_as_handled()
						return
						
				var rect_order: Array[int] = []
				for r_i in blueprint.org_rects.size(): rect_order.append(r_i)
				rect_order.sort_custom(func(a, b):
					var sa = blueprint.org_rects[a]["size"]
					var sb = blueprint.org_rects[b]["size"]
					return (sa.x * sa.y) < (sb.x * sb.y)
				)
				for r_i in rect_order:
					var r = blueprint.org_rects[r_i]
					var rr = Rect2(r["pos"], r["size"])
					var margin = 14.0 / graph_edit.zoom
					var edges = _hit_test_rect_edges(rr, mp_graph, margin)
					if event.double_click and rr.has_point(mp_graph):
						# Seamless in-canvas double-click rename on Organization Rectangle (#25)!
						var sr := Rect2(rr.position * graph_edit.zoom - graph_edit.scroll_offset, Vector2(rr.size.x * graph_edit.zoom, 28.0))
						_start_inline_canvas_rename("rect", r_i, r["title"], sr)
						get_viewport().set_input_as_handled()
						return
					elif edges != 0:
						active_box_op = "resize_rect"
						active_box_idx = r_i
						active_resize_edges = edges
						box_drag_start_mouse_graph = mp_graph
						box_start_rect = rr
						get_viewport().set_input_as_handled()
						return
					elif rr.has_point(mp_graph):
						active_box_op = "move_rect"
						active_box_idx = r_i
						selected_rect_indices[r_i] = true
						box_drag_start_mouse_graph = mp_graph
						box_start_rect = rr
						_record_enclosed_elements_for_rect(r_i, rr)
						get_viewport().set_input_as_handled()
						return
						
				selected_rect_indices.clear()
				lasso_active = true
				lasso_start_screen = mp_local
				lasso_current_screen = mp_local
		else:
			if active_box_op != "":
				active_box_op = ""
				active_box_idx = -1
				_mark_unsaved(true)
				get_viewport().set_input_as_handled()
				return
			if lasso_active:
				lasso_active = false
				if lasso_start_screen.distance_to(lasso_current_screen) > 8.0:
					_finalize_lasso_selection()
				fg_overlay.queue_redraw()
				return
				
	elif event is InputEventMouseMotion:
		if active_box_op != "":
			var delta_g = mp_graph - box_drag_start_mouse_graph
			if active_box_op == "move_comment":
				blueprint.comments[active_box_idx]["pos"] = box_start_rect.position + delta_g
			elif active_box_op == "resize_comment":
				var nr = _apply_8way_resize(box_start_rect, delta_g, active_resize_edges, Vector2(120, 60))
				blueprint.comments[active_box_idx]["pos"] = nr.position
				blueprint.comments[active_box_idx]["size"] = nr.size
			elif active_box_op == "resize_rect":
				var nr = _apply_8way_resize(box_start_rect, delta_g, active_resize_edges, Vector2(180, 110))
				blueprint.org_rects[active_box_idx]["pos"] = nr.position
				blueprint.org_rects[active_box_idx]["size"] = nr.size
				outline_dirty = true
			elif active_box_op == "move_rect":
				is_syncing_multi_move = true
				blueprint.org_rects[active_box_idx]["pos"] = box_start_rect.position + delta_g
				for nid in enclosed_nodes_at_drag_start:
					var np = enclosed_nodes_at_drag_start[nid] + delta_g
					blueprint.blocks[nid]["graph_pos"] = np
					node_last_positions[nid] = np
					if graph_edit.has_node(NodePath(nid)):
						graph_edit.get_node(NodePath(nid)).position_offset = np
				for child_ri in enclosed_rects_at_drag_start:
					blueprint.org_rects[child_ri]["pos"] = enclosed_rects_at_drag_start[child_ri] + delta_g
				for child_ci in enclosed_comments_at_drag_start:
					blueprint.comments[child_ci]["pos"] = enclosed_comments_at_drag_start[child_ci] + delta_g
				is_syncing_multi_move = false
				outline_dirty = true
				wires_dirty = true
			bg_overlay.queue_redraw()
			fg_overlay.queue_redraw()
			get_viewport().set_input_as_handled()
		elif lasso_active:
			lasso_current_screen = mp_local
			fg_overlay.queue_redraw()

func _hit_test_rect_edges(r: Rect2, pt: Vector2, tol: float) -> int:
	if not r.grow(tol).has_point(pt):
		return 0
	var mask := 0
	if abs(pt.x - r.position.x) <= tol: mask |= 1
	elif abs(pt.x - r.end.x) <= tol: mask |= 2
	if abs(pt.y - r.position.y) <= tol: mask |= 4
	elif abs(pt.y - r.end.y) <= tol: mask |= 8
	return mask

func _apply_8way_resize(start_r: Rect2, delta: Vector2, mask: int, min_sz: Vector2) -> Rect2:
	var left = start_r.position.x
	var right = start_r.end.x
	var top = start_r.position.y
	var bottom = start_r.end.y
	if (mask & 1) != 0: left = min(left + delta.x, right - min_sz.x)
	if (mask & 2) != 0: right = max(right + delta.x, left + min_sz.x)
	if (mask & 4) != 0: top = min(top + delta.y, bottom - min_sz.y)
	if (mask & 8) != 0: bottom = max(bottom + delta.y, top + min_sz.y)
	return Rect2(Vector2(left, top), Vector2(right - left, bottom - top))

func _record_enclosed_elements_for_rect(rect_idx: int, rr: Rect2) -> void:
	enclosed_nodes_at_drag_start.clear()
	enclosed_rects_at_drag_start.clear()
	enclosed_comments_at_drag_start.clear()
	for child in graph_edit.get_children():
		if child is GraphNode:
			var center = child.position_offset + child.size * 0.5
			if rr.has_point(center):
				enclosed_nodes_at_drag_start[String(child.name)] = child.position_offset
	for i in blueprint.org_rects.size():
		if i != rect_idx:
			var other_r = Rect2(blueprint.org_rects[i]["pos"], blueprint.org_rects[i]["size"])
			if rr.encloses(other_r):
				enclosed_rects_at_drag_start[i] = blueprint.org_rects[i]["pos"]
	for i in blueprint.comments.size():
		var com_r = Rect2(blueprint.comments[i]["pos"], blueprint.comments[i]["size"])
		if rr.intersects(com_r):
			enclosed_comments_at_drag_start[i] = blueprint.comments[i]["pos"]

func _finalize_lasso_selection() -> void:
	var l_rect_screen = Rect2(
		Vector2(min(lasso_start_screen.x, lasso_current_screen.x), min(lasso_start_screen.y, lasso_current_screen.y)),
		Vector2(abs(lasso_current_screen.x - lasso_start_screen.x), abs(lasso_current_screen.y - lasso_start_screen.y))
	)
	if not Input.is_key_pressed(KEY_CTRL):
		selected_node_ids.clear()
		selected_rect_indices.clear()
		for child in graph_edit.get_children():
			if child is GraphNode:
				child.selected = false
	var z = graph_edit.zoom
	var sc = graph_edit.scroll_offset
	for child in graph_edit.get_children():
		if child is GraphNode and child.visible:
			var nid = String(child.name)
			if disabled_block_types.get(blueprint.blocks.get(nid, {}).get("xsi_type", ""), false):
				continue
			var nr_screen = Rect2(child.position_offset * z - sc, child.size * z)
			if l_rect_screen.intersects(nr_screen):
				selected_node_ids[nid] = true
				child.selected = true
	for r_i in blueprint.org_rects.size():
		var r = blueprint.org_rects[r_i]
		var rr_screen = Rect2(r["pos"] * z - sc, r["size"] * z)
		if l_rect_screen.intersects(rr_screen):
			selected_rect_indices[r_i] = true
			var rr_graph = Rect2(r["pos"], r["size"])
			for child in graph_edit.get_children():
				if child is GraphNode and rr_graph.has_point(child.position_offset + child.size * 0.5):
					selected_node_ids[String(child.name)] = true
					child.selected = true
	ship_3d.update_highlights_only(blueprint, config, selected_node_ids, hovered_node_id, hovered_wire_info, disabled_block_types, disabled_actions)
	bg_overlay.queue_redraw()
	fg_overlay.queue_redraw()

# ==============================================================================
# SECTION: WINDOW NOTIFICATIONS & BACKUPS
# ==============================================================================
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if has_unsaved_changes:
			quit_confirm_dialog.popup_centered()
		else:
			get_tree().quit()

func _mark_unsaved(is_dirty: bool = true) -> void:
	has_unsaved_changes = is_dirty
	outline_dirty = true
	wires_dirty = true
	var file_label = current_file_path.get_file() if current_file_path != "" else blueprint.grid_name
	var prefix = "* " if has_unsaved_changes else ""
	DisplayServer.window_set_title("%sSE Blueprint Logic Architect - [%s]" % [prefix, file_label])

func _set_status(msg: String) -> void:
	var dirty_tag = " [UNSAVED]" if has_unsaved_changes else " [Saved]"
	status_label.text = " " + msg + dirty_tag

func _get_se_blueprints_dir() -> String:
	var os_name = OS.get_name()
	if os_name == "Windows":
		var appdata = OS.get_environment("APPDATA")
		if appdata != "":
			var win_path = appdata.path_join("SpaceEngineers/Blueprints/local")
			if DirAccess.dir_exists_absolute(win_path):
				return win_path
	elif os_name == "Linux":
		var home = OS.get_environment("HOME")
		for c in [
			home.path_join(".steam/steam/steamapps/compatdata/244850/pfx/drive_c/users/steamuser/AppData/Roaming/SpaceEngineers/Blueprints/local"),
			home.path_join(".local/share/Steam/steamapps/compatdata/244850/pfx/drive_c/users/steamuser/AppData/Roaming/SpaceEngineers/Blueprints/local")
		]:
			if DirAccess.dir_exists_absolute(c):
				return c
	return OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)

func _create_rolling_backup_before_save(target_path: String) -> void:
	if not FileAccess.file_exists(target_path):
		return
	var iso_dt = Time.get_datetime_string_from_system(false, false).replace(":", "-")
	var backup_path = "%s.backup-%s~" % [target_path, iso_dt]
	DirAccess.copy_absolute(target_path, backup_path)
	
	var base_dir = target_path.get_base_dir()
	var base_file = target_path.get_file() + ".backup-"
	var dir = DirAccess.open(base_dir)
	if not dir:
		return
	var backups: Array[String] = []
	dir.list_dir_begin()
	var fn = dir.get_next()
	while fn != "":
		if not dir.current_is_dir() and fn.begins_with(base_file) and fn.ends_with("~"):
			backups.append(base_dir.path_join(fn))
		fn = dir.get_next()
	dir.list_dir_end()
	backups.sort()
	while backups.size() > 4:
		var oldest = backups.pop_front()
		DirAccess.remove_absolute(oldest)

# ==============================================================================
# SECTION: GODOT-STYLE DOCKABLE WORKSPACE SYSTEM (#22)
# ==============================================================================
# Wraps any UI panel in a dockable container with a dock-slot selector ("L-Top",
# "L-Bot", "R-Top", "R-Bot", or "Float" in an OS Window) so the user can freely
# rearrange tabs or float windows just like the Godot Editor!
func _create_dockable_panel(panel_id: String, tab_title: String, content: Control, initial_slot: String) -> Control:
	var wrapper = VBoxContainer.new()
	wrapper.name = tab_title
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	var dock_bar = HBoxContainer.new()
	var title_lbl = Label.new()
	title_lbl.text = " " + tab_title
	title_lbl.add_theme_color_override("font_color", Color(0.75, 0.82, 0.92))
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dock_bar.add_child(title_lbl)
	
	var dock_dd = OptionButton.new()
	var slot_names = ["L-Top", "L-Bot", "R-Top", "R-Bot", "Float"]
	for i in slot_names.size():
		dock_dd.add_item("Dock: " + slot_names[i], i)
		if slot_names[i] == initial_slot:
			dock_dd.selected = i
	dock_dd.item_selected.connect(func(idx):
		_move_panel_to_dock_slot(panel_id, slot_names[idx], dock_dd)
	)
	dock_bar.add_child(dock_dd)
	wrapper.add_child(dock_bar)
	
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrapper.add_child(content)
	
	dock_panels[panel_id] = wrapper
	_move_panel_to_dock_slot(panel_id, initial_slot, dock_dd)
	return wrapper

func _move_panel_to_dock_slot(panel_id: String, target_slot: String, dropdown: OptionButton = null) -> void:
	var panel: Control = dock_panels.get(panel_id)
	if not panel:
		return
	if panel.get_parent():
		panel.get_parent().remove_child(panel)
		
	if floating_windows.has(panel_id):
		var old_win: Window = floating_windows[panel_id]
		floating_windows.erase(panel_id)
		if is_instance_valid(old_win):
			old_win.queue_free()
			
	if target_slot == "Float":
		var win = Window.new()
		win.title = panel.name
		win.size = Vector2i(520, 420)
		win.position = Vector2i(180, 140)
		win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		win.content_scale_factor = config.ui_scale
		win.close_requested.connect(func():
			if dropdown: dropdown.selected = 0
			_move_panel_to_dock_slot(panel_id, "L-Top", dropdown)
		)
		add_child(win)
		panel.set_anchors_preset(Control.PRESET_FULL_RECT)
		win.add_child(panel)
		win.show()
		floating_windows[panel_id] = win
	else:
		var tc: TabContainer = dock_slots.get(target_slot)
		if tc:
			tc.add_child(panel)
			tc.current_tab = tc.get_tab_count() - 1
	_update_dock_containers_visibility()

func _update_dock_containers_visibility() -> void:
	for k in dock_slots:
		var tc: TabContainer = dock_slots[k]
		tc.visible = (tc.get_child_count() > 0)
	if left_vsplit:
		left_vsplit.visible = (dock_slots["L-Top"].visible or dock_slots["L-Bot"].visible)
	if right_vsplit:
		right_vsplit.visible = (dock_slots["R-Top"].visible or dock_slots["R-Bot"].visible)

func _build_ui() -> void:
	var bg = PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg_style = StyleBoxFlat.new()
	bg_style.bg_color = Color(0.10, 0.11, 0.14)
	bg.add_theme_stylebox_override("panel", bg_style)
	add_child(bg)
	
	var root_vbox = VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 4)
	bg.add_child(root_vbox)
	
	var top_bar = HBoxContainer.new()
	top_bar.add_theme_constant_override("separation", 12)
	root_vbox.add_child(top_bar)
	
	var menu_bar = MenuBar.new()
	top_bar.add_child(menu_bar)
	
	# 1. FILE MENU
	var file_menu = PopupMenu.new()
	file_menu.name = "File"
	file_menu.add_item("Open Blueprint (.sbc)...", 1)
	
	recent_submenu = PopupMenu.new()
	recent_submenu.name = "OpenRecent"
	recent_submenu.id_pressed.connect(_on_recent_file_selected)
	file_menu.add_child(recent_submenu)
	file_menu.add_submenu_item("Open Recent", "OpenRecent", 2)
	_rebuild_recent_files_menu()
	
	file_menu.add_separator()
	file_menu.add_item("Save Blueprint (With Layout in CustomData)", 3)
	file_menu.add_item("Save Blueprint As...", 4)
	file_menu.add_item("Save Blueprint WITHOUT Editor CustomData...", 5)
	file_menu.add_separator()
	file_menu.add_item("Copy .sbc XML to Clipboard", 6)
	file_menu.add_item("Reset Demo Ship", 7)
	file_menu.id_pressed.connect(_on_file_menu_id)
	menu_bar.add_child(file_menu)
	
	# 2. ADD & EDIT MENU
	var edit_menu = PopupMenu.new()
	edit_menu.name = "Add & Edit"
	edit_menu.add_item("+ Add Timer Block (Replaces Dummy)", 1)
	edit_menu.add_item("+ Add Event Controller (Replaces Dummy)", 2)
	edit_menu.add_separator()
	edit_menu.add_item("+ Add Sticky Comment (Double-Click to Edit Text)", 3)
	edit_menu.add_item("+ Add Organization Rectangle (Click Inside to Move, 8-Way Resize)", 4)
	edit_menu.add_separator()
	edit_menu.add_item("Delete Selected / Hovered Block or Wire (Del)", 5)
	edit_menu.add_item("Re-Run 2D Grid Auto-Layout & AStar Routing", 6)
	edit_menu.id_pressed.connect(_on_edit_menu_id)
	menu_bar.add_child(edit_menu)
	
	# 3. VIEW MENU
	var view_menu = PopupMenu.new()
	view_menu.name = "View"
	view_menu.add_check_item("Use Smart AStar Routed Wires (vs Vanilla Bezier Lines)", 1)
	view_menu.set_item_checked(0, config.use_smart_astar_wires)
	view_menu.add_check_item("Hide Unused Logic Blocks", 2)
	view_menu.set_item_checked(1, config.hide_unused_blocks)
	view_menu.add_check_item("Create Groups for Unused Blocks", 3)
	view_menu.set_item_checked(2, config.create_groups_for_unused_blocks)
	view_menu.add_check_item("Show Action Labels Above 2D Wires", 4)
	view_menu.set_item_checked(3, config.show_wire_labels)
	view_menu.add_check_item("Show Action Labels in 3D View on Selected Wires", 5)
	view_menu.set_item_checked(4, config.show_3d_selected_wire_labels)
	view_menu.add_check_item("Show Initial Letters (T, E, W...) on 3D Block Faces", 6)
	view_menu.set_item_checked(5, config.show_3d_block_letters)
	view_menu.add_check_item("Show Initial Letters on 3D Wires", 7)
	view_menu.set_item_checked(6, config.show_3d_wire_letters)
	view_menu.add_check_item("Show Clamped Group Overview Titles When Zoomed Out", 8)
	view_menu.set_item_checked(7, config.show_zoomed_out_group_titles)
	view_menu.add_check_item("Show Friendly In-Game Block Names", 9)
	view_menu.set_item_checked(8, config.show_friendly_names)
	view_menu.add_check_item("Show Animated Data Flow Pulses on Wires", 10)
	view_menu.set_item_checked(9, config.show_data_flow_pulses)
	view_menu.add_check_item("Show Top-Right Controls & Shortcuts Overlay", 11)
	view_menu.set_item_checked(10, config.show_controls_overlay)
	view_menu.id_pressed.connect(func(id):
		match id:
			1:
				config.use_smart_astar_wires = not config.use_smart_astar_wires
				view_menu.set_item_checked(0, config.use_smart_astar_wires)
				_update_vanilla_connection_layer_visibility()
			2:
				config.hide_unused_blocks = not config.hide_unused_blocks
				view_menu.set_item_checked(1, config.hide_unused_blocks)
			3:
				config.create_groups_for_unused_blocks = not config.create_groups_for_unused_blocks
				view_menu.set_item_checked(2, config.create_groups_for_unused_blocks)
			4:
				config.show_wire_labels = not config.show_wire_labels
				view_menu.set_item_checked(3, config.show_wire_labels)
			5:
				config.show_3d_selected_wire_labels = not config.show_3d_selected_wire_labels
				view_menu.set_item_checked(4, config.show_3d_selected_wire_labels)
			6:
				config.show_3d_block_letters = not config.show_3d_block_letters
				view_menu.set_item_checked(5, config.show_3d_block_letters)
			7:
				config.show_3d_wire_letters = not config.show_3d_wire_letters
				view_menu.set_item_checked(6, config.show_3d_wire_letters)
			8:
				config.show_zoomed_out_group_titles = not config.show_zoomed_out_group_titles
				view_menu.set_item_checked(7, config.show_zoomed_out_group_titles)
			9:
				config.show_friendly_names = not config.show_friendly_names
				view_menu.set_item_checked(8, config.show_friendly_names)
			10:
				config.show_data_flow_pulses = not config.show_data_flow_pulses
				view_menu.set_item_checked(9, config.show_data_flow_pulses)
			11:
				config.show_controls_overlay = not config.show_controls_overlay
				view_menu.set_item_checked(10, config.show_controls_overlay)
				if controls_overlay_panel:
					controls_overlay_panel.visible = config.show_controls_overlay
		config.save_config()
		_refresh_views()
	)
	menu_bar.add_child(view_menu)
	
	# 4. MULTIPLAYER MENU
	var mp_menu = PopupMenu.new()
	mp_menu.name = "Multiplayer (P2P)"
	mp_menu.add_item("Open P2P Connection & GitHub Gist Lobby...", 1)
	mp_menu.id_pressed.connect(func(_id): p2p_dialog.popup_centered(Vector2i(520, 220)))
	menu_bar.add_child(mp_menu)
	
	# 5. SETTINGS MENU
	var settings_menu = PopupMenu.new()
	settings_menu.name = "Settings"
	settings_menu.add_item("Configure Colors, Dimmed Filter Color & UI Scale...", 1)
	settings_menu.id_pressed.connect(func(_id): settings_dialog.popup_centered(Vector2i(540, 540)))
	menu_bar.add_child(settings_menu)
	
	var top_spacer = Control.new()
	top_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(top_spacer)
	
	var hint_lbl = Label.new()
	hint_lbl.text = "Shift+Hover: All Ports | Ctrl+Drag: Lasso | Docks: Move/Tab/Float Any Panel  "
	hint_lbl.add_theme_color_override("font_color", Color(0.65, 0.70, 0.78))
	top_bar.add_child(hint_lbl)
	
	dummy_counter_label = Label.new()
	dummy_counter_label.text = "Dummy Slots Free: 0  "
	dummy_counter_label.add_theme_color_override("font_color", Color(0.3, 0.9, 1.0))
	top_bar.add_child(dummy_counter_label)
	
	# --- GODOT-STYLE DOCKABLE SPLIT WORKSPACE (#22) ---
	main_hsplit = HSplitContainer.new()
	main_hsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_hsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_hsplit.split_offset = 260
	root_vbox.add_child(main_hsplit)
	
	left_vsplit = VSplitContainer.new()
	left_vsplit.custom_minimum_size = Vector2(180, 0)
	left_vsplit.split_offset = 280
	main_hsplit.add_child(left_vsplit)
	
	dock_slots["L-Top"] = TabContainer.new()
	dock_slots["L-Top"].size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_vsplit.add_child(dock_slots["L-Top"])
	
	dock_slots["L-Bot"] = TabContainer.new()
	dock_slots["L-Bot"].size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_vsplit.add_child(dock_slots["L-Bot"])
	
	right_hsplit = HSplitContainer.new()
	right_hsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_hsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_hsplit.split_offset = 920
	main_hsplit.add_child(right_hsplit)
	
	# Center Main Graph View
	graph_container = Control.new()
	graph_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graph_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph_container.clip_contents = true
	right_hsplit.add_child(graph_container)
	
	graph_edit = GraphEdit.new()
	graph_edit.set_anchors_preset(Control.PRESET_FULL_RECT)
	graph_edit.right_disconnects = true
	graph_edit.zoom_min = 0.03
	graph_edit.zoom_max = 3.0
	graph_edit.connection_request.connect(_on_connection_request)
	graph_edit.disconnection_request.connect(_on_disconnection_request)
	graph_edit.node_selected.connect(func(node: Node):
		selected_node_ids[String(node.name)] = true
		ship_3d.update_highlights_only(blueprint, config, selected_node_ids, hovered_node_id, hovered_wire_info, disabled_block_types, disabled_actions)
		fg_overlay.queue_redraw()
	)
	graph_edit.node_deselected.connect(func(node: Node):
		selected_node_ids.erase(String(node.name))
		ship_3d.update_highlights_only(blueprint, config, selected_node_ids, hovered_node_id, hovered_wire_info, disabled_block_types, disabled_actions)
		fg_overlay.queue_redraw()
	)
	graph_container.add_child(graph_edit)
	
	bg_overlay = GraphCustomOverlay.new()
	bg_overlay.main_app = self
	bg_overlay.is_background = true
	bg_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	graph_container.add_child(bg_overlay)
	
	fg_overlay = GraphCustomOverlay.new()
	fg_overlay.main_app = self
	fg_overlay.is_background = false
	fg_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	fg_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	graph_container.add_child(fg_overlay)
	
	# Right Dock Split (R-Top & R-Bot TabContainers)
	right_vsplit = VSplitContainer.new()
	right_vsplit.custom_minimum_size = Vector2(200, 0)
	right_vsplit.split_offset = 440
	right_hsplit.add_child(right_vsplit)
	
	dock_slots["R-Top"] = TabContainer.new()
	dock_slots["R-Top"].size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vsplit.add_child(dock_slots["R-Top"])
	
	dock_slots["R-Bot"] = TabContainer.new()
	dock_slots["R-Bot"].size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vsplit.add_child(dock_slots["R-Bot"])
	
	# --- CREATE THE 4 DOCKABLE PANELS (#22) ---
	# Dock Panel 1: Live Organization Outline (Left Top)
	outline_tree = Tree.new()
	outline_tree.hide_root = false
	outline_tree.item_selected.connect(_on_outline_item_selected)
	_create_dockable_panel("outline", "Organization Outline", outline_tree, "L-Top")
	
	# Dock Panel 2: 3D Ship Preview (Right Top)
	var vp_wrapper = Control.new()
	vp_wrapper.custom_minimum_size = Vector2(180, 120)
	vp_wrapper.clip_contents = true
	var sub_vp_container = SubViewportContainer.new()
	sub_vp_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	sub_vp_container.stretch = true
	sub_vp_container.gui_input.connect(func(ev): ship_3d.handle_viewport_input(ev))
	vp_wrapper.add_child(sub_vp_container)
	var sub_vp = SubViewport.new()
	sub_vp_container.add_child(sub_vp)
	ship_3d = ShipPreview3D.new()
	ship_3d.block_clicked_in_3d.connect(_on_3d_block_clicked)
	ship_3d.wire_clicked_in_3d.connect(_on_3d_wire_clicked)
	sub_vp.add_child(ship_3d)
	var vp_overlay_bar = HBoxContainer.new()
	vp_overlay_bar.position = Vector2(8, 8)
	vp_wrapper.add_child(vp_overlay_bar)
	var btn_reset_cam = Button.new()
	btn_reset_cam.text = "Reset Center"
	btn_reset_cam.pressed.connect(func(): ship_3d.reset_camera_to_center())
	vp_overlay_bar.add_child(btn_reset_cam)
	_create_dockable_panel("preview3d", "3D Ship Preview", vp_wrapper, "R-Top")
	
	# Dock Panel 3: Merged Visibility Filters & Wire Action Color Legend on the Right (#35)!
	var filter_scroll = ScrollContainer.new()
	filter_vbox = VBoxContainer.new()
	filter_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	filter_scroll.add_child(filter_vbox)
	legend_vbox = filter_vbox # Merged into the same dockable panel (#35)
	_create_dockable_panel("filters", "Filters & Wire Legend", filter_scroll, "R-Bot")
	
	# Top-Right Comprehensive Controls & Features Graph Overlay (#34)
	_build_top_right_controls_overlay()
	
	status_label = Label.new()
	status_label.text = " Ready."
	root_vbox.add_child(status_label)

func _on_3d_block_clicked(entity_id: String, ctrl_held: bool) -> void:
	selected_wire_info.clear()
	if not ctrl_held:
		selected_node_ids.clear()
		for child in graph_edit.get_children():
			if child is GraphNode:
				child.selected = false
	selected_node_ids[entity_id] = true
	if graph_edit.has_node(NodePath(entity_id)):
		var gn: GraphNode = graph_edit.get_node(NodePath(entity_id))
		gn.selected = true
		graph_edit.scroll_offset = (gn.position_offset + gn.size * 0.5) * graph_edit.zoom - graph_container.size * 0.5
	ship_3d.update_highlights_only(blueprint, config, selected_node_ids, hovered_node_id, hovered_wire_info, disabled_block_types, disabled_actions)
	fg_overlay.queue_redraw()
	_set_status("Selected block '%s' from 3D Preview." % blueprint.blocks[entity_id]["custom_name"])

# Handles clicking a wire in the 3D preview to highlight it and its connected nodes in 3D & 2D (#18)
func _on_3d_wire_clicked(w_info: Dictionary) -> void:
	selected_wire_info = w_info.duplicate()
	selected_wire_info["selected_wire"] = true
	selected_node_ids.clear()
	selected_node_ids[w_info["src"]] = true
	selected_node_ids[w_info["dst"]] = true
	for child in graph_edit.get_children():
		if child is GraphNode:
			child.selected = selected_node_ids.has(String(child.name))
	if graph_edit.has_node(NodePath(w_info["src"])):
		var gn: GraphNode = graph_edit.get_node(NodePath(w_info["src"]))
		graph_edit.scroll_offset = (gn.position_offset + gn.size * 0.5) * graph_edit.zoom - graph_container.size * 0.5
	ship_3d.update_highlights_only(blueprint, config, selected_node_ids, hovered_node_id, selected_wire_info, disabled_block_types, disabled_actions)
	fg_overlay.queue_redraw()
	_set_status("Selected wire [%s -> %s (%s)] from 3D Preview." % [
		blueprint.blocks[w_info["src"]]["custom_name"],
		blueprint.blocks[w_info["dst"]]["custom_name"],
		w_info["action"]
	])

# ==============================================================================
# SECTION: VISIBILITY FILTERS & OUTLINE TREE
# ==============================================================================
func _rebuild_visibility_filter_panel() -> void:
	if not filter_vbox:
		return
	for c in filter_vbox.get_children():
		c.queue_free()
	filter_checkboxes.clear()
	
	var present_block_types: Dictionary = {}
	var present_actions: Dictionary = {}
	for id in blueprint.blocks:
		if not _should_display_block_in_graph(id):
			continue
		var b = blueprint.blocks[id]
		present_block_types[b["xsi_type"]] = present_block_types.get(b["xsi_type"], 0) + 1
		for s in b["slots"]:
			if s["target_id"] != "" and s["target_id"] != "0":
				present_actions[s["action"]] = present_actions.get(s["action"], 0) + 1
		if not b["monitored_blocks"].is_empty():
			present_actions["EventMonitor"] = present_actions.get("EventMonitor", 0) + b["monitored_blocks"].size()
			
	var lbl_bt = Label.new()
	lbl_bt.text = "Block Types (Drag-Sweep / Shift-Solo):"
	lbl_bt.add_theme_color_override("font_color", Color(0.65, 0.78, 0.95))
	filter_vbox.add_child(lbl_bt)
	
	for b_type in present_block_types.keys():
		var row = HBoxContainer.new()
		var swatch = ColorRect.new()
		swatch.custom_minimum_size = Vector2(12, 12)
		swatch.color = config.get_block_color(b_type)
		var chk = CheckBox.new()
		chk.text = "[%s] %s (%d)" % [config.get_block_initial(b_type), config.get_block_display_type(b_type), present_block_types[b_type]]
		chk.button_pressed = not disabled_block_types.get(b_type, false)
		chk.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(swatch)
		row.add_child(chk)
		filter_vbox.add_child(row)
		filter_checkboxes.append({"chk": chk, "kind": "block", "key": b_type})
		
	filter_vbox.add_child(HSeparator.new())
	var lbl_act = Label.new()
	lbl_act.text = "Events, Actions & Wire Legend (Drag / Shift-Solo):"
	lbl_act.add_theme_color_override("font_color", Color(0.95, 0.78, 0.55))
	filter_vbox.add_child(lbl_act)
	
	for act in present_actions.keys():
		var row = HBoxContainer.new()
		var st = config.get_action_style(act)
		var sw1 = ColorRect.new(); sw1.custom_minimum_size = Vector2(10, 12); sw1.color = config.get_action_color(act)
		var sw2 = ColorRect.new(); sw2.custom_minimum_size = Vector2(10, 12); sw2.color = config.get_action_secondary_color(act)
		var chk = CheckBox.new()
		chk.text = "[%s] %s [%s] (%d)" % [config.get_action_initial(act), config.get_action_display_name(act), st.get("pattern", "Solid"), present_actions[act]]
		chk.button_pressed = not disabled_actions.get(act, false)
		chk.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(sw1); row.add_child(sw2); row.add_child(chk)
		filter_vbox.add_child(row)
		filter_checkboxes.append({"chk": chk, "kind": "action", "key": act})

func _set_filter_checkbox_state(fc: Dictionary, state: bool) -> void:
	var chk: CheckBox = fc["chk"]
	chk.set_pressed_no_signal(state)
	if fc["kind"] == "block":
		if state: disabled_block_types.erase(fc["key"])
		else: disabled_block_types[fc["key"]] = true
	else:
		if state: disabled_actions.erase(fc["key"])
		else: disabled_actions[fc["key"]] = true
	_apply_visibility_filters_to_nodes_and_3d()

func _solo_visibility_filter_item(kind: String, key: String) -> void:
	var relevant_fcs = filter_checkboxes.filter(func(f): return f["kind"] == kind)
	var already_soloed = true
	for f in relevant_fcs:
		var expected = (f["key"] == key)
		if f["chk"].button_pressed != expected:
			already_soloed = false
			break
	for f in relevant_fcs:
		var target_state = true if already_soloed else (f["key"] == key)
		f["chk"].set_pressed_no_signal(target_state)
		if kind == "block":
			if target_state: disabled_block_types.erase(f["key"])
			else: disabled_block_types[f["key"]] = true
		else:
			if target_state: disabled_actions.erase(f["key"])
			else: disabled_actions[f["key"]] = true
	_apply_visibility_filters_to_nodes_and_3d()

func _apply_visibility_filters_to_nodes_and_3d() -> void:
	var dim_col = Color.from_string(config.dimmed_filter_color, Color(0.25, 0.27, 0.32))
	for child in graph_edit.get_children():
		if child is GraphNode:
			var id = String(child.name)
			if not blueprint.blocks.has(id):
				continue
			var b = blueprint.blocks[id]
			var is_dimmed = disabled_block_types.get(b["xsi_type"], false)
			child.modulate = Color(dim_col.r, dim_col.g, dim_col.b, 0.16) if is_dimmed else Color.WHITE
			child.mouse_filter = Control.MOUSE_FILTER_IGNORE if is_dimmed else Control.MOUSE_FILTER_STOP
	wires_dirty = true
	ship_3d.rebuild_mesh(blueprint, config, selected_node_ids, hovered_node_id, hovered_wire_info, disabled_block_types, disabled_actions)

# ==============================================================================
# SECTION: MENU & DIALOG HANDLERS
# ==============================================================================
func _rebuild_recent_files_menu() -> void:
	if not recent_submenu: return
	recent_submenu.clear()
	if config.recent_files.is_empty():
		recent_submenu.add_item("(No Recent Blueprints)", 999)
		recent_submenu.set_item_disabled(0, true)
		return
	for i in config.recent_files.size():
		recent_submenu.add_item(config.recent_files[i], i)

func _on_recent_file_selected(idx: int) -> void:
	if idx >= 0 and idx < config.recent_files.size():
		var path = config.recent_files[idx]
		if FileAccess.file_exists(path):
			_load_blueprint_from_path(path)
		else:
			_set_status("Recent file not found: " + path)

func _on_file_menu_id(id: int) -> void:
	match id:
		1:
			open_file_dialog.current_dir = _get_se_blueprints_dir()
			open_file_dialog.popup_centered(Vector2i(750, 480))
		3:
			save_without_custom_data_flag = false
			_on_save_blueprint_pressed()
		4:
			save_without_custom_data_flag = false
			save_file_dialog.current_dir = _get_se_blueprints_dir()
			save_file_dialog.popup_centered(Vector2i(750, 480))
		5:
			save_without_custom_data_flag = true
			save_file_dialog.current_dir = _get_se_blueprints_dir()
			save_file_dialog.popup_centered(Vector2i(750, 480))
		6:
			var xml = blueprint.export_to_sbc_xml(true)
			DisplayServer.clipboard_set(xml)
			_mark_unsaved(false)
			_set_status("Copied modified .sbc XML to clipboard (%d bytes)" % xml.length())
		7:
			_load_demo_blueprint()

func _on_edit_menu_id(id: int) -> void:
	match id:
		1: _spawn_new_logic_block("MyObjectBuilder_TimerBlock", "TimerBlockLarge", "New Timer")
		2: _spawn_new_logic_block("MyObjectBuilder_EventControllerBlock", "EventControllerLarge", "New Event Ctrl")
		3:
			blueprint.comments.append({
				"pos": graph_edit.scroll_offset / graph_edit.zoom + Vector2(220, 140),
				"size": Vector2(220, 95),
				"text": "Double-click to edit comment..."
			})
			_mark_unsaved(true)
		4:
			blueprint.org_rects.append({
				"pos": graph_edit.scroll_offset / graph_edit.zoom + Vector2(80, 80),
				"size": Vector2(480, 320),
				"title": "New Subsystem Group",
				"color": CLUSTER_PALETTE[blueprint.org_rects.size() % CLUSTER_PALETTE.size()]
			})
			_mark_unsaved(true)
		5:
			if not hovered_wire_info.is_empty():
				_delete_hovered_wire(hovered_wire_info)
			elif not selected_wire_info.is_empty():
				_delete_hovered_wire(selected_wire_info)
				selected_wire_info.clear()
			elif hovered_node_id != "":
				_delete_block_and_refresh(hovered_node_id)
		6:
			_force_recompute_smart_layout()

func _force_recompute_smart_layout() -> void:
	for id in blueprint.blocks:
		blueprint.blocks[id]["graph_pos"] = Vector2.INF
	blueprint.org_rects.clear()
	await _refresh_views()
	_mark_unsaved(true)
	_set_status("Re-computed 2D Grid Subsystem Layout & AStarGrid2D Non-Overlapping Wire Routes!")

func _build_dialogs() -> void:
	var default_se_dir = _get_se_blueprints_dir()
	
	open_file_dialog = FileDialog.new()
	open_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	open_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	open_file_dialog.use_native_dialog = true
	open_file_dialog.filters = PackedStringArray(["*.sbc ; Space Engineers Blueprint"])
	open_file_dialog.current_dir = default_se_dir
	open_file_dialog.file_selected.connect(_load_blueprint_from_path)
	add_child(open_file_dialog)
	
	save_file_dialog = FileDialog.new()
	save_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	save_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	save_file_dialog.use_native_dialog = true
	save_file_dialog.filters = PackedStringArray(["*.sbc ; Space Engineers Blueprint"])
	save_file_dialog.current_dir = default_se_dir
	save_file_dialog.current_file = "bp.sbc"
	save_file_dialog.file_selected.connect(_save_blueprint_to_path)
	add_child(save_file_dialog)
	
	quit_confirm_dialog = ConfirmationDialog.new()
	quit_confirm_dialog.title = "Unsaved Blueprint Changes"
	quit_confirm_dialog.dialog_text = "You have unsaved changes to your blueprint logic, comments, or layout.\nSave before closing?"
	quit_confirm_dialog.ok_button_text = "Save & Quit"
	quit_confirm_dialog.add_button("Discard & Quit", true, "discard")
	quit_confirm_dialog.confirmed.connect(func():
		quitting_after_save = true
		save_without_custom_data_flag = false
		_on_save_blueprint_pressed()
	)
	quit_confirm_dialog.custom_action.connect(func(action: StringName):
		if action == "discard":
			get_tree().quit()
	)
	add_child(quit_confirm_dialog)
	
	rule_warning_dialog = ConfirmationDialog.new()
	rule_warning_dialog.title = "Incompatible Monitored Blocks"
	rule_warning_dialog.ok_button_text = "Disconnect Incompatible & Change Rule"
	add_child(rule_warning_dialog)
	
	text_edit_dialog = AcceptDialog.new()
	text_edit_dialog.title = "Edit Text"
	text_edit_box = TextEdit.new()
	text_edit_box.custom_minimum_size = Vector2(360, 140)
	text_edit_dialog.add_child(text_edit_box)
	text_edit_dialog.confirmed.connect(func():
		if editing_box_index >= 0:
			if editing_is_rect and editing_box_index < blueprint.org_rects.size():
				blueprint.org_rects[editing_box_index]["title"] = text_edit_box.text.strip_edges()
			elif not editing_is_rect and editing_box_index < blueprint.comments.size():
				blueprint.comments[editing_box_index]["text"] = text_edit_box.text
			_mark_unsaved(true)
			bg_overlay.queue_redraw()
			fg_overlay.queue_redraw()
	)
	add_child(text_edit_dialog)
	
	p2p_dialog = AcceptDialog.new()
	p2p_dialog.title = "P2P Multiplayer (Direct WebRTC & GitHub Gist Lobby)"
	var p2p_vbox = VBoxContainer.new()
	p2p_dialog.add_child(p2p_vbox)
	token_input = LineEdit.new()
	token_input.placeholder_text = "Optional: GitHub Personal Access Token (Gist scope)"
	token_input.secret = true
	p2p_vbox.add_child(token_input)
	var p2p_h1 = HBoxContainer.new(); p2p_vbox.add_child(p2p_h1)
	var b_hd = Button.new(); b_hd.text = "Host Direct P2P"; b_hd.pressed.connect(func(): p2p.start_direct_host())
	var b_hg = Button.new(); b_hg.text = "Host via GitHub Gist"; b_hg.pressed.connect(func(): p2p.start_github_host(token_input.text))
	p2p_h1.add_child(b_hd); p2p_h1.add_child(b_hg)
	code_input = LineEdit.new()
	code_input.placeholder_text = "Paste Direct Invite Code OR Gist ID here..."
	p2p_vbox.add_child(code_input)
	var p2p_h2 = HBoxContainer.new(); p2p_vbox.add_child(p2p_h2)
	var b_jd = Button.new(); b_jd.text = "Accept Direct Code"; b_jd.pressed.connect(func(): p2p.accept_remote_code(code_input.text))
	var b_jg = Button.new(); b_jg.text = "Join Gist ID"; b_jg.pressed.connect(func(): p2p.join_github_gist(token_input.text, code_input.text))
	p2p_h2.add_child(b_jd); p2p_h2.add_child(b_jg)
	add_child(p2p_dialog)
	
	_build_settings_dialog()

func _open_box_text_editor(is_rect: bool, idx: int, initial_text: String) -> void:
	editing_is_rect = is_rect
	editing_box_index = idx
	text_edit_box.text = initial_text
	text_edit_dialog.popup_centered(Vector2i(400, 200))

func _build_settings_dialog() -> void:
	settings_dialog = AcceptDialog.new()
	settings_dialog.title = "Settings (space-engineers-blueprint-editor-config.json)"
	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(640, 480)
	settings_dialog.add_child(tabs)
	
	# --- TAB 1: GENERAL & BLOCK COLORS (#31) ---
	var tab_gen := ScrollContainer.new(); tab_gen.name = "General & Blocks"; tabs.add_child(tab_gen)
	var v_gen := VBoxContainer.new(); v_gen.size_flags_horizontal = Control.SIZE_EXPAND_FILL; tab_gen.add_child(v_gen)
	
	var scale_hbox = HBoxContainer.new(); v_gen.add_child(scale_hbox)
	var scale_lbl = Label.new(); scale_lbl.text = "High-DPI UI Scale Factor (0.35 - 1.25):"; scale_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var scale_spin = SpinBox.new(); scale_spin.min_value = 0.35; scale_spin.max_value = 1.25; scale_spin.step = 0.05; scale_spin.value = config.ui_scale
	scale_spin.value_changed.connect(func(v):
		config.ui_scale = v
		get_tree().root.content_scale_factor = v
		config.save_config()
	)
	scale_hbox.add_child(scale_lbl); scale_hbox.add_child(scale_spin)
	
	var def_act_hbox = HBoxContainer.new(); v_gen.add_child(def_act_hbox)
	var def_act_lbl = Label.new(); def_act_lbl.text = "Default Unused Taskbar Action (#31):"; def_act_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var def_act_dd = OptionButton.new()
	var act_keys = config.action_colors.keys().filter(func(k): return k != "EventMonitor")
	for i in act_keys.size():
		def_act_dd.add_item(act_keys[i], i)
		if act_keys[i] == config.default_unused_slot_action: def_act_dd.selected = i
	def_act_dd.item_selected.connect(func(i):
		config.default_unused_slot_action = act_keys[i]
		config.save_config()
		_refresh_views()
	)
	def_act_hbox.add_child(def_act_lbl); def_act_hbox.add_child(def_act_dd)
	
	v_gen.add_child(HSeparator.new())
	for b_type in config.block_colors.keys():
		var row = HBoxContainer.new()
		var lbl = Label.new(); lbl.text = config.get_block_display_type(b_type) + " (" + b_type + ")"; lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var cp = ColorPickerButton.new(); cp.custom_minimum_size = Vector2(46, 20); cp.color = config.get_block_color(b_type)
		cp.color_changed.connect(func(c: Color):
			config.block_colors[b_type] = "#" + c.to_html(false)
			config.save_config()
			_refresh_views()
		)
		row.add_child(lbl); row.add_child(cp); v_gen.add_child(row)
		
	# --- TAB 2: WIRE PATTERNS (2 COLORS) & DATA FLOW PULSES (#28, #29) ---
	var tab_wires := ScrollContainer.new(); tab_wires.name = "Wire Patterns & Flow"; tabs.add_child(tab_wires)
	var v_wires := VBoxContainer.new(); v_wires.size_flags_horizontal = Control.SIZE_EXPAND_FILL; tab_wires.add_child(v_wires)
	for a_type in config.action_styles.keys():
		var st: Dictionary = config.get_action_style(a_type)
		var row = HBoxContainer.new()
		var lbl = Label.new(); lbl.text = a_type; lbl.custom_minimum_size.x = 135; row.add_child(lbl)
		var cp1 = ColorPickerButton.new(); cp1.custom_minimum_size = Vector2(34, 20); cp1.color = config.get_action_color(a_type)
		cp1.color_changed.connect(func(c: Color): st["c1"] = "#" + c.to_html(false); config.save_config(); _refresh_views())
		var cp2 = ColorPickerButton.new(); cp2.custom_minimum_size = Vector2(34, 20); cp2.color = config.get_action_secondary_color(a_type)
		cp2.color_changed.connect(func(c: Color): st["c2"] = "#" + c.to_html(false); config.save_config(); _refresh_views())
		var pat_dd = OptionButton.new()
		for p_i in AppConfig.LINE_PATTERNS.size():
			pat_dd.add_item(AppConfig.LINE_PATTERNS[p_i], p_i)
			if AppConfig.LINE_PATTERNS[p_i] == st.get("pattern", "Solid"): pat_dd.selected = p_i
		pat_dd.item_selected.connect(func(p_i): st["pattern"] = AppConfig.LINE_PATTERNS[p_i]; config.save_config(); _refresh_views())
		var sp_freq = SpinBox.new(); sp_freq.min_value = 0.2; sp_freq.max_value = 8.0; sp_freq.step = 0.2; sp_freq.value = float(st.get("pulse_freq", 1.8)); sp_freq.prefix = "Spd:"
		sp_freq.value_changed.connect(func(v): st["pulse_freq"] = v; config.save_config(); _refresh_views())
		var sp_cnt = SpinBox.new(); sp_cnt.min_value = 1; sp_cnt.max_value = 10; sp_cnt.step = 1; sp_cnt.value = int(st.get("pulse_count", 3)); sp_cnt.prefix = "Qty:"
		sp_cnt.value_changed.connect(func(v): st["pulse_count"] = int(v); config.save_config(); _refresh_views())
		row.add_child(cp1); row.add_child(cp2); row.add_child(pat_dd); row.add_child(sp_freq); row.add_child(sp_cnt)
		v_wires.add_child(row)
		
	# --- TAB 3: CUSTOM ALIASES FOR BLOCKS, EVENTS & ACTIONS (#33) ---
	var tab_alias := ScrollContainer.new(); tab_alias.name = "Custom Aliases"; tabs.add_child(tab_alias)
	var v_alias := VBoxContainer.new(); v_alias.size_flags_horizontal = Control.SIZE_EXPAND_FILL; tab_alias.add_child(v_alias)
	var al_info = Label.new(); al_info.text = "Custom display aliases (Blueprints still save standard Space Engineers XML names):"; v_alias.add_child(al_info)
	for b_type in AppConfig.FRIENDLY_TYPE_NAMES.keys():
		var row = HBoxContainer.new()
		var lbl = Label.new(); lbl.text = b_type; lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var le = LineEdit.new(); le.placeholder_text = AppConfig.FRIENDLY_TYPE_NAMES[b_type]; le.text = config.block_aliases.get(b_type, ""); le.custom_minimum_size.x = 220
		le.text_changed.connect(func(t): config.block_aliases[b_type] = t; config.save_config(); _refresh_views())
		row.add_child(lbl); row.add_child(le); v_alias.add_child(row)
	v_alias.add_child(HSeparator.new())
	for a_type in config.action_styles.keys():
		var row = HBoxContainer.new()
		var lbl = Label.new(); lbl.text = "Action: " + a_type; lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var le = LineEdit.new(); le.placeholder_text = a_type; le.text = config.action_aliases.get(a_type, ""); le.custom_minimum_size.x = 220
		le.text_changed.connect(func(t): config.action_aliases[a_type] = t; config.save_config(); _refresh_views())
		row.add_child(lbl); row.add_child(le); v_alias.add_child(row)
	v_alias.add_child(HSeparator.new())
	for ev_rule in AppConfig.EVENT_RULES.keys():
		var row = HBoxContainer.new()
		var lbl = Label.new(); lbl.text = "Event: " + ev_rule; lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var le = LineEdit.new(); le.placeholder_text = ev_rule; le.text = config.event_aliases.get(ev_rule, ""); le.custom_minimum_size.x = 220
		le.text_changed.connect(func(t): config.event_aliases[ev_rule] = t; config.save_config(); _refresh_views())
		row.add_child(lbl); row.add_child(le); v_alias.add_child(row)
		
	# --- TAB 4: KEYBINDS (#34.2) ---
	var tab_keys := VBoxContainer.new(); tab_keys.name = "Keybinds"; tabs.add_child(tab_keys)
	for kb_action in config.keybinds.keys():
		var row = HBoxContainer.new()
		var lbl = Label.new(); lbl.text = kb_action.capitalize(); lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var btn = Button.new(); btn.custom_minimum_size.x = 160
		btn.text = OS.get_keycode_string(config.keybinds[kb_action])
		btn.pressed.connect(func():
			btn.text = "Press any key..."
			btn.set_meta("listening_kb", kb_action)
		)
		btn.gui_input.connect(func(ev: InputEvent):
			if btn.has_meta("listening_kb") and ev is InputEventKey and ev.pressed:
				config.keybinds[kb_action] = ev.keycode
				btn.text = OS.get_keycode_string(ev.keycode)
				btn.remove_meta("listening_kb")
				config.save_config()
				get_viewport().set_input_as_handled()
		)
		row.add_child(lbl); row.add_child(btn); tab_keys.add_child(row)
		
	add_child(settings_dialog)

func _on_save_blueprint_pressed() -> void:
	if current_file_path != "":
		_save_blueprint_to_path(current_file_path)
	else:
		save_file_dialog.current_dir = _get_se_blueprints_dir()
		save_file_dialog.popup_centered(Vector2i(750, 480))

func _load_blueprint_from_path(path: String) -> void:
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		_set_status("Error opening: " + path)
		return
	var xml_text = file.get_as_text()
	file.close()
	current_file_path = path
	config.add_recent_file(path)
	_rebuild_recent_files_menu()
	disabled_block_types.clear()
	disabled_actions.clear()
	selected_node_ids.clear()
	selected_rect_indices.clear()
	selected_wire_info.clear()
	blueprint.parse_sbc_string(xml_text)
	await _refresh_views()
	_mark_unsaved(false)
	_set_status("Loaded: " + path)

func _save_blueprint_to_path(path: String) -> void:
	_create_rolling_backup_before_save(path)
	var xml_text = blueprint.export_to_sbc_xml(not save_without_custom_data_flag)
	var file = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		_set_status("Error saving: " + path)
		quitting_after_save = false
		return
	file.store_string(xml_text)
	file.close()
	
	var b5_cache_path = path + "B5"
	if FileAccess.file_exists(b5_cache_path):
		DirAccess.remove_absolute(b5_cache_path)
		
	current_file_path = path
	config.add_recent_file(path)
	_rebuild_recent_files_menu()
	_mark_unsaved(false)
	var cd_msg = "WITHOUT CustomData" if save_without_custom_data_flag else "with CustomData & rolling backup created"
	_set_status("Saved blueprint (%s) to: %s" % [cd_msg, path])
	if quitting_after_save:
		get_tree().quit()

func _update_runtime_outline_tree() -> void:
	if not outline_tree: return
	var sorted_rects: Array[Dictionary] = blueprint.org_rects.duplicate()
	sorted_rects.sort_custom(func(a, b): return (a["size"].x * a["size"].y) > (b["size"].x * b["size"].y))
	
	outline_tree.clear()
	var root = outline_tree.create_item()
	root.set_text(0, blueprint.grid_name)
	
	var rect_tree_items: Array[TreeItem] = []
	for i in sorted_rects.size():
		var r = sorted_rects[i]
		var r_rect = Rect2(r["pos"], r["size"])
		var parent_item = root
		for j in range(i - 1, -1, -1):
			var outer = sorted_rects[j]
			if Rect2(outer["pos"], outer["size"]).encloses(r_rect):
				parent_item = rect_tree_items[j]
				break
		var ti = outline_tree.create_item(parent_item)
		ti.set_text(0, "[Group] " + r["title"])
		ti.set_custom_color(0, Color.from_string(r["color"], Color.CORNFLOWER_BLUE).lightened(0.3))
		rect_tree_items.append(ti)
		
	for child in graph_edit.get_children():
		if child is GraphNode:
			var n_center = child.position_offset + child.size * 0.5
			var parent_item = root
			for i in range(sorted_rects.size() - 1, -1, -1):
				var r = sorted_rects[i]
				if Rect2(r["pos"], r["size"]).has_point(n_center):
					parent_item = rect_tree_items[i]
					break
			var ni = outline_tree.create_item(parent_item)
			var b = blueprint.blocks.get(String(child.name), {})
			ni.set_text(0, b.get("custom_name", String(child.name)))
			ni.set_metadata(0, String(child.name))

func _on_outline_item_selected() -> void:
	var sel = outline_tree.get_selected()
	if not sel: return
	var id = sel.get_metadata(0)
	if id and blueprint.blocks.has(id):
		_on_3d_block_clicked(id, false)

# ==============================================================================
# SECTION: 2D GRID SUBSYSTEM LAYOUT ENGINE
# ==============================================================================
func _should_display_block_in_graph(id: String) -> bool:
	var b = blueprint.blocks[id]
	var is_used = blueprint.is_block_used_in_logic(id)
	if is_used and not str(id).begins_with("armor_"):
		return true
	if b["xsi_type"] in SEBlueprint.LOGIC_TYPES:
		return not config.hide_unused_blocks
	return false

func _refresh_views() -> void:
	_update_vanilla_connection_layer_visibility()
	
	graph_edit.clear_connections()
	for child in graph_edit.get_children():
		if child is GraphNode:
			child.free()
	node_last_positions.clear()
	
	var visible_ids: Array[String] = []
	var unpositioned_ids: Array[String] = []
	
	for id in blueprint.blocks:
		if _should_display_block_in_graph(id):
			visible_ids.append(id)
			var b = blueprint.blocks[id]
			var pos: Vector2 = b.get("graph_pos", Vector2.INF)
			if pos == Vector2.INF:
				unpositioned_ids.append(id)
				pos = Vector2.ZERO
			_create_graph_node_for_block(b, pos)
			
	await get_tree().process_frame
	await get_tree().process_frame
	
	if not unpositioned_ids.is_empty():
		_compute_2d_grid_clustered_layout(visible_ids, unpositioned_ids)
		
	for child in graph_edit.get_children():
		if child is GraphNode:
			node_last_positions[String(child.name)] = child.position_offset
			
	_rebuild_all_graph_connections()
	_rebuild_legend()
	_rebuild_visibility_filter_panel()
	_apply_visibility_filters_to_nodes_and_3d()
	dummy_counter_label.text = "Dummy Slots Free: %d  " % blueprint.dummy_pool.size()
	outline_dirty = true
	wires_dirty = true

func _compute_2d_grid_clustered_layout(visible_ids: Array[String], unpositioned_ids: Array[String]) -> void:
	var vis_set: Dictionary = {}
	for id in visible_ids: vis_set[id] = true
	
	var out_edges: Dictionary = {}
	var in_edges: Dictionary = {}
	var undirected: Dictionary = {}
	for id in visible_ids:
		out_edges[id] = []
		in_edges[id] = []
		undirected[id] = []
		
	for id in visible_ids:
		var b = blueprint.blocks[id]
		for s in b["slots"]:
			var tid = s["target_id"]
			if vis_set.has(tid) and tid != id:
				if not (tid in out_edges[id]): out_edges[id].append(tid)
				if not (id in in_edges[tid]): in_edges[tid].append(id)
				if not (tid in undirected[id]): undirected[id].append(tid)
				if not (id in undirected[tid]): undirected[tid].append(id)
		for mon_id in b.get("monitored_blocks", []):
			if vis_set.has(mon_id) and mon_id != id:
				if not (id in out_edges[mon_id]): out_edges[mon_id].append(id)
				if not (mon_id in in_edges[id]): in_edges[id].append(mon_id)
				if not (mon_id in undirected[id]): undirected[id].append(mon_id)
				if not (id in undirected[mon_id]): undirected[mon_id].append(id)
				
	var token_freq: Dictionary = {}
	var block_tokens: Dictionary = {}
	var stop_words = ["block", "small", "large", "timer", "event", "controller", "sensor", "control", "seat", "cockpit", "light", "the", "and", "for"]
	for id in visible_ids:
		var clean = blueprint.blocks[id]["custom_name"].replace("_", " ").replace("-", " ").replace("/", " ")
		var words := PackedStringArray()
		for w in clean.split(" ", false):
			var lw = w.to_lower()
			if lw.length() >= 3 and not (lw in stop_words):
				words.append(w)
				token_freq[lw] = token_freq.get(lw, 0) + 1
		block_tokens[id] = words
		
	var ship_prefix_tokens: Dictionary = {}
	for lw in token_freq:
		if token_freq[lw] >= max(3, int(visible_ids.size() * 0.65)):
			ship_prefix_tokens[lw] = true
			
	var visited: Dictionary = {}
	var clusters: Array[Array] = []
	for seed_id in visible_ids:
		if visited.has(seed_id): continue
		var comp: Array[String] = []
		var queue: Array[String] = [seed_id]
		visited[seed_id] = true
		while not queue.is_empty():
			var cur = queue.pop_front()
			comp.append(cur)
			if blueprint.blocks[cur]["xsi_type"] in ["MyObjectBuilder_Cockpit", "MyObjectBuilder_RemoteControl"] and comp.size() > 1:
				continue
			for nb in undirected[cur]:
				if not visited.has(nb):
					visited[nb] = true
					queue.append(nb)
		clusters.append(comp)
		
	var refined_clusters: Array[Dictionary] = []
	for comp in clusters:
		if comp.size() <= 6:
			refined_clusters.append({
				"nodes": comp,
				"title": _infer_cluster_title(comp, block_tokens, ship_prefix_tokens)
			})
		else:
			var sub_buckets: Dictionary = {}
			for nid in comp:
				var key = _best_subsystem_keyword(nid, block_tokens, ship_prefix_tokens)
				if not sub_buckets.has(key): sub_buckets[key] = []
				sub_buckets[key].append(nid)
			for key in sub_buckets:
				refined_clusters.append({
					"nodes": sub_buckets[key],
					"title": key + " Subsystem"
				})
				
	var col_gap_x := 420.0
	var row_gap_y := 160.0
	var cluster_layouts: Array[Dictionary] = []
	
	for c_idx in refined_clusters.size():
		var c_info = refined_clusters[c_idx]
		var c_nodes: Array = c_info["nodes"]
		var c_set: Dictionary = {}
		var any_used_in_cluster := false
		for nid in c_nodes:
			c_set[nid] = true
			if blueprint.is_block_used_in_logic(nid):
				any_used_in_cluster = true
				
		var ranks: Dictionary = {}
		for nid in c_nodes:
			var xtype = blueprint.blocks[nid]["xsi_type"]
			var has_in = false
			for p in in_edges[nid]:
				if c_set.has(p): has_in = true
			var has_out = false
			for ch in out_edges[nid]:
				if c_set.has(ch): has_out = true
			if xtype in ["MyObjectBuilder_Cockpit", "MyObjectBuilder_RemoteControl", "MyObjectBuilder_ButtonPanel", "MyObjectBuilder_SensorBlock"] and not has_in:
				ranks[nid] = 0
			elif xtype == "MyObjectBuilder_EventControllerBlock":
				ranks[nid] = 1
			elif xtype == "MyObjectBuilder_TimerBlock":
				ranks[nid] = 2
			elif not has_out and has_in:
				ranks[nid] = 3
			else:
				ranks[nid] = 1
				
		for _iter in range(3):
			for u in c_nodes:
				for v in out_edges[u]:
					if c_set.has(v) and u != v and ranks[v] <= ranks[u]:
						ranks[v] = min(4, ranks[u] + 1)
						
		var columns: Dictionary = {}
		for nid in c_nodes:
			var r = ranks[nid]
			if not columns.has(r): columns[r] = []
			columns[r].append(nid)
			
		var sorted_col_keys = columns.keys()
		sorted_col_keys.sort()
		
		var local_positions: Dictionary = {}
		var col_x := 0.0
		var max_cluster_h := 0.0
		
		for r_key in sorted_col_keys:
			var col_nodes: Array = columns[r_key]
			col_nodes.sort_custom(func(a, b): return blueprint.blocks[a]["custom_name"] < blueprint.blocks[b]["custom_name"])
			var col_y := 0.0
			var max_w := 280.0
			for nid in col_nodes:
				if not graph_edit.has_node(NodePath(nid)): continue
				var gn: GraphNode = graph_edit.get_node(NodePath(nid))
				var sz = Vector2(max(gn.size.x, gn.custom_minimum_size.x), max(gn.size.y, gn.custom_minimum_size.y))
				local_positions[nid] = Vector2(col_x, col_y)
				col_y += sz.y + row_gap_y
				max_w = max(max_w, sz.x)
			max_cluster_h = max(max_cluster_h, col_y - row_gap_y)
			col_x += max_w + col_gap_x
			
		var total_w = max(320.0, col_x - col_gap_x)
		var total_h = max(180.0, max_cluster_h)
		cluster_layouts.append({
			"title": c_info["title"],
			"nodes": c_nodes,
			"local_pos": local_positions,
			"size": Vector2(total_w, total_h),
			"has_used_logic": any_used_in_cluster
		})
		
	var can_generate_rects = blueprint.org_rects.is_empty() and (unpositioned_ids.size() == visible_ids.size())
	var target_row_width := 3800.0
	var group_gap_x := 520.0
	var group_gap_y := 420.0
	var cursor := Vector2(160.0, 160.0)
	var current_row_max_h := 0.0
	
	for c_idx in cluster_layouts.size():
		var cl = cluster_layouts[c_idx]
		var c_sz: Vector2 = cl["size"]
		if cursor.x > 180.0 and (cursor.x + c_sz.x > target_row_width):
			cursor.x = 160.0
			cursor.y += current_row_max_h + group_gap_y
			current_row_max_h = 0.0
			
		for nid in cl["nodes"]:
			if nid in unpositioned_ids and cl["local_pos"].has(nid):
				var final_p: Vector2 = cursor + cl["local_pos"][nid]
				blueprint.blocks[nid]["graph_pos"] = final_p
				if graph_edit.has_node(NodePath(nid)):
					graph_edit.get_node(NodePath(nid)).position_offset = final_p
					
		if can_generate_rects and (cl["has_used_logic"] or config.create_groups_for_unused_blocks):
			var pad_top := Vector2(65, 68)
			var pad_bot := Vector2(65, 55)
			blueprint.org_rects.append({
				"pos": cursor - pad_top,
				"size": c_sz + pad_top + pad_bot,
				"title": cl["title"],
				"color": CLUSTER_PALETTE[c_idx % CLUSTER_PALETTE.size()]
			})
			
		cursor.x += c_sz.x + group_gap_x
		current_row_max_h = max(current_row_max_h, c_sz.y)

func _best_subsystem_keyword(nid: String, block_tokens: Dictionary, ship_prefix_tokens: Dictionary) -> String:
	var words: PackedStringArray = block_tokens.get(nid, PackedStringArray())
	for w in words:
		if not ship_prefix_tokens.has(w.to_lower()):
			return w
	return AppConfig.FRIENDLY_TYPE_NAMES.get(blueprint.blocks[nid]["xsi_type"], "General")

func _infer_cluster_title(node_ids: Array, block_tokens: Dictionary, ship_prefix_tokens: Dictionary) -> String:
	var counts: Dictionary = {}
	var display_word: Dictionary = {}
	for nid in node_ids:
		var seen_in_node: Dictionary = {}
		for w in block_tokens.get(nid, PackedStringArray()):
			var lw = w.to_lower()
			if ship_prefix_tokens.has(lw) or seen_in_node.has(lw): continue
			seen_in_node[lw] = true
			counts[lw] = counts.get(lw, 0) + 1
			display_word[lw] = w
	var best_lw := ""
	var best_c := 0
	for lw in counts:
		if counts[lw] > best_c:
			best_c = counts[lw]
			best_lw = lw
	if best_lw != "":
		return "%s Subsystem (%d blocks)" % [display_word[best_lw], node_ids.size()]
	var first_name = blueprint.blocks[node_ids[0]]["custom_name"]
	return "%s Group (%d blocks)" % [first_name.left(24), node_ids.size()]

# ==============================================================================
# SECTION: GRAPH NODE BUILDER (CLEAN LEFT/RIGHT SPLIT PILLS #17 & PORT DOTS #16)
# ==============================================================================
func _create_graph_node_for_block(b: Dictionary, pos: Vector2) -> GraphNode:
	var gn = GraphNode.new()
	gn.name = b["entity_id"]
	gn.title = "[%s] %s" % [config.get_block_initial(b["xsi_type"]), b["custom_name"]]
	gn.position_offset = pos
	var min_w = max(330.0, float(b["custom_name"].length() * 7 + 160))
	gn.custom_minimum_size = Vector2(min_w, 90)
	
	var tb_style = StyleBoxFlat.new()
	tb_style.bg_color = config.get_block_color(b["xsi_type"])
	tb_style.set_corner_radius_all(3)
	tb_style.set_content_margin_all(4)
	gn.add_theme_stylebox_override("titlebar", tb_style)
	
	gn.position_offset_changed.connect(func():
		var new_p = gn.position_offset
		var old_p: Vector2 = node_last_positions.get(b["entity_id"], new_p)
		var delta = new_p - old_p
		node_last_positions[b["entity_id"]] = new_p
		b["graph_pos"] = new_p
		
		if not is_syncing_multi_move and selected_node_ids.has(b["entity_id"]) and not selected_rect_indices.is_empty():
			is_syncing_multi_move = true
			for r_i in selected_rect_indices.keys():
				if r_i >= 0 and r_i < blueprint.org_rects.size():
					blueprint.org_rects[r_i]["pos"] += delta
			is_syncing_multi_move = false
			
		_mark_unsaved(true)
		if not suppress_network_sync:
			p2p.broadcast_action({"op": "move", "id": b["entity_id"], "x": gn.position_offset.x, "y": gn.position_offset.y})
	)
	
	graph_edit.add_child(gn)
	_populate_graph_node_rows(gn, b)
	return gn

func _rebuild_single_graph_node_slots(entity_id: String) -> void:
	if not graph_edit.has_node(NodePath(entity_id)):
		return
	var gn: GraphNode = graph_edit.get_node(NodePath(entity_id))
	_populate_graph_node_rows(gn, blueprint.blocks[entity_id])
	_rebuild_all_graph_connections()

func _get_used_incoming_actions_for_block(target_id: String) -> Array[String]:
	var used: Array[String] = []
	for other_id in blueprint.blocks:
		var ob = blueprint.blocks[other_id]
		for s in ob["slots"]:
			if s["target_id"] == target_id and s["action"] != "" and not (s["action"] in used):
				used.append(s["action"])
	return used

# Returns all Event Controller rules currently watching this block (#32)
func _get_active_watched_states_for_block(entity_id: String) -> Array[String]:
	var states: Array[String] = []
	for other_id in blueprint.blocks:
		var ob = blueprint.blocks[other_id]
		if ob["xsi_type"] == "MyObjectBuilder_EventControllerBlock" and (entity_id in ob.get("monitored_blocks", [])):
			var rule: String = ob.get("event_rule", "Block On/Off")
			if not (rule in states):
				states.append(rule)
	return states

func _populate_graph_node_rows(gn: GraphNode, b: Dictionary) -> void:
	gn.clear_all_slots()
	for c in gn.get_children():
		c.queue_free()
		
	var expand_key: int = int(config.keybinds.get("expand_all_ports", KEY_SHIFT))
	var show_all_shift: bool = (hovered_node_id == b["entity_id"] and Input.is_key_pressed(expand_key))
	var slot_line_alpha: float = 0.0 if config.use_smart_astar_wires else 0.90
	
	# --- 1. DYNAMIC STATE OUTPUT ROWS ABOVE "State Out [+] ->" (#32 & #32.2) ---
	var active_states: Array[String] = _get_active_watched_states_for_block(b["entity_id"])
	if show_all_shift:
		for st_rule in config.get_supported_output_states_for_block(b["xsi_type"]):
			if not (st_rule in active_states):
				active_states.append(st_rule)
				
	var state_to_out_port_map: Dictionary = {}
	var out_port_colors: Array[Color] = []
	var out_port_counter := 0
	var row_idx := 0
	
	for st_i in active_states.size():
		var st_rule: String = active_states[st_i]
		var st_row = HBoxContainer.new()
		st_row.mouse_filter = Control.MOUSE_FILTER_PASS
		if st_i == 0:
			var sub_lbl = Label.new()
			sub_lbl.text = config.format_block_type_line(b["xsi_type"], b["subtype"])
			sub_lbl.add_theme_color_override("font_color", Color(0.62, 0.66, 0.72))
			sub_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			st_row.add_child(sub_lbl)
		else:
			var sp = Control.new()
			sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sp.mouse_filter = Control.MOUSE_FILTER_PASS
			st_row.add_child(sp)
			
		var st_lbl = Label.new()
		st_lbl.text = "State: %s ->" % config.get_event_display_name(st_rule)
		st_lbl.add_theme_color_override("font_color", Color(0.86, 0.65, 1.0))
		st_row.add_child(st_lbl)
		gn.add_child(st_row)
		gn.set_slot(row_idx, false, 0, Color(1, 1, 1, slot_line_alpha), true, 1, Color(0.78, 0.49, 1.0, slot_line_alpha))
		state_to_out_port_map[st_rule] = out_port_counter
		out_port_colors.append(Color(0.78, 0.49, 1.0))
		out_port_counter += 1
		row_idx += 1
		
	# Base "State Out [+] ->" row (always available to connect new state requests #32)
	var r0 = HBoxContainer.new()
	r0.mouse_filter = Control.MOUSE_FILTER_PASS
	if active_states.is_empty():
		var sub_lbl = Label.new()
		sub_lbl.text = config.format_block_type_line(b["xsi_type"], b["subtype"])
		sub_lbl.add_theme_color_override("font_color", Color(0.62, 0.66, 0.72))
		sub_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r0.add_child(sub_lbl)
	else:
		var sp = Control.new()
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sp.mouse_filter = Control.MOUSE_FILTER_PASS
		r0.add_child(sp)
		
	var state_out_lbl = Label.new()
	state_out_lbl.text = "State Out [+] ->"
	state_out_lbl.add_theme_color_override("font_color", Color(0.78, 0.55, 1.0))
	r0.add_child(state_out_lbl)
	gn.add_child(r0)
	gn.set_slot(row_idx, false, 0, Color(1, 1, 1, slot_line_alpha), true, 1, Color(0.78, 0.49, 1.0, slot_line_alpha))
	var generic_state_out_port: int = out_port_counter
	out_port_colors.append(Color(0.78, 0.49, 1.0))
	out_port_counter += 1
	row_idx += 1
	
	# --- 2. TIMER BLOCK SPECIFIC CONTROLS ---
	if b["xsi_type"] == "MyObjectBuilder_TimerBlock":
		var timer_bar = HBoxContainer.new()
		timer_bar.mouse_filter = Control.MOUSE_FILTER_PASS
		var chk_silent = CheckBox.new()
		chk_silent.text = "Silent"
		chk_silent.button_pressed = b.get("silent", false)
		chk_silent.toggled.connect(func(on): b["silent"] = on; _mark_unsaved(true))
		timer_bar.add_child(chk_silent)
		var delay_lbl = Label.new(); delay_lbl.text = " Delay(s):"
		timer_bar.add_child(delay_lbl)
		var spin_delay = SpinBox.new()
		spin_delay.min_value = 1.0; spin_delay.max_value = 3600.0; spin_delay.step = 1.0
		spin_delay.value = float(b.get("delay_ms", 1000)) / 1000.0
		spin_delay.value_changed.connect(func(v): b["delay_ms"] = int(v * 1000.0); _mark_unsaved(true))
		timer_bar.add_child(spin_delay)
		gn.add_child(timer_bar)
		row_idx += 1
		
	# --- 3. EVENT CONTROLLER SPECIFIC CONTROLS ---
	if b["xsi_type"] == "MyObjectBuilder_EventControllerBlock":
		var ec_bar = HBoxContainer.new()
		ec_bar.mouse_filter = Control.MOUSE_FILTER_PASS
		var gate_lbl = Label.new(); gate_lbl.text = "Gate:"
		ec_bar.add_child(gate_lbl)
		var btn_group = ButtonGroup.new()
		var rb_and = CheckBox.new(); rb_and.text = "AND"; rb_and.button_group = btn_group
		var rb_or = CheckBox.new(); rb_or.text = "OR"; rb_or.button_group = btn_group
		rb_and.button_pressed = b.get("is_and_mode", false)
		rb_or.button_pressed = not b.get("is_and_mode", false)
		rb_and.toggled.connect(func(on): b["is_and_mode"] = on; _mark_unsaved(true))
		ec_bar.add_child(rb_and); ec_bar.add_child(rb_or)
		
		var rule_dd = OptionButton.new()
		var rules_list = AppConfig.EVENT_RULES.keys()
		for i in rules_list.size():
			rule_dd.add_item(config.get_event_display_name(rules_list[i]), i)
			if rules_list[i] == b.get("event_rule", "Block On/Off"):
				rule_dd.selected = i
		rule_dd.item_selected.connect(func(idx):
			_on_event_controller_rule_changed(b, rules_list[idx], rule_dd)
		)
		ec_bar.add_child(rule_dd)
		gn.add_child(ec_bar)
		row_idx += 1
		
	# --- 4. BUILD LEFT INPUT ITEMS & RIGHT OUTPUT TOOLBAR SLOTS (#30, #31) ---
	var left_items: Array[Dictionary] = []
	if b["xsi_type"] == "MyObjectBuilder_EventControllerBlock":
		var mon_count = b["monitored_blocks"].size()
		for m_i in range(mon_count + 1):
			var txt = ("Watch [%d]: %s" % [m_i + 1, blueprint.blocks[b["monitored_blocks"][m_i]]["custom_name"]]) if (m_i < mon_count and blueprint.blocks.has(b["monitored_blocks"][m_i])) else ("Watch [%d]: <Free Input> [...]" % (m_i + 1))
			left_items.append({"kind": "monitor", "index": m_i, "label": txt})
			
	var supported_inputs = config.get_supported_inputs_for_block(b["xsi_type"], show_all_shift)
	var used_incoming = _get_used_incoming_actions_for_block(b["entity_id"])
	for u_act in used_incoming:
		if not (u_act in supported_inputs):
			supported_inputs.push_front(u_act)
	for in_act in supported_inputs:
		left_items.append({"kind": "action_in", "action": in_act, "label": "In: " + config.get_action_display_name(in_act)})
		
	var supports_toolbar = b["xsi_type"] in [
		"MyObjectBuilder_TimerBlock", "MyObjectBuilder_EventControllerBlock",
		"MyObjectBuilder_SensorBlock", "MyObjectBuilder_ButtonPanel",
		"MyObjectBuilder_Cockpit", "MyObjectBuilder_RemoteControl"
	] or not b["slots"].is_empty()
	
	var right_items: Array[Dictionary] = []
	if supports_toolbar:
		var used_indices: Array[int] = []
		var max_used_slot := -1
		for s in b["slots"]:
			if s["target_id"] != "" and s["target_id"] != "0":
				used_indices.append(s["index"])
				if s["index"] > max_used_slot:
					max_used_slot = s["index"]
		var slots_to_render: Array[int] = []
		if show_all_shift:
			# Show all 9 Toolbars x 9 Slots (81 slots total) when holding Shift (#30)!
			for i in range(max(81, max_used_slot + 1)):
				slots_to_render.append(i)
		else:
			for s_idx in used_indices:
				if not (s_idx in slots_to_render):
					slots_to_render.append(s_idx)
			var next_free = max_used_slot + 1
			if not (next_free in slots_to_render):
				slots_to_render.append(next_free)
			if b["xsi_type"] == "MyObjectBuilder_EventControllerBlock":
				if not (0 in slots_to_render): slots_to_render.append(0)
				if not (1 in slots_to_render): slots_to_render.append(1)
			slots_to_render.sort()
		for s_idx in slots_to_render:
			right_items.append({"kind": "slot", "slot_index": s_idx})
		if not show_all_shift:
			var dummy_slot_idx = (slots_to_render.back() + 1) if not slots_to_render.is_empty() else 0
			right_items.append({"kind": "dummy_more", "slot_index": dummy_slot_idx})
			
	var max_rows = max(left_items.size(), right_items.size())
	var input_action_to_port_map: Dictionary = {}
	var monitor_to_port_map: Dictionary = {}
	var slot_to_port_map: Dictionary = {}
	var in_port_colors: Array[Color] = []
	var in_port_counter := 0
	
	# --- 5. BUILD TWO DISTINCT TERMINATED PILLS PER ROW WITH AN EMPTY CENTER GAP (#17) ---
	for i in range(max_rows):
		var has_left = (i < left_items.size())
		var has_right = (i < right_items.size())
		var l_info: Dictionary = left_items[i] if has_left else {}
		var r_info: Dictionary = right_items[i] if has_right else {}
		
		var row_hbox = HBoxContainer.new()
		row_hbox.mouse_filter = Control.MOUSE_FILTER_PASS
		row_hbox.add_theme_constant_override("separation", 0)
		
		var l_port_type := 0
		var l_port_col := Color.LIGHT_GREEN
		if has_left:
			var left_pill = PanelContainer.new()
			left_pill.mouse_filter = Control.MOUSE_FILTER_PASS
			var l_sb = StyleBoxFlat.new()
			l_sb.bg_color = Color(0.14, 0.16, 0.21, 0.72)
			l_sb.border_color = Color(0.28, 0.32, 0.40, 0.65)
			l_sb.border_width_right = 2
			l_sb.set_corner_radius_all(3)
			l_sb.content_margin_left = 6
			l_sb.content_margin_right = 8
			l_sb.content_margin_top = 2
			l_sb.content_margin_bottom = 2
			left_pill.add_theme_stylebox_override("panel", l_sb)
			
			var l_lbl = Label.new()
			l_lbl.text = l_info["label"]
			if l_info["kind"] == "monitor":
				l_port_type = 1
				l_port_col = Color(0.78, 0.49, 1.0)
				l_lbl.add_theme_color_override("font_color", Color(0.85, 0.72, 1.0))
				monitor_to_port_map[l_info["index"]] = in_port_counter
			else:
				var act_name: String = l_info["action"]
				l_port_type = 0
				l_port_col = config.get_action_color(act_name)
				l_lbl.add_theme_color_override("font_color", l_port_col.lightened(0.25))
				input_action_to_port_map[act_name] = in_port_counter
			left_pill.add_child(l_lbl)
			row_hbox.add_child(left_pill)
			in_port_colors.append(l_port_col)
			in_port_counter += 1
			
		var empty_gap = Control.new()
		empty_gap.custom_minimum_size = Vector2(28, 0)
		empty_gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		empty_gap.mouse_filter = Control.MOUSE_FILTER_PASS
		row_hbox.add_child(empty_gap)
		
		var r_port_col := Color.ORANGE
		if has_right:
			var right_pill = PanelContainer.new()
			right_pill.mouse_filter = Control.MOUSE_FILTER_PASS
			var r_sb = StyleBoxFlat.new()
			var s_idx: int = r_info["slot_index"]
			if b["xsi_type"] == "MyObjectBuilder_EventControllerBlock" and r_info.get("kind", "") == "slot":
				r_sb.bg_color = Color(0.12, 0.48, 0.22, 0.55) if (s_idx % 2 == 0) else Color(0.55, 0.14, 0.16, 0.55)
			else:
				r_sb.bg_color = Color(0.16, 0.19, 0.25, 0.72)
			r_sb.border_color = Color(0.30, 0.35, 0.44, 0.65)
			r_sb.border_width_left = 2
			r_sb.set_corner_radius_all(3)
			r_sb.content_margin_left = 8
			r_sb.content_margin_right = 6
			r_sb.content_margin_top = 2
			r_sb.content_margin_bottom = 2
			right_pill.add_theme_stylebox_override("panel", r_sb)
			
			var r_inner = HBoxContainer.new()
			r_inner.mouse_filter = Control.MOUSE_FILTER_PASS
			right_pill.add_child(r_inner)
			
			var tb_num: int = (s_idx / 9) + 1
			var tb_slot: int = (s_idx % 9) + 1
			if r_info["kind"] == "dummy_more":
				var more_lbl = Label.new()
				more_lbl.text = "[...] (Toolbar %d Slot %d+)" % [tb_num, tb_slot]
				more_lbl.add_theme_color_override("font_color", Color(0.55, 0.62, 0.72))
				r_inner.add_child(more_lbl)
				r_port_col = Color(0.55, 0.62, 0.72)
			else:
				var slot_data: Dictionary = {}
				for s in b["slots"]:
					if s["index"] == s_idx:
						slot_data = s
						break
				var act_dd = OptionButton.new()
				var actions = config.action_colors.keys().filter(func(k): return k != "EventMonitor")
				# Default unused taskbar slots to config.default_unused_slot_action ("OnOff_On" #31)
				var cur_act: String = slot_data.get("action", config.default_unused_slot_action)
				if cur_act != "" and not (cur_act in actions):
					actions.append(cur_act)
				for a_i in actions.size():
					act_dd.add_item(config.get_action_display_name(actions[a_i]), a_i)
					if actions[a_i] == cur_act:
						act_dd.selected = a_i
				act_dd.item_selected.connect(func(a_i):
					for s in b["slots"]:
						if s["index"] == s_idx:
							s["action"] = actions[a_i]
							if graph_edit.has_node(NodePath(s["target_id"])):
								_rebuild_single_graph_node_slots(s["target_id"])
					_mark_unsaved(true)
					ship_3d.rebuild_mesh(blueprint, config, selected_node_ids, hovered_node_id, hovered_wire_info, disabled_block_types, disabled_actions)
				)
				r_inner.add_child(act_dd)
				
				var slot_lbl = Label.new()
				if b["xsi_type"] == "MyObjectBuilder_EventControllerBlock":
					var tf_tag = "TRUE" if (s_idx % 2 == 0) else "FALSE"
					slot_lbl.text = " TB%d Slot %d (%s) ->" % [tb_num, tb_slot, tf_tag]
				else:
					slot_lbl.text = " Toolbar %d Slot %d ->" % [tb_num, tb_slot]
				r_inner.add_child(slot_lbl)
				r_port_col = config.get_action_color(cur_act)
				
			row_hbox.add_child(right_pill)
			slot_to_port_map[s_idx] = out_port_counter
			out_port_colors.append(r_port_col)
			out_port_counter += 1
			
		gn.add_child(row_hbox)
		gn.set_slot(
			row_idx,
			has_left, l_port_type, Color(l_port_col.r, l_port_col.g, l_port_col.b, slot_line_alpha),
			has_right, 0, Color(r_port_col.r, r_port_col.g, r_port_col.b, slot_line_alpha)
		)
		row_idx += 1
		
	gn.set_meta("state_to_out_port_map", state_to_out_port_map)
	gn.set_meta("generic_state_out_port", generic_state_out_port)
	gn.set_meta("slot_to_port_map", slot_to_port_map)
	gn.set_meta("input_action_to_port_map", input_action_to_port_map)
	gn.set_meta("monitor_to_port_map", monitor_to_port_map)
	gn.set_meta("in_port_colors", in_port_colors)
	gn.set_meta("out_port_colors", out_port_colors)
	wires_dirty = true

func _rebuild_all_graph_connections() -> void:
	graph_edit.clear_connections()
	for id in blueprint.blocks:
		var b = blueprint.blocks[id]
		if not graph_edit.has_node(NodePath(id)):
			continue
		var src_gn: GraphNode = graph_edit.get_node(NodePath(id))
		var port_map: Dictionary = src_gn.get_meta("slot_to_port_map", {})
		for s in b["slots"]:
			var tid = s["target_id"]
			if tid != "" and tid != "0" and graph_edit.has_node(NodePath(tid)) and port_map.has(s["index"]):
				var dst_gn: GraphNode = graph_edit.get_node(NodePath(tid))
				var in_map: Dictionary = dst_gn.get_meta("input_action_to_port_map", {})
				var dst_port: int = in_map.get(s["action"], 0)
				graph_edit.connect_node(id, port_map[s["index"]], tid, dst_port)
				
		if b["xsi_type"] == "MyObjectBuilder_EventControllerBlock":
			var mon_map: Dictionary = src_gn.get_meta("monitor_to_port_map", {})
			var ev_rule: String = b.get("event_rule", "Block On/Off")
			for m_idx in b["monitored_blocks"].size():
				var mon_id = b["monitored_blocks"][m_idx]
				if graph_edit.has_node(NodePath(mon_id)) and mon_map.has(m_idx):
					var mon_gn: GraphNode = graph_edit.get_node(NodePath(mon_id))
					var state_map: Dictionary = mon_gn.get_meta("state_to_out_port_map", {})
					var out_port: int = state_map.get(ev_rule, int(mon_gn.get_meta("generic_state_out_port", 0)))
					graph_edit.connect_node(mon_id, out_port, id, mon_map[m_idx])
	_update_vanilla_connection_layer_visibility()
	wires_dirty = true

# ==============================================================================
# SECTION: WIRE CONNECTION & DELETION
# ==============================================================================
func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	var src_id = str(from_node)
	var dst_id = str(to_node)
	if src_id == dst_id or not blueprint.blocks.has(src_id) or not blueprint.blocks.has(dst_id):
		return
	var src_b = blueprint.blocks[src_id]
	var dst_b = blueprint.blocks[dst_id]
	var src_gn: GraphNode = graph_edit.get_node(NodePath(src_id))
	var dst_gn: GraphNode = graph_edit.get_node(NodePath(dst_id))
	
	var generic_state_port: int = int(src_gn.get_meta("generic_state_out_port", 0))
	
	# Case 1: Connecting any State Output port (from_port <= generic_state_port) into an Event Controller (#32)
	if from_port <= generic_state_port and dst_b["xsi_type"] == "MyObjectBuilder_EventControllerBlock":
		var rule: String = dst_b.get("event_rule", "Block On/Off")
		# If the user dragged from a specific expanded State row (when holding Shift #32.2), adopt that state rule if compatible
		var state_map: Dictionary = src_gn.get_meta("state_to_out_port_map", {})
		for st_rule in state_map:
			if state_map[st_rule] == from_port:
				rule = st_rule
				dst_b["event_rule"] = rule
				break
				
		var allowed = AppConfig.EVENT_RULES.get(rule, [])
		if not (src_b["xsi_type"] in allowed):
			_set_status("Cannot connect %s: incompatible with Event Controller rule '%s'!" % [src_b["custom_name"], rule])
			return
		if not (src_id in dst_b["monitored_blocks"]):
			dst_b["monitored_blocks"].append(src_id)
		_mark_unsaved(true)
		# Rebuild both nodes so src_id immediately creates the new "State: <Rule> ->" row above "State Out [+] ->" (#32)!
		_rebuild_single_graph_node_slots(src_id)
		_rebuild_single_graph_node_slots(dst_id)
		_rebuild_visibility_filter_panel()
		ship_3d.rebuild_mesh(blueprint, config, selected_node_ids, hovered_node_id, hovered_wire_info, disabled_block_types, disabled_actions)
		return
		
	# Case 2: Connecting a Toolbar Output Slot -> Specific Action Input Port on Target Node
	var port_map: Dictionary = src_gn.get_meta("slot_to_port_map", {})
	var slot_index := 0
	for k in port_map:
		if port_map[k] == from_port:
			slot_index = k
			break
			
	var in_map: Dictionary = dst_gn.get_meta("input_action_to_port_map", {})
	var chosen_action := ""
	for act_key in in_map:
		if in_map[act_key] == to_port:
			chosen_action = act_key
			break
	if chosen_action == "":
		var supported = config.get_supported_inputs_for_block(dst_b["xsi_type"], true)
		chosen_action = supported[0] if not supported.is_empty() else config.default_unused_slot_action
		
	src_b["slots"] = src_b["slots"].filter(func(s): return s["index"] != slot_index)
	src_b["slots"].append({"index": slot_index, "action": chosen_action, "target_id": dst_id})
	_mark_unsaved(true)
	_rebuild_single_graph_node_slots(src_id)
	_rebuild_single_graph_node_slots(dst_id)
	_rebuild_visibility_filter_panel()
	ship_3d.rebuild_mesh(blueprint, config, selected_node_ids, hovered_node_id, hovered_wire_info, disabled_block_types, disabled_actions)

func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, _to_port: int) -> void:
	var src_id = str(from_node)
	var dst_id = str(to_node)
	if not blueprint.blocks.has(src_id) or not blueprint.blocks.has(dst_id):
		return
	var src_b = blueprint.blocks[src_id]
	var dst_b = blueprint.blocks[dst_id]
	
	if from_port == 0 and dst_b["xsi_type"] == "MyObjectBuilder_EventControllerBlock":
		dst_b["monitored_blocks"].erase(src_id)
		_mark_unsaved(true)
		_rebuild_single_graph_node_slots(dst_id)
		ship_3d.rebuild_mesh(blueprint, config, selected_node_ids, hovered_node_id, hovered_wire_info, disabled_block_types, disabled_actions)
		return
		
	var src_gn: GraphNode = graph_edit.get_node(NodePath(src_id))
	var port_map: Dictionary = src_gn.get_meta("slot_to_port_map", {})
	var slot_index := -1
	for k in port_map:
		if port_map[k] == from_port:
			slot_index = k
			break
	src_b["slots"] = src_b["slots"].filter(func(s): return not (s["index"] == slot_index and s["target_id"] == dst_id))
	_mark_unsaved(true)
	_rebuild_single_graph_node_slots(src_id)
	ship_3d.rebuild_mesh(blueprint, config, selected_node_ids, hovered_node_id, hovered_wire_info, disabled_block_types, disabled_actions)

func _delete_hovered_wire(w_info: Dictionary) -> void:
	var src_id: String = w_info.get("src", "")
	var dst_id: String = w_info.get("dst", "")
	if not blueprint.blocks.has(src_id) or not blueprint.blocks.has(dst_id):
		return
	if w_info.get("is_monitor", false):
		blueprint.blocks[dst_id]["monitored_blocks"].erase(src_id)
		_rebuild_single_graph_node_slots(dst_id)
	else:
		var s_idx: int = int(w_info.get("slot", -1))
		var src_b = blueprint.blocks[src_id]
		src_b["slots"] = src_b["slots"].filter(func(s): return not (s["index"] == s_idx and s["target_id"] == dst_id))
		_rebuild_single_graph_node_slots(src_id)
	hovered_wire_info.clear()
	_mark_unsaved(true)
	_rebuild_visibility_filter_panel()
	ship_3d.rebuild_mesh(blueprint, config, selected_node_ids, hovered_node_id, hovered_wire_info, disabled_block_types, disabled_actions)
	_set_status("Deleted connection wire.")

func _delete_block_and_refresh(entity_id: String) -> void:
	var b_name = blueprint.blocks[entity_id]["custom_name"]
	blueprint.delete_block(entity_id)
	selected_node_ids.erase(entity_id)
	if hovered_node_id == entity_id:
		hovered_node_id = ""
	_mark_unsaved(true)
	_refresh_views()
	_set_status("Deleted block '%s' and its connections." % b_name)

func _on_event_controller_rule_changed(b: Dictionary, new_rule: String, dropdown: OptionButton) -> void:
	var old_rule = b.get("event_rule", "Block On/Off")
	var allowed_types: Array = AppConfig.EVENT_RULES.get(new_rule, [])
	var incompatible_ids: Array[String] = []
	var incompatible_names: PackedStringArray = PackedStringArray()
	
	for mon_id in b["monitored_blocks"]:
		if blueprint.blocks.has(mon_id):
			var mon_b = blueprint.blocks[mon_id]
			if not (mon_b["xsi_type"] in allowed_types):
				incompatible_ids.append(mon_id)
				incompatible_names.append("- %s (%s)" % [mon_b["custom_name"], mon_b["xsi_type"]])
				
	if incompatible_ids.is_empty():
		b["event_rule"] = new_rule
		_mark_unsaved(true)
		return
		
	rule_warning_dialog.dialog_text = (
		"Changing Event Controller rule to '%s' is incompatible with the following connected blocks:\n\n%s\n\n" +
		"Proceeding will disconnect these incompatible blocks."
	) % [new_rule, "\n".join(incompatible_names)]
	
	for conn in rule_warning_dialog.confirmed.get_connections():
		rule_warning_dialog.confirmed.disconnect(conn["callable"])
	for conn in rule_warning_dialog.canceled.get_connections():
		rule_warning_dialog.canceled.disconnect(conn["callable"])
		
	rule_warning_dialog.confirmed.connect(func():
		b["event_rule"] = new_rule
		b["monitored_blocks"] = b["monitored_blocks"].filter(func(id): return not (id in incompatible_ids))
		_mark_unsaved(true)
		_rebuild_single_graph_node_slots(b["entity_id"])
		ship_3d.rebuild_mesh(blueprint, config, selected_node_ids, hovered_node_id, hovered_wire_info, disabled_block_types, disabled_actions)
	, CONNECT_ONE_SHOT)
	
	rule_warning_dialog.canceled.connect(func():
		var rules_list = AppConfig.EVENT_RULES.keys()
		dropdown.selected = rules_list.find(old_rule)
	, CONNECT_ONE_SHOT)
	
	rule_warning_dialog.popup_centered()

# ==============================================================================
# SECTION: AStarGrid2D OBSTACLE-AVOIDING WIRE ROUTER
# ==============================================================================
func _recompute_astar_graph_wires() -> void:
	cached_graph_wires.clear()
	var cell_size := 20.0
	var node_rects_graph: Dictionary = {}
	var bounds_min := Vector2(INF, INF)
	var bounds_max := Vector2(-INF, -INF)
	
	for child in graph_edit.get_children():
		if child is GraphNode and child.visible:
			var r = Rect2(child.position_offset, child.size)
			node_rects_graph[String(child.name)] = r
			bounds_min.x = min(bounds_min.x, r.position.x)
			bounds_min.y = min(bounds_min.y, r.position.y)
			bounds_max.x = max(bounds_max.x, r.end.x)
			bounds_max.y = max(bounds_max.y, r.end.y)
			
	if node_rects_graph.is_empty():
		return
		
	var grid_origin: Vector2 = (bounds_min - Vector2(400, 400)).snapped(Vector2(cell_size, cell_size))
	var grid_span: Vector2 = (bounds_max + Vector2(400, 400)) - grid_origin
	var grid_w: int = clampi(int(ceil(grid_span.x / cell_size)), 16, 650)
	var grid_h: int = clampi(int(ceil(grid_span.y / cell_size)), 16, 650)
	
	var astar := AStarGrid2D.new()
	astar.region = Rect2i(0, 0, grid_w, grid_h)
	astar.cell_size = Vector2(cell_size, cell_size)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar.update()
	
	for nid in node_rects_graph:
		var nr: Rect2 = node_rects_graph[nid].grow(14.0)
		var c_min_x: int = clampi(int(floor((nr.position.x - grid_origin.x) / cell_size)), 0, grid_w - 1)
		var c_max_x: int = clampi(int(floor((nr.end.x - grid_origin.x) / cell_size)), 0, grid_w - 1)
		var c_min_y: int = clampi(int(floor((nr.position.y - grid_origin.y) / cell_size)), 0, grid_h - 1)
		var c_max_y: int = clampi(int(floor((nr.end.y - grid_origin.y) / cell_size)), 0, grid_h - 1)
		for gx in range(c_min_x, c_max_x + 1):
			for gy in range(c_min_y, c_max_y + 1):
				astar.set_point_solid(Vector2i(gx, gy), true)
				
	var out_lane_counter: Dictionary = {}
	var in_lane_counter: Dictionary = {}
	
	for id in blueprint.blocks:
		var src_b = blueprint.blocks[id]
		if not graph_edit.has_node(NodePath(id)):
			continue
		var src_gn: GraphNode = graph_edit.get_node(NodePath(id))
		var port_map: Dictionary = src_gn.get_meta("slot_to_port_map", {})
		
		for s in src_b["slots"]:
			var dst_id = s["target_id"]
			if dst_id == "" or dst_id == "0" or not graph_edit.has_node(NodePath(dst_id)) or not port_map.has(s["index"]):
				continue
			var dst_gn: GraphNode = graph_edit.get_node(NodePath(dst_id))
			var out_port = port_map[s["index"]]
			var in_map: Dictionary = dst_gn.get_meta("input_action_to_port_map", {})
			var in_port: int = in_map.get(s["action"], 0)
			if out_port >= src_gn.get_output_port_count() or in_port >= dst_gn.get_input_port_count():
				continue
				
			var p1: Vector2 = src_gn.position_offset + src_gn.get_output_port_position(out_port)
			var p2: Vector2 = dst_gn.position_offset + dst_gn.get_input_port_position(in_port)
			var act: String = s["action"]
			var tb_num: int = (int(s["index"]) / 9) + 1
			var tb_slot: int = (int(s["index"]) % 9) + 1
			var label_txt = "TB%d S%d: %s" % [tb_num, tb_slot, act]
			var is_filtered = disabled_actions.get(act, false) or disabled_block_types.get(src_b["xsi_type"], false) or disabled_block_types.get(blueprint.blocks[dst_id]["xsi_type"], false)
			
			var out_idx: int = out_lane_counter.get(id, 0)
			out_lane_counter[id] = out_idx + 1
			var in_idx: int = in_lane_counter.get(dst_id, 0)
			in_lane_counter[dst_id] = in_idx + 1
			
			var pts = _route_single_wire_astar(p1, p2, out_idx, in_idx, astar, grid_origin, cell_size, grid_w, grid_h)
			cached_graph_wires.append({
				"graph_pts": pts, "src": id, "dst": dst_id, "slot": s["index"],
				"action": act, "label": label_txt, "is_monitor": false, "is_filtered": is_filtered
			})
			
		if src_b["xsi_type"] == "MyObjectBuilder_EventControllerBlock":
			var mon_map: Dictionary = src_gn.get_meta("monitor_to_port_map", {})
			for m_i in src_b["monitored_blocks"].size():
				var mon_id = src_b["monitored_blocks"][m_i]
				if not graph_edit.has_node(NodePath(mon_id)) or not mon_map.has(m_i):
					continue
				var mon_gn: GraphNode = graph_edit.get_node(NodePath(mon_id))
				var in_port: int = mon_map[m_i]
				if mon_gn.get_output_port_count() == 0 or in_port >= src_gn.get_input_port_count():
					continue
				var ev_rule: String = src_b.get("event_rule", "Block On/Off")
				var state_map: Dictionary = mon_gn.get_meta("state_to_out_port_map", {})
				var mon_out_port: int = state_map.get(ev_rule, int(mon_gn.get_meta("generic_state_out_port", 0)))
				var p1: Vector2 = mon_gn.position_offset + mon_gn.get_output_port_position(clampi(mon_out_port, 0, mon_gn.get_output_port_count() - 1))
				var p2: Vector2 = src_gn.position_offset + src_gn.get_input_port_position(in_port)
				var label_txt = "Watch: %s" % src_b.get("event_rule", "Block On/Off")
				var is_filtered = disabled_actions.get("EventMonitor", false) or disabled_block_types.get(src_b["xsi_type"], false) or disabled_block_types.get(blueprint.blocks[mon_id]["xsi_type"], false)
				
				var out_idx: int = out_lane_counter.get(mon_id, 0)
				out_lane_counter[mon_id] = out_idx + 1
				var in_idx: int = in_lane_counter.get(id, 0)
				in_lane_counter[id] = in_idx + 1
				
				var pts = _route_single_wire_astar(p1, p2, out_idx, in_idx, astar, grid_origin, cell_size, grid_w, grid_h)
				cached_graph_wires.append({
					"graph_pts": pts, "src": mon_id, "dst": id, "slot": m_i,
					"action": "EventMonitor", "label": label_txt, "is_monitor": true, "is_filtered": is_filtered
				})

func _route_single_wire_astar(
	p1: Vector2, p2: Vector2, out_idx: int, in_idx: int,
	astar: AStarGrid2D, grid_origin: Vector2, cell_size: float, grid_w: int, grid_h: int
) -> PackedVector2Array:
	var stub_out := p1 + Vector2(26.0 + float(out_idx % 8) * 12.0, 0.0)
	var stub_in := p2 - Vector2(26.0 + float(in_idx % 8) * 12.0, 0.0)
	
	var c_start := Vector2i(
		clampi(int(round((stub_out.x - grid_origin.x) / cell_size)), 0, grid_w - 1),
		clampi(int(round((stub_out.y - grid_origin.y) / cell_size)), 0, grid_h - 1)
	)
	var c_end := Vector2i(
		clampi(int(round((stub_in.x - grid_origin.x) / cell_size)), 0, grid_w - 1),
		clampi(int(round((stub_in.y - grid_origin.y) / cell_size)), 0, grid_h - 1)
	)
	
	var was_start_solid: bool = astar.is_point_solid(c_start)
	var was_end_solid: bool = astar.is_point_solid(c_end)
	astar.set_point_solid(c_start, false)
	astar.set_point_solid(c_end, false)
	
	var raw_grid_path: PackedVector2Array = astar.get_point_path(c_start, c_end)
	
	for gp in raw_grid_path:
		var cell := Vector2i(
			clampi(int(round(gp.x / cell_size)), 0, grid_w - 1),
			clampi(int(round(gp.y / cell_size)), 0, grid_h - 1)
		)
		var cur_w: float = astar.get_point_weight_scale(cell)
		astar.set_point_weight_scale(cell, cur_w + 18.0)
		
	astar.set_point_solid(c_start, was_start_solid)
	astar.set_point_solid(c_end, was_end_solid)
	
	var lane_nudge: float = float((out_idx + in_idx) % 7 - 3) * 4.5
	var waypoints: Array[Vector2] = [p1, stub_out]
	if raw_grid_path.size() >= 2:
		var simplified: Array[Vector2] = []
		for i in raw_grid_path.size():
			var world_pt: Vector2 = grid_origin + raw_grid_path[i] + Vector2(lane_nudge, lane_nudge)
			if i == 0:
				world_pt.y = p1.y
			elif i == raw_grid_path.size() - 1:
				world_pt.y = p2.y
			if simplified.size() >= 2:
				var a: Vector2 = simplified[simplified.size() - 2]
				var b: Vector2 = simplified[simplified.size() - 1]
				if abs(a.x - b.x) < 0.1 and abs(b.x - world_pt.x) < 0.1:
					simplified[simplified.size() - 1] = world_pt
					continue
				if abs(a.y - b.y) < 0.1 and abs(b.y - world_pt.y) < 0.1:
					simplified[simplified.size() - 1] = world_pt
					continue
			simplified.append(world_pt)
		for sp in simplified:
			waypoints.append(sp)
	waypoints.append(stub_in)
	waypoints.append(p2)
	
	return _sample_rounded_orthogonal_waypoints(waypoints, 10.0)

func _sample_rounded_orthogonal_waypoints(wps: Array[Vector2], corner_radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	if wps.size() < 2:
		return pts
	pts.append(wps[0])
	for i in range(1, wps.size() - 1):
		var prev = wps[i - 1]
		var cur = wps[i]
		var nxt = wps[i + 1]
		var d1 = cur.distance_to(prev)
		var d2 = cur.distance_to(nxt)
		var r = min(corner_radius, min(d1, d2) * 0.42)
		if r < 1.5:
			pts.append(cur)
			continue
		var p_enter = cur - (cur - prev).normalized() * r
		var p_exit = cur + (nxt - cur).normalized() * r
		for s in range(4):
			var t = float(s) / 3.0
			var omt = 1.0 - t
			pts.append((omt * omt * p_enter) + (2.0 * omt * t * cur) + (t * t * p_exit))
	pts.append(wps.back())
	return pts

# ==============================================================================
# SECTION: 2D OVERLAY DRAWING (PORT DOTS #16 & CLAMPED TRANSPARENT TITLES #20)
# ==============================================================================
func _draw_background_org_rects_and_comments(canvas: Control) -> void:
	var zoom: float = graph_edit.zoom
	var scroll: Vector2 = graph_edit.scroll_offset
	var font: Font = ThemeDB.fallback_font
	
	for r_i in blueprint.org_rects.size():
		var r = blueprint.org_rects[r_i]
		var sr := Rect2(r["pos"] * zoom - scroll, r["size"] * zoom)
		var base_col := Color.from_string(r["color"], Color(0.23, 0.51, 0.96))
		var is_rect_sel = selected_rect_indices.has(r_i)
		canvas.draw_rect(sr, Color(base_col.r, base_col.g, base_col.b, 0.12 if is_rect_sel else 0.06), true)
		canvas.draw_rect(sr, Color(0.25, 1.0, 0.45, 0.95) if is_rect_sel else Color(base_col.r, base_col.g, base_col.b, 0.72), false, 3.0 if is_rect_sel else 2.0)
		
		var header_h: float = max(12.0, 24.0 * zoom)
		var hr := Rect2(sr.position, Vector2(sr.size.x, header_h))
		canvas.draw_rect(hr, Color(base_col.r, base_col.g, base_col.b, 0.24), true)
		if zoom >= 0.45:
			canvas.draw_string(font, sr.position + Vector2(8.0 * zoom, 16.0 * zoom), "[Group] " + r["title"], HORIZONTAL_ALIGNMENT_LEFT, max(10.0, sr.size.x - 16.0), max(8, int(11 * zoom)), Color(1, 1, 1, 0.85))
			
		var grip_sz: float = max(3.5, 6.0 * zoom)
		for gp in [
			sr.position, Vector2(sr.end.x - grip_sz, sr.position.y),
			Vector2(sr.position.x, sr.end.y - grip_sz), sr.end - Vector2(grip_sz, grip_sz),
			Vector2(sr.get_center().x - grip_sz*0.5, sr.position.y), Vector2(sr.get_center().x - grip_sz*0.5, sr.end.y - grip_sz),
			Vector2(sr.position.x, sr.get_center().y - grip_sz*0.5), Vector2(sr.end.x - grip_sz, sr.get_center().y - grip_sz*0.5)
		]:
			canvas.draw_rect(Rect2(gp, Vector2(grip_sz, grip_sz)), base_col.lightened(0.35), true)
			
	for c in blueprint.comments:
		var cr := Rect2(c["pos"] * zoom - scroll, c["size"] * zoom)
		canvas.draw_rect(cr, Color(0.96, 0.89, 0.45, 0.92), true)
		canvas.draw_rect(cr, Color(0.70, 0.58, 0.15, 1.0), false, 2.0)
		if zoom >= 0.3:
			canvas.draw_string_multiline(font, cr.position + Vector2(8.0 * zoom, 18.0 * zoom), c["text"], HORIZONTAL_ALIGNMENT_LEFT, max(10.0, cr.size.x - 16.0 * zoom), max(8, int(11 * zoom)), -1, Color(0.1, 0.1, 0.12))

func _draw_foreground_wires_and_lasso(canvas: Control) -> void:
	var zoom: float = graph_edit.zoom
	var scroll: Vector2 = graph_edit.scroll_offset
	var font: Font = ThemeDB.fallback_font
	var dot_radius: float = clampf(4.8 * zoom, 2.2, 7.5)
	
	# 1. Highlight Selected/Hovered GraphNodes AND Draw Crisp Colored Port Dots (#16)
	for child in graph_edit.get_children():
		if child is GraphNode and child.visible:
			var id = String(child.name)
			var b = blueprint.blocks.get(id, {})
			var is_dimmed = disabled_block_types.get(b.get("xsi_type", ""), false)
			var sr = Rect2(child.position_offset * zoom - scroll, child.size * zoom)
			var is_sel = selected_node_ids.has(id)
			var is_hov = (id == hovered_node_id) or (hovered_wire_info.get("src", "") == id) or (hovered_wire_info.get("dst", "") == id)
			if is_hov:
				canvas.draw_rect(sr.grow(4.5), Color(1.0, 0.92, 0.25, 0.98), false, 4.0)
			elif is_sel:
				canvas.draw_rect(sr.grow(3.5), Color(0.25, 1.0, 0.45, 0.92), false, 3.0)
				
			# Draw vibrant colored circles on every Input and Output port (#16)!
			if not is_dimmed and zoom >= 0.22:
				var in_cols: Array = child.get_meta("in_port_colors", [])
				for p_i in child.get_input_port_count():
					var pt_screen: Vector2 = (child.position_offset + child.get_input_port_position(p_i)) * zoom - scroll
					var pc: Color = in_cols[p_i] if p_i < in_cols.size() else Color.LIGHT_GREEN
					canvas.draw_circle(pt_screen, dot_radius + 1.4, Color(0.05, 0.06, 0.08, 0.95))
					canvas.draw_circle(pt_screen, dot_radius, pc)
					
				var out_cols: Array = child.get_meta("out_port_colors", [])
				for p_o in child.get_output_port_count():
					var pt_screen: Vector2 = (child.position_offset + child.get_output_port_position(p_o)) * zoom - scroll
					var pc: Color = out_cols[p_o] if p_o < out_cols.size() else Color.ORANGE
					canvas.draw_circle(pt_screen, dot_radius + 1.4, Color(0.05, 0.06, 0.08, 0.95))
					canvas.draw_circle(pt_screen, dot_radius, pc)
					
	# 2. Draw Pre-Computed Smart AStar Wires (When enabled in View menu #15.2)
	if config.use_smart_astar_wires:
		for w_info in cached_graph_wires:
			var g_pts: PackedVector2Array = w_info["graph_pts"]
			if g_pts.size() < 2:
				continue
			var src_id: String = w_info["src"]
			var dst_id: String = w_info["dst"]
			var act: String = w_info["action"]
			var is_filtered: bool = w_info["is_filtered"]
			var is_sel_wire: bool = selected_node_ids.has(src_id) or selected_node_ids.has(dst_id) or (selected_wire_info.get("src", "") == src_id and selected_wire_info.get("dst", "") == dst_id and int(selected_wire_info.get("slot", -1)) == int(w_info["slot"]))
			var is_hov_wire: bool = (hovered_node_id == src_id or hovered_node_id == dst_id) or (hovered_wire_info == w_info)
			
			var col: Color = config.get_dimmed_color() if (is_filtered and not is_sel_wire and not is_hov_wire) else config.get_action_color(act)
			var width: float = 5.4 if is_hov_wire else (3.8 if is_sel_wire else (1.2 if is_filtered else 2.2))
			var draw_col: Color = col.lightened(0.38 if is_hov_wire else (0.18 if is_sel_wire else 0.0))
			
			var screen_pts := PackedVector2Array()
			screen_pts.resize(g_pts.size())
			for i in g_pts.size():
				screen_pts[i] = g_pts[i] * zoom - scroll
				
			if not is_filtered or is_sel_wire or is_hov_wire:
				canvas.draw_polyline(screen_pts, Color(0, 0, 0, 0.78), width + 1.8, true)
			_draw_2d_patterned_and_pulsing_wire(canvas, screen_pts, act, draw_col, width, is_filtered and not is_sel_wire and not is_hov_wire, zoom)
			
			var tip: Vector2 = screen_pts[screen_pts.size() - 1]
			var prev: Vector2 = screen_pts[screen_pts.size() - 2]
			var dir: Vector2 = (tip - prev).normalized()
			var nrm := Vector2(-dir.y, dir.x)
			var arrow_sz: float = max(4.0, (9.5 if is_hov_wire else (8.0 if is_sel_wire else 6.5)) * zoom)
			canvas.draw_colored_polygon(PackedVector2Array([
				tip,
				tip - dir * arrow_sz + nrm * (arrow_sz * 0.55),
				tip - dir * arrow_sz - nrm * (arrow_sz * 0.55)
			]), draw_col)
			
			if ( (config.show_wire_labels and zoom >= 0.45) or is_hov_wire or is_sel_wire ) and (not is_filtered or is_hov_wire or is_sel_wire):
				var mid_idx: int = screen_pts.size() / 2
				var anchor: Vector2 = (screen_pts[mid_idx - 1] + screen_pts[mid_idx]) * 0.5
				var label_txt: String = w_info["label"]
				var font_sz: int = clampi(int(10.0 * zoom), 9, 14)
				var str_sz: Vector2 = font.get_string_size(label_txt, HORIZONTAL_ALIGNMENT_CENTER, -1, font_sz)
				var pill_size := Vector2(str_sz.x + 10, str_sz.y + 4)
				var pill_rect := Rect2(anchor - pill_size * 0.5, pill_size)
				canvas.draw_rect(pill_rect, Color(0.06, 0.07, 0.10, 0.94), true)
				canvas.draw_rect(pill_rect, draw_col, false, 2.0 if is_hov_wire else 1.0)
				canvas.draw_string(font, pill_rect.position + Vector2(5, pill_rect.size.y - 4), label_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, draw_col.lightened(0.25))
				
	# 3. Clamped & Semi-Transparent Zoomed-Out Group Titles (#20 - Never exceed rectangle bounds!)
	if config.show_zoomed_out_group_titles and zoom < 0.45:
		for r in blueprint.org_rects:
			var sr := Rect2(r["pos"] * zoom - scroll, r["size"] * zoom)
			if sr.size.x < 28.0 or sr.size.y < 16.0:
				continue
			var title_txt: String = r["title"]
			var base_col := Color.from_string(r["color"], Color(0.23, 0.51, 0.96))
			
			# Measure at reference font size 24, then scale down so width NEVER exceeds 88% of sr.size.x (#20)
			var ref_sz: Vector2 = font.get_string_size(title_txt, HORIZONTAL_ALIGNMENT_CENTER, -1, 24)
			var max_allowed_w: float = sr.size.x * 0.88
			var max_allowed_h: float = sr.size.y * 0.65
			var scale_w: float = max_allowed_w / max(1.0, ref_sz.x)
			var scale_h: float = max_allowed_h / max(1.0, ref_sz.y)
			var fit_font_sz: int = clampi(int(24.0 * min(scale_w, scale_h)), 8, 32)
			
			var t_sz: Vector2 = font.get_string_size(title_txt, HORIZONTAL_ALIGNMENT_CENTER, max_allowed_w, fit_font_sz)
			var badge_w: float = min(sr.size.x - 4.0, t_sz.x + 14.0)
			var badge_h: float = min(sr.size.y - 4.0, t_sz.y + 8.0)
			var badge_rect := Rect2(sr.get_center() - Vector2(badge_w, badge_h) * 0.5, Vector2(badge_w, badge_h))
			
			canvas.draw_rect(badge_rect, Color(0.05, 0.06, 0.09, 0.42), true)
			canvas.draw_rect(badge_rect, Color(base_col.r, base_col.g, base_col.b, 0.48), false, 1.5)
			canvas.draw_string(
				font,
				badge_rect.position + Vector2(7, badge_rect.size.y - 6),
				title_txt,
				HORIZONTAL_ALIGNMENT_CENTER,
				badge_w - 10.0,
				fit_font_sz,
				Color(1.0, 1.0, 1.0, 0.68)
			)
			
	# 4. Active Lasso Box
	if lasso_active:
		var lr = Rect2(
			Vector2(min(lasso_start_screen.x, lasso_current_screen.x), min(lasso_start_screen.y, lasso_current_screen.y)),
			Vector2(abs(lasso_current_screen.x - lasso_start_screen.x), abs(lasso_current_screen.y - lasso_start_screen.y))
		)
		canvas.draw_rect(lr, Color(0.25, 0.65, 1.0, 0.18), true)
		canvas.draw_rect(lr, Color(0.35, 0.78, 1.0, 0.90), false, 1.8)

func _rebuild_legend() -> void:
	pass

# ==============================================================================
# SECTION: DUMMY BLOCK SPAWNING, P2P SYNC & DEMO BLUEPRINT
# ==============================================================================
func _spawn_new_logic_block(xsi_type: String, subtype: String, label_prefix: String, forced_id: String = "", spawn_pos: Vector2 = Vector2.INF) -> void:
	if spawn_pos == Vector2.INF:
		spawn_pos = graph_edit.scroll_offset / graph_edit.zoom + Vector2(220 + randi_range(0, 180), 160 + randi_range(0, 140))
	var new_b = blueprint.spawn_logic_block_from_dummy(
		xsi_type, subtype, "%s #%d" % [label_prefix, randi_range(10, 99)], forced_id, spawn_pos
	)
	if new_b.is_empty():
		_set_status("No [DUMMY] blocks left on the ship to replace!")
		return
	_create_graph_node_for_block(new_b, spawn_pos)
	node_last_positions[new_b["entity_id"]] = spawn_pos
	selected_node_ids.clear()
	selected_node_ids[new_b["entity_id"]] = true
	_rebuild_visibility_filter_panel()
	ship_3d.rebuild_mesh(blueprint, config, selected_node_ids, hovered_node_id, hovered_wire_info, disabled_block_types, disabled_actions)
	dummy_counter_label.text = "Dummy Slots Free: %d  " % blueprint.dummy_pool.size()
	_mark_unsaved(true)
	
	if not suppress_network_sync:
		p2p.broadcast_action({
			"op": "spawn", "xsi_type": xsi_type, "subtype": subtype,
			"name": new_b["custom_name"], "id": new_b["entity_id"],
			"x": spawn_pos.x, "y": spawn_pos.y
		})

func _on_p2p_action_received(data: Dictionary) -> void:
	suppress_network_sync = true
	match data.get("op", ""):
		"move":
			var id = str(data["id"])
			var new_pos = Vector2(data["x"], data["y"])
			if graph_edit.has_node(NodePath(id)):
				graph_edit.get_node(NodePath(id)).position_offset = new_pos
			if blueprint.blocks.has(id):
				blueprint.blocks[id]["graph_pos"] = new_pos
			_mark_unsaved(true)
		"connect":
			_on_connection_request(data["from"], int(data["port"]) + 1, data["to"], 0)
		"spawn":
			_spawn_new_logic_block(data["xsi_type"], data["subtype"], data["name"], data["id"], Vector2(data.get("x", 260), data.get("y", 220)))
	suppress_network_sync = false

func _load_demo_blueprint() -> void:
	current_file_path = ""
	disabled_block_types.clear()
	disabled_actions.clear()
	selected_node_ids.clear()
	selected_rect_indices.clear()
	selected_wire_info.clear()
	var sample_sbc := """<?xml version="1.0"?>
<Definitions xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <ShipBlueprints><ShipBlueprint><CubeGrids><CubeGrid>
    <DisplayName>Corvette_Logic_MkV</DisplayName>
    <CubeBlocks>
      <MyObjectBuilder_CubeBlock><SubtypeName>LargeBlockArmorBlock</SubtypeName><Min x="-3" y="0" z="-2" /></MyObjectBuilder_CubeBlock>
      <MyObjectBuilder_CubeBlock><SubtypeName>LargeBlockArmorBlock</SubtypeName><Min x="-1" y="0" z="-2" /></MyObjectBuilder_CubeBlock>
      <MyObjectBuilder_CubeBlock><SubtypeName>LargeBlockArmorBlock</SubtypeName><Min x="1" y="0" z="-2" /></MyObjectBuilder_CubeBlock>
      <MyObjectBuilder_CubeBlock><SubtypeName>LargeBlockArmorBlock</SubtypeName><Min x="3" y="0" z="-2" /></MyObjectBuilder_CubeBlock>

      <!-- SUBSYSTEM 1: FUEL & THRUST SAFETY -->
      <MyObjectBuilder_CubeBlock xsi:type="MyObjectBuilder_GasTank">
        <SubtypeName>LargeHydrogenTank</SubtypeName><EntityId>1000</EntityId>
        <Min x="-4" y="1" z="0" /><CustomName>Corvette Fuel Hydrogen Tank Alpha</CustomName>
      </MyObjectBuilder_CubeBlock>

      <MyObjectBuilder_CubeBlock xsi:type="MyObjectBuilder_EventControllerBlock">
        <SubtypeName>EventControllerLarge</SubtypeName><EntityId>1001</EntityId>
        <Min x="-1" y="1" z="0" /><CustomName>Corvette Fuel Low Event Controller</CustomName>
        <IsAndMode>true</IsAndMode><EventRule>Gas Tank Filled %%</EventRule>
        <SelectedBlocks><long>1000</long></SelectedBlocks>
        <Toolbar><Slots>
          <Slot><Index>0</Index><Item xsi:type="MyObjectBuilder_ToolbarItemTerminalBlock">
            <Action>TriggerNow</Action><BlockEntityId>1002</BlockEntityId>
          </Item></Slot>
          <Slot><Index>1</Index><Item xsi:type="MyObjectBuilder_ToolbarItemTerminalBlock">
            <Action>OnOff_Off</Action><BlockEntityId>1003</BlockEntityId>
          </Item></Slot>
        </Slots></Toolbar>
      </MyObjectBuilder_CubeBlock>

      <MyObjectBuilder_CubeBlock xsi:type="MyObjectBuilder_TimerBlock">
        <SubtypeName>TimerBlockLarge</SubtypeName><EntityId>1002</EntityId>
        <Min x="1" y="1" z="0" /><CustomName>Corvette Fuel Emergency Reserve Timer</CustomName>
        <Silent>true</Silent><Delay>3000</Delay>
        <Toolbar><Slots>
          <Slot><Index>0</Index><Item xsi:type="MyObjectBuilder_ToolbarItemTerminalBlock">
            <Action>OnOff_On</Action><BlockEntityId>1003</BlockEntityId>
          </Item></Slot>
          <Slot><Index>9</Index><Item xsi:type="MyObjectBuilder_ToolbarItemTerminalBlock">
            <Action>OnOff_On</Action><BlockEntityId>1004</BlockEntityId>
          </Item></Slot>
        </Slots></Toolbar>
      </MyObjectBuilder_CubeBlock>

      <MyObjectBuilder_CubeBlock xsi:type="MyObjectBuilder_InteriorLight">
        <SubtypeName>SmallLight</SubtypeName><EntityId>1003</EntityId>
        <Min x="3" y="1" z="-2" /><CustomName>Corvette Fuel Bridge Warning Strobe</CustomName>
      </MyObjectBuilder_CubeBlock>

      <MyObjectBuilder_CubeBlock xsi:type="MyObjectBuilder_Thrust">
        <SubtypeName>LargeBlockSmallThrust</SubtypeName><EntityId>1004</EntityId>
        <Min x="3" y="1" z="2" /><CustomName>Corvette Fuel Backup Thruster</CustomName>
      </MyObjectBuilder_CubeBlock>

      <!-- SUBSYSTEM 2: AUTODOCK & CONNECTOR SEQUENCE -->
      <MyObjectBuilder_CubeBlock xsi:type="MyObjectBuilder_SensorBlock">
        <SubtypeName>LargeBlockSensor</SubtypeName><EntityId>2001</EntityId>
        <Min x="-3" y="2" z="1" /><CustomName>Corvette AutoDock Proximity Sensor</CustomName>
        <Toolbar><Slots>
          <Slot><Index>0</Index><Item xsi:type="MyObjectBuilder_ToolbarItemTerminalBlock">
            <Action>TriggerNow</Action><BlockEntityId>2002</BlockEntityId>
          </Item></Slot>
        </Slots></Toolbar>
      </MyObjectBuilder_CubeBlock>

      <MyObjectBuilder_CubeBlock xsi:type="MyObjectBuilder_TimerBlock">
        <SubtypeName>TimerBlockLarge</SubtypeName><EntityId>2002</EntityId>
        <Min x="-1" y="2" z="1" /><CustomName>Corvette AutoDock Clamp Timer</CustomName>
        <Silent>false</Silent><Delay>2000</Delay>
        <Toolbar><Slots>
          <Slot><Index>0</Index><Item xsi:type="MyObjectBuilder_ToolbarItemTerminalBlock">
            <Action>Lock</Action><BlockEntityId>2003</BlockEntityId>
          </Item></Slot>
        </Slots></Toolbar>
      </MyObjectBuilder_CubeBlock>

      <MyObjectBuilder_CubeBlock xsi:type="MyObjectBuilder_ShipConnector">
        <SubtypeName>Connector</SubtypeName><EntityId>2003</EntityId>
        <Min x="1" y="2" z="1" /><CustomName>Corvette AutoDock Main Connector</CustomName>
      </MyObjectBuilder_CubeBlock>

      <!-- UNUSED LOGIC BLOCK -->
      <MyObjectBuilder_CubeBlock xsi:type="MyObjectBuilder_SensorBlock">
        <SubtypeName>LargeBlockSensor</SubtypeName><EntityId>1099</EntityId>
        <Min x="0" y="2" z="0" /><CustomName>Unwired Spare Cargo Sensor (Unused)</CustomName>
      </MyObjectBuilder_CubeBlock>

      <!-- DUMMY SLOTS -->
      <MyObjectBuilder_CubeBlock><SubtypeName>LargeBlockArmorBlock</SubtypeName><Min x="-2" y="1" z="-2" /><ColorMaskHSV x="0.55" y="0.8" z="0.8" /></MyObjectBuilder_CubeBlock>
      <MyObjectBuilder_CubeBlock><SubtypeName>LargeBlockArmorBlock</SubtypeName><Min x="0" y="1" z="-2" /><ColorMaskHSV x="0.55" y="0.8" z="0.8" /></MyObjectBuilder_CubeBlock>
      <MyObjectBuilder_CubeBlock><SubtypeName>LargeBlockArmorBlock</SubtypeName><Min x="2" y="1" z="-2" /><ColorMaskHSV x="0.55" y="0.8" z="0.8" /></MyObjectBuilder_CubeBlock>
    </CubeBlocks>
  </CubeGrid></CubeGrids></ShipBlueprint></ShipBlueprints>
</Definitions>"""
	
	blueprint.parse_sbc_string(sample_sbc)
	await _refresh_views()
	ship_3d.reset_camera_to_center()
	_mark_unsaved(false)
	_set_status("All 22 features active! Try panning/zooming, docking/floating panels, or clicking 3D blocks & wires.")

# Completely hides Godot's internal _connections_layer Node2D when Smart AStar wires are active (#24)!
func _update_vanilla_connection_layer_visibility() -> void:
	if not graph_edit:
		return
	for ch in graph_edit.get_children(true):
		if ch.name == "_connections_layer" or ch.is_class("GraphEditFilter"):
			ch.visible = not config.use_smart_astar_wires
		for sub in ch.get_children(true):
			if sub.name == "_connections_layer":
				sub.visible = not config.use_smart_astar_wires

# Returns true if mp_graph is within 18px of any visible node's input or output port (#27)
func _is_mouse_near_any_node_port(mp_graph: Vector2) -> bool:
	var tol: float = 18.0 / max(0.15, graph_edit.zoom)
	for child in graph_edit.get_children():
		if child is GraphNode and child.visible:
			var nr := Rect2(child.position_offset, child.size).grow(tol)
			if not nr.has_point(mp_graph):
				continue
			for i in child.get_input_port_count():
				if mp_graph.distance_to(child.position_offset + child.get_input_port_position(i)) <= tol:
					return true
			for o in child.get_output_port_count():
				if mp_graph.distance_to(child.position_offset + child.get_output_port_position(o)) <= tol:
					return true
	return false

# Spawns/positions an in-canvas LineEdit with all text pre-selected for instant renaming (#25, #26.2)
func _start_inline_canvas_rename(target_type: String, target_id: Variant, initial_text: String, screen_rect: Rect2) -> void:
	if not inline_canvas_edit:
		inline_canvas_edit = LineEdit.new()
		inline_canvas_edit.top_level = false
		inline_canvas_edit.z_index = 100
		inline_canvas_edit.text_submitted.connect(func(_new_t): _commit_inline_canvas_rename())
		inline_canvas_edit.focus_exited.connect(func(): _commit_inline_canvas_rename())
		graph_container.add_child(inline_canvas_edit)
	inline_edit_target_type = target_type
	inline_edit_target_id = target_id
	inline_canvas_edit.position = screen_rect.position
	inline_canvas_edit.size = Vector2(max(180.0, screen_rect.size.x), max(26.0, screen_rect.size.y))
	inline_canvas_edit.text = initial_text
	inline_canvas_edit.visible = true
	inline_canvas_edit.grab_focus()
	inline_canvas_edit.select_all()

func _commit_inline_canvas_rename() -> void:
	if not inline_canvas_edit or not inline_canvas_edit.visible:
		return
	var new_txt: String = inline_canvas_edit.text.strip_edges()
	inline_canvas_edit.visible = false
	if new_txt == "":
		return
	if inline_edit_target_type == "rect":
		var r_idx: int = int(inline_edit_target_id)
		if r_idx >= 0 and r_idx < blueprint.org_rects.size():
			blueprint.org_rects[r_idx]["title"] = new_txt
	elif inline_edit_target_type == "node":
		var nid: String = str(inline_edit_target_id)
		if blueprint.blocks.has(nid):
			blueprint.blocks[nid]["custom_name"] = new_txt
			if graph_edit.has_node(NodePath(nid)):
				var gn: GraphNode = graph_edit.get_node(NodePath(nid))
				gn.title = "[%s] %s" % [config.get_block_initial(blueprint.blocks[nid]["xsi_type"]), new_txt]
	_mark_unsaved(true)
	bg_overlay.queue_redraw()
	fg_overlay.queue_redraw()

func _build_top_right_controls_overlay() -> void:
	controls_overlay_panel = PanelContainer.new()
	controls_overlay_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	controls_overlay_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	controls_overlay_panel.offset_right = -14
	controls_overlay_panel.offset_top = 42
	controls_overlay_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	controls_overlay_panel.visible = config.show_controls_overlay
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.10, 0.86)
	sb.border_color = Color(0.28, 0.36, 0.50, 0.75)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(5)
	sb.set_content_margin_all(8)
	controls_overlay_panel.add_theme_stylebox_override("panel", sb)
	
	var lbl := Label.new()
	lbl.text = (
		"CONTROLS & SHORTCUTS OVERLAY (View -> Toggle)\n" +
		"• Pan / Zoom 2D Graph: MMB Drag / Scroll Wheel (0.03x - 3.0x)\n" +
		"• Expand All 9x9 Toolbars, Inputs & State Outs: Hold [SHIFT] on Node\n" +
		"• Multi-Select / Lasso Nodes & Groups: [CTRL] + LMB Drag or Click\n" +
		"• Rename Node or Group In-Place: Double-Click Node or Group Header\n" +
		"• Move / 8-Way Resize Group: Drag Empty Group Space / Drag 8 Border Grips\n" +
		"• Connect State Out: Drag 'State Out' -> Event Controller (Auto-adds State Row)\n" +
		"• Delete Hovered/Selected Node or Wire: Press [DEL]\n" +
		"• Visibility Filters: LMB Drag-Sweep to Toggle Many | [SHIFT]+Click to Solo\n" +
		"• 3D Preview: LMB Pick Block/Wire | MMB Pan | RMB Spin & Throw Inertia"
	)
	lbl.add_theme_color_override("font_color", Color(0.82, 0.88, 0.96))
	controls_overlay_panel.add_child(lbl)
	graph_container.add_child(controls_overlay_panel)

func _draw_2d_patterned_and_pulsing_wire(
	canvas: Control, screen_pts: PackedVector2Array, act: String,
	primary_col: Color, width: float, is_dimmed: bool, zoom: float
) -> void:
	if is_dimmed:
		canvas.draw_polyline(screen_pts, primary_col, width, true)
		return
	var st: Dictionary = config.get_action_style(act)
	var pattern: String = str(st.get("pattern", "Solid"))
	var sec_col: Color = config.get_action_secondary_color(act)
	
	# 1. Draw base secondary color along full path, then overlay primary color dashes/dots (#28)
	if pattern == "Solid":
		canvas.draw_polyline(screen_pts, primary_col, width, true)
	else:
		canvas.draw_polyline(screen_pts, sec_col, width, true)
		var dash_len: float = max(6.0, (18.0 if pattern == "LongDash" else (6.0 if pattern == "Dotted" else 12.0)) * zoom)
		var gap_len: float = max(5.0, (8.0 if pattern == "Dotted" else 10.0) * zoom)
		var cycle: float = dash_len + gap_len
		var dist_acc := 0.0
		for i in range(screen_pts.size() - 1):
			var a: Vector2 = screen_pts[i]
			var b: Vector2 = screen_pts[i + 1]
			var seg_len: float = a.distance_to(b)
			if seg_len < 0.5: continue
			var dir: Vector2 = (b - a) / seg_len
			var d := 0.0
			while d < seg_len:
				var in_cycle: float = fposmod(dist_acc + d, cycle)
				if in_cycle < dash_len:
					var draw_d: float = min(seg_len - d, dash_len - in_cycle)
					canvas.draw_line(a + dir * d, a + dir * (d + draw_d), primary_col, width, true)
					d += draw_d
				else:
					d += (cycle - in_cycle)
			dist_acc += seg_len
			
	# 2. Draw animated data flow pulses traveling from output -> input (#29)
	if config.show_data_flow_pulses:
		var total_len := 0.0
		var seg_lengths: Array[float] = []
		for i in range(screen_pts.size() - 1):
			var sl = screen_pts[i].distance_to(screen_pts[i + 1])
			seg_lengths.append(sl)
			total_len += sl
		if total_len > 8.0:
			var freq: float = max(0.1, float(st.get("pulse_freq", 1.8)))
			var count: int = clampi(int(st.get("pulse_count", 3)), 1, 10)
			var t_sec: float = float(Time.get_ticks_msec()) * 0.001
			var pulse_col: Color = primary_col.lightened(0.48)
			var pulse_r: float = max(2.8, width * 1.35)
			for p_i in count:
				var phase: float = fposmod(t_sec * freq * 0.35 + float(p_i) / float(count), 1.0)
				var target_d: float = phase * total_len
				var accum := 0.0
				for s_i in seg_lengths.size():
					var sl: float = seg_lengths[s_i]
					if accum + sl >= target_d and sl > 0.001:
						var frac: float = (target_d - accum) / sl
						var pt: Vector2 = screen_pts[s_i].lerp(screen_pts[s_i + 1], frac)
						canvas.draw_circle(pt, pulse_r + 1.5, Color(0, 0, 0, 0.75))
						canvas.draw_circle(pt, pulse_r, pulse_col)
						break
					accum += sl
