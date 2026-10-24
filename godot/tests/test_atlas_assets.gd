extends "res://tests/test_case.gd"
## Guards the 14 atlas images and their layout (step S2, design sections 4 and 6.1).
##
## tools/extract_assets.mjs writes res://assets/atlas/*.webp, atlas_manifest.json and atlas_layout.json
## from the original game; tools/check_assets.sh (run by tools/run_godot_tests.sh) checks that the
## committed files still equal a fresh extraction. This file checks what only Godot can: that the
## engine decodes and imports the images exactly, and that AtlasLayout serves the layout correctly.

const ATLAS_DIR: String = "res://assets/atlas"
const MANIFEST_PATH: String = "res://assets/atlas/atlas_manifest.json"
const LAYOUT_PATH: String = "res://assets/atlas/atlas_layout.json"

## manifest key -> [width, height]. Written down here (from the data URIs of original.html), not read
## from the manifest, so the manifest itself is checked as well.
const EXPECTED_IMAGES: Dictionary = {
	"enemy_fx_elite_shockwave": [256, 256],
	"enemy_fx_boss_charge": [384, 192],
	"overhaul_characters": [896, 256],
	"overhaul_fx": [512, 1280],
	"overhaul_weapon_icons": [256, 64],
	"art_hits": [128, 96],
	"art_projectiles": [128, 96],
	"art_characters": [896, 704],
	"art_enemies": [320, 288],
	"art_weapons": [128, 128],
	"art_elements": [160, 64],
	"art_effects": [128, 96],
	"signature_fx": [512, 2944],
	"range_fx": [512, 512],
}

## sheet -> [cols, rows, ids in layout, ids with aliases], from ART_LAYOUTS of the game.
const EXPECTED_SHEETS: Dictionary = {
	"projectiles": [4, 3, 12, 12],
	"hits": [4, 3, 12, 12],
	"characters": [14, 11, 154, 165],
	"enemies": [10, 9, 90, 99],
	"weapons": [4, 4, 14, 14],
	"elements": [5, 2, 10, 10],
	"effects": [4, 3, 12, 12],
}

## Order of the ids that give the cells their numbers: [first id, last id, sha256 of the ids joined by ","].
## Computed from ART_LAYOUTS, OVERHAUL_FX_ROWS and the keys of SIGNATURE_FX_META of original.html (not from
## atlas_layout.json), so a consistently reordered list in the JSON cannot pass.
const EXPECTED_ID_ORDER: Dictionary = {
	"projectiles": ["pulse", "generic_blade", "dad2be1ddcb8bbef82176ff27fe00ad098b96dc3aa5379112ae08211fe612c3f"],
	"hits": ["normal", "wood", "981692163cc2562a0faa1cfebc06be034089822a5bb5ec7cf195654ef2bfc903"],
	"characters": ["catalyst_idle1", "berserker_convergence_ko4", "e7ba170abde964d42cb49fdfff4344b16f289531f1a38044b7e6e1d82326eb8d"],
	"enemies": ["swarm_idle1", "boss_attack4", "5a856fb88c89daf8522912f2c8496368239ea10fbf61db9f222e5390baef2a37"],
	"weapons": ["pulse", "mortar", "d7fd45fa73fbd133b1d9ab816a5c70ec08e7d91600a3fa784f3de33d3efbccbe"],
	"elements": ["fire", "wood", "1030eae28702739eb78036392677011c829571bcc1ae4116ab7d6ea8beb0aef1"],
	"effects": ["explosion", "wood", "0e2457a223375e7cb95ca4f6f249572b7caf0ed05495fa461ffd4d57ba79dd51"],
	"overhaul_fx": ["sentinel_shield_wave", "pathfinder_double_trace", "b8848b9bb5107283b08026183f1d2339f4063c41bc5a203e6d7b3a7cc0be785f"],
	"signature_fx": ["barrier_link", "wood_arrow", "0e2038d0db18e7a8790a0c636c505535ce8bd42b836b2c4f42f9b54646636c06"],
}

## Geometry computed by running the game's own buildAtlasDrawGeometry (the ART_CELL_CACHE loop and the
## function, cut out of original.html) on the real image sizes; see verification/godot/s2/extract.txt.
## [sheet, id, sx, sy, sourceW, sourceH]. Every entry also has dxMul=-0.5, dyMul=-0.5, dwMul=1, dhMul=1
## because CHARACTER_FRAME_SOURCE_INSETS is {} in the game.
const JS_GEOMETRY: Array = [
	["characters", "catalyst_idle1", 0, 0, 64, 64],
	["characters", "berserker_convergence_ko4", 832, 640, 64, 64],
	["characters", "miko_attack2", 448, 512, 64, 64],
	["characters", "archivist", 0, 192, 64, 64],
	["enemies", "boss_attack4", 288, 256, 32, 32],
	["enemies", "boss", 0, 256, 32, 32],
	["enemies", "tank_walk3", 128, 64, 32, 32],
	["weapons", "mortar", 32, 96, 32, 32],
	["elements", "wood", 128, 32, 32, 32],
	["hits", "dark", 32, 64, 32, 32],
	["projectiles", "generic_blade", 96, 64, 32, 32],
	["effects", "explosion", 0, 0, 32, 32],
	["effects", "wood", 96, 64, 32, 32],
]

var _manifest: Dictionary = {}
var _layout: Dictionary = {}


func _read_json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		fail("%s is not a JSON object" % path)
		return {}
	return parsed


func _manifest_images() -> Dictionary:
	if _manifest.is_empty():
		_manifest = _read_json(MANIFEST_PATH)
	return _manifest.get("images", {})


func _layout_json() -> Dictionary:
	if _layout.is_empty():
		_layout = _read_json(LAYOUT_PATH)
	return _layout


func _sha256_hex(data: PackedByteArray) -> String:
	var context: HashingContext = HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(data)
	return context.finish().hex_encode()


func _rgba_bytes(image: Image) -> PackedByteArray:
	var copy: Image = image.duplicate()
	if copy.get_format() != Image.FORMAT_RGBA8:
		copy.convert(Image.FORMAT_RGBA8)
	return copy.get_data()


func test_manifest_lists_the_14_images() -> void:
	var images: Dictionary = _manifest_images()
	assert_eq(images.size(), 14, "image count in the manifest")
	for key: String in EXPECTED_IMAGES:
		assert_true(images.has(key), "manifest has %s" % key)
	for key: String in images:
		assert_true(EXPECTED_IMAGES.has(key), "manifest key %s is expected" % key)


func test_every_manifest_image_loads_as_a_texture_of_the_manifest_size() -> void:
	var images: Dictionary = _manifest_images()
	for key: String in images:
		var entry: Dictionary = images[key]
		var path: String = ATLAS_DIR.path_join(entry["file"])
		assert_true(FileAccess.file_exists(path), "%s exists" % path)
		var texture: Texture2D = ResourceLoader.load(path, "Texture2D") as Texture2D
		assert_true(texture != null, "%s loads as Texture2D" % path)
		if texture == null:
			continue
		assert_eq(texture.get_width(), int(entry["width"]), "%s width" % key)
		assert_eq(texture.get_height(), int(entry["height"]), "%s height" % key)
		var expected: Array = EXPECTED_IMAGES.get(key, [0, 0])
		assert_eq(texture.get_width(), expected[0], "%s width from the original game" % key)
		assert_eq(texture.get_height(), expected[1], "%s height from the original game" % key)


func test_webp_files_are_the_bytes_of_the_data_uris() -> void:
	# The SHA-256 in the manifest was checked against the data URI when the file was written; here
	# the file on disk is hashed again, so a file edited by hand or by a tool is caught.
	var images: Dictionary = _manifest_images()
	for key: String in images:
		var entry: Dictionary = images[key]
		var path: String = ATLAS_DIR.path_join(entry["file"])
		assert_eq(FileAccess.get_sha256(path), String(entry["sha256"]), "%s sha256" % key)
		assert_eq(FileAccess.get_file_as_bytes(path).size(), int(entry["bytes"]), "%s size in bytes" % key)


func test_godot_decodes_the_webp_files_exactly() -> void:
	# rgba_sha256 comes from libwebp (PIL) and was cross-checked against Chromium's canvas decode.
	var images: Dictionary = _manifest_images()
	for key: String in images:
		var entry: Dictionary = images[key]
		var path: String = ATLAS_DIR.path_join(entry["file"])
		var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
		var image: Image = Image.new()
		assert_eq(image.load_webp_from_buffer(bytes), OK, "%s decodes" % key)
		assert_eq(image.get_width(), int(entry["width"]), "%s decoded width" % key)
		assert_eq(_sha256_hex(_rgba_bytes(image)), String(entry["rgba_sha256"]), "%s decoded RGBA8" % key)


func test_imported_textures_keep_every_texel() -> void:
	# With process/fix_alpha_border=true Godot rewrites the RGB of transparent pixels; with the
	# import settings below the texture is texel for texel the decoded WebP.
	var images: Dictionary = _manifest_images()
	for key: String in images:
		var entry: Dictionary = images[key]
		var texture: Texture2D = ResourceLoader.load(ATLAS_DIR.path_join(entry["file"]), "Texture2D") as Texture2D
		if texture == null:
			fail("%s did not load" % key)
			continue
		var image: Image = texture.get_image()
		assert_true(image != null, "%s has image data" % key)
		if image == null:
			continue
		assert_eq(_sha256_hex(_rgba_bytes(image)), String(entry["rgba_sha256"]), "%s imported texels" % key)


func test_import_settings_are_pixel_art_lossless() -> void:
	var images: Dictionary = _manifest_images()
	for key: String in images:
		var entry: Dictionary = images[key]
		var import_path: String = ATLAS_DIR.path_join(entry["file"]) + ".import"
		var config: ConfigFile = ConfigFile.new()
		assert_eq(config.load(import_path), OK, "%s loads" % import_path)
		assert_eq(config.get_value("remap", "importer"), "texture", "%s importer" % key)
		assert_eq(config.get_value("remap", "type"), "CompressedTexture2D", "%s type" % key)
		var metadata: Dictionary = config.get_value("remap", "metadata", {})
		assert_eq(metadata.get("vram_texture"), false, "%s is not VRAM compressed" % key)
		assert_eq(config.get_value("params", "compress/mode"), 0, "%s lossless" % key)
		assert_eq(config.get_value("params", "mipmaps/generate"), false, "%s has no mipmaps" % key)
		assert_eq(config.get_value("params", "process/fix_alpha_border"), false, "%s keeps the RGB of transparent texels" % key)
		assert_eq(config.get_value("params", "process/premult_alpha"), false, "%s keeps straight alpha" % key)
		assert_eq(config.get_value("params", "process/size_limit"), 0, "%s has no size limit" % key)
		assert_eq(config.get_value("params", "detect_3d/compress_to"), 0, "%s is not recompressed when used in 3D" % key)
	# Nearest filtering is the project default (checked in test_project_settings as well).
	assert_eq(ProjectSettings.get_setting("rendering/textures/canvas_textures/default_texture_filter"), 0)


func test_layout_sheets_reference_manifest_images() -> void:
	var images: Dictionary = _manifest_images()
	var sheets: Dictionary = _layout_json().get("sheets", {})
	assert_eq(sheets.size(), EXPECTED_SHEETS.size(), "sheet count")
	for sheet: String in sheets:
		var data: Dictionary = sheets[sheet]
		assert_true(EXPECTED_SHEETS.has(sheet), "sheet %s is expected" % sheet)
		assert_true(images.has(data["image"]), "%s: image %s is in the manifest" % [sheet, data["image"]])
		var entry: Dictionary = images.get(data["image"], {})
		assert_eq(data["file"], entry.get("file"), "%s file" % sheet)
		assert_true(FileAccess.file_exists(ATLAS_DIR.path_join(data["file"])), "%s image file exists" % sheet)
		assert_eq(data["width"], entry.get("width"), "%s width" % sheet)
		assert_eq(data["height"], entry.get("height"), "%s height" % sheet)
		# The cells tile the image exactly.
		assert_eq(float(data["cols"]) * float(data["cell_w"]), float(data["width"]), "%s columns cover the width" % sheet)
		assert_eq(float(data["rows"]) * float(data["cell_h"]), float(data["height"]), "%s rows cover the height" % sheet)
	# Every other atlas section points at a manifest image of the same size, too.
	var layout: Dictionary = _layout_json()
	for name: String in AtlasLayout.SECTION_ATLASES:
		var section_data: Dictionary = layout[name]
		var entry: Dictionary = images.get(section_data["image"], {})
		assert_true(not entry.is_empty(), "%s image %s is in the manifest" % [name, section_data["image"]])
		assert_eq(section_data["file"], entry.get("file"), "%s file" % name)
		assert_eq(section_data["width"], entry.get("width"), "%s width" % name)
		assert_eq(section_data["height"], entry.get("height"), "%s height" % name)
		assert_eq(float(section_data["cols"]) * float(section_data["cell_w"]), float(section_data["width"]), "%s columns" % name)
		assert_eq(float(section_data["rows"]) * float(section_data["cell_h"]), float(section_data["height"]), "%s rows" % name)
	var generated: Dictionary = layout["generated_enemy_fx"]
	for effect: String in generated:
		var entry: Dictionary = images.get(generated[effect]["image"], {})
		assert_true(not entry.is_empty(), "%s image is in the manifest" % effect)
		assert_eq(generated[effect]["width"], entry.get("width"), "%s width" % effect)
		assert_eq(generated[effect]["height"], entry.get("height"), "%s height" % effect)


func test_ids_are_unique_and_fit_the_grid() -> void:
	var sheets: Dictionary = _layout_json().get("sheets", {})
	for sheet: String in sheets:
		var data: Dictionary = sheets[sheet]
		var expected: Array = EXPECTED_SHEETS.get(sheet, [0, 0, -1, -1])
		var ids: Array = data["ids"]
		var seen: Dictionary = {}
		for id: String in ids:
			assert_false(seen.has(id), "%s: id %s is unique" % [sheet, id])
			seen[id] = true
		assert_true(ids.size() <= int(data["cols"]) * int(data["rows"]), "%s: %d ids fit %dx%d cells" % [sheet, ids.size(), data["cols"], data["rows"]])
		assert_eq(int(data["cols"]), expected[0], "%s columns" % sheet)
		assert_eq(int(data["rows"]), expected[1], "%s rows" % sheet)
		assert_eq(ids.size(), expected[2], "%s id count" % sheet)
		var aliases: Dictionary = data["aliases"]
		for alias: String in aliases:
			assert_false(seen.has(alias), "%s: alias %s is not also a cell id" % [sheet, alias])
			assert_true(seen.has(aliases[alias]), "%s: alias %s points to an existing id" % [sheet, alias])
		assert_eq((data["geometry"] as Dictionary).size(), expected[3], "%s geometry entries (ids + aliases)" % sheet)
	# Cell numbers follow ART_CELL_CACHE: ids in order, row-major.
	var characters: Dictionary = sheets["characters"]
	assert_eq((characters["ids"] as Array)[0], "catalyst_idle1")
	assert_eq((characters["ids"] as Array)[14], "arcanist_idle1")
	assert_eq((characters["ids"] as Array)[153], "berserker_convergence_ko4")


func _ids_sha256(ids: Array) -> String:
	return _sha256_hex(",".join(PackedStringArray(ids)).to_utf8_buffer())


func test_id_order_matches_the_game() -> void:
	# The cell number of an id is its position in the list, so a reordered list moves sprites even when
	# every other test of the JSON still agrees with itself. The pins come from the original game.
	var atlas: AtlasLayout = AtlasLayout.new()
	var lists: Dictionary = {}
	for sheet: String in EXPECTED_SHEETS:
		lists[sheet] = Array(atlas.sheet_ids(sheet))
	lists["overhaul_fx"] = atlas.section("overhaul_fx")["row_ids"]
	lists["signature_fx"] = atlas.section("signature_fx")["meta"].keys()
	assert_eq(lists.size(), EXPECTED_ID_ORDER.size(), "every pinned list is checked")
	for name: String in EXPECTED_ID_ORDER:
		var want: Array = EXPECTED_ID_ORDER[name]
		var ids: Array = lists.get(name, [])
		assert_true(not ids.is_empty(), "%s ids exist" % name)
		if ids.is_empty():
			continue
		assert_eq(ids[0], want[0], "%s first id" % name)
		assert_eq(ids[ids.size() - 1], want[1], "%s last id" % name)
		assert_eq(_ids_sha256(ids), want[2], "%s id order (sha256 of the ids joined by commas)" % name)


func test_geometry_equals_the_json_and_lies_inside_the_texture() -> void:
	var atlas: AtlasLayout = AtlasLayout.new()
	assert_true(atlas.is_loaded(), "layout loads: %s" % atlas.last_error)
	var sheets: Dictionary = _layout_json().get("sheets", {})
	for sheet: String in sheets:
		assert_true(atlas.has_sheet(sheet), "AtlasLayout knows %s" % sheet)
		var data: Dictionary = sheets[sheet]
		var geometry_data: Dictionary = data["geometry"]
		var texture: Texture2D = atlas.texture(sheet)
		assert_true(texture != null, "%s texture" % sheet)
		if texture == null:
			continue
		var bounds: Rect2 = Rect2(0.0, 0.0, texture.get_width(), texture.get_height())
		for id: String in geometry_data:
			var want: Dictionary = geometry_data[id]
			var got: Dictionary = atlas.geometry(sheet, id)
			assert_eq(got.size(), 8, "%s/%s has 8 geometry fields" % [sheet, id])
			var exact: bool = true
			for field: String in AtlasLayout.GEOMETRY_FIELDS:
				# Exact comparison of the doubles (no tolerance); a miss is reported once per cell.
				if not got.has(field) or typeof(got[field]) != TYPE_FLOAT or got[field] != want[field]:
					exact = false
			assert_true(exact, "%s/%s geometry equals the JSON: %s vs %s" % [sheet, id, got, want])
			var rect: Rect2 = atlas.cell_rect(sheet, id)
			assert_eq(rect, Rect2(want["sx"], want["sy"], want["sourceW"], want["sourceH"]), "%s/%s cell_rect" % [sheet, id])
			assert_true(bounds.encloses(rect), "%s/%s %s lies inside the %s texture" % [sheet, id, rect, bounds])
			assert_true(rect.size.x > 0.0 and rect.size.y > 0.0, "%s/%s has an area" % [sheet, id])


func test_geometry_follows_buildAtlasDrawGeometry() -> void:
	# The formula of the game, evaluated here from cols/rows/ids and the real texture size
	# (CHARACTER_FRAME_SOURCE_INSETS is empty, so no insets): sw = W / cols, sh = H / rows (float
	# division), sx = col * sw, sy = row * sh, dxMul = -0.5, dwMul = sourceW / sw.
	var atlas: AtlasLayout = AtlasLayout.new()
	assert_eq((atlas.section("animation")["CHARACTER_FRAME_SOURCE_INSETS"] as Dictionary).size(), 0, "no frame insets in the original")
	for sheet: String in EXPECTED_SHEETS:
		var texture: Texture2D = atlas.texture(sheet)
		if texture == null:
			fail("%s has no texture" % sheet)
			continue
		var grid: Dictionary = atlas.grid(sheet)
		var cols: int = grid["cols"]
		var rows: int = grid["rows"]
		var sw: float = float(texture.get_width()) / float(cols)
		var sh: float = float(texture.get_height()) / float(rows)
		assert_eq(grid["cell_w"], sw, "%s cell_w" % sheet)
		assert_eq(grid["cell_h"], sh, "%s cell_h" % sheet)
		var ids: PackedStringArray = atlas.sheet_ids(sheet)
		for index: int in ids.size():
			var id: String = ids[index]
			var want: Dictionary = {
				"sx": float(index % cols) * sw, "sy": floorf(float(index) / float(cols)) * sh,
				"sourceW": sw, "sourceH": sh, "dxMul": -0.5, "dyMul": -0.5, "dwMul": 1.0, "dhMul": 1.0,
			}
			assert_eq(atlas.geometry(sheet, id), want, "%s/%s geometry from the formula" % [sheet, id])
			assert_eq(atlas.cell_index(sheet, id), index, "%s/%s cell number" % [sheet, id])


func test_geometry_spot_checks_from_the_game_function() -> void:
	var atlas: AtlasLayout = AtlasLayout.new()
	assert_true(JS_GEOMETRY.size() >= 5, "at least 5 spot checks")
	for row: Array in JS_GEOMETRY:
		var sheet: String = row[0]
		var id: String = row[1]
		var want: Dictionary = {
			"sx": float(row[2]), "sy": float(row[3]), "sourceW": float(row[4]), "sourceH": float(row[5]),
			"dxMul": -0.5, "dyMul": -0.5, "dwMul": 1.0, "dhMul": 1.0,
		}
		assert_eq(atlas.geometry(sheet, id), want, "%s/%s geometry" % [sheet, id])
		assert_eq(atlas.cell_rect(sheet, id), Rect2(float(row[2]), float(row[3]), float(row[4]), float(row[5])), "%s/%s rect" % [sheet, id])


func test_art_ids_are_aliases_of_the_idle1_cell() -> void:
	var atlas: AtlasLayout = AtlasLayout.new()
	var animation: Dictionary = atlas.section("animation")
	for art_id: String in animation["CHARACTER_ART_IDS"]:
		assert_eq(atlas.geometry("characters", art_id), atlas.geometry("characters", art_id + "_idle1"), "characters/%s = idle1" % art_id)
		assert_eq(atlas.cell_index("characters", art_id), atlas.cell_index("characters", art_id + "_idle1"), "characters/%s cell number" % art_id)
	for art_id: String in animation["ENEMY_ART_IDS"]:
		assert_eq(atlas.geometry("enemies", art_id), atlas.geometry("enemies", art_id + "_idle1"), "enemies/%s = idle1" % art_id)
	assert_eq((animation["CHARACTER_ART_IDS"] as Array).size(), 11)
	assert_eq((animation["ENEMY_ART_IDS"] as Array).size(), 9)
	assert_eq(animation["MIKO_ATLAS_ROW"], 8.0)
	assert_eq(animation["CHARACTER_ATLAS_CELL_SIZE"], 64.0)
	# The sheets carry no cell for the idle frames of other sheets' ids.
	assert_false(atlas.has_cell("weapons", "catalyst"))


func test_unknown_lookups_return_empty_values_without_crashing() -> void:
	var atlas: AtlasLayout = AtlasLayout.new()
	atlas.quiet = true # lookup failures are push_error in production; the test runner counts those as failures
	assert_false(atlas.has_sheet("no_such_sheet"))
	assert_false(atlas.has_cell("characters", "no_such_id"))
	assert_false(atlas.has_cell("no_such_sheet", "pulse"))
	assert_eq(atlas.cell_rect("no_such_sheet", "pulse"), Rect2())
	assert_true(atlas.last_error.contains("unknown sheet 'no_such_sheet'"), atlas.last_error)
	assert_eq(atlas.cell_rect("hits", "no_such_id"), Rect2())
	assert_true(atlas.last_error.contains("unknown id 'no_such_id' in sheet 'hits'"), atlas.last_error)
	assert_eq(atlas.geometry("hits", "no_such_id"), {})
	assert_eq(atlas.geometry("no_such_sheet", "x"), {})
	assert_eq(atlas.cell_index("hits", "no_such_id"), -1)
	assert_eq(atlas.grid("no_such_sheet"), {})
	assert_eq(atlas.sheet_ids("no_such_sheet"), PackedStringArray())
	assert_true(atlas.texture("no_such_sheet") == null)
	assert_true(atlas.last_error.contains("unknown atlas"), atlas.last_error)
	assert_eq(atlas.section("no_such_section"), {})
	assert_eq(atlas.section("sheets"), {}, "'sheets' is reached through geometry() and cell_rect()")
	assert_eq(atlas.meta_frame_rect("hits", "x", 0), Rect2())
	assert_eq(atlas.meta_frame_rect("signature_fx", "no_such_effect", 0), Rect2())
	assert_eq(atlas.overhaul_character_rect("miko", "idle1"), Rect2())
	assert_eq(atlas.overhaul_character_rect("sentinel", "dance1"), Rect2())
	assert_eq(atlas.overhaul_icon_rect("pulse"), Rect2())
	assert_eq(atlas.range_fx_rect(4), Rect2())
	assert_eq(atlas.range_fx_rect(-1), Rect2())
	assert_eq(atlas.meta_frame_rect("overhaul_fx", "catalyst_charge", 0), Rect2())
	assert_true(atlas.last_error.contains("unknown effect 'catalyst_charge' in overhaul_fx"), atlas.last_error)
	assert_eq(atlas.overhaul_character_rect("catalyst", "idle1"), Rect2())
	assert_true(atlas.last_error.contains("unknown overhaul character cell 'catalyst' / 'idle1'"), atlas.last_error)
	assert_eq(atlas.overhaul_icon_rect("pulse"), Rect2())
	assert_true(atlas.last_error.contains("unknown overhaul weapon icon 'pulse'"), atlas.last_error)
	# A missing layout file yields an unusable but harmless instance.
	var broken: AtlasLayout = AtlasLayout.new("res://assets/atlas/does_not_exist.json", true)
	assert_false(broken.is_loaded())
	assert_true(broken.last_error.contains("not found"), broken.last_error)
	assert_false(broken.has_sheet("characters"))
	assert_eq(broken.sheet_names().size(), 0)
	_assert_unusable_instance(broken, "missing file")


## Every lookup of an instance whose layout did not load returns an empty value and goes through
## the quiet/last_error path, without a script error (the runner fails a test on any engine error).
func _assert_unusable_instance(broken: AtlasLayout, label: String) -> void:
	assert_false(broken.is_loaded(), "%s: not loaded" % label)
	assert_true(not broken.last_error.is_empty(), "%s: last_error says why" % label)
	assert_eq(broken.cell_rect("characters", "catalyst_idle1"), Rect2(), "%s: cell_rect" % label)
	assert_eq(broken.geometry("characters", "catalyst_idle1"), {}, "%s: geometry" % label)
	assert_true(broken.texture("characters") == null, "%s: texture" % label)
	assert_eq(broken.section("animation"), {}, "%s: section" % label)
	assert_false(broken.has_overhaul_character("sentinel", "idle1"), "%s: has_overhaul_character" % label)
	assert_false(broken.has_overhaul_icon("fortress_shield"), "%s: has_overhaul_icon" % label)
	assert_false(broken.has_meta_effect("signature_fx", "barrier_link"), "%s: has_meta_effect" % label)
	assert_eq(broken.meta_frame_rect("signature_fx", "barrier_link", 0), Rect2(), "%s: meta_frame_rect" % label)
	assert_true(broken.last_error.contains("'signature_fx' is not available"), broken.last_error)
	assert_eq(broken.meta_frame_rect("overhaul_fx", "sentinel_shield_wave", 0), Rect2(), "%s: meta_frame_rect overhaul" % label)
	assert_eq(broken.overhaul_character_rect("sentinel", "idle1"), Rect2(), "%s: overhaul_character_rect" % label)
	assert_true(broken.last_error.contains("'overhaul_characters' is not available"), broken.last_error)
	assert_eq(broken.overhaul_icon_rect("fortress_shield"), Rect2(), "%s: overhaul_icon_rect" % label)
	assert_true(broken.last_error.contains("'overhaul_weapon_icons' is not available"), broken.last_error)
	assert_eq(broken.range_fx_rect(0), Rect2(), "%s: range_fx_rect" % label)
	assert_true(broken.last_error.contains("'range_fx' is not available"), broken.last_error)


func test_unusable_layout_files_fail_quietly_for_every_helper() -> void:
	var good: Dictionary = _read_json(LAYOUT_PATH)
	var without_section: Dictionary = good.duplicate(true)
	without_section.erase("range_fx")
	var wrong_format: Dictionary = good.duplicate(true)
	wrong_format["format"] = 2
	var cases: Dictionary = {
		"invalid JSON": "{ this is not json",
		"not an object": "[1, 2, 3]",
		"missing section": JSON.stringify(without_section),
		"unsupported format": JSON.stringify(wrong_format),
	}
	var path: String = "user://s2_unusable_layout.json"
	for label: String in cases:
		var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		assert_true(file != null, "%s: temporary layout file can be written" % label)
		if file == null:
			continue
		file.store_string(cases[label])
		file.close()
		_assert_unusable_instance(AtlasLayout.new(path, true), label)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_expected_misses_in_overhaul_and_meta_atlases_are_not_errors() -> void:
	# The game's drawOverhaulCharacterFrame, drawOverhaulWeaponIcon and resolveFxMeta return false for
	# an id that the overhaul atlases do not hold (catalyst, pulse ...); the caller then falls back. The
	# predicates must not report that: this instance is NOT quiet, so a push_error would fail the test run.
	var atlas: AtlasLayout = AtlasLayout.new()
	assert_false(atlas.quiet)
	assert_false(atlas.has_overhaul_character("catalyst", "idle1"), "catalyst is not in OVERHAUL_CHAR_ROWS")
	assert_false(atlas.has_overhaul_character("sentinel", "dance1"), "unknown frame")
	assert_false(atlas.has_overhaul_character("", ""))
	assert_true(atlas.has_overhaul_character("sentinel", "idle1"))
	assert_true(atlas.has_overhaul_character("pathfinder", "ko4"))
	assert_false(atlas.has_overhaul_icon("pulse"), "pulse has no overhaul icon")
	assert_false(atlas.has_overhaul_icon("catalytic_ring"))
	assert_false(atlas.has_overhaul_icon("blades"))
	assert_false(atlas.has_overhaul_icon("wand"))
	assert_true(atlas.has_overhaul_icon("fortress_shield"))
	assert_true(atlas.has_overhaul_icon("survey_piercer"))
	assert_false(atlas.has_meta_effect("overhaul_fx", "catalyst_charge"), "catalyst_charge is not in OVERHAUL_FX_META")
	assert_true(atlas.has_meta_effect("overhaul_fx", "sentinel_shield_wave"))
	assert_true(atlas.has_meta_effect("signature_fx", "barrier_link"))
	assert_false(atlas.has_meta_effect("signature_fx", "sentinel_shield_wave"))
	assert_false(atlas.has_meta_effect("hits", "normal"), "not a meta atlas")
	assert_false(atlas.has_meta_effect("no_such_atlas", "x"))
	assert_eq(atlas.last_error, "", "none of the predicates recorded a failure")
	# Each predicate agrees with the strict helper: a rectangle exactly when the predicate is true.
	var rect_checks: Array = [
		[atlas.has_overhaul_character("sentinel", "idle1"), atlas.overhaul_character_rect("sentinel", "idle1")],
		[atlas.has_overhaul_icon("fortress_shield"), atlas.overhaul_icon_rect("fortress_shield")],
		[atlas.has_meta_effect("signature_fx", "barrier_link"), atlas.meta_frame_rect("signature_fx", "barrier_link", 0)],
	]
	for check: Array in rect_checks:
		assert_true(check[0] and (check[1] as Rect2).has_area(), "a true predicate comes with a real rectangle")
	assert_eq(atlas.last_error, "")


func test_geometry_is_read_only() -> void:
	var atlas: AtlasLayout = AtlasLayout.new()
	assert_true(atlas.geometry("hits", "normal").is_read_only(), "shared geometry entries cannot be changed by a caller")


func test_every_atlas_has_a_texture_through_atlas_layout() -> void:
	var atlas: AtlasLayout = AtlasLayout.new()
	var names: PackedStringArray = atlas.atlas_names()
	assert_eq(names.size(), 14, "14 atlases: %s" % [names])
	for name: String in names:
		assert_true(atlas.texture(name) != null, "%s has a texture" % name)
	assert_eq(atlas.texture("characters"), atlas.texture("characters"), "textures are loaded once")
	assert_eq(atlas.texture("eliteShockwave").get_width(), 256)
	assert_eq(atlas.texture("bossCharge").get_width(), 384)
	assert_eq(atlas.texture("signature_fx").get_height(), 2944)
	assert_eq(atlas.texture("range_fx").get_width(), 512)
	assert_eq(atlas.texture("characters").get_size(), Vector2(896.0, 704.0))


func test_shared_instance_is_created_once() -> void:
	var first: AtlasLayout = AtlasLayout.shared()
	assert_true(first.is_loaded(), first.last_error)
	assert_true(first == AtlasLayout.shared(), "shared() returns the same instance")
	assert_eq(first.sheet_names().size(), 7)


func test_overhaul_character_icon_and_range_cells() -> void:
	var atlas: AtlasLayout = AtlasLayout.new()
	# OVERHAUL_CHAR_ATLAS_SOURCE: 14 columns (frames) x 4 rows (sentinel, striker, harmonizer, pathfinder).
	assert_eq(atlas.overhaul_character_rect("sentinel", "idle1"), Rect2(0.0, 0.0, 64.0, 64.0))
	assert_eq(atlas.overhaul_character_rect("striker", "walk2"), Rect2(192.0, 64.0, 64.0, 64.0))
	assert_eq(atlas.overhaul_character_rect("pathfinder", "ko4"), Rect2(832.0, 192.0, 64.0, 64.0))
	# OVERHAUL_ICON_SOURCE: 4 icons in one row.
	assert_eq(atlas.overhaul_icon_rect("fortress_shield"), Rect2(0.0, 0.0, 64.0, 64.0))
	assert_eq(atlas.overhaul_icon_rect("survey_piercer"), Rect2(192.0, 0.0, 64.0, 64.0))
	# RANGE_FX_SOURCE: 2x2 cells of 256, RANGE_FX_STYLE_CELLS order.
	assert_eq(atlas.range_fx_rect(0), Rect2(0.0, 0.0, 256.0, 256.0))
	assert_eq(atlas.range_fx_rect(1), Rect2(256.0, 0.0, 256.0, 256.0))
	assert_eq(atlas.range_fx_rect(3), Rect2(256.0, 256.0, 256.0, 256.0))
	var range_fx: Dictionary = atlas.section("range_fx")
	assert_eq(range_fx["style"], {"ARCANE": 0.0, "NATURE": 1.0, "STORM": 2.0, "TELEGRAPH": 3.0})
	assert_eq(range_fx["style_cells"][0]["outerRatio"], 0.455)
	assert_eq(range_fx["style_cells"][3]["outerRatio"], 0.43)


func test_meta_atlas_frames() -> void:
	var atlas: AtlasLayout = AtlasLayout.new()
	var signature: Dictionary = atlas.section("signature_fx")
	var meta: Dictionary = signature["meta"]
	assert_eq(meta.size(), 46, "SIGNATURE_FX_META has 46 effects")
	var by_frames: Dictionary = {}
	for effect_id: String in meta:
		var frames: float = meta[effect_id]["frames"]
		by_frames[frames] = int(by_frames.get(frames, 0)) + 1
		assert_eq(meta[effect_id]["effectId"], effect_id)
	assert_eq(by_frames, {4.0: 7, 6.0: 28, 8.0: 11}, "frame counts of the effects")
	assert_eq(signature["max_active"], 180.0)
	# Row i of the sheet is the i-th key (alphabetical); the frame is clamped like drawSignatureFxFrame.
	assert_eq(atlas.meta_frame_rect("signature_fx", "barrier_link", 0), Rect2(0.0, 0.0, 64.0, 64.0))
	assert_eq(atlas.meta_frame_rect("signature_fx", "record_mark_loop", 3), Rect2(192.0, 2112.0, 64.0, 64.0))
	assert_eq(atlas.meta_frame_rect("signature_fx", "record_mark_loop", 99), Rect2(320.0, 2112.0, 64.0, 64.0), "clamped to the last of 6 frames")
	assert_eq(atlas.meta_frame_rect("signature_fx", "wood_arrow", -5), Rect2(0.0, 2880.0, 64.0, 64.0), "clamped to the first frame")
	assert_eq(atlas.meta_frame_rect("signature_fx", "wood_arrow", 9), Rect2(192.0, 2880.0, 64.0, 64.0), "clamped to the last of 4 frames")
	# OVERHAUL_FX_META keeps the source order (not alphabetical): 20 rows of 8 frames.
	var overhaul: Dictionary = atlas.section("overhaul_fx")
	assert_eq(overhaul["row_ids"][0], "sentinel_shield_wave")
	assert_eq(overhaul["row_ids"][19], "pathfinder_double_trace")
	assert_eq(atlas.meta_frame_rect("overhaul_fx", "sentinel_shield_wave", 7), Rect2(448.0, 0.0, 64.0, 64.0))
	assert_eq(atlas.meta_frame_rect("overhaul_fx", "pathfinder_double_trace", 2), Rect2(128.0, 1216.0, 64.0, 64.0))
	assert_eq(overhaul["content_ratio"], 64.0 / 52.0, "OVERHAUL_FX_CONTENT_RATIO")
	# The meta rectangles of both atlases lie inside their images, and the rows are stacked in key order
	# (the invariant tools/extract_assets.mjs checks in expectStackedMeta): x = 0, y = row * 64, 64 x 64.
	assert_eq(overhaul["row_ids"], overhaul["meta"].keys(), "OVERHAUL_FX_ROWS are the keys of OVERHAUL_FX_META")
	for name: String in AtlasLayout.META_ATLASES:
		var texture: Texture2D = atlas.texture(name)
		var bounds: Rect2 = Rect2(0.0, 0.0, texture.get_width(), texture.get_height())
		var section_meta: Dictionary = atlas.section(name)["meta"]
		var row_index: int = 0
		for effect_id: String in section_meta:
			var entry: Dictionary = section_meta[effect_id]
			assert_eq(entry["x"], 0.0, "%s/%s x" % [name, effect_id])
			assert_eq(entry["y"], float(row_index * 64), "%s/%s y is row %d * 64" % [name, effect_id, row_index])
			assert_eq(entry["width"], 64.0, "%s/%s width" % [name, effect_id])
			assert_eq(entry["height"], 64.0, "%s/%s height" % [name, effect_id])
			assert_eq(atlas.meta_frame_rect(name, effect_id, 0).position, Vector2(0.0, float(row_index * 64)), "%s/%s first frame" % [name, effect_id])
			row_index += 1
			var frames: int = int(section_meta[effect_id]["frames"])
			assert_true(bounds.encloses(atlas.meta_frame_rect(name, effect_id, 0)), "%s/%s first frame inside" % [name, effect_id])
			assert_true(bounds.encloses(atlas.meta_frame_rect(name, effect_id, frames - 1)), "%s/%s last frame inside" % [name, effect_id])


func test_pointer_dependent_constants_hold_both_modes() -> void:
	# IS_COARSE_POINTER is true on Android. Values from the declarations in original.html
	# (the first seven were also read in Chromium, see the S2 analysis).
	var raster: Dictionary = AtlasLayout.new().section("raster")
	assert_eq(raster["coarse"], {
		"FX_RASTER_RES": 18.0, "REACTION_FX_RASTER_RES": 12.0, "FX_GEOMETRY_GRID": 2.0,
		"REACTION_FX_GEOMETRY_GRID": 5.0, "RANGE_FX_CACHE_RESOLUTION": 96.0, "BASE_MAX_PIXEL_FX": 72.0,
		"BASE_RANGE_AURA_GLYPHS": 2.0, "BASE_TRANSIENT_RANGE_FX_DRAW_BUDGET": 10.0,
	})
	assert_eq(raster["fine"], {
		"FX_RASTER_RES": 22.0, "REACTION_FX_RASTER_RES": 16.0, "FX_GEOMETRY_GRID": 1.0,
		"REACTION_FX_GEOMETRY_GRID": 4.0, "RANGE_FX_CACHE_RESOLUTION": 128.0, "BASE_MAX_PIXEL_FX": 128.0,
		"BASE_RANGE_AURA_GLYPHS": 4.0, "BASE_TRANSIENT_RANGE_FX_DRAW_BUDGET": 22.0,
	})


func test_art_maps_and_generated_fx() -> void:
	var atlas: AtlasLayout = AtlasLayout.new()
	var maps: Dictionary = atlas.section("art_maps")
	# Every sprite name used by the maps is a cell of the sheet it is drawn from.
	for weapon: String in maps["PROJECTILE_ART_BY_WEAPON"]:
		assert_true(atlas.has_cell("projectiles", maps["PROJECTILE_ART_BY_WEAPON"][weapon]), "projectile art of %s" % weapon)
	for shape: String in maps["PROJECTILE_ART_BY_SHAPE"]:
		assert_true(atlas.has_cell("projectiles", maps["PROJECTILE_ART_BY_SHAPE"][shape]), "projectile art of shape %s" % shape)
	for hazard: String in maps["HAZARD_OVERLAY_ART"]:
		assert_true(atlas.has_cell("effects", maps["HAZARD_OVERLAY_ART"][hazard]), "hazard overlay of %s" % hazard)
	assert_eq(maps["SPINNING_HAZARD_TYPES"], ["cyclone", "wildfirewhirl", "blackfire"])
	var generated: Dictionary = atlas.section("generated_enemy_fx")
	assert_eq(generated["eliteShockwave"]["width"], 256.0)
	assert_eq(generated["bossCharge"]["height"], 192.0)
	var signature_icons: Dictionary = atlas.section("signature_fx")["weapon_icon"]
	var signature_meta: Dictionary = atlas.section("signature_fx")["meta"]
	for weapon: String in signature_icons:
		assert_true(signature_meta.has(signature_icons[weapon]), "signature icon of %s" % weapon)


func test_runtime_derived_image_parameters() -> void:
	# The game builds these images with canvases; step S7 rebuilds them in shaders from these numbers.
	var derived: Dictionary = AtlasLayout.new().section("runtime_derived")
	var flash: Dictionary = derived["enemy_hit_flash"]
	assert_eq(flash["alpha_base"], 0.32)
	assert_eq(flash["alpha_per_strength"], 0.46)
	assert_eq(flash["base_alpha"], 1.0, "enemies are drawn without opts.alpha")
	assert_eq(flash["flash_decay_per_second"], 5.0)
	# The pass exists only while flash > 0; the handoff text must say so (k is 0, not 0.32, at rest).
	assert_true(String(flash["applies_when"]).begins_with("flash > 0 only"), flash["applies_when"])
	assert_true(String(flash["draw"]).contains("only while flash > 0"), flash["draw"])
	assert_true(String(flash["shader_equivalent"]).contains("if flash == 0: rgb unchanged (k = 0, NOT 0.32)"), flash["shader_equivalent"])
	var lowres: Dictionary = derived["lowres_effect_cache"]
	assert_eq(lowres["min_resolution"], 6.0)
	assert_eq(lowres["default_resolution"], 16.0)
	assert_eq(lowres["resolution_in_drawSpriteFx"]["ultra_quality"], 64.0)
	assert_eq(lowres["resolution_in_drawSpriteFx"]["hits_sheet"], 32.0)
	# visualFxGrid is 1 at ultra quality and for an effect with neither flag; positions are snapped to it.
	assert_true(String(lowres["draw_size_in_drawSpriteFx"]).contains("1 at ultra quality"), lowres["draw_size_in_drawSpriteFx"])
	assert_true(String(lowres["draw_size_in_drawSpriteFx"]).contains("fx.reactionFx"), lowres["draw_size_in_drawSpriteFx"])
	assert_true(String(lowres["draw_size_in_drawSpriteFx"]).contains("fx.fxLowRes"), lowres["draw_size_in_drawSpriteFx"])
	assert_true(String(lowres["position_snap_in_drawSpriteFx"]).contains("round(v / grid) * grid"), lowres["position_snap_in_drawSpriteFx"])
	# The nearest-sampling index formula is a Chromium measurement with a limited scope.
	assert_true(String(lowres["measured_index_formula_scope"]).contains("NOT a general rule"), lowres["measured_index_formula_scope"])
	var raster: Dictionary = AtlasLayout.new().section("raster")
	for mode: String in raster:
		# Both range cache resolutions of the game lie inside the verified scope (256 px cells at 32/64/96/128).
		assert_true([32.0, 64.0, 96.0, 128.0].has(raster[mode]["RANGE_FX_CACHE_RESOLUTION"]), "%s range cache resolution is verified" % mode)
		# The effect rasters are inside 6..72 (32 px and 64 px cells).
		for key: String in ["FX_RASTER_RES", "REACTION_FX_RASTER_RES"]:
			assert_true(raster[mode][key] >= 6.0 and raster[mode][key] <= 72.0, "%s %s is inside the verified 6..72" % [mode, key])
	var tint: Dictionary = derived["range_fx_tint"]
	assert_eq(tint["ring_outer_radius"], 0.492)
	assert_eq(tint["ring_inner_radius"], 0.185)
	assert_eq(tint["alpha_cut"], 26.0)
	assert_eq(tint["alpha_step"], 32.0)
	assert_eq(tint["cache_entries"], 36.0)
