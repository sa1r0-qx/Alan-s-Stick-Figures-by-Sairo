# Scripts/Stickman.gd
class_name Stickman
extends CharacterBody2D

signal state_changed(new_state: String)
signal ai_build_started(structure_name: String)
signal ai_build_completed(structure_name: String)

enum State {
	IDLE,
	WALK,
	JUMP,
	ACTION_ANIM, # Воспроизведение place_break_block
	DRAGGED,
	WORKING # Управляется корутиной строительства/разрушения ИИ
}

enum DepthLayer {
	FOREGROUND,  # Перед блоками (z_index = 10, коллизия только с полом, никогда не застревает)
	BLOCKS,      # На слое блоков (z_index = 5, коллизия с полом и блоками, можно ходить по крышам)
	BACKGROUND   # За блоками (z_index = -5, коллизия только с полом, легкая тень, ходит позади)
}

@export var depth_layer: DepthLayer = DepthLayer.FOREGROUND
@export var character_scale: float = 0.16
@export var walk_speed: float = 130.0
@export var jump_velocity: float = -420.0
@export var gravity: float = 980.0
@export var eas_path: String = "res://Sprites/Characters/TSC.eas"
@export var png_path: String = "res://Sprites/Characters/TSC.png"

# Радиус досягаемости рук (в клетках сетки)
const REACH_X: int = 2       # влево/вправо
const REACH_UP: int = 3      # вверх от ног
const REACH_DOWN: int = 1    # вниз под ноги

var current_state: State = State.IDLE
var walk_direction: float = 1.0
var state_timer: float = 0.0

# Перетаскивание мышью
var is_hovered: bool = false
var is_dragging: bool = false
var drag_offset: Vector2 = Vector2.ZERO
var last_mouse_pos: Vector2 = Vector2.ZERO
var throw_velocity: Vector2 = Vector2.ZERO

# Ссылки на системы
var block_manager: BlockManager = null
var ai_service: AIService = null
var main_ref = null

# История построек и строительные леса
var previous_structure_blocks: Array[Vector2i] = []
var scaffold_blocks: Array[Vector2i] = []
var is_busy_with_ai: bool = false
var _visual_height: float = 118.0
var _visual_width: float = 36.0

# Ноды
@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var click_area: Area2D = $ClickArea
@onready var click_shape: CollisionShape2D = $ClickArea/CollisionShape2D

func _ready() -> void:
	add_to_group("stickmen")
	setup_sprites()
	setup_collisions()
	set_depth_layer(depth_layer)
	
	click_area.monitorable = true
	click_area.monitoring = true
	click_area.input_pickable = true
	click_area.collision_layer = 4
	click_area.collision_mask = 0
	click_area.mouse_entered.connect(_on_mouse_entered)
	click_area.mouse_exited.connect(_on_mouse_exited)
	click_area.input_event.connect(_on_click_area_input)
	
	switch_state(State.IDLE)

## Переключение слоя глубины персонажа (перед блоками / на слое блоков / за блоками)
func set_depth_layer(new_layer: DepthLayer) -> void:
	depth_layer = new_layer
	collision_layer = 4
	collision_mask = 3 # Слой 1 (пол экрана) | Слой 2 (блоки) — всегда стоим на блоках!
	match depth_layer:
		DepthLayer.FOREGROUND:
			z_index = 10
			modulate = Color(1.0, 1.0, 1.0, 1.0)
		DepthLayer.BLOCKS:
			z_index = 5
			modulate = Color(1.0, 1.0, 1.0, 1.0)
		DepthLayer.BACKGROUND:
			z_index = -5
			modulate = Color(0.65, 0.65, 0.75, 0.9)

## Выборочная фильтрация коллизий:
## Стикмен стоит на блоке под ногами, а все блоки ВЫШЕ ног игнорируются конкретно для этого стикмена
func update_block_collisions() -> void:
	if not is_instance_valid(block_manager):
		return
		
	var foot_y := global_position.y
	var margin := 6.0 # Запас для надежного приземления и стояния на блоке
	
	for grid_pos in block_manager.placed_blocks:
		var block: Block = block_manager.placed_blocks[grid_pos]
		if not is_instance_valid(block) or block.block_type == "void":
			continue
			
		var block_top_y := block.global_position.y - float(block_manager.block_size)
		
		# Если верхняя грань блока выше ног стикмена (блок на уровне тела/головы/выше) —
		# отключаем коллизию конкретно для этого стикмена, чтобы он свободно проходил сквозь текстуры!
		if block_top_y < foot_y - margin:
			add_collision_exception_with(block)
		else:
			# Блок находится под ногами — стикмен уверенно стоит на нем и не падает!
			remove_collision_exception_with(block)

func cycle_depth_layer() -> void:
	match depth_layer:
		DepthLayer.FOREGROUND:
			set_depth_layer(DepthLayer.BLOCKS)
		DepthLayer.BLOCKS:
			set_depth_layer(DepthLayer.BACKGROUND)
		DepthLayer.BACKGROUND:
			set_depth_layer(DepthLayer.FOREGROUND)

func setup_sprites() -> void:
	# Если спрайты уже настроены в инспекторе сцены (Red, Yellow, Green, Blue, TSC) — не перезаписываем их!
	if animated_sprite and animated_sprite.sprite_frames and animated_sprite.sprite_frames.get_animation_names().size() > 0:
		print("[Stickman] Используются готовые SpriteFrames из сцены для: ", name)
		return
		
	var frames = SpriteSheetLoader.load_eas_spritesheet(eas_path, png_path)
	if frames == null:
		printerr("[Stickman] EAS не загрузился, рисую запасного стикмена.")
		frames = SpriteSheetLoader.make_fallback_frames()
	
	animated_sprite.sprite_frames = frames
	animated_sprite.centered = true
	animated_sprite.visible = true
	animated_sprite.modulate = Color.WHITE
	animated_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	animated_sprite.material = null
	
	var frame_h := 741.0
	var used_scale := character_scale
	if frames and frames.has_animation("idle") and frames.get_frame_count("idle") > 0:
		var tex := frames.get_frame_texture("idle", 0)
		if tex:
			frame_h = float(tex.get_height())
			if frame_h < 400.0:
				used_scale = 1.0
	animated_sprite.scale = Vector2(used_scale, used_scale)
	var drawn_h := frame_h * used_scale
	var drawn_w := 220.0 * used_scale
	if frames and frames.has_animation("idle") and frames.get_frame_count("idle") > 0:
		var tex2 := frames.get_frame_texture("idle", 0)
		if tex2:
			drawn_w = float(tex2.get_width()) * used_scale
	animated_sprite.position = Vector2(0, -drawn_h * 0.5)
	_visual_height = drawn_h
	_visual_width = drawn_w

func setup_collisions() -> void:
	# Если коллизии уже настроены в инспекторе сцены — сохраняем их
	if collision_shape and collision_shape.shape != null and click_shape and click_shape.shape != null:
		return
		
	var height = _visual_height if _visual_height > 8.0 else 741.0 * character_scale
	var width = _visual_width if _visual_width > 8.0 else 220.0 * character_scale
	
	var capsule = CapsuleShape2D.new()
	capsule.radius = width * 0.5
	capsule.height = height * 0.85
	collision_shape.shape = capsule
	collision_shape.position = Vector2(0, -height * 0.45)
	
	var rect_shape = RectangleShape2D.new()
	rect_shape.size = Vector2(width * 1.5, height)
	click_shape.shape = rect_shape
	click_shape.position = Vector2(0, -height * 0.5)

func _physics_process(delta: float) -> void:
	# Выборочная фильтрация коллизий: блоки под ногами держат стикмена, а блоки выше ног прозрачны
	update_block_collisions()

	# 1. Перетаскивание мышью игроком
	if current_state == State.DRAGGED:
		var current_mouse = get_global_mouse_position()
		global_position = current_mouse + drag_offset
		throw_velocity = (current_mouse - last_mouse_pos) / max(delta, 0.001)
		last_mouse_pos = current_mouse
		return

	# 2. Если стикмен занят выполнением сложной строительной задачи ИИ
	if current_state == State.WORKING:
		# Физика обрабатывается корутинами
		if not is_on_floor():
			velocity.y += gravity * delta
		move_and_slide()
		return

	# 3. Базовая гравитация
	if not is_on_floor():
		velocity.y += gravity * delta
	else:
		if current_state == State.JUMP and velocity.y >= 0:
			switch_state(State.IDLE)
			
	state_timer -= delta
	
	match current_state:
		State.IDLE:
			velocity.x = move_toward(velocity.x, 0, walk_speed * 4.0 * delta)
			if state_timer <= 0:
				choose_autonomous_action()
				
		State.WALK:
			velocity.x = walk_direction * walk_speed
			update_facing(walk_direction)
			
			if is_on_wall():
				if randf() < 0.6:
					try_jump()
				else:
					walk_direction *= -1.0
					update_facing(walk_direction)
					
			if state_timer <= 0:
				switch_state(State.IDLE)
				
		State.JUMP:
			velocity.x = walk_direction * (walk_speed * 0.8)
			
		State.ACTION_ANIM:
			velocity.x = 0
			
	move_and_slide()

## Автономный выбор действий стикмена во время отдыха / в свободном режиме
func choose_autonomous_action() -> void:
	if is_busy_with_ai:
		return
		
	var roll = randf()
	if roll < 0.001:
		# 0.1%: пакость окну под ногами (закрыть), если хаос разрешён в HUD
		try_window_mischief()
	elif roll < 0.50:
		walk_direction = 1.0 if randf() < 0.5 else -1.0
		switch_state(State.WALK)
	elif roll < 0.75:
		switch_state(State.IDLE)
	elif roll < 0.90:
		try_jump()
	elif roll < 0.92:
		# Стикмен решает проломить рабочий стол (создает черную дыру void)
		break_desktop_at_feet()
	else:
		# Шанс захотеть построить структуру всей командой
		if main_ref and not main_ref.is_team_building:
			main_ref.start_cooperative_build()
		else:
			trigger_ai_build()

## 0.1% пакость: стикмен хлопает по окну под ногами и просит его закрыть (WM_CLOSE).
## Срабатывает только если в HUD включён хаос окон и ноги реально стоят на окне.
func try_window_mischief() -> void:
	if main_ref == null or not bool(main_ref.allow_window_close):
		switch_state(State.IDLE)
		return
	var hwnd: int = int(main_ref.window_hwnd_at(global_position))
	if hwnd == 0:
		switch_state(State.IDLE)
		return
	switch_state(State.ACTION_ANIM)
	play_animation("place_break_block")
	await get_tree().create_timer(0.35).timeout
	if main_ref != null and bool(main_ref.allow_window_close):
		main_ref.request_close_window(hwnd)
		print("[Stickman] Пакость удалась: попросил закрыть окно HWND %d" % hwnd)
	await get_tree().create_timer(0.2).timeout
	if current_state == State.ACTION_ANIM:
		switch_state(State.IDLE)

## Стикмен ударяет и проламывает рабочий стол перед собой
func break_desktop_at_feet() -> void:
	if not block_manager or is_busy_with_ai:
		return
	var my_grid = get_current_grid_pos()
	var target_grid = Vector2i(my_grid.x + int(walk_direction), my_grid.y)
	
	switch_state(State.ACTION_ANIM)
	update_facing(walk_direction)
	play_animation("place_break_block")
	await get_tree().create_timer(0.35).timeout
	
	# Создаем черную пустоту на рабочем столе
	block_manager.place_block(target_grid, "void")
	print("[Stickman] Стикмен проломил рабочий стол (пустота void на %s)!" % target_grid)
	
	await get_tree().create_timer(0.2).timeout
	switch_state(State.IDLE)

func try_jump() -> void:
	if is_on_floor():
		velocity.y = jump_velocity
		switch_state(State.JUMP)

func switch_state(new_state: State) -> void:
	current_state = new_state
	
	match current_state:
		State.IDLE:
			state_timer = randf_range(2.0, 5.0)
			play_animation("idle")
			state_changed.emit("idle")
			
		State.WALK:
			state_timer = randf_range(2.5, 6.0)
			play_animation("walk")
			state_changed.emit("walk")
			
		State.JUMP:
			play_animation("jump")
			state_changed.emit("jump")
			
		State.ACTION_ANIM:
			play_animation("place_break_block")
			state_changed.emit("action")
			
		State.DRAGGED:
			play_animation("jump")
			velocity = Vector2.ZERO
			state_changed.emit("dragged")
			
		State.WORKING:
			state_changed.emit("working")

func play_animation(anim_name: String) -> void:
	if not animated_sprite or not animated_sprite.sprite_frames:
		return
		
	var sf: SpriteFrames = animated_sprite.sprite_frames
	var target: String = anim_name.to_lower()
	
	# 1. Прямое совпадение
	if sf.has_animation(anim_name):
		animated_sprite.play(anim_name)
		return
		
	# 2. Поиск без учета регистра (например, "walk" -> "Walk", "idle" -> "Idle", "jump" -> "Jump")
	for existing in sf.get_animation_names():
		if str(existing).to_lower() == target:
			animated_sprite.play(existing)
			return
			
	# 3. Сопоставление синонимов для строительства/действия (Place_Break, build, place_break_block, action)
	if target in ["place_break_block", "build", "place_break", "action"]:
		for syn in ["place_break", "build", "place_break_block", "action"]:
			for existing in sf.get_animation_names():
				if str(existing).to_lower() == syn:
					animated_sprite.play(existing)
					return
					
	# 4. Запасной вариант (idle / Idle)
	for existing in sf.get_animation_names():
		if str(existing).to_lower() == "idle":
			animated_sprite.play(existing)
			return

func update_facing(dir: float) -> void:
	if abs(dir) > 0.01:
		animated_sprite.flip_h = (dir < 0)

# ==============================================================================
# --- ИИ СТРОИТЕЛЬСТВО И СНОС СТРУКТУР (Alan Becker AI Architecture) ---
# ==============================================================================

## Запрос к ИИ на постройку новой структуры
func trigger_ai_build(theme_hint: String = "") -> void:
	if is_busy_with_ai or not ai_service or not block_manager:
		return
		
	is_busy_with_ai = true
	switch_state(State.WORKING)
	velocity = Vector2.ZERO
	play_animation("idle")
	
	# Передаем ИИ СПИСОК СУЩЕСТВУЮЩИХ БЛОКОВ во избежание галлюцинаций
	var available: Array[String] = []
	for bname in block_manager.block_names:
		available.append(bname)
	if available.is_empty():
		available = ["stone", "wood", "brick", "glass", "grass", "dirt", "gold", "leaves"]
		
	print("[Stickman] Передаю ИИ список доступных блоков: ", available)
	
	# Подписываемся на разовый ответ чертежа
	var on_blueprint = func(blueprint: StructureBlueprint):
		execute_full_construction_pipeline(blueprint)
		
	ai_service.blueprint_ready.connect(on_blueprint, CONNECT_ONE_SHOT)
	ai_service.request_structure(available, theme_hint)

## Полный цикл: снос старой постройки -> стройка новой
func execute_full_construction_pipeline(blueprint: StructureBlueprint) -> void:
	ai_build_started.emit(blueprint.name)
	print("[Stickman] Начинаю работу над чертежом: '%s'" % blueprint.name)
	
	# 1. ПОЛНЫЙ СНОС ПРЕДЫДУЩЕЙ ПОСТРОЙКИ (если есть)
	if not previous_structure_blocks.is_empty():
		print("[Stickman] Снос предыдущей постройки...")
		await demolish_previous_structure()
		
	# 2. ОПРЕДЕЛЯЕМ МЕСТО ДЛЯ СТРОИТЕЛЬСТВА
	# Строим прямо перед стикменом на уровне пола
	var stick_grid = get_current_grid_pos()
	var ground_origin = Vector2i(stick_grid.x + 1, stick_grid.y)
	
	# Не даем постройке выйти за пределы экрана справа
	var screen_cols = int(floor(DisplayServer.screen_get_size().x / float(block_manager.block_size)))
	if ground_origin.x + blueprint.width >= screen_cols - 2:
		ground_origin.x = max(2, screen_cols - blueprint.width - 2)
		
	var target_tasks = blueprint.to_world_grid_blocks(ground_origin)
	var world_steps = blueprint.to_world_steps(ground_origin)
	
	# Запоминаем координаты новой постройки для будущего сноса
	previous_structure_blocks.clear()
	for t in target_tasks:
		previous_structure_blocks.append(t["grid_pos"])
		
	# 3. ИИ УПРАВЛЯЕТ ДВИЖЕНИЯМИ СТИКМЕНА (Action Plan)
	print("[Stickman] ИИ управляет движениями стикмена! Выполняю %d шагов плана..." % world_steps.size())
	await execute_ai_steps(world_steps)
	
	print("[Stickman] Постройка '%s' успешно завершена и сохранена!" % blueprint.name)
	ai_build_completed.emit(blueprint.name)
	
	is_busy_with_ai = false
	switch_state(State.IDLE)

## Логика сноса предыдущей постройки
func demolish_previous_structure() -> void:
	# Сортируем блоки сверху вниз (с меньшим Y в Godot - они выше), чтобы не висели в воздухе
	var blocks_to_destroy = previous_structure_blocks.duplicate()
	# Сортируем сверху вниз: меньшая Y (выше) идет первой
	blocks_to_destroy.sort_custom(func(a, b): return int(a.y) - int(b.y))

	var remaining = blocks_to_destroy.duplicate()
	while not remaining.is_empty():
		var target_pos = remaining[0]

		# Если блок уже удален кем-то другим
		if not block_manager.has_block(target_pos):
			remaining.pop_front()
			continue

		# Подходим по X
		await walk_to_grid_x(target_pos.x - 1 if target_pos.x >= get_current_grid_pos().x else target_pos.x + 1)

		# Проверяем, достаем ли по высоте
		var reach_attempts = 0
		var blocked = false
		while not can_reach_block(target_pos) and reach_attempts < 8:
			reach_attempts += 1
			var my_grid_local = get_current_grid_pos()
			var stand_x_local = target_pos.x - 1 if target_pos.x >= my_grid_local.x else target_pos.x + 1
			var front_block_local = block_manager.has_block(Vector2i(stand_x_local, my_grid_local.y))
			var is_above_local = target_pos.y < my_grid_local.y
			if front_block_local or is_above_local:
				await build_scaffold_up()
			else:
				var alt_stand = target_pos.x + 1 if stand_x_local == target_pos.x - 1 else target_pos.x - 1
				await walk_to_grid_x(alt_stand)
				if not can_reach_block(target_pos):
					var my_grid_check = get_current_grid_pos()
					var front_block_check = block_manager.has_block(Vector2i(alt_stand, my_grid_check.y))
					var is_above_check = target_pos.y < my_grid_check.y
					if not (front_block_check or is_above_check):
						print("[Stickman] При сносе: не удалось достичь блока %s за %d попыток" % [target_pos, reach_attempts])
						blocked = true
						break

		if blocked or not can_reach_block(target_pos):
			remaining.pop_front()
			continue

		# Находясь на этой высоте, ломаем ВСЕ блоки сверху, до которых достаем!
		var i = 0
		while i < remaining.size():
			var check_pos = remaining[i]
			if block_manager.has_block(check_pos) and can_reach_block(check_pos):
				await perform_action_at_block(check_pos, "break")
				remaining.remove_at(i)
			else:
				i += 1

	# Ломаем временный столб и спускаемся вниз
	await dismantle_all_scaffolding()
	previous_structure_blocks.clear()

## Выполняет пошаговый план движений и действий, составленный нейросетью
func execute_ai_steps(steps: Array[Dictionary]) -> void:
	for step in steps:
		if not is_busy_with_ai:
			break
			
		var action = str(step.get("action", ""))
		match action:
			"walk_to":
				var target_gx = int(step.get("grid_x", 0))
				await walk_to_grid_x(target_gx)
				
			"place":
				var pos: Vector2i = step.get("grid_pos", Vector2i.ZERO)
				var btype = str(step.get("type", "stone"))
				
				# Если блок ниже уровня ног — спрыгиваем вниз
				if pos.y > get_current_grid_pos().y + REACH_DOWN:
					await descend_to_ground()
					
				# Если не достаем до блока, подходим к свободной стороне
				if not can_reach_block(pos):
					var stand_x = find_best_stand_x(pos.x)
					await walk_to_grid_x(stand_x)
					
				# Если блок все еще выше нас, поднимаемся по столбу
				if pos.y < get_current_grid_pos().y:
					await build_scaffold_up()
					
				# Проверяем клетку: если уже стоит другой блок, сначала ломаем
				var cur = block_manager.get_block(pos)
				if cur != null:
					if cur.block_type == btype:
						continue
					await perform_action_at_block(pos, "break")
					
				await perform_action_at_block(pos, "place", btype)
				
			"break":
				var pos: Vector2i = step.get("grid_pos", Vector2i.ZERO)
				if block_manager.has_block(pos):
					if not can_reach_block(pos):
						var stand_x = find_best_stand_x(pos.x)
						await walk_to_grid_x(stand_x)
					await perform_action_at_block(pos, "break")
					
			"scaffold_up":
				await build_scaffold_up()
				
			"jump_down":
				await descend_to_ground()
				
	# Всегда гарантированно возвращаемся на землю после окончания плана
	await descend_to_ground()

## Логика строительства новой структуры.
## Гарантированно завершается: задачи с лимитом попыток, недостижимое пропускается,
## а не крутится бесконечно (это и был клин "куда идти и куда ставить").
func construct_structure(tasks: Array[Dictionary]) -> void:
	var pending_tasks: Array = tasks.duplicate()
	# Снизу вверх: больший grid_y (ниже на экране) первым
	pending_tasks.sort_custom(func(a, b): return int(b["grid_pos"].y) - int(a["grid_pos"].y))
	var fails := {}
	var rounds := 0
	while not pending_tasks.is_empty() and rounds < 20:
		rounds += 1
		var progressed := false

		# 1. Наводимся на первую задачу: спуститься / подойти / подняться
		var first_pos: Vector2i = pending_tasks[0]["grid_pos"]
		var my_grid := get_current_grid_pos()
		if first_pos.y > my_grid.y + REACH_DOWN:
			await descend_to_ground()
		if not can_reach_block(first_pos):
			await walk_to_grid_x(find_best_stand_x(first_pos.x))
		var ups := 0
		while not can_reach_block(first_pos) and ups < 10:
			var cg := get_current_grid_pos()
			if first_pos.y < cg.y:
				await build_scaffold_up()
			else:
				break
			ups += 1

		# 2. С текущей позиции делаем ВСЁ досягаемое, чтобы не бегать туда-сюда
		var i := 0
		while i < pending_tasks.size():
			var cur_pos: Vector2i = pending_tasks[i]["grid_pos"]
			var cur_type: String = str(pending_tasks[i]["type"])
			if can_reach_block(cur_pos):
				var cur_block := block_manager.get_block(cur_pos)
				if cur_block != null and cur_block.block_type == cur_type:
					pending_tasks.remove_at(i)
					progressed = true
					continue
				if cur_block != null:
					await perform_action_at_block(cur_pos, "break")
				await perform_action_at_block(cur_pos, "place", cur_type)
				pending_tasks.remove_at(i)
				progressed = true
			else:
				i += 1

		# 3. Без прогресса — первая задача проблемная: в конец, после 3 кругов выкинуть
		if not progressed and not pending_tasks.is_empty():
			var fail_key := str(pending_tasks[0]["grid_pos"])
			fails[fail_key] = int(fails.get(fail_key, 0)) + 1
			if int(fails[fail_key]) < 3:
				pending_tasks.push_back(pending_tasks.pop_front())
			else:
				pending_tasks.pop_front()
				print("[Stickman] Пропускаю недостижимый блок %s, иду дальше" % fail_key)

	# После завершения всех задач убираем леса и возвращаемся на землю
	await descend_to_ground()

## Физический снос списка блоков: стикмен САМ подходит и ломает каждый блок
## сверху вниз (используется командой перед новой постройкой).
## tasks: Array[Dictionary] вида {"grid_pos": Vector2i}. Гарантированно завершается.
func dismantle_tasks(tasks: Array[Dictionary]) -> void:
	var pending: Array = tasks.duplicate()
	# Сверху вниз: меньший grid_y (выше на экране) первым, чтобы не висеть в воздухе
	pending.sort_custom(func(a, b): return int(a["grid_pos"].y) - int(b["grid_pos"].y))
	var fails := {}
	var rounds := 0
	while not pending.is_empty() and rounds < 12:
		rounds += 1
		var progressed := false
		var i := 0
		while i < pending.size():
			var pos: Vector2i = pending[i]["grid_pos"]
			if not block_manager.has_block(pos):
				pending.remove_at(i)
				progressed = true
				continue
			if not can_reach_block(pos):
				await walk_to_grid_x(find_best_stand_x(pos.x))
				# К высокой цели поднимаемся серией лесов, а не по одному за круг
				var ups := 0
				while not can_reach_block(pos) and ups < 8:
					var my2 := get_current_grid_pos()
					if pos.y < my2.y:
						await build_scaffold_up()
					else:
						break
					ups += 1
			if can_reach_block(pos):
				await perform_action_at_block(pos, "break")
				pending.remove_at(i)
				progressed = true
			else:
				var fail_key := str(pos)
				fails[fail_key] = int(fails.get(fail_key, 0)) + 1
				if int(fails[fail_key]) > 2:
					print("[Stickman] Не дотянулся до %s при сносе, пропускаю" % fail_key)
					pending.remove_at(i)
					progressed = true
				else:
					i += 1
		if not progressed:
			break
	await dismantle_all_scaffolding()

## Спуск стикмена вниз: разбирает столб или спрыгивает с крыши/постройки на землю
func descend_to_ground() -> void:
	# 1. Разбираем строительный столб под ногами, если он был
	if not scaffold_blocks.is_empty():
		await dismantle_all_scaffolding()

	# 2. Если все еще стоим высоко над полом (на крыше или стене), спрыгиваем к свободному краю
	var my_grid = get_current_grid_pos()
	var ground_grid_y := block_manager.floor_grid_y

	if my_grid.y < ground_grid_y - 1:
		print("[Stickman] Стою на высоте (Y=%d, пол Y=%d), ищу край для спрыгивания..." % [my_grid.y, ground_grid_y])

		# Ищем ближайший край слева и справа где нет твердого блока под ногами
		var left_edge = my_grid.x
		while block_manager.has_solid_block(Vector2i(left_edge, my_grid.y + 1)) and left_edge > 1:
			left_edge -= 1

		var right_edge = my_grid.x
		var max_cols = int(DisplayServer.screen_get_size().x / float(block_manager.block_size)) - 2
		while block_manager.has_solid_block(Vector2i(right_edge, my_grid.y + 1)) and right_edge < max_cols:
			right_edge += 1

		var jump_x = left_edge if abs(left_edge - my_grid.x) <= abs(right_edge - my_grid.x) else right_edge
		print("[Stickman] Иду к краю крыши X=%d чтобы спрыгнуть на пол" % jump_x)
		await walk_to_grid_x(jump_x)

		# Шаг вперед и прыжок вниз
		var drop_dir = -1.0 if jump_x < my_grid.x else 1.0
		velocity.x = drop_dir * (walk_speed * 1.2)
		velocity.y = -60.0
		play_animation("jump")

		var wait_time = 0.0
		while not is_on_floor() and wait_time < 2.5:
			await get_tree().physics_frame
			wait_time += 0.016

		velocity = Vector2.ZERO
		play_animation("idle")
		print("[Stickman] Успешно приземлился на землю!")

## Находит лучшую свободную позицию X рядом с целью, не упираясь в блоки
func find_best_stand_x(target_x: int) -> int:
	var my_x = get_current_grid_pos().x
	var my_y = get_current_grid_pos().y
	# Не даём цели уйти за край экрана — там walk_to_grid_x виснет у стены
	var max_cols := int(DisplayServer.screen_get_size().x / float(block_manager.block_size)) - 2
	var candidates: Array[int] = []
	if my_x <= target_x:
		candidates = [target_x - 1, target_x - 2, target_x + 1, target_x + 2]
	else:
		candidates = [target_x + 1, target_x + 2, target_x - 1, target_x - 2]

	for cx in candidates:
		var clamped := clampi(cx, 1, maxi(1, max_cols))
		if not block_manager.has_solid_block(Vector2i(clamped, my_y)):
			return clamped
	return clampi(candidates[0], 1, maxi(1, max_cols))

## Проверка досягаемости блока руками стикмена
func can_reach_block(target_pos: Vector2i) -> bool:
	var my_grid = get_current_grid_pos()
	var dx = abs(target_pos.x - my_grid.x)
	var dy = my_grid.y - target_pos.y # положительно, если цель выше ног
	return dx <= REACH_X and dy >= -REACH_DOWN and dy <= REACH_UP

## Выполнение анимации Place_BreakBlock и действия с блоком
func perform_action_at_block(pos: Vector2i, action: String, block_type: String = "") -> void:
	# Поворачиваемся к блоку
	update_facing(pos.x - get_current_grid_pos().x)
	
	# Играем анимацию Place_BreakBlock
	play_animation("place_break_block")
	await get_tree().create_timer(0.35).timeout
	
	if action == "break":
		block_manager.break_block(pos)
	elif action == "place":
		block_manager.place_block(pos, block_type)
		
	await get_tree().create_timer(0.15).timeout
	play_animation("idle")

## Подъем по временному столбу вверх (Jump + Scaffold Placement)
func build_scaffold_up() -> void:
	var current_grid = get_current_grid_pos()
	var scaffold_pos = current_grid # ставим блок прямо под ноги
	
	# Поднимаем стикмена ДО установки блока с небольшим запасом, чтобы гарантированно не застрять
	global_position.y -= float(block_manager.block_size + 4)
	
	play_animation("place_break_block")
	var scaffold_block = block_manager.place_block(scaffold_pos, "scaffold")
	scaffold_blocks.append(scaffold_pos)
	
	await get_tree().create_timer(0.2).timeout
	play_animation("idle")

## Разбор всех строительных лесов сверху вниз и спуск на землю
func dismantle_all_scaffolding() -> void:
	# Ломаем блоки столба сверху вниз (от меньшего Y к большему)
	scaffold_blocks.sort_custom(func(a, b): return int(a.y) - int(b.y))
	
	for scaffold_pos in scaffold_blocks:
		var bl := block_manager.get_block(scaffold_pos)
		# Ломаем ТОЛЬКО свои леса: ячейку мог уже занять готовый блок постройки!
		if bl != null and bl.block_type == "scaffold":
			play_animation("place_break_block")
			await get_tree().create_timer(0.25).timeout
			block_manager.break_block(scaffold_pos)
			await get_tree().create_timer(0.15).timeout
			
	scaffold_blocks.clear()
	play_animation("idle")
	
	# Ждем приземления под гравитацией
	var wait_time = 0.0
	while not is_on_floor() and wait_time < 2.0:
		await get_tree().process_frame
		wait_time += 0.016

## Плавное перемещение стикмена к определенной колонке сетки
func walk_to_grid_x(target_grid_x: int) -> void:
	var target_x = (target_grid_x + 0.5) * block_manager.block_size
	var timeout = 6.0  # Увеличил с 4 до 6 секунд
	var stuck_check_counter = 0
	var last_pos = global_position.x
	var no_progress_count = 0

	while abs(global_position.x - target_x) > 16.0 and timeout > 0:
		var dir = 1.0 if target_x > global_position.x else -1.0
		velocity.x = dir * walk_speed
		update_facing(dir)
		play_animation("walk")

		# Если уперлись в препятствие при ходьбе - пробуем перепрыгнуть
		if is_on_wall() and is_on_floor():
			velocity.y = jump_velocity
			play_animation("jump")

		await get_tree().physics_frame
		timeout -= 0.016
		stuck_check_counter += 1

		# Проверяем прогресс каждые 30 кадров (~0.5 сек)
		if stuck_check_counter >= 30:
			stuck_check_counter = 0
			if abs(global_position.x - last_pos) < 5.0:
				no_progress_count += 1
				if no_progress_count >= 3:
					print("[Stickman] Препятствие непреодолимо при ходьбе к X=%d, завершаем движение" % target_grid_x)
					break
			else:
				no_progress_count = 0
			last_pos = global_position.x

	velocity.x = 0
	play_animation("idle")

func get_current_grid_pos() -> Vector2i:
	if not block_manager:
		return Vector2i.ZERO
	# Позиция ног стикмена
	return block_manager.world_to_grid(global_position + Vector2(0, -4))

# --- Drag & Drop мышью и переключение слоев колесиком ---
func _on_mouse_entered() -> void:
	is_hovered = true

func _on_mouse_exited() -> void:
	is_hovered = false

func _on_click_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.is_pressed():
		if event.button_index == MOUSE_BUTTON_LEFT:
			start_drag()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			# Колесико вверх: вытащить перед блоками
			set_depth_layer(DepthLayer.FOREGROUND)
			print("[Stickman] %s выдвинут на передний план (FOREGROUND)" % name)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			# Колесико вниз: убрать за блоки
			set_depth_layer(DepthLayer.BACKGROUND)
			print("[Stickman] %s убран на задний план (BACKGROUND)" % name)
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			# Колесико нажатие: переключить на слой блоков
			cycle_depth_layer()

func _input(event: InputEvent) -> void:
	if is_dragging and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.is_pressed():
			stop_drag()

func start_drag() -> void:
	is_dragging = true
	is_busy_with_ai = false # Прерываем автоматическую стройку если игрок схватил стикмена
	last_mouse_pos = get_global_mouse_position()
	drag_offset = global_position - last_mouse_pos
	switch_state(State.DRAGGED)

func stop_drag() -> void:
	if not is_dragging:
		return
	is_dragging = false
	velocity = throw_velocity.clamp(Vector2(-1200, -1200), Vector2(1200, 1200))
	switch_state(State.JUMP)

func get_interaction_rect() -> Rect2:
	var height = _visual_height if _visual_height > 8.0 else 741.0 * character_scale
	var width = _visual_width if _visual_width > 8.0 else 220.0 * character_scale
	# Сузим область захвата до реальных границ стикмена.
	# Иначе polygon захватывает пустые зоны вокруг тела и создаёт «дыры»/слепые области.
	var pad_x: float = max(10.0, width * 0.15)
	var pad_y: float = max(8.0, height * 0.12)
	return Rect2(
		global_position.x - width * 0.5 + pad_x,
		global_position.y - height * 0.9 + pad_y,
		width - pad_x * 2.0,
		height - pad_y * 2.0
	)
	
