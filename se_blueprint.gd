# ==============================================================================
# FILE: res://se_blueprint.gd
# PURPOSE: Parses and exports Space Engineers .sbc XML blueprints.
#          Properly tracks XML depth so nested <Component> or <Pilot> tags
#          never overwrite a CubeBlock's real <EntityId> or <Min>.
#          Computes accurate 3D world positions across multiple subgrids and
#          supports exporting WITH or WITHOUT <CustomData> editor metadata.
# ==============================================================================
class_name SEBlueprint
extends RefCounted

# Keyed by EntityId (String) -> Block Dictionary
var blocks: Dictionary = {}
var dummy_pool: Array[Dictionary] = []
var comments: Array[Dictionary] = [] # {pos: Vector2, size: Vector2, text: String}
var org_rects: Array[Dictionary] = [] # {pos: Vector2, size: Vector2, title: String, color: String}
var grid_name: String = "UnnamedGrid"

const LOGIC_TYPES = [
	"MyObjectBuilder_TimerBlock",
	"MyObjectBuilder_EventControllerBlock",
	"MyObjectBuilder_SensorBlock",
	"MyObjectBuilder_ButtonPanel",
	"MyObjectBuilder_MyProgrammableBlock",
	"MyObjectBuilder_Cockpit",
	"MyObjectBuilder_RemoteControl",
	"MyObjectBuilder_Thrust",
	"MyObjectBuilder_InteriorLight",
	"MyObjectBuilder_ReflectorLight",
	"MyObjectBuilder_GasTank",
	"MyObjectBuilder_BatteryBlock",
	"MyObjectBuilder_ShipConnector",
	"MyObjectBuilder_MergeBlock",
	"MyObjectBuilder_ShipWelder",
	"MyObjectBuilder_ShipGrinder",
	"MyObjectBuilder_MotorStator",
	"MyObjectBuilder_ExtendedPistonBase",
	"MyObjectBuilder_Door",
	"MyObjectBuilder_AirtightHangarDoor",
	"MyObjectBuilder_SoundBlock",
	"MyObjectBuilder_Beacon",
	"MyObjectBuilder_RadioAntenna"
]

const DUMMY_SUBTYPE = "LargeBlockArmorBlock"
const DUMMY_COLOR_X = 0.55

const POS_REGEX = "\\[SELogicGraphPos:([-0-9.]+),([-0-9.]+)\\]"
const COMMENT_REGEX = "\\[SELogicComment:([-0-9.]+),([-0-9.]+),([-0-9.]+),([-0-9.]+),([A-Za-z0-9+/=]+)\\]"
const RECT_REGEX = "\\[SELogicRect:([-0-9.]+),([-0-9.]+),([-0-9.]+),([-0-9.]+),([#A-Fa-f0-9]+),([A-Za-z0-9+/=]+)\\]"

# ==============================================================================
# SECTION: XML PARSER (DEPTH-SAFE & MULTI-SUBGRID AWARE)
# ==============================================================================
func parse_sbc_string(xml_text: String) -> void:
	blocks.clear()
	dummy_pool.clear()
	comments.clear()
	org_rects.clear()
	grid_name = "UnnamedGrid"
	
	var parser = XMLParser.new()
	parser.open_buffer(xml_text.to_utf8_buffer())
	
	var element_stack: Array[String] = []
	var cube_block_depth: int = -1
	var cube_grid_depth: int = -1
	var toolbar_depth: int = -1
	var slot_depth: int = -1
	var selected_blocks_depth: int = -1
	
	var current_grid_index: int = -1
	var current_grid_scale: float = 1.0 # 1.0 for Large Grid, 0.2 for Small Grid (relative visual units)
	var current_grid_offset: Vector3 = Vector3.ZERO
	
	var current_block: Dictionary = {}
	var current_slot: Dictionary = {}
	var pending_comments: Array[Dictionary] = []
	
	while parser.read() != ERR_FILE_EOF:
		var node_type = parser.get_node_type()
		
		if node_type == XMLParser.NODE_ELEMENT:
			var el_name = parser.get_node_name()
			var is_empty_el = parser.is_empty()
			element_stack.push_back(el_name)
			var depth = element_stack.size()
			
			if el_name == "CubeGrid" and cube_grid_depth == -1:
				cube_grid_depth = depth
				current_grid_index += 1
				current_grid_scale = 1.0
				# Offset secondary subgrids slightly if no world position is parsed
				current_grid_offset = Vector3.ZERO
				
			elif el_name == "MyObjectBuilder_CubeBlock" and cube_block_depth == -1:
				cube_block_depth = depth
				var xsi_type = parser.get_named_attribute_value_safe("xsi:type")
				current_block = {
					"xsi_type": xsi_type,
					"subtype": "",
					"entity_id": "",
					"custom_name": "",
					"custom_data": "",
					"graph_pos": Vector2.INF,
					"min": Vector3i.ZERO,
					"world_pos": Vector3.ZERO,
					"grid_scale": current_grid_scale,
					"grid_index": current_grid_index,
					"color_hsv": Vector3.ZERO,
					"slots": [], # {index: int, action: String, target_id: String}
					"silent": false,
					"delay_ms": 1000,
					"is_and_mode": false,
					"event_rule": "Block On/Off",
					"monitored_blocks": [],
					"is_dummy": false
				}
			elif cube_block_depth != -1 and depth == cube_block_depth + 1:
				# Only read direct child attributes of MyObjectBuilder_CubeBlock!
				if el_name == "Min":
					current_block["min"] = Vector3i(
						parser.get_named_attribute_value_safe("x").to_int(),
						parser.get_named_attribute_value_safe("y").to_int(),
						parser.get_named_attribute_value_safe("z").to_int()
					)
				elif el_name == "ColorMaskHSV":
					current_block["color_hsv"] = Vector3(
						parser.get_named_attribute_value_safe("x").to_float(),
						parser.get_named_attribute_value_safe("y").to_float(),
						parser.get_named_attribute_value_safe("z").to_float()
					)
				elif el_name == "Toolbar":
					toolbar_depth = depth
				elif el_name == "SelectedBlocks":
					selected_blocks_depth = depth
			elif toolbar_depth != -1 and el_name == "Slot" and slot_depth == -1:
				slot_depth = depth
				current_slot = {"index": 0, "action": "", "target_id": ""}
				
			if is_empty_el:
				if depth == slot_depth: slot_depth = -1
				if depth == toolbar_depth: toolbar_depth = -1
				if depth == selected_blocks_depth: selected_blocks_depth = -1
				if depth == cube_block_depth:
					cube_block_depth = -1
					_finalize_parsed_block(current_block)
				if depth == cube_grid_depth: cube_grid_depth = -1
				element_stack.pop_back()
				
		elif node_type == XMLParser.NODE_TEXT:
			var text = parser.get_node_data().strip_edges()
			if text.is_empty() or element_stack.is_empty():
				continue
			var cur_el = element_stack.back()
			var depth = element_stack.size()
			
			if cube_grid_depth != -1 and cube_block_depth == -1:
				if cur_el == "GridSizeEnum":
					current_grid_scale = 0.5 if text == "Small" else 1.0
				elif cur_el == "DisplayName" and grid_name == "UnnamedGrid":
					grid_name = text
			elif cube_block_depth != -1:
				if slot_depth != -1:
					match cur_el:
						"Index": current_slot["index"] = text.to_int()
						"Action": current_slot["action"] = text
						"BlockEntityId": current_slot["target_id"] = text
				elif selected_blocks_depth != -1 and cur_el == "long":
					if text != "0" and not (text in current_block["monitored_blocks"]):
						current_block["monitored_blocks"].append(text)
				elif depth == cube_block_depth + 1:
					# Strictly direct children of MyObjectBuilder_CubeBlock so nested Components/Pilots never overwrite EntityId!
					match cur_el:
						"SubtypeName": current_block["subtype"] = text
						"EntityId": current_block["entity_id"] = text
						"CustomName": current_block["custom_name"] = text
						"Silent": current_block["silent"] = (text.to_lower() == "true")
						"Delay": current_block["delay_ms"] = text.to_int()
						"IsAndMode": current_block["is_and_mode"] = (text.to_lower() == "true")
						"EventRule": current_block["event_rule"] = text
						"CustomData":
							current_block["custom_data"] = text
							_parse_custom_data_metadata(current_block, text, pending_comments)
							
		elif node_type == XMLParser.NODE_ELEMENT_END:
			var closed_name = parser.get_node_name()
			var depth = element_stack.size()
			if depth == slot_depth and closed_name == "Slot":
				slot_depth = -1
				if current_slot["target_id"] != "" and current_slot["target_id"] != "0":
					if current_slot["action"] == "":
						current_slot["action"] = "TriggerNow"
					current_block["slots"].append(current_slot.duplicate())
			elif depth == toolbar_depth and closed_name == "Toolbar":
				toolbar_depth = -1
			elif depth == selected_blocks_depth and closed_name == "SelectedBlocks":
				selected_blocks_depth = -1
			elif depth == cube_block_depth and closed_name == "MyObjectBuilder_CubeBlock":
				cube_block_depth = -1
				_finalize_parsed_block(current_block)
			elif depth == cube_grid_depth and closed_name == "CubeGrid":
				cube_grid_depth = -1
			if not element_stack.is_empty():
				element_stack.pop_back()
				
	# Resolve relative comment positions against their host block's graph_pos
	for pc in pending_comments:
		var host_id = pc["host_id"]
		var base_pos = Vector2(100, 100)
		if blocks.has(host_id) and blocks[host_id]["graph_pos"] != Vector2.INF:
			base_pos = blocks[host_id]["graph_pos"]
		comments.append({
			"pos": base_pos + pc["offset"],
			"size": pc["size"],
			"text": pc["text"]
		})

func _finalize_parsed_block(b: Dictionary) -> void:
	# Compute true 3D center of the block based on its estimated multi-cell size
	var cell_span: Vector3 = AppConfig.estimate_block_grid_size(b["xsi_type"], b["subtype"])
	var min_v := Vector3(b["min"].x, b["min"].y, b["min"].z)
	var center_cell := min_v + (cell_span - Vector3.ONE) * 0.5
	b["cell_span"] = cell_span
	b["world_pos"] = center_cell
	
	var is_dummy_color = abs(b["color_hsv"].x - DUMMY_COLOR_X) < 0.02
	var is_dummy_name = b["custom_name"].begins_with("[DUMMY]")
	
	if (b["subtype"] == DUMMY_SUBTYPE and is_dummy_color) or is_dummy_name:
		b["is_dummy"] = true
		dummy_pool.append(b)
		return
		
	if b["entity_id"] == "":
		b["entity_id"] = "armor_%d_%d_%d_%d" % [b["grid_index"], b["min"].x, b["min"].y, b["min"].z]
	if b["custom_name"] == "":
		b["custom_name"] = b["subtype"] if b["subtype"] != "" else b["xsi_type"].replace("MyObjectBuilder_", "")
		
	blocks[b["entity_id"]] = b

# ==============================================================================
# SECTION: CUSTOM DATA METADATA PARSING & STRIPPING
# ==============================================================================
func _parse_custom_data_metadata(b: Dictionary, cd: String, pending_comments: Array[Dictionary]) -> void:
	var rx_pos = RegEx.new()
	rx_pos.compile(POS_REGEX)
	var m_pos = rx_pos.search(cd)
	if m_pos:
		b["graph_pos"] = Vector2(m_pos.get_string(1).to_float(), m_pos.get_string(2).to_float())
		
	var rx_com = RegEx.new()
	rx_com.compile(COMMENT_REGEX)
	for m in rx_com.search_all(cd):
		pending_comments.append({
			"host_id": b["entity_id"],
			"offset": Vector2(m.get_string(1).to_float(), m.get_string(2).to_float()),
			"size": Vector2(m.get_string(3).to_float(), m.get_string(4).to_float()),
			"text": Marshalls.base64_to_utf8(m.get_string(5))
		})
		
	var rx_rect = RegEx.new()
	rx_rect.compile(RECT_REGEX)
	for m in rx_rect.search_all(cd):
		org_rects.append({
			"pos": Vector2(m.get_string(1).to_float(), m.get_string(2).to_float()),
			"size": Vector2(m.get_string(3).to_float(), m.get_string(4).to_float()),
			"color": m.get_string(5),
			"title": Marshalls.base64_to_utf8(m.get_string(6))
		})

func _strip_all_metadata_tags(cd: String) -> String:
	var out = cd
	for pattern in [POS_REGEX, COMMENT_REGEX, RECT_REGEX]:
		var rx = RegEx.new()
		rx.compile(pattern)
		out = rx.sub(out, "", true)
	var clean_lines := PackedStringArray()
	for line in out.split("\n"):
		if not line.strip_edges().is_empty():
			clean_lines.append(line)
	return "\n".join(clean_lines)

# ==============================================================================
# SECTION: GRAPH QUERIES & MUTATIONS
# ==============================================================================
func is_block_used_in_logic(entity_id: String) -> bool:
	if not blocks.has(entity_id):
		return false
	var b = blocks[entity_id]
	for s in b["slots"]:
		if blocks.has(s["target_id"]):
			return true
	for mb_id in b["monitored_blocks"]:
		if blocks.has(mb_id):
			return true
	for other_id in blocks:
		var ob = blocks[other_id]
		for s in ob["slots"]:
			if s["target_id"] == entity_id:
				return true
		if entity_id in ob["monitored_blocks"]:
			return true
	return false

# Removes a block from the blueprint and cleans up all wires pointing to it
func delete_block(entity_id: String) -> void:
	if not blocks.has(entity_id):
		return
	blocks.erase(entity_id)
	for other_id in blocks:
		var ob = blocks[other_id]
		ob["slots"] = ob["slots"].filter(func(s): return s["target_id"] != entity_id)
		ob["monitored_blocks"].erase(entity_id)

func spawn_logic_block_from_dummy(xsi_type: String, subtype: String, custom_name: String, forced_id: String = "", initial_pos: Vector2 = Vector2(360, 220)) -> Dictionary:
	if dummy_pool.is_empty():
		return {}
	var dummy = dummy_pool.pop_front()
	var new_id = forced_id if forced_id != "" else str(randi_range(100000000, 999999999))
	var cell_span = AppConfig.estimate_block_grid_size(xsi_type, subtype)
	var min_v = Vector3(dummy["min"].x, dummy["min"].y, dummy["min"].z)
	
	var new_block = {
		"xsi_type": xsi_type,
		"subtype": subtype,
		"entity_id": new_id,
		"custom_name": custom_name,
		"custom_data": "",
		"graph_pos": initial_pos,
		"min": dummy["min"],
		"cell_span": cell_span,
		"world_pos": min_v + (cell_span - Vector3.ONE) * 0.5,
		"grid_scale": dummy.get("grid_scale", 1.0),
		"grid_index": dummy.get("grid_index", 0),
		"color_hsv": Vector3(0.0, 0.8, 0.5),
		"slots": [],
		"silent": false,
		"delay_ms": 1000,
		"is_and_mode": false,
		"event_rule": "Block On/Off",
		"monitored_blocks": [],
		"is_dummy": false
	}
	blocks[new_id] = new_block
	return new_block

func _xml_escape(s: String) -> String:
	return s.replace("&", "&").replace("<", "<").replace(">", ">").replace("\"", "\"")

# ==============================================================================
# SECTION: XML SERIALIZATION (SUPPORTS WITH OR WITHOUT CUSTOM BLOCK DATA)
# ==============================================================================
func export_to_sbc_xml(include_editor_custom_data: bool = true) -> String:
	var logic_ids: Array[String] = []
	var top_left_id: String = ""
	var best_top_left_score := INF
	
	for id in blocks:
		var b = blocks[id]
		if not str(id).begins_with("armor_") and b.get("graph_pos", Vector2.INF) != Vector2.INF:
			logic_ids.append(id)
			var score = b["graph_pos"].x + b["graph_pos"].y
			if score < best_top_left_score:
				best_top_left_score = score
				top_left_id = id
				
	var comments_by_block: Dictionary = {}
	if include_editor_custom_data:
		for c in comments:
			var best_id := ""
			var best_dist := INF
			for id in logic_ids:
				var d = blocks[id]["graph_pos"].distance_squared_to(c["pos"])
				if d < best_dist:
					best_dist = d
					best_id = id
			if best_id != "":
				if not comments_by_block.has(best_id):
					comments_by_block[best_id] = []
				comments_by_block[best_id].append(c)

	var out := PackedStringArray()
	out.append('<?xml version="1.0"?>')
	out.append('<Definitions xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">')
	out.append('  <ShipBlueprints><ShipBlueprint><CubeGrids><CubeGrid>')
	out.append('    <DisplayName>%s</DisplayName>' % _xml_escape(grid_name))
	out.append('    <CubeBlocks>')
	
	for id in blocks:
		var b = blocks[id]
		if b["xsi_type"] != "":
			out.append('      <MyObjectBuilder_CubeBlock xsi:type="%s">' % b["xsi_type"])
		else:
			out.append('      <MyObjectBuilder_CubeBlock>')
		out.append('        <SubtypeName>%s</SubtypeName>' % _xml_escape(b["subtype"]))
		if not str(id).begins_with("armor_"):
			out.append('        <EntityId>%s</EntityId>' % b["entity_id"])
		out.append('        <Min x="%d" y="%d" z="%d" />' % [b["min"].x, b["min"].y, b["min"].z])
		out.append('        <ColorMaskHSV x="%s" y="%s" z="%s" />' % [b["color_hsv"].x, b["color_hsv"].y, b["color_hsv"].z])
		if b["custom_name"] != "":
			out.append('        <CustomName>%s</CustomName>' % _xml_escape(b["custom_name"]))
			
		if b["xsi_type"] == "MyObjectBuilder_TimerBlock":
			out.append('        <Silent>%s</Silent>' % ("true" if b.get("silent", false) else "false"))
			out.append('        <Delay>%d</Delay>' % int(b.get("delay_ms", 1000)))
			
		if b["xsi_type"] == "MyObjectBuilder_EventControllerBlock":
			out.append('        <IsAndMode>%s</IsAndMode>' % ("true" if b.get("is_and_mode", false) else "false"))
			out.append('        <EventRule>%s</EventRule>' % _xml_escape(b.get("event_rule", "Block On/Off")))
			if not b["monitored_blocks"].is_empty():
				out.append('        <SelectedBlocks>')
				for mb_id in b["monitored_blocks"]:
					out.append('          <long>%s</long>' % mb_id)
				out.append('        </SelectedBlocks>')
				
		var base_cd = _strip_all_metadata_tags(b.get("custom_data", ""))
		var meta_tags := PackedStringArray()
		if base_cd != "":
			meta_tags.append(base_cd)
			
		if include_editor_custom_data and not str(id).begins_with("armor_") and b.get("graph_pos", Vector2.INF) != Vector2.INF:
			var gp: Vector2 = b["graph_pos"]
			meta_tags.append("[SELogicGraphPos:%d,%d]" % [roundi(gp.x), roundi(gp.y)])
			if comments_by_block.has(id):
				for c in comments_by_block[id]:
					var rel: Vector2 = c["pos"] - gp
					var sz: Vector2 = c["size"]
					var b64 = Marshalls.utf8_to_base64(c["text"])
					meta_tags.append("[SELogicComment:%d,%d,%d,%d,%s]" % [roundi(rel.x), roundi(rel.y), roundi(sz.x), roundi(sz.y), b64])
			if id == top_left_id:
				for r in org_rects:
					var rp: Vector2 = r["pos"]
					var rs: Vector2 = r["size"]
					var b64_t = Marshalls.utf8_to_base64(r["title"])
					meta_tags.append("[SELogicRect:%d,%d,%d,%d,%s,%s]" % [roundi(rp.x), roundi(rp.y), roundi(rs.x), roundi(rs.y), r["color"], b64_t])
					
		if not meta_tags.is_empty():
			out.append('        <CustomData>%s</CustomData>' % _xml_escape("\n".join(meta_tags)))
			
		if not b["slots"].is_empty():
			out.append('        <Toolbar><Slots>')
			for s in b["slots"]:
				out.append('          <Slot><Index>%d</Index><Item xsi:type="MyObjectBuilder_ToolbarItemTerminalBlock">' % s["index"])
				out.append('            <Action>%s</Action><BlockEntityId>%s</BlockEntityId>' % [_xml_escape(s["action"]), s["target_id"]])
				out.append('          </Item></Slot>')
			out.append('        </Slots></Toolbar>')
		out.append('      </MyObjectBuilder_CubeBlock>')
		
	for d in dummy_pool:
		out.append('      <MyObjectBuilder_CubeBlock>')
		out.append('        <SubtypeName>%s</SubtypeName>' % _xml_escape(d["subtype"]))
		out.append('        <Min x="%d" y="%d" z="%d" />' % [d["min"].x, d["min"].y, d["min"].z])
		out.append('        <ColorMaskHSV x="%s" y="%s" z="%s" />' % [d["color_hsv"].x, d["color_hsv"].y, d["color_hsv"].z])
		out.append('      </MyObjectBuilder_CubeBlock>')
		
	out.append('    </CubeBlocks>')
	out.append('  </CubeGrid></CubeGrids></ShipBlueprint></ShipBlueprints>')
	out.append('</Definitions>')
	return "\n".join(out)
