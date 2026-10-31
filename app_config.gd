# ==============================================================================
# FILE: res://app_config.gd
# PURPOSE: Persistent configuration, color palettes, block/action initial letters,
#          visibility settings, dock layout persistence, and Space Engineers schemas.
# ==============================================================================
class_name AppConfig
extends RefCounted

const CONFIG_FILENAME = "space-engineers-blueprint-editor-config.json"
const MAX_RECENT_FILES = 10

# --- GENERAL UI & DISPLAY SETTINGS ---
var ui_scale: float = 0.55
var show_friendly_names: bool = true
var hide_unused_blocks: bool = true
var create_groups_for_unused_blocks: bool = false
var use_smart_astar_wires: bool = true
var show_wire_labels: bool = true
var show_3d_selected_wire_labels: bool = true
var show_3d_block_letters: bool = true
var show_3d_wire_letters: bool = false
var show_zoomed_out_group_titles: bool = true
var show_data_flow_pulses: bool = true            # Animated data flow pulses in 2D & 3D (#29)
var show_controls_overlay: bool = true            # Top-right comprehensive controls overlay (#34)
var default_unused_slot_action: String = "OnOff_On" # Default action for unused taskbar slots (#31)
var dimmed_filter_color: String = "#3a3f4b"
var recent_files: Array[String] = []

# --- PER-ACTION DUAL COLORS, DOTTED PATTERNS (#28) & PULSE SPEED/DENSITY (#29) ---
# Patterns: "Solid", "Dashed", "Dotted", "DashDot", "LongDash"
var action_styles: Dictionary = {
	"TriggerNow": {"c1": "#ff9f1c", "c2": "#2b1900", "pattern": "Dashed", "pulse_freq": 2.4, "pulse_count": 3},
	"Start": {"c1": "#ffbf69", "c2": "#3d2600", "pattern": "LongDash", "pulse_freq": 1.8, "pulse_count": 2},
	"Stop": {"c1": "#e71d36", "c2": "#3b0008", "pattern": "Dotted", "pulse_freq": 1.5, "pulse_count": 4},
	"OnOff": {"c1": "#4ea8de", "c2": "#0d2b3e", "pattern": "Solid", "pulse_freq": 1.6, "pulse_count": 2},
	"OnOff_Toggle": {"c1": "#4ea8de", "c2": "#12354a", "pattern": "DashDot", "pulse_freq": 1.8, "pulse_count": 3},
	"OnOff_On": {"c1": "#2ec4b6", "c2": "#083833", "pattern": "Solid", "pulse_freq": 2.0, "pulse_count": 3},
	"OnOff_Off": {"c1": "#ff4d6d", "c2": "#420914", "pattern": "Dashed", "pulse_freq": 1.4, "pulse_count": 2},
	"Lock": {"c1": "#38b000", "c2": "#0d2e00", "pattern": "Solid", "pulse_freq": 1.5, "pulse_count": 2},
	"Unlock": {"c1": "#f77f00", "c2": "#3b1e00", "pattern": "Dashed", "pulse_freq": 2.0, "pulse_count": 3},
	"SwitchLock": {"c1": "#fcbf49", "c2": "#3b2a05", "pattern": "DashDot", "pulse_freq": 1.8, "pulse_count": 2},
	"Control": {"c1": "#00bbf9", "c2": "#002f40", "pattern": "Solid", "pulse_freq": 2.2, "pulse_count": 3},
	"View": {"c1": "#9b5de5", "c2": "#240e40", "pattern": "Dotted", "pulse_freq": 1.5, "pulse_count": 4},
	"ActivateBehavior_On": {"c1": "#00f5d4", "c2": "#003b33", "pattern": "LongDash", "pulse_freq": 2.2, "pulse_count": 3},
	"ActivateBehavior_Off": {"c1": "#f15bb5", "c2": "#3b0a27", "pattern": "Dashed", "pulse_freq": 1.4, "pulse_count": 2},
	"PlaySound": {"c1": "#fee440", "c2": "#3d3500", "pattern": "Dotted", "pulse_freq": 2.8, "pulse_count": 4},
	"StopSound": {"c1": "#f15bb5", "c2": "#360722", "pattern": "Dashed", "pulse_freq": 1.2, "pulse_count": 2},
	"EventMonitor": {"c1": "#c77dff", "c2": "#2d0b47", "pattern": "DashDot", "pulse_freq": 2.5, "pulse_count": 4}
}

# --- USER-CUSTOMIZABLE ALIASES FOR BLOCKS, EVENTS & ACTIONS (#33) ---
var block_aliases: Dictionary = {}  # xsi_type -> user alias string
var action_aliases: Dictionary = {} # action_name -> user alias string
var event_aliases: Dictionary = {}  # event_rule -> user alias string

# --- CONFIGURABLE KEYBINDS (#34.2) ---
var keybinds: Dictionary = {
	"expand_all_ports": KEY_SHIFT,
	"lasso_modifier": KEY_CTRL,
	"delete_item": KEY_DELETE,
	"reorganize_graph": KEY_R
}

const LINE_PATTERNS: Array[String] = ["Solid", "Dashed", "Dotted", "DashDot", "LongDash"]

# --- CONFIGURABLE BLOCK TYPE COLORS ---
var block_colors: Dictionary = {
	"MyObjectBuilder_TimerBlock": "#2b6cb0",
	"MyObjectBuilder_EventControllerBlock": "#6b46c1",
	"MyObjectBuilder_SensorBlock": "#2f855a",
	"MyObjectBuilder_ButtonPanel": "#b7791f",
	"MyObjectBuilder_MyProgrammableBlock": "#2c7a7b",
	"MyObjectBuilder_Cockpit": "#4a5568",
	"MyObjectBuilder_RemoteControl": "#319795",
	"MyObjectBuilder_Thrust": "#c53030",
	"MyObjectBuilder_InteriorLight": "#d69e2e",
	"MyObjectBuilder_ReflectorLight": "#d69e2e",
	"MyObjectBuilder_GasTank": "#00a3c4",
	"MyObjectBuilder_BatteryBlock": "#38a169",
	"MyObjectBuilder_ShipConnector": "#dd6b20",
	"MyObjectBuilder_MergeBlock": "#d53f8c",
	"MyObjectBuilder_ShipWelder": "#e53e3e",
	"MyObjectBuilder_ShipGrinder": "#805ad5",
	"MyObjectBuilder_MotorStator": "#718096",
	"MyObjectBuilder_ExtendedPistonBase": "#718096",
	"MyObjectBuilder_Door": "#5a67d8",
	"MyObjectBuilder_AirtightHangarDoor": "#5a67d8",
	"MyObjectBuilder_SoundBlock": "#b83280",
	"MyObjectBuilder_Beacon": "#ecc94b",
	"MyObjectBuilder_RadioAntenna": "#ecc94b"
}

const BLOCK_INITIALS: Dictionary = {
	"MyObjectBuilder_TimerBlock": "T",
	"MyObjectBuilder_EventControllerBlock": "E",
	"MyObjectBuilder_SensorBlock": "S",
	"MyObjectBuilder_ButtonPanel": "B",
	"MyObjectBuilder_MyProgrammableBlock": "P",
	"MyObjectBuilder_Cockpit": "C",
	"MyObjectBuilder_RemoteControl": "R",
	"MyObjectBuilder_Thrust": "H",
	"MyObjectBuilder_InteriorLight": "L",
	"MyObjectBuilder_ReflectorLight": "L",
	"MyObjectBuilder_GasTank": "G",
	"MyObjectBuilder_BatteryBlock": "A",
	"MyObjectBuilder_ShipConnector": "K",
	"MyObjectBuilder_MergeBlock": "M",
	"MyObjectBuilder_ShipWelder": "W",
	"MyObjectBuilder_ShipGrinder": "X",
	"MyObjectBuilder_MotorStator": "O",
	"MyObjectBuilder_ExtendedPistonBase": "I",
	"MyObjectBuilder_Door": "D",
	"MyObjectBuilder_AirtightHangarDoor": "D",
	"MyObjectBuilder_SoundBlock": "N",
	"MyObjectBuilder_Beacon": "Q",
	"MyObjectBuilder_RadioAntenna": "U"
}

var action_colors: Dictionary = {
	"TriggerNow": "#ff9f1c",
	"Start": "#ffbf69",
	"Stop": "#e71d36",
	"OnOff": "#4ea8de",
	"OnOff_Toggle": "#4ea8de",
	"OnOff_On": "#2ec4b6",
	"OnOff_Off": "#ff4d6d",
	"Lock": "#38b000",
	"Unlock": "#f77f00",
	"SwitchLock": "#fcbf49",
	"Control": "#00bbf9",
	"View": "#9b5de5",
	"ActivateBehavior_On": "#00f5d4",
	"ActivateBehavior_Off": "#f15bb5",
	"PlaySound": "#fee440",
	"StopSound": "#f15bb5",
	"EventMonitor": "#c77dff"
}

const FRIENDLY_TYPE_NAMES: Dictionary = {
	"MyObjectBuilder_TimerBlock": "Timer Block",
	"MyObjectBuilder_EventControllerBlock": "Event Controller",
	"MyObjectBuilder_SensorBlock": "Sensor",
	"MyObjectBuilder_ButtonPanel": "Button Panel",
	"MyObjectBuilder_MyProgrammableBlock": "Programmable Block",
	"MyObjectBuilder_Cockpit": "Cockpit / Control Seat",
	"MyObjectBuilder_RemoteControl": "Remote Control",
	"MyObjectBuilder_Thrust": "Thruster",
	"MyObjectBuilder_InteriorLight": "Interior Light",
	"MyObjectBuilder_ReflectorLight": "Spotlight",
	"MyObjectBuilder_GasTank": "Gas Tank",
	"MyObjectBuilder_BatteryBlock": "Battery",
	"MyObjectBuilder_ShipConnector": "Connector",
	"MyObjectBuilder_MergeBlock": "Merge Block",
	"MyObjectBuilder_ShipWelder": "Welder",
	"MyObjectBuilder_ShipGrinder": "Grinder",
	"MyObjectBuilder_MotorStator": "Rotor / Hinge",
	"MyObjectBuilder_ExtendedPistonBase": "Piston",
	"MyObjectBuilder_Door": "Door",
	"MyObjectBuilder_AirtightHangarDoor": "Hangar Door",
	"MyObjectBuilder_SoundBlock": "Sound Block",
	"MyObjectBuilder_Beacon": "Beacon",
	"MyObjectBuilder_RadioAntenna": "Antenna"
}

const PRIMARY_INPUT_ACTIONS: Array[String] = [
	"OnOff", "OnOff_Toggle", "OnOff_On", "OnOff_Off"
]

const SECONDARY_UNIVERSAL_INPUT_ACTIONS: Array[String] = [
	"ShowOnHUD", "ShowOnHUD_On", "ShowOnHUD_Off"
]

const SPECIFIC_BLOCK_INPUT_ACTIONS: Dictionary = {
	"MyObjectBuilder_TimerBlock": ["TriggerNow", "Start", "Stop", "Silent"],
	"MyObjectBuilder_ShipConnector": ["SwitchLock", "Lock", "Unlock"],
	"MyObjectBuilder_MotorStator": ["Reverse", "Detach", "Attach", "RotorLock"],
	"MyObjectBuilder_ExtendedPistonBase": ["Reverse", "Extend", "Retract"],
	"MyObjectBuilder_Door": ["Open", "Open_On", "Open_Off"],
	"MyObjectBuilder_AirtightHangarDoor": ["Open", "Open_On", "Open_Off"],
	"MyObjectBuilder_BatteryBlock": ["Recharge", "Recharge_On", "Recharge_Off", "Discharge_On"],
	"MyObjectBuilder_GasTank": ["Stockpile", "Stockpile_On", "Stockpile_Off"],
	"MyObjectBuilder_SoundBlock": ["PlaySound", "StopSound"],
	"MyObjectBuilder_RemoteControl": ["Control", "AutoPilot_On", "AutoPilot_Off"],
	"MyObjectBuilder_MyProgrammableBlock": ["Run", "RunWithDefaultArgument"]
}

const EVENT_RULES: Dictionary = {
	"Block On/Off": [
		"MyObjectBuilder_TimerBlock", "MyObjectBuilder_EventControllerBlock",
		"MyObjectBuilder_SensorBlock", "MyObjectBuilder_InteriorLight",
		"MyObjectBuilder_Thrust", "MyObjectBuilder_GasTank", "MyObjectBuilder_BatteryBlock",
		"MyObjectBuilder_ShipConnector", "MyObjectBuilder_ShipWelder", "MyObjectBuilder_ShipGrinder",
		"MyObjectBuilder_RemoteControl", "MyObjectBuilder_MergeBlock"
	],
	"Connector Connected": ["MyObjectBuilder_ShipConnector"],
	"Gas Tank Filled %": ["MyObjectBuilder_GasTank"],
	"Battery Stored %": ["MyObjectBuilder_BatteryBlock"],
	"Thrust Output %": ["MyObjectBuilder_Thrust"],
	"Sensor Detected Entity": ["MyObjectBuilder_SensorBlock"]
}

# ==============================================================================
# SECTION: JSON PERSISTENCE
# ==============================================================================
func get_config_path() -> String:
	if OS.has_feature("editor"):
		return "user://" + CONFIG_FILENAME
	var exe_dir = OS.get_executable_path().get_base_dir()
	var candidate = exe_dir.path_join(CONFIG_FILENAME)
	if FileAccess.file_exists(candidate):
		return candidate
	var tmp_path = exe_dir.path_join(".se_write_test.tmp")
	var test = FileAccess.open(tmp_path, FileAccess.WRITE)
	if test:
		test.close()
		DirAccess.remove_absolute(tmp_path)
		return candidate
	return "user://" + CONFIG_FILENAME

func load_config() -> void:
	var path = get_config_path()
	if not FileAccess.file_exists(path):
		save_config()
		return
	var f = FileAccess.open(path, FileAccess.READ)
	if not f:
		return
	var raw_text = f.get_as_text().strip_edges()
	f.close()
	if raw_text.is_empty():
		save_config()
		return
	var json = JSON.new()
	if json.parse(raw_text) != OK or typeof(json.data) != TYPE_DICTIONARY:
		save_config()
		return
	var data: Dictionary = json.data
	ui_scale = float(data.get("ui_scale", ui_scale))
	show_friendly_names = bool(data.get("show_friendly_names", show_friendly_names))
	hide_unused_blocks = bool(data.get("hide_unused_blocks", hide_unused_blocks))
	create_groups_for_unused_blocks = bool(data.get("create_groups_for_unused_blocks", create_groups_for_unused_blocks))
	use_smart_astar_wires = bool(data.get("use_smart_astar_wires", use_smart_astar_wires))
	show_wire_labels = bool(data.get("show_wire_labels", show_wire_labels))
	show_3d_selected_wire_labels = bool(data.get("show_3d_selected_wire_labels", show_3d_selected_wire_labels))
	show_3d_block_letters = bool(data.get("show_3d_block_letters", show_3d_block_letters))
	show_3d_wire_letters = bool(data.get("show_3d_wire_letters", show_3d_wire_letters))
	show_zoomed_out_group_titles = bool(data.get("show_zoomed_out_group_titles", show_zoomed_out_group_titles))
	show_data_flow_pulses = bool(data.get("show_data_flow_pulses", show_data_flow_pulses))
	show_controls_overlay = bool(data.get("show_controls_overlay", show_controls_overlay))
	default_unused_slot_action = str(data.get("default_unused_slot_action", default_unused_slot_action))
	if data.has("action_styles") and typeof(data["action_styles"]) == TYPE_DICTIONARY:
		for k in data["action_styles"]:
			if typeof(data["action_styles"][k]) == TYPE_DICTIONARY:
				action_styles[k] = data["action_styles"][k].duplicate()
	if data.has("block_aliases") and typeof(data["block_aliases"]) == TYPE_DICTIONARY:
		block_aliases = data["block_aliases"].duplicate()
	if data.has("action_aliases") and typeof(data["action_aliases"]) == TYPE_DICTIONARY:
		action_aliases = data["action_aliases"].duplicate()
	if data.has("event_aliases") and typeof(data["event_aliases"]) == TYPE_DICTIONARY:
		event_aliases = data["event_aliases"].duplicate()
	if data.has("keybinds") and typeof(data["keybinds"]) == TYPE_DICTIONARY:
		for k in data["keybinds"]:
			keybinds[k] = int(data["keybinds"][k])
	dimmed_filter_color = str(data.get("dimmed_filter_color", dimmed_filter_color))
	
	recent_files.clear()
	if data.has("recent_files") and typeof(data["recent_files"]) == TYPE_ARRAY:
		for rf in data["recent_files"]:
			var s = str(rf)
			if not s.is_empty() and not (s in recent_files):
				recent_files.append(s)
	if data.has("block_colors") and typeof(data["block_colors"]) == TYPE_DICTIONARY:
		for k in data["block_colors"]:
			block_colors[k] = str(data["block_colors"][k])
	if data.has("action_colors") and typeof(data["action_colors"]) == TYPE_DICTIONARY:
		for k in data["action_colors"]:
			action_colors[k] = str(data["action_colors"][k])

func save_config() -> void:
	var path = get_config_path()
	var f = FileAccess.open(path, FileAccess.WRITE)
	if not f:
		return
	var payload = {
		"show_data_flow_pulses": show_data_flow_pulses,
		"show_controls_overlay": show_controls_overlay,
		"default_unused_slot_action": default_unused_slot_action,
		"action_styles": action_styles,
		"block_aliases": block_aliases,
		"action_aliases": action_aliases,
		"event_aliases": event_aliases,
		"keybinds": keybinds,
		"ui_scale": ui_scale,
		"show_friendly_names": show_friendly_names,
		"hide_unused_blocks": hide_unused_blocks,
		"create_groups_for_unused_blocks": create_groups_for_unused_blocks,
		"use_smart_astar_wires": use_smart_astar_wires,
		"show_wire_labels": show_wire_labels,
		"show_3d_selected_wire_labels": show_3d_selected_wire_labels,
		"show_3d_block_letters": show_3d_block_letters,
		"show_3d_wire_letters": show_3d_wire_letters,
		"show_zoomed_out_group_titles": show_zoomed_out_group_titles,
		"dimmed_filter_color": dimmed_filter_color,
		"recent_files": recent_files,
		"block_colors": block_colors,
		"action_colors": action_colors
	}
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()

func add_recent_file(path: String) -> void:
	var clean = path.strip_edges()
	if clean.is_empty():
		return
	recent_files.erase(clean)
	recent_files.push_front(clean)
	while recent_files.size() > MAX_RECENT_FILES:
		recent_files.pop_back()
	save_config()

# ==============================================================================
# SECTION: HELPERS
# ==============================================================================
func get_block_color(xsi_type: String) -> Color:
	return Color.from_string(block_colors.get(xsi_type, "#3a4556"), Color(0.28, 0.34, 0.44))

func get_block_initial(xsi_type: String) -> String:
	if BLOCK_INITIALS.has(xsi_type):
		return BLOCK_INITIALS[xsi_type]
	var clean = xsi_type.replace("MyObjectBuilder_", "")
	return clean.left(1).to_upper() if not clean.is_empty() else "?"

func get_action_initial(action: String) -> String:
	return action.left(1).to_upper() if not action.is_empty() else "A"

func get_action_color(action: String) -> Color:
	if action_colors.has(action):
		return Color.from_string(action_colors[action], Color.CORNFLOWER_BLUE)
	var h = float(abs(action.hash()) % 360) / 360.0
	return Color.from_hsv(h, 0.72, 0.95)

func get_dimmed_color() -> Color:
	var c = Color.from_string(dimmed_filter_color, Color(0.23, 0.25, 0.30))
	return Color(c.r, c.g, c.b, 0.14)

func get_supported_inputs_for_block(xsi_type: String, include_secondary: bool) -> Array[String]:
	var res: Array[String] = []
	if SPECIFIC_BLOCK_INPUT_ACTIONS.has(xsi_type):
		for a in SPECIFIC_BLOCK_INPUT_ACTIONS[xsi_type]:
			res.append(a)
	for a in PRIMARY_INPUT_ACTIONS:
		if not (a in res):
			res.append(a)
	if include_secondary:
		for a in SECONDARY_UNIVERSAL_INPUT_ACTIONS:
			if not (a in res):
				res.append(a)
	return res

func get_action_style(action: String) -> Dictionary:
	if not action_styles.has(action):
		var c1_hex = action_colors.get(action, "#4ea8de")
		var c2_hex = "#" + Color.from_string(c1_hex, Color.CORNFLOWER_BLUE).darkened(0.65).to_html(false)
		action_styles[action] = {"c1": c1_hex, "c2": c2_hex, "pattern": "Solid", "pulse_freq": 1.8, "pulse_count": 3}
	return action_styles[action]

func get_action_secondary_color(action: String) -> Color:
	var st = get_action_style(action)
	return Color.from_string(st.get("c2", "#102a3c"), Color.DARK_SLATE_BLUE)

func get_block_display_type(xsi_type: String) -> String:
	var alias = str(block_aliases.get(xsi_type, "")).strip_edges()
	if alias != "":
		return alias
	if show_friendly_names:
		return FRIENDLY_TYPE_NAMES.get(xsi_type, xsi_type.replace("MyObjectBuilder_", ""))
	return xsi_type

func get_action_display_name(action: String) -> String:
	var alias = str(action_aliases.get(action, "")).strip_edges()
	return alias if alias != "" else action

func get_event_display_name(rule: String) -> String:
	var alias = str(event_aliases.get(rule, "")).strip_edges()
	return alias if alias != "" else rule

func format_block_type_line(xsi_type: String, subtype: String) -> String:
	var t = get_block_display_type(xsi_type)
	return "%s — %s" % [t, subtype if subtype != "" else "Standard"]

# Returns all possible states a block can expose on its State Out section when holding Shift (#32.2)
func get_supported_output_states_for_block(xsi_type: String) -> Array[String]:
	var states: Array[String] = ["Block On/Off"]
	for rule_name in EVENT_RULES:
		if xsi_type in EVENT_RULES[rule_name] and not (rule_name in states):
			states.append(rule_name)
	return states

static func estimate_block_grid_size(xsi_type: String, subtype: String) -> Vector3:
	var st = subtype.to_lower()
	if "largehydrogentank" in st and not "small" in st:
		return Vector3(3, 3, 3)
	if "cockpit" in st and not "dbb" in st and not "seat" in st:
		return Vector3(3, 3, 3) if "small" in st else Vector3(1, 1, 2)
	if "welder" in st or "grinder" in st or "drill" in st:
		return Vector3(3, 3, 6) if "small" in st else Vector3(1, 1, 3)
	if "connector" in st and "small" in st and not "medium" in st:
		return Vector3(3, 3, 2)
	if xsi_type == "MyObjectBuilder_TimerBlock" and "reskin" in st:
		return Vector3(1, 1, 1)
	return Vector3.ONE
