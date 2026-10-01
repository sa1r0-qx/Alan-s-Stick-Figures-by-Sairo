# Scripts/BlockManager.gd
class_name BlockManager
extends Node2D

signal block_placed(grid_pos: Vector2i, block_type: String)
signal block_broken(grid_pos: Vector2i)
signal block_list_updated(block_names: Array[String])

@export var block_size: int = 32
@export var blocks_folder_path: String = "res://Sprites/Blocks"
var ground_y: float = 1000.0

var floor_grid_y: int:
	get:
		return int(round(ground_y / float(block_size)))

var block_scene: PackedScene = preload("res://Scenes/Block.tscn")

# Загруженные текстуры: block_id -> Texture2D
var available_blocks: Dictionary = {}
# Список названий доступных блоков для UI / инвентаря / ИИ
var block_names: Array[String] = []

# Размещенные блоки: Vector2i -> Block
var placed_blocks: Dictionary = {}

# Палитра каноничных цветов материалов (Minecraft / Alan Becker стиль)
const MATERIAL_COLORS: Dictionary = {
	"void": Color(0.0, 0.0, 0.0, 1.0),      # Черная дыра / пролом рабочего стола (Alan Becker)
	"stone": Color(0.50, 0.52, 0.54),       # Серый камень/булыжник
	"wood": Color(0.62, 0.42, 0.22),        # Теплое дерево/доски
	"brick": Color(0.78, 0.25, 0.20),       # Красный терракотовый кирпич
	"glass": Color(0.55, 0.82, 0.95, 0.75),  # Полупрозрачное стекло
	"grass": Color(0.32, 0.68, 0.26),       # Сочная трава
	"dirt": Color(0.48, 0.32, 0.18),        # Земля
	"leaves": Color(0.18, 0.52, 0.18),      # Листва
	"gold": Color(0.96, 0.80, 0.20),        # Золотой блок
	"diamond": Color(0.28, 0.82, 0.90),     # Алмазный блок
	"iron": Color(0.85, 0.85, 0.88),        # Железо
	"scaffold": Color(0.92, 0.65, 0.15),    # Строительные леса
}

func get_color_for_block_type(type_id: String) -> Color:
	var lower = type_id.to_lower()
	if MATERIAL_COLORS.has(lower):
		return MATERIAL_COLORS[lower]
	for k in MATERIAL_COLORS.keys():
		if lower.contains(k):
			return MATERIAL_COLORS[k]
	# Детерминированный цвет на основе хэша, чтобы одинаковые типы блоков всегда имели один цвет
	var h = fmod(abs(float(lower.hash())) / 1000.0, 1.0)
	return Color.from_hsv(h, 0.70, 0.85)

func _ready() -> void:
	scan_blocks_folder()

## Сканирует папку res://Sprites/Blocks/ и составляет список текстур.
## Три источника: живой листинг (редактор), манифест (экспорт — листинг DirAccess
## в .pck мёртв, а load() по точному пути работает), loose-файлы рядом с игрой.
const BLOCK_MANIFEST_PATH := "res://Sprites/Blocks/manifest.json"

func scan_blocks_folder() -> void:
	available_blocks.clear()
	block_names.clear()

	scan_imported_blocks_folder()
	scan_manifest_blocks()
	scan_loose_blocks_folder()

	if OS.has_feature("editor"):
		write_blocks_manifest()
		
	if available_blocks.is_empty():
		# Набор каноничных строительных материалов (void сюда НЕ входит:
		# это дыра в рабочем столе, а не блок)
		block_names = ["stone", "wood", "brick", "glass", "grass", "dirt", "gold", "leaves"]
		print("[BlockManager] Текстуры не найдены. Загружен каноничный набор материалов: ", block_names)
	else:
		print("[BlockManager] Найдено блоков с текстурами: ", available_blocks.size(), " -> ", block_names)

	block_list_updated.emit(block_names)

func scan_imported_blocks_folder() -> void:
	var dir := DirAccess.open(blocks_folder_path)
	if dir != null:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if not dir.current_is_dir():
				var ext = file_name.get_extension().to_lower()
				# Проверяем графические форматы
				if ext in ["png", "jpg", "jpeg", "webp"]:
					# Проверяем, что это не файл .import
					if not file_name.ends_with(".import"):
						# id в нижнем регистре, чтобы совпадать с промптом ИИ; void пропускаем (дыра, не блок)
						var block_id = file_name.get_basename().to_lower()
						if block_id == "void" or available_blocks.has(block_id):
							file_name = dir.get_next()
							continue
						var full_path = blocks_folder_path.path_join(file_name)
						var texture = load(full_path)
						if texture is Texture2D:
							available_blocks[block_id] = texture
							block_names.append(block_id)
							print("[BlockManager] Загружен блок с текстурой: '", block_id, "' из ", full_path)
			file_name = dir.get_next()
		dir.list_dir_end()

## Блоки из манифеста: точные имена файлов, load() по ним работает и в экспорте
func scan_manifest_blocks() -> void:
	if not FileAccess.file_exists(BLOCK_MANIFEST_PATH):
		return
	var text := FileAccess.get_file_as_string(BLOCK_MANIFEST_PATH).strip_edges()
	if text.is_empty():
		return
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Array:
		_load_manifest_files(parsed)
	elif parsed is Dictionary and (parsed as Dictionary).has("files"):
		_load_manifest_files((parsed as Dictionary)["files"])

func _load_manifest_files(files: Variant) -> void:
	if not (files is Array):
		return
	for entry in (files as Array):
		var file_name := str(entry)
		if file_name.is_empty() or file_name.ends_with(".import"):
			continue
		var block_id := file_name.get_basename().to_lower()
		if block_id == "void" or available_blocks.has(block_id):
			continue
		var texture = load(blocks_folder_path.path_join(file_name))
		if texture is Texture2D:
			available_blocks[block_id] = texture
			block_names.append(block_id)
			print("[BlockManager] Загружен блок из манифеста: '", block_id, "'")

## В редакторе манифест всегда свежий: перезаписывается с живого скана
func write_blocks_manifest() -> void:
	var dir := DirAccess.open(blocks_folder_path)
	if dir == null:
		return
	var files: Array[String] = []
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var ext := file_name.get_extension().to_lower()
			if ext in ["png", "jpg", "jpeg", "webp"] and not file_name.ends_with(".import"):
				if file_name.get_basename().to_lower() != "void":
					files.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	files.sort()
	var f := FileAccess.open(BLOCK_MANIFEST_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"files": files}))
		f.close()

## Loose-текстуры рядом с exe: кладите PNG в Sprites/Blocks возле игры —
## подхватятся без участия импортёра (спасает экспорт).
func scan_loose_blocks_folder() -> void:
	var loose_dir := OS.get_executable_path().get_base_dir().path_join("Sprites/Blocks")
	if not DirAccess.dir_exists_absolute(loose_dir):
		return
	var dir := DirAccess.open(loose_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var ext := file_name.get_extension().to_lower()
			if ext in ["png", "jpg", "jpeg"]:
				if not file_name.ends_with(".import"):
					var block_id := file_name.get_basename().to_lower()
					if block_id != "void" and not available_blocks.has(block_id):
						var img := Image.load_from_file(loose_dir.path_join(file_name))
						if img != null and not img.is_empty():
							available_blocks[block_id] = ImageTexture.create_from_image(img)
							block_names.append(block_id)
							print("[BlockManager] Загружен loose-блок: '", block_id, "'")
		file_name = dir.get_next()
	dir.list_dir_end()

## Преобразует координаты экрана (мировые) в координаты сетки
func world_to_grid(world_pos: Vector2) -> Vector2i:
	var gx := int(floor(world_pos.x / float(block_size)))
	var dy := ground_y - world_pos.y
	var row_from_ground := int(floor(dy / float(block_size)))
	var gy := floor_grid_y - row_from_ground
	return Vector2i(gx, gy)

## Преобразует координаты сетки в мировую позицию пивота блока (центр-низ)
func grid_to_world(grid_pos: Vector2i) -> Vector2:
	var x := (float(grid_pos.x) + 0.5) * float(block_size)
	var y := ground_y - float(floor_grid_y - grid_pos.y) * float(block_size)
	return Vector2(x, y)

## Преобразует координаты сетки в центр блока
func grid_to_center_world(grid_pos: Vector2i) -> Vector2:
	var pt := grid_to_world(grid_pos)
	return Vector2(pt.x, pt.y - float(block_size) * 0.5)

## Проверяет наличие блока в клетке сетки
func has_block(grid_pos: Vector2i) -> bool:
	return placed_blocks.has(grid_pos)

## Проверяет наличие твердого блока (не void) в клетке сетки
func has_solid_block(grid_pos: Vector2i) -> bool:
	if not placed_blocks.has(grid_pos):
		return false
	var b = placed_blocks[grid_pos]
	return is_instance_valid(b) and b.block_type != "void"

## Возвращает блок по координатам сетки
func get_block(grid_pos: Vector2i) -> Block:
	return placed_blocks.get(grid_pos, null)

func get_random_non_black_color() -> Color:
	var colors = MATERIAL_COLORS.values()
	if randf() < 0.6 and not colors.is_empty():
		return colors[randi() % colors.size()]
	var hue = randf()
	var sat = randf_range(0.55, 1.0)
	var val = randf_range(0.60, 1.0)
	return Color.from_hsv(hue, sat, val)

## Устанавливает блок в клетку сетки.
## "void" — НЕ блок, а дыра в рабочем столе: создаётся отдельно, без текстуры и коллизии.
func place_block(grid_pos: Vector2i, block_id: String = "") -> Block:
	if has_block(grid_pos):
		return placed_blocks[grid_pos]

	if block_id == "void":
		var hole: Block = block_scene.instantiate() as Block
		add_child(hole)
		hole.setup(grid_pos, block_size, "void", null, Color.BLACK)
		placed_blocks[grid_pos] = hole
		block_placed.emit(grid_pos, "void")
		return hole
		
	var block_instance: Block = block_scene.instantiate() as Block
	add_child(block_instance)
	
	var texture: Texture2D = null
	var color: Color = Color.WHITE
	
	if not block_id.is_empty() and available_blocks.has(block_id):
		texture = available_blocks[block_id]
	elif not available_blocks.is_empty():
		# Берем случайный из доступных с текстурой
		var keys = available_blocks.keys()
		block_id = keys[randi() % keys.size()]
		texture = available_blocks[block_id]
	else:
		# Текстур нет -> используем красивую каноничную палитру материала!
		if block_id.is_empty():
			block_id = "stone"
		color = get_color_for_block_type(block_id)
		
	block_instance.setup(grid_pos, block_size, block_id, texture, color)
	placed_blocks[grid_pos] = block_instance
	
	block_placed.emit(grid_pos, block_id)
	return block_instance

## Разрушает блок (черный квадрат "пустоты")
func break_block(grid_pos: Vector2i) -> bool:
	if not has_block(grid_pos):
		return false
		
	var block: Block = placed_blocks[grid_pos]
	placed_blocks.erase(grid_pos)
	block.destroy_as_void()
	block_broken.emit(grid_pos)
	return true

## Получает список всех Rect2 установленных блоков для mouse_passthrough
func get_blocks_rects() -> Array[Rect2]:
	var rects: Array[Rect2] = []
	for pos in placed_blocks.keys():
		rects.append(Rect2(Vector2(pos * block_size), Vector2(block_size, block_size)))
	return rects
