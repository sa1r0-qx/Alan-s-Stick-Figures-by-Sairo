# Scripts/AIService.gd
class_name AIService
extends Node

signal blueprint_ready(blueprint: StructureBlueprint)
signal request_failed(error_message: String)

enum Provider {
	FALLBACK_LOCAL,
	GOOGLE_GEMINI,
	OLLAMA
}

@export var provider: Provider = Provider.GOOGLE_GEMINI
@export var gemini_api_key: String = ""
@export var gemini_model: String = "gemini-3.5-flash"
@export var ollama_url: String = "http://127.0.0.1:11434/api/generate"
@export var ollama_model: String = "phi3"

var http_request: HTTPRequest
var current_available_blocks: Array[String] = []

func _ready() -> void:
	http_request = HTTPRequest.new()
	http_request.timeout = 30.0
	add_child(http_request)
	http_request.request_completed.connect(_on_http_request_completed)
	
	# 1. Загружаем Gemini API ключ из api_key.txt
	if FileAccess.file_exists("res://api_key.txt"):
		var f = FileAccess.open("res://api_key.txt", FileAccess.READ)
		if f:
			var key = f.get_as_text().strip_edges()
			f.close()
			if not key.is_empty():
				gemini_api_key = key
				provider = Provider.GOOGLE_GEMINI
				print("[AIService] Gemini API ключ загружен из api_key.txt! Модель: %s" % gemini_model)
				
	# 2. Если не найден в файле, проверяем переменную окружения
	if gemini_api_key.is_empty():
		var env_key = OS.get_environment("GEMINI_API_KEY")
		if not env_key.is_empty():
			gemini_api_key = env_key
			provider = Provider.GOOGLE_GEMINI
			print("[AIService] Gemini API ключ загружен из GEMINI_API_KEY")
	
	print("[AIService] Активный провайдер: %s | Модель: %s" % [Provider.keys()[provider], gemini_model if provider == Provider.GOOGLE_GEMINI else ollama_model])

## Запрос генерации структуры
func request_structure(available_blocks: Array[String], theme_hint: String = "") -> void:
	current_available_blocks = available_blocks.duplicate()
	if current_available_blocks.is_empty():
		current_available_blocks = ["stone", "wood", "brick", "glass", "grass", "dirt", "gold", "leaves"]
		
	match provider:
		Provider.GOOGLE_GEMINI:
			if gemini_api_key.is_empty():
				print("[AIService] Gemini API ключ не задан, используем автономный генератор.")
				generate_fallback_structure(theme_hint)
			else:
				send_gemini_request(theme_hint)
				
		Provider.OLLAMA:
			send_ollama_request(theme_hint)
			
		Provider.FALLBACK_LOCAL:
			generate_fallback_structure(theme_hint)

## Формирование системного промпта: большая законченная постройка для команды из 5 стикменов
func build_prompt(theme_hint: String) -> String:
	var blocks_str = ", ".join(current_available_blocks)
	var prompt = """You are an architectural AI for a 2D stickman sandbox game in the style of Alan Becker (Animation vs Minecraft).
Design a LARGE, completed, cohesive, beautifully textured 2D building, castle, or monument that will be constructed cooperatively by a team of 5 stick figures (The Second Coming, Red, Yellow, Green, Blue) working together!
Suitable designs: Grand Medieval Castle with twin towers, Royal Fortress with battlements, Ancient Colosseum/Temple with colonnades, Victorian Manor with windows, Arc de Triomphe, Pirate Galleon base, Nether/End Portal Shrine, Steampunk Clocktower.

CRITICAL ARCHITECTURAL RULES:
1. ONLY use block types from this exact list: [%s].
2. The structure must look COMPLETE, grand, and finished:
   - Bottom row y=0 MUST be a solid foundation (stone, brick, or wood) spanning the entire width.
   - Middle rows (y=1 to y=4) are pillars, gate arches, interior rooms with windows (glass), and walls.
   - Upper rows (y=5 to y=8) are battlements, parapets, roof peaks, flags, spires, or towers.
   - Use DIFFERENT materials for foundation, walls, windows, decorations, and roof so the building is rich, colorful, and diverse!
3. Dimensions for 5-stickmen cooperative building:
   - Width: between 14 and 20 blocks.
   - Height: between 6 and 30 blocks.
   - Total blocks: around 35 to 120 blocks.
4. SYMMETRY: the building MUST be mirror-symmetric left-right (tiny decor may differ by 1-2 blocks). Twin towers must have equal height, windows must repeat on both sides.
5. NO FLOATING BLOCKS: every block with y>0 must stand on another block directly below it (same x, y-1), or be part of an arch span with neighbours on BOTH sides. Never leave isolated blocks hanging in the air.
6. COMPLETENESS: fill all wall gaps and close the roofline. Bottom row y=0 must be solid across the FULL width. The silhouette must look like a finished building, not a sketch.
4. RETURN ONLY VALID RAW JSON in this exact structure without markdown backticks:
{
  "name": "Grand Medieval Castle",
  "width": 16,
  "height": 7,
  "blocks": [
    {"x": 0, "y": 0, "type": "stone"},
    {"x": 1, "y": 0, "type": "stone"},
    {"x": 2, "y": 0, "type": "stone"},
    {"x": 15, "y": 0, "type": "stone"}
  ]
}
""" % blocks_str

	if not theme_hint.is_empty():
		prompt += "\nPreferred structure style or theme: " + theme_hint
	return prompt

## Отправка запроса к Google Gemini API
func send_gemini_request(theme_hint: String) -> void:
	var url = "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent" % [gemini_model]
	var headers = [
		"Content-Type: application/json",
		"x-goog-api-key: " + gemini_api_key
	]
	var prompt_text = build_prompt(theme_hint)
	
	var payload = {
		"contents": [{
			"parts": [{"text": prompt_text}]
		}],
		"generationConfig": {
			"temperature": 0.7,
			"response_mime_type": "application/json"
		}
	}
	
	var json_body = JSON.stringify(payload)
	var err = http_request.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		printerr("[AIService] Ошибка отправки запроса к Gemini: ", err)
		generate_fallback_structure(theme_hint)

## Отправка запроса к Ollama
func send_ollama_request(theme_hint: String) -> void:
	var headers = ["Content-Type: application/json"]
	var prompt_text = build_prompt(theme_hint)
	
	var payload = {
		"model": ollama_model,
		"prompt": prompt_text,
		"stream": false,
		"format": "json"
	}
	
	var json_body = JSON.stringify(payload)
	var err = http_request.request(ollama_url, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		printerr("[AIService] Ошибка отправки запроса к Ollama: ", err)
		generate_fallback_structure(theme_hint)

func _on_http_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		printerr("[AIService] HTTP запрос завершился с кодом: ", response_code, " результат: ", result)
		generate_fallback_structure()
		return
		
	var body_text = body.get_string_from_utf8()
	var json = JSON.new()
	var parse_err = json.parse(body_text)
	if parse_err != OK:
		printerr("[AIService] Ошибка парсинга ответа: ", json.get_error_message())
		generate_fallback_structure()
		return
		
	var raw_data = json.data
	var json_content: String = ""
	
	# Извлекаем текст в зависимости от провайдера
	if raw_data is Dictionary and raw_data.has("candidates"):
		# Gemini формат
		var candidates = raw_data["candidates"]
		if not candidates.is_empty():
			var parts = candidates[0].get("content", {}).get("parts", [])
			if not parts.is_empty():
				json_content = parts[0].get("text", "")
	elif raw_data is Dictionary and raw_data.has("response"):
		# Ollama формат
		json_content = raw_data["response"]
	else:
		json_content = body_text
		
	# Очищаем от возможных markdown тегов ```json ... ```
	json_content = clean_json_markdown(json_content)
	
	var parsed_blueprint = parse_and_validate_blueprint(json_content)
	if parsed_blueprint:
		blueprint_ready.emit(parsed_blueprint)
	else:
		print("[AIService] Не удалось распознать чертеж из ответа ИИ, переключаемся на автономный генератор.")
		generate_fallback_structure()

func clean_json_markdown(text: String) -> String:
	var trimmed = text.strip_edges()
	if trimmed.begins_with("```"):
		var first_newline = trimmed.find("\n")
		if first_newline != -1:
			trimmed = trimmed.substr(first_newline + 1)
		if trimmed.ends_with("```"):
			trimmed = trimmed.substr(0, trimmed.length() - 3)
	return trimmed.strip_edges()

## Валидация блоков: проверяет и заменяет любые выдуманные ИИ материалы!
func parse_and_validate_blueprint(json_text: String) -> StructureBlueprint:
	var json = JSON.new()
	if json.parse(json_text) != OK:
		return null
		
	var data = json.data
	if not data is Dictionary or not data.has("blocks"):
		return null
		
	var bp_name = str(data.get("name", "AI Structure"))
	var width = clampi(int(data.get("width", 5)), 4, 24)
	var height = clampi(int(data.get("height", 4)), 3, 30)
	if not (data["blocks"] is Array):
		return null
	var raw_blocks: Array = data["blocks"]

	var blueprint = StructureBlueprint.new(bp_name, width, height)
	if current_available_blocks.is_empty():
		return null
	# Чертежам запрещены служебные типы: только видимые строительные материалы
	var solid_types: Array[String] = []
	for t in current_available_blocks:
		if t != "void" and t != "scaffold":
			solid_types.append(t)
	if solid_types.is_empty():
		for t in current_available_blocks:
			solid_types.append(t)

	# 1. Дедуп + кламп в габариты + замена выдуманных/служебных типов
	var cells := {}
	for b in raw_blocks:
		if not b is Dictionary:
			continue
		var bx := clampi(int(b.get("x", 0)), 0, width - 1)
		var by := clampi(int(b.get("y", 0)), 0, height - 1)
		var btype := str(b.get("type", ""))
		if not solid_types.has(btype):
			var valid_fallback: String = solid_types[randi() % solid_types.size()]
			print("[AIService] Валидация блоков: '%s' заменен на валидный '%s'!" % [btype, valid_fallback])
			btype = valid_fallback
		cells[Vector2i(bx, by)] = btype

	# 2. Сплошной фундамент: нижний ряд обязан идти по всей ширине
	var foundation_votes := {}
	for k in cells.keys():
		var ck: Vector2i = k
		if ck.y == 0:
			var ft: String = cells[k]
			foundation_votes[ft] = int(foundation_votes.get(ft, 0)) + 1
	var foundation_type: String = solid_types[0]
	var best_votes := -1
	for t in foundation_votes.keys():
		if int(foundation_votes[t]) > best_votes:
			best_votes = int(foundation_votes[t])
			foundation_type = str(t)
	for x in range(width):
		var fkey := Vector2i(x, 0)
		if not cells.has(fkey):
			cells[fkey] = foundation_type

	# 2.5. Зеркальная симметрия: более заполненная половина отражается на другую.
	# Промпт просит симметрию, но LLM её не держит — доводим детерминированно.
	var left_count := 0
	var right_count := 0
	for k in cells.keys():
		var ck2: Vector2i = k
		var mk: int = width - 1 - ck2.x
		if ck2.x < mk:
			left_count += 1
		elif ck2.x > mk:
			right_count += 1
	var use_left := left_count >= right_count
	var sym := {}
	for y in range(height):
		for x in range(width):
			var mx: int = width - 1 - x
			var sx := x
			if use_left and x > mx:
				sx = mx
			elif not use_left and x < mx:
				sx = mx
			var skey := Vector2i(sx, y)
			if cells.has(skey):
				sym[Vector2i(x, y)] = cells[skey]
	cells = sym

	# 3. Только блоки с опорой: y=0, либо блок снизу, либо арка (соседи с обеих сторон).
	# Проход снизу вверх до fixpoint — висящий мусор (как на скриншоте) отрезается.
	var occupied := {}
	for k in cells.keys():
		var c0: Vector2i = k
		if c0.y == 0:
			occupied[c0] = true
	var changed := true
	var passes := 0
	while changed and passes < height + 2:
		changed = false
		passes += 1
		for k in cells.keys():
			var c: Vector2i = k
			if occupied.has(c):
				continue
			var below := Vector2i(c.x, c.y - 1)
			var left := Vector2i(c.x - 1, c.y)
			var right := Vector2i(c.x + 1, c.y)
			if occupied.has(below) or (occupied.has(left) and occupied.has(right)):
				occupied[c] = true
				changed = true
	for k in cells.keys():
		var cc: Vector2i = k
		if occupied.has(cc):
			blueprint.add_block(cc.x, cc.y, str(cells[k]))

	if blueprint.blocks.is_empty():
		return null

	# 4. Лимит: оставляем нижние (несущие) блоки
	if blueprint.blocks.size() > 160:
		var sorted: Array[Dictionary] = []
		for bl in blueprint.blocks:
			sorted.append(bl)
		sorted.sort_custom(func(a, b): return (int(a["y"]) * 1000 + int(a["x"])) - (int(b["y"]) * 1000 + int(b["x"])))
		var trimmed: Array[Dictionary] = []
		for i in range(mini(160, sorted.size())):
			trimmed.append(sorted[i])
		blueprint.blocks = trimmed
		
	# Парсим пошаговый план движений от ИИ
	if data.has("steps") and data["steps"] is Array:
		for s in data["steps"]:
			if s is Dictionary:
				blueprint.add_step(s)
		print("[AIService] Загружен пошаговый план движений: %d шагов от ИИ!" % blueprint.steps.size())
		
	print("[AIService] Успешно получен и валидирован чертеж '%s' (%d блоков, %d шагов)" % [blueprint.name, blueprint.blocks.size(), blueprint.steps.size()])
	return blueprint

## Встроенный автономный генератор структур (Fallback)
func generate_fallback_structure(hint: String = "") -> void:
	var types = current_available_blocks
	if types.is_empty():
		types = ["stone", "grass", "wood"]
	var t1 = types[0]
	var t2 = types[min(1, types.size() - 1)]
	var t3 = types[min(2, types.size() - 1)]
	
	var templates = ["castle", "mansion", "fortress", "temple", "bridge"]
	var chosen = templates[randi() % templates.size()]
	if not hint.is_empty():
		for t in templates:
			if hint.to_lower().contains(t):
				chosen = t
				break
				
	var bp: StructureBlueprint
	match chosen:
		"castle":
			bp = StructureBlueprint.new("Большой Королевский Замок", 16, 7)
			# 1. Фундамент по всей ширине
			for x in range(16):
				bp.add_block(x, 0, t1)
			# 2. Левая башня
			for y in range(1, 6):
				bp.add_block(0, y, t1)
				bp.add_block(2, y, t1)
			bp.add_block(1, 3, t3) # Окно башни
			bp.add_block(0, 6, t1) # Зубцы
			bp.add_block(2, 6, t1)
			# 3. Правая башня
			for y in range(1, 6):
				bp.add_block(13, y, t1)
				bp.add_block(15, y, t1)
			bp.add_block(14, 3, t3) # Окно башни
			bp.add_block(13, 6, t1) # Зубцы
			bp.add_block(15, 6, t1)
			# 4. Центральные стены и арка ворот
			for x in range(3, 13):
				bp.add_block(x, 3, t2)
			for y in range(1, 3):
				bp.add_block(5, y, t1)
				bp.add_block(10, y, t1)
			# 5. Зубцы центральной стены
			for x in [3, 5, 7, 8, 10, 12]:
				bp.add_block(x, 4, t1)
			bp.add_block(7, 5, t2)
			bp.add_block(8, 5, t2)
			bp.add_block(7, 6, t3) # Флагшток / знамя
		"mansion":
			bp = StructureBlueprint.new("Большой Особняк", 15, 6)
			# Фундамент
			for x in range(15):
				bp.add_block(x, 0, t1)
			# Стены 1 этажа
			for y in range(1, 3):
				bp.add_block(0, y, t2)
				bp.add_block(4, y, t2)
				bp.add_block(10, y, t2)
				bp.add_block(14, y, t2)
			# Окна 1 этажа
			bp.add_block(2, 1, t3)
			bp.add_block(12, 1, t3)
			# Балка 2 этажа
			for x in range(15):
				bp.add_block(x, 3, t2)
			# Окна 2 этажа
			for x in [2, 5, 9, 12]:
				bp.add_block(x, 4, t3)
			# Крыша
			for x in range(1, 14):
				bp.add_block(x, 5, t1)
		"fortress":
			bp = StructureBlueprint.new("Великая Крепость", 16, 6)
			for x in range(16):
				bp.add_block(x, 0, t1)
			# Колонны бастионов
			for y in range(1, 5):
				bp.add_block(0, y, t1)
				bp.add_block(1, y, t1)
				bp.add_block(7, y, t2)
				bp.add_block(8, y, t2)
				bp.add_block(14, y, t1)
				bp.add_block(15, y, t1)
			# Зубцы
			for x in range(0, 16, 2):
				bp.add_block(x, 5, t1)
		"temple":
			bp = StructureBlueprint.new("Античный Пантеон", 15, 6)
			# Ступени
			for x in range(15):
				bp.add_block(x, 0, t1)
			for x in range(1, 14):
				bp.add_block(x, 1, t1)
			# 5 колонн (для каждого из 5 стикменов!)
			for col_x in [2, 5, 7, 9, 12]:
				bp.add_block(col_x, 2, t2)
				bp.add_block(col_x, 3, t2)
			# Архитрав и крыша
			for x in range(1, 14):
				bp.add_block(x, 4, t1)
			for x in range(3, 12):
				bp.add_block(x, 5, t3)
		_: # bridge
			bp = StructureBlueprint.new("Арочный Мост", 16, 5)
			for x in range(16):
				bp.add_block(x, 3, t2) # Дорога моста
				bp.add_block(x, 4, t3) # Перила
			# Опоры моста
			for y in range(3):
				bp.add_block(0, y, t1)
				bp.add_block(1, y, t1)
				bp.add_block(14, y, t1)
				bp.add_block(15, y, t1)
			# Центральная арка
			bp.add_block(5, 2, t1)
			bp.add_block(6, 2, t1)
			bp.add_block(9, 2, t1)
			bp.add_block(10, 2, t1)
			
	print("[AIService] Сгенерирована большая командная структура: '%s' (%d блоков)" % [bp.name, bp.blocks.size()])
	get_tree().create_timer(0.3).timeout.connect(func(): blueprint_ready.emit(bp))
