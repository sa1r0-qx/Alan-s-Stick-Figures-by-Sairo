# Scripts/SpriteSheetLoader.gd
class_name SpriteSheetLoader
extends RefCounted

## Загрузчик спрайт-листов Adobe Animate (.eas JSON) для создания SpriteFrames в Godot 4.
static func load_eas_spritesheet(eas_path: String, texture_path: String) -> SpriteFrames:
	if not FileAccess.file_exists(eas_path):
		printerr("[SpriteSheetLoader] EAS файл не найден: ", eas_path)
		return null
		
	var file = FileAccess.open(eas_path, FileAccess.READ)
	if not file:
		printerr("[SpriteSheetLoader] Не удалось открыть: ", eas_path)
		return null
		
	var json_str = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var error = json.parse(json_str)
	if error != OK:
		printerr("[SpriteSheetLoader] Ошибка парсинга JSON в: ", eas_path, " строка: ", json.get_error_line(), " ошибка: ", json.get_error_message())
		return null
		
	var data = json.data
	if not data is Dictionary or not data.has("frames"):
		printerr("[SpriteSheetLoader] Некорректный формат EAS: отсутствует секция 'frames'")
		return null
		
	var texture: Texture2D = load(texture_path)
	if not texture:
		printerr("[SpriteSheetLoader] Не удалось загрузить текстуру: ", texture_path)
		return null
		
	var sprite_frames = SpriteFrames.new()
	# Удаляем анимацию по умолчанию "default" если она создалась
	if sprite_frames.has_animation("default"):
		sprite_frames.remove_animation("default")
		
	# Группируем кадры по названиям анимаций
	# Регулярное выражение для разделения имени анимации и номера кадра (например Walk0001 -> Walk, 0001)
	var regex = RegEx.new()
	regex.compile("^([a-zA-Z_]+)(\\d+)$")
	
	var anim_groups: Dictionary = {}
	
	var raw_frames = data["frames"]
	for item in raw_frames:
		var filename: String = item.get("filename", "")
		var frame_dict: Dictionary = item.get("frame", {})
		if filename.is_empty() or frame_dict.is_empty():
			continue
			
		var match_res = regex.search(filename)
		var anim_name: String = ""
		var frame_index: int = 0
		
		if match_res:
			anim_name = match_res.get_string(1)
			frame_index = int(match_res.get_string(2))
		else:
			anim_name = filename
			frame_index = 0
			
		# Стандартизируем названия для удобства
		var lower_name = anim_name.to_lower()
		var mapped_anim_name = lower_name
		if lower_name == "blockbuild":
			mapped_anim_name = "build"
			
		if not anim_groups.has(mapped_anim_name):
			anim_groups[mapped_anim_name] = []
			
		var rect = Rect2(
			float(frame_dict.get("x", 0)),
			float(frame_dict.get("y", 0)),
			float(frame_dict.get("w", 0)),
			float(frame_dict.get("h", 0))
		)
		
		anim_groups[mapped_anim_name].append({
			"index": frame_index,
			"rect": rect
		})
		
	# Создаем анимации в SpriteFrames
	for anim_name in anim_groups:
		var frame_list: Array = anim_groups[anim_name]
		# Сортируем по индексу кадра
		frame_list.sort_custom(func(a, b): return a["index"] < b["index"])
		
		sprite_frames.add_animation(anim_name)
		
		# Настройки скорости и зацикливания
		var is_looping = (anim_name == "idle" or anim_name == "walk")
		var fps: float = 12.0
		if anim_name == "jump":
			fps = 16.0
		elif anim_name == "build":
			fps = 14.0
		elif anim_name == "walk":
			fps = 14.0
		elif anim_name == "idle":
			fps = 6.0
			
		sprite_frames.set_animation_loop(anim_name, is_looping)
		sprite_frames.set_animation_speed(anim_name, fps)
		
		for f in frame_list:
			var atlas_tex = AtlasTexture.new()
			atlas_tex.atlas = texture
			atlas_tex.region = f["rect"]
			atlas_tex.filter_clip = true
			sprite_frames.add_frame(anim_name, atlas_tex)
			
	# Добавляем алиас place_break_block для анимации build
	if sprite_frames.has_animation("build") and not sprite_frames.has_animation("place_break_block"):
		sprite_frames.add_animation("place_break_block")
		sprite_frames.set_animation_loop("place_break_block", false)
		sprite_frames.set_animation_speed("place_break_block", 14.0)
		for i in range(sprite_frames.get_frame_count("build")):
			var tex = sprite_frames.get_frame_texture("build", i)
			sprite_frames.add_frame("place_break_block", tex)
			
	print("[SpriteSheetLoader] Успешно загружен спрайтшит: ", eas_path, " Анимации: ", sprite_frames.get_animation_names())
	return sprite_frames

## Запасной оранжевый стикмен, если PNG/EAS недоступны.
static func make_fallback_frames() -> SpriteFrames:
	var sprite_frames := SpriteFrames.new()
	if sprite_frames.has_animation("default"):
		sprite_frames.remove_animation("default")
	
	var idle := _draw_stick_pose("idle")
	var walk_a := _draw_stick_pose("walk_a")
	var walk_b := _draw_stick_pose("walk_b")
	var jump := _draw_stick_pose("jump")
	var build := _draw_stick_pose("build")
	
	_add_anim(sprite_frames, "idle", [idle], true, 4.0)
	_add_anim(sprite_frames, "walk", [walk_a, walk_b], true, 8.0)
	_add_anim(sprite_frames, "jump", [jump], false, 8.0)
	_add_anim(sprite_frames, "build", [build, idle], false, 10.0)
	_add_anim(sprite_frames, "place_break_block", [build, idle], false, 10.0)
	print("[SpriteSheetLoader] Создан процедурный стикмен (fallback).")
	return sprite_frames

static func _add_anim(frames: SpriteFrames, anim_name: String, textures: Array, loop: bool, fps: float) -> void:
	if not frames.has_animation(anim_name):
		frames.add_animation(anim_name)
	frames.set_animation_loop(anim_name, loop)
	frames.set_animation_speed(anim_name, fps)
	for tex in textures:
		frames.add_frame(anim_name, tex)

static func _draw_stick_pose(pose: String) -> Texture2D:
	var w := 96
	var h := 160
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var ink := Color(1.0, 0.45, 0.08, 1.0)
	var cx := w * 0.5
	var head := Vector2(cx, 28)
	_draw_circle(img, head, 14, ink)
	
	var hip := Vector2(cx, 88)
	var neck := Vector2(cx, 42)
	_draw_line(img, neck, hip, ink, 3)
	
	var arm_l := Vector2(cx - 22, 70)
	var arm_r := Vector2(cx + 22, 70)
	var leg_l := Vector2(cx - 16, 148)
	var leg_r := Vector2(cx + 16, 148)
	match pose:
		"walk_a":
			arm_l = Vector2(cx - 18, 78)
			arm_r = Vector2(cx + 24, 62)
			leg_l = Vector2(cx - 22, 148)
			leg_r = Vector2(cx + 10, 140)
		"walk_b":
			arm_l = Vector2(cx - 24, 62)
			arm_r = Vector2(cx + 18, 78)
			leg_l = Vector2(cx - 10, 140)
			leg_r = Vector2(cx + 22, 148)
		"jump":
			arm_l = Vector2(cx - 26, 52)
			arm_r = Vector2(cx + 26, 52)
			leg_l = Vector2(cx - 12, 138)
			leg_r = Vector2(cx + 20, 132)
		"build":
			arm_l = Vector2(cx - 8, 58)
			arm_r = Vector2(cx + 30, 48)
			leg_l = Vector2(cx - 14, 148)
			leg_r = Vector2(cx + 14, 148)
	
	_draw_line(img, Vector2(cx, 52), arm_l, ink, 3)
	_draw_line(img, Vector2(cx, 52), arm_r, ink, 3)
	_draw_line(img, hip, leg_l, ink, 3)
	_draw_line(img, hip, leg_r, ink, 3)
	return ImageTexture.create_from_image(img)

static func _draw_circle(img: Image, center: Vector2, radius: int, color: Color) -> void:
	for y in range(int(center.y) - radius, int(center.y) + radius + 1):
		for x in range(int(center.x) - radius, int(center.x) + radius + 1):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			if Vector2(x, y).distance_to(center) <= radius and Vector2(x, y).distance_to(center) >= radius - 3:
				img.set_pixel(x, y, color)

static func _draw_line(img: Image, a: Vector2, b: Vector2, color: Color, thickness: int) -> void:
	var steps := int(a.distance_to(b)) + 1
	for i in range(steps + 1):
		var p := a.lerp(b, float(i) / float(max(steps, 1)))
		for oy in range(-thickness, thickness + 1):
			for ox in range(-thickness, thickness + 1):
				var x := int(round(p.x)) + ox
				var y := int(round(p.y)) + oy
				if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
					continue
				if Vector2(ox, oy).length() <= thickness:
					img.set_pixel(x, y, color)
