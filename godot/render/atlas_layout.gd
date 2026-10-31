class_name AtlasLayout
extends RefCounted
## Cell lookup for the 14 texture atlases taken from the original game (design section 4, step S2).
##
## The data comes from res://assets/atlas/atlas_layout.json, which tools/extract_assets.mjs derives
## from the game's own ART_LAYOUTS and buildAtlasDrawGeometry (it is never edited by hand), and the
## textures are the imported res://assets/atlas/*.webp files. There is no drawing code here: the
## renderer (step S7) asks this class where a sprite sits in its sheet.
##
## Sliced sheets (cell grids with ids): projectiles, hits, characters, enemies, weapons, elements,
## effects. For them geometry(sheet, id) returns the game's draw geometry as a Dictionary:
##   sx, sy, sourceW, sourceH   source rectangle in texels, insets already applied
##   dxMul, dyMul, dwMul, dhMul sprite placement: the sprite is drawn at (x + dxMul * w, y + dyMul * h)
##                              with the size (dwMul * w, dhMul * h)
## For characters and enemies the art id itself ("catalyst", "boss") is an alias of its idle1 cell,
## exactly as in the game. The other atlases (overhaul_*, signature_fx, range_fx and the two generated
## enemy effects) are reached through section(), the *_rect() helpers and texture().
##
## Lookups of unknown sheets or ids report the problem with push_error and return an empty value
## (Rect2(), {}, null, -1). Setting `quiet` records the message in `last_error` without push_error;
## the tests use that to check the failure paths. This also holds for an instance whose layout file
## did not load: every lookup then fails the same way (is_loaded() is false).
##
## A miss in the overhaul and meta atlases is expected control flow, not an error. The game's
## OVERHAUL_CHAR_ROWS cover 4 of the 11 characters and OVERHAUL_WEAPON_ICON_INDEX 4 weapons, and
## drawOverhaulCharacterFrame, drawOverhaulWeaponIcon and drawSignatureFxFrame simply return false for
## any other id so that the caller falls back (characters sheet, weapons sheet, ...). Ask
## has_overhaul_character(), has_overhaul_icon() and has_meta_effect() first: they never report an
## error. overhaul_character_rect(), overhaul_icon_rect() and meta_frame_rect() are the strict
## versions for an id that is known to exist and call push_error otherwise.

const LAYOUT_PATH: String = "res://assets/atlas/atlas_layout.json"
const ATLAS_DIR: String = "res://assets/atlas"
const FORMAT_VERSION: int = 1
const GEOMETRY_FIELDS: PackedStringArray = [
	"sx", "sy", "sourceW", "sourceH", "dxMul", "dyMul", "dwMul", "dhMul",
]
## Layout sections that are one atlas each (the sliced sheets live under "sheets").
const SECTION_ATLASES: PackedStringArray = [
	"overhaul_characters", "overhaul_fx", "overhaul_weapon_icons", "signature_fx", "range_fx",
]
## Sections whose rows are described by a meta table: row id -> {x, y, width, height, frames, ...}.
const META_ATLASES: PackedStringArray = ["overhaul_fx", "signature_fx"]

static var _shared: AtlasLayout = null

## When true a failed lookup only sets last_error instead of also calling push_error.
var quiet: bool = false
## Message of the most recent failure ("" if none happened yet).
var last_error: String = ""

var _loaded: bool = false
var _root: Dictionary = {}
## sheet -> {id -> Rect2}: source rectangle of every cell (aliases included).
var _rects: Dictionary = {}
## sheet -> {id -> Dictionary}: read-only copies of the geometry entries.
var _geometry: Dictionary = {}
## sheet -> {id -> int}: cell number (row * cols + col); an alias has the number of its target cell.
var _cell_index: Dictionary = {}
## sheet -> {cols, rows, cell_w, cell_h, width, height}
var _grids: Dictionary = {}
## atlas name -> file name inside ATLAS_DIR (the 7 sheets, the 5 section atlases, the 2 enemy effects)
var _atlas_files: Dictionary = {}
var _textures: Dictionary = {}


## The shared instance; atlas_layout.json is read the first time it is requested.
static func shared() -> AtlasLayout:
	if _shared == null:
		_shared = AtlasLayout.new()
	return _shared


## quiet_errors is applied before the file is read, so that even a missing layout file can be
## reported without push_error (see `quiet`).
func _init(layout_path: String = LAYOUT_PATH, quiet_errors: bool = false) -> void:
	quiet = quiet_errors
	_loaded = _load(layout_path)
	if not _loaded:
		# A half-read layout must not be served: the instance stays empty, last_error says why.
		_root = {}
		_rects = {}
		_geometry = {}
		_cell_index = {}
		_grids = {}
		_atlas_files = {}


## False if atlas_layout.json could not be read; last_error then says why.
func is_loaded() -> bool:
	return _loaded


## True for the sliced sheets (cell grids with ids).
func has_sheet(sheet: String) -> bool:
	return _rects.has(sheet)


## True for every atlas texture: the sliced sheets, the section atlases and the generated enemy effects.
func has_atlas(atlas: String) -> bool:
	return _atlas_files.has(atlas)


func sheet_names() -> PackedStringArray:
	return PackedStringArray(_rects.keys())


func atlas_names() -> PackedStringArray:
	return PackedStringArray(_atlas_files.keys())


## The ids of a sheet in cell order (without the aliases).
func sheet_ids(sheet: String) -> PackedStringArray:
	if not _check_sheet(sheet):
		return PackedStringArray()
	var ids: Array = (_root["sheets"] as Dictionary)[sheet]["ids"]
	return PackedStringArray(ids)


## True if the id names a cell of the sheet (an alias counts).
func has_cell(sheet: String, id: String) -> bool:
	if not _rects.has(sheet):
		return false
	return (_rects[sheet] as Dictionary).has(id)


## {cols, rows, cell_w, cell_h, width, height} of a sheet; {} if unknown.
func grid(sheet: String) -> Dictionary:
	if not _check_sheet(sheet):
		return {}
	return (_grids[sheet] as Dictionary).duplicate()


## Cell number of an id (row * cols + col); -1 if unknown. The renderer passes it to the shader.
func cell_index(sheet: String, id: String) -> int:
	if not _check_cell(sheet, id):
		return -1
	return (_cell_index[sheet] as Dictionary)[id]


## Source rectangle of a cell in texels, insets applied (Rect2(sx, sy, sourceW, sourceH)).
func cell_rect(sheet: String, id: String) -> Rect2:
	if not _check_cell(sheet, id):
		return Rect2()
	return (_rects[sheet] as Dictionary)[id]


## The game's draw geometry of a cell (8 fields, see the class comment). The returned
## dictionary is shared and read-only.
func geometry(sheet: String, id: String) -> Dictionary:
	if not _check_cell(sheet, id):
		return {}
	return (_geometry[sheet] as Dictionary)[id]


## The imported texture of an atlas: a sliced sheet ("characters") or another atlas name from
## atlas_names() ("signature_fx", "eliteShockwave", ...). null if unknown.
func texture(atlas: String) -> Texture2D:
	if not _atlas_files.has(atlas):
		_fail("unknown atlas '%s'" % atlas)
		return null
	var file: String = _atlas_files[atlas]
	if not _textures.has(file):
		var path: String = ATLAS_DIR.path_join(file)
		var loaded: Texture2D = ResourceLoader.load(path, "Texture2D") as Texture2D
		if loaded == null:
			_fail("cannot load the texture %s of atlas '%s'" % [path, atlas])
			return null
		_textures[file] = loaded
	return _textures[file]


## A deep copy of a layout section for data that needs no helper: "animation", "raster",
## "art_maps", "overhaul_characters", "overhaul_fx", "overhaul_weapon_icons", "signature_fx",
## "range_fx", "generated_enemy_fx", "runtime_derived" (parameters of the images the game builds at
## run time: hit flash, low-resolution cache, range-ring tint). {} if unknown.
func section(name: String) -> Dictionary:
	if name == "sheets" or not _root.has(name) or not (_root[name] is Dictionary):
		_fail("unknown layout section '%s'" % name)
		return {}
	return (_root[name] as Dictionary).duplicate(true)


## True if the meta atlas ("signature_fx" or "overhaul_fx") has a row for the effect. Never reports
## an error, also not for an unknown atlas name: use it before meta_frame_rect() when a miss is
## expected (the game's resolveFxMeta returns nothing for an unknown effect and the caller falls back).
func has_meta_effect(atlas: String, effect_id: String) -> bool:
	if not META_ATLASES.has(atlas) or not _has_section(atlas):
		return false
	return ((_root[atlas] as Dictionary).get("meta", {}) as Dictionary).has(effect_id)


## True if OVERHAUL_CHAR_ATLAS_SOURCE has a cell for the art id and the frame (the game's
## drawOverhaulCharacterFrame returns false otherwise and drawPlayer draws the characters sheet).
## Never reports an error.
func has_overhaul_character(art_id: String, frame_id: String) -> bool:
	if not _has_section("overhaul_characters"):
		return false
	var section_data: Dictionary = _root["overhaul_characters"]
	return (section_data["row_ids"] as Array).has(art_id) and (section_data["frame_ids"] as Array).has(frame_id)


## True if OVERHAUL_ICON_SOURCE has an icon for the weapon id (the game's drawOverhaulWeaponIcon
## returns false otherwise and the weapons sheet is used). Never reports an error.
func has_overhaul_icon(weapon_id: String) -> bool:
	if not _has_section("overhaul_weapon_icons"):
		return false
	return ((_root["overhaul_weapon_icons"] as Dictionary)["icon_index"] as Dictionary).has(weapon_id)


## Source rectangle of one frame of a meta atlas ("signature_fx" or "overhaul_fx"): row = the effect,
## column = the frame. Like the game's drawSignatureFxFrame the frame is floored and clamped to
## 0..frames-1. Rect2() and an error if the atlas or the effect is unknown (ask has_meta_effect() first
## when a miss is expected).
func meta_frame_rect(atlas: String, effect_id: String, frame: int) -> Rect2:
	if not META_ATLASES.has(atlas):
		_fail("'%s' is not a meta atlas (%s)" % [atlas, ", ".join(META_ATLASES)])
		return Rect2()
	if not _check_section(atlas):
		return Rect2()
	var meta: Dictionary = (_root[atlas] as Dictionary)["meta"]
	if not meta.has(effect_id):
		_fail("unknown effect '%s' in %s" % [effect_id, atlas])
		return Rect2()
	var entry: Dictionary = meta[effect_id]
	var frames: int = int(entry["frames"])
	var column: int = clampi(frame, 0, frames - 1)
	var width: float = entry["width"]
	return Rect2(float(entry["x"]) + float(column) * width, entry["y"], width, entry["height"])


## Cell of OVERHAUL_CHAR_ATLAS_SOURCE: row = art id (OVERHAUL_CHAR_ROWS), column = frame
## (CHARACTER_ANIMATION_FRAMES, for example "walk2"). Rect2() and an error if unknown (ask
## has_overhaul_character() first when a miss is expected).
func overhaul_character_rect(art_id: String, frame_id: String) -> Rect2:
	if not _check_section("overhaul_characters"):
		return Rect2()
	var section_data: Dictionary = _root["overhaul_characters"]
	var row: int = (section_data["row_ids"] as Array).find(art_id)
	var column: int = (section_data["frame_ids"] as Array).find(frame_id)
	if row < 0 or column < 0:
		_fail("unknown overhaul character cell '%s' / '%s'" % [art_id, frame_id])
		return Rect2()
	var cell_w: float = section_data["cell_w"]
	var cell_h: float = section_data["cell_h"]
	return Rect2(float(column) * cell_w, float(row) * cell_h, cell_w, cell_h)


## Cell of OVERHAUL_ICON_SOURCE for a weapon id (OVERHAUL_WEAPON_ICON_INDEX). Rect2() and an error if
## unknown (ask has_overhaul_icon() first when a miss is expected).
func overhaul_icon_rect(weapon_id: String) -> Rect2:
	if not _check_section("overhaul_weapon_icons"):
		return Rect2()
	var section_data: Dictionary = _root["overhaul_weapon_icons"]
	var index: Dictionary = section_data["icon_index"]
	if not index.has(weapon_id):
		_fail("unknown overhaul weapon icon '%s'" % weapon_id)
		return Rect2()
	var cell_w: float = section_data["cell_w"]
	return Rect2(float(index[weapon_id]) * cell_w, 0.0, cell_w, section_data["cell_h"])


## Cell of RANGE_FX_SOURCE for a RANGE_FX_STYLE value (0 ARCANE, 1 NATURE, 2 STORM, 3 TELEGRAPH).
## Rect2() if the style does not exist.
func range_fx_rect(style: int) -> Rect2:
	if not _check_section("range_fx"):
		return Rect2()
	var section_data: Dictionary = _root["range_fx"]
	var cells: Array = section_data["style_cells"]
	if style < 0 or style >= cells.size():
		_fail("unknown range fx style %d" % style)
		return Rect2()
	var cell: Dictionary = cells[style]
	var cell_w: float = section_data["cell_w"]
	var cell_h: float = section_data["cell_h"]
	return Rect2(float(cell["col"]) * cell_w, float(cell["row"]) * cell_h, cell_w, cell_h)


func _fail(message: String) -> bool:
	last_error = message
	if not quiet:
		push_error("AtlasLayout: %s" % message)
	return false


## True if the layout loaded and has the section; never reports an error.
func _has_section(section_name: String) -> bool:
	return _loaded and _root.has(section_name) and _root[section_name] is Dictionary


func _check_section(section_name: String) -> bool:
	if _has_section(section_name):
		return true
	return _fail("layout section '%s' is not available (layout loaded: %s)" % [section_name, _loaded])


func _check_sheet(sheet: String) -> bool:
	if _rects.has(sheet):
		return true
	return _fail("unknown sheet '%s' (known: %s)" % [sheet, ", ".join(PackedStringArray(_rects.keys()))])


func _check_cell(sheet: String, id: String) -> bool:
	if not _check_sheet(sheet):
		return false
	if (_rects[sheet] as Dictionary).has(id):
		return true
	return _fail("unknown id '%s' in sheet '%s'" % [id, sheet])


func _load(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return _fail("layout file not found: %s" % path)
	# JSON.parse_string would push an engine error of its own, which `quiet` could not suppress.
	var json: JSON = JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return _fail("layout file is not valid JSON (line %d: %s): %s" % [json.get_error_line(), json.get_error_message(), path])
	var parsed: Variant = json.data
	if not (parsed is Dictionary):
		return _fail("layout file is not a JSON object: %s" % path)
	_root = parsed
	if int(_root.get("format", 0)) != FORMAT_VERSION:
		return _fail("unsupported layout format %s in %s (expected %d)" % [_root.get("format"), path, FORMAT_VERSION])
	for required: String in ["sheets", "animation", "raster", "art_maps", "generated_enemy_fx", "runtime_derived"] + Array(SECTION_ATLASES):
		if not (_root.get(required) is Dictionary):
			return _fail("layout section '%s' is missing in %s" % [required, path])

	var sheets: Dictionary = _root["sheets"]
	for sheet: String in sheets:
		if not _load_sheet(sheet, sheets[sheet]):
			return false
		_atlas_files[sheet] = (sheets[sheet] as Dictionary)["file"]
	for atlas: String in SECTION_ATLASES:
		_atlas_files[atlas] = (_root[atlas] as Dictionary)["file"]
	var generated: Dictionary = _root["generated_enemy_fx"]
	for effect: String in generated:
		_atlas_files[effect] = (generated[effect] as Dictionary)["file"]
	return true


func _load_sheet(sheet: String, data: Dictionary) -> bool:
	for key: String in ["file", "width", "height", "cols", "rows", "cell_w", "cell_h", "ids", "aliases", "geometry"]:
		if not data.has(key):
			return _fail("sheet '%s' has no '%s'" % [sheet, key])
	var cols: int = int(data["cols"])
	var ids: Array = data["ids"]
	var aliases: Dictionary = data["aliases"]
	var geometry_data: Dictionary = data["geometry"]
	var rects: Dictionary = {}
	var geometries: Dictionary = {}
	var indices: Dictionary = {}
	for id: String in geometry_data:
		var source: Dictionary = geometry_data[id]
		for field: String in GEOMETRY_FIELDS:
			if not source.has(field):
				return _fail("sheet '%s' id '%s' has no '%s'" % [sheet, id, field])
		var entry: Dictionary = source.duplicate()
		entry.make_read_only()
		geometries[id] = entry
		rects[id] = Rect2(entry["sx"], entry["sy"], entry["sourceW"], entry["sourceH"])
		var target: String = aliases.get(id, id)
		var position: int = ids.find(target)
		if position < 0:
			return _fail("sheet '%s' id '%s' points to the unknown cell '%s'" % [sheet, id, target])
		indices[id] = position
	for id: Variant in ids:
		if not geometries.has(id):
			return _fail("sheet '%s' has no geometry for id '%s'" % [sheet, id])
	_rects[sheet] = rects
	_geometry[sheet] = geometries
	_cell_index[sheet] = indices
	_grids[sheet] = {
		"cols": cols, "rows": int(data["rows"]), "cell_w": data["cell_w"], "cell_h": data["cell_h"],
		"width": int(data["width"]), "height": int(data["height"]),
	}
	return true
