# Scripts/Main.gd
class_name Main
extends Node2D

@export var block_size: int = 32
@export var taskbar_offset: int = 45
@export var ground_offset: float = 2.5 # Опускает пол на панель задач (устраняет зазор)

var build_mode: bool = false
var selected_block_id: String = ""
var is_mouse_captured: bool = false
var world_size: Vector2 = Vector2(1920, 1080)
var ground_y: float = 1080.0
var is_team_building: bool = false
var previous_team_blocks: Array[Vector2i] = []
var active_team_structure_name: String = ""

# Селективный оверлей: пустые места пропускают клики в систему,
# стикмены/блоки/HUD остаются интерактивными.
var _passthrough_applied: bool = false
var _has_native_passthrough: bool = false
var _hover_grow: float = 6.0
# Анти-дребезг переключения Win32-флагов: каждый флип WS_EX_TRANSPARENT
# дёргает DWM, поэтому переключаем только устоявшееся состояние.
var _pending_passthrough: bool = false
var _pending_frames: int = 0
var _last_toggle_msec: int = 0
const HOVER_CONFIRM_FRAMES: int = 4
const TOGGLE_COOLDOWN_MS: int = 250

# Интерактив с окнами приложений: платформы по верху окон + редкие закрытия
var allow_window_close: bool = true
var _window_rects: Array = [] # Array[Dictionary] {hwnd: int, rect: Rect2} в мировых координатах
var _platforms_sig: String = ""
var _rects_timer: float = 0.0
const RECTS_REFRESH_SEC: float = 1.0
const MAX_WINDOW_PLATFORMS: int = 32

@onready var ai_service: AIService = $AIService
@onready var block_manager: BlockManager = $BlockManager
@onready var grid_overlay: GridOverlay = $GridOverlay
@onready var hud: CanvasLayer = $HUD
@onready var hud_panel: Control = $HUD/Panel
@onready var mode_label: Label = $HUD/Panel/VBox/ModeLabel
@onready var ai_status_label: Label = $HUD/Panel/VBox/AIStatusLabel
@onready var blocks_label: Label = $HUD/Panel/VBox/BlocksLabel
@onready var help_label: Label = $HUD/Panel/VBox/HelpLabel
@onready var title_label: Label = $HUD/Panel/VBox/TitleLabel
@onready var chaos_btn: Button = $HUD/Panel/VBox/ChaosBtn
@onready var window_platforms: StaticBody2D = $WindowPlatforms

func _ready() -> void:
	setup_overlay_window()
	setup_screen_boundaries()
	
	block_manager.block_size = block_size
	block_manager.ground_y = ground_y
	grid_overlay.block_size = block_size
	grid_overlay.block_manager = block_manager
	
	# Инициализируем всех стикменов со сцены, сохраняя их расстановку по X
	for sm in get_tree().get_nodes_in_group("stickmen"):
		if sm is Stickman:
			initialize_stickman(sm)
			sm.global_position.y = ground_y - 5.0
	
	block_manager.block_list_updated.connect(_on_block_list_updated)
	_on_block_list_updated(block_manager.block_names)
	
	var exit_btn = get_node_or_null("HUD/Panel/VBox/ExitBtn")
	if exit_btn:
		exit_btn.pressed.connect(func(): get_tree().quit())
	if is_instance_valid(chaos_btn):
		chaos_btn.toggled.connect(_on_chaos_toggled)
		
	update_hud()
	
	# user:// должен существовать до старта helper'а: .NET не создаёт папки сам
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://"))
	# Проверяем нативный GDExtension для мгновенного click-through
	_has_native_passthrough = Engine.has_singleton("MousePassthrough")
	print("[Main] Native MousePassthrough: ", _has_native_passthrough)
	# Запуск нативного фонового Win32-помощника для клик-сквозь в Windows без клиппинга
	start_window_helper()
	_write_boot_log("ready")
	# Окно стартует интерактивным; селективный passthrough подхватит _process
	_passthrough_applied = false
	print("[Main] Desktop pet готов. Мир: %s, пол Y: %s" % [world_size, ground_y])

func setup_overlay_window() -> void:
	var win := get_window()
	get_tree().root.transparent_bg = true
	win.transparent = true
	win.borderless = true
	win.always_on_top = true
	win.mode = Window.MODE_FULLSCREEN

	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_TRANSPARENT, true)

	var screen_idx := DisplayServer.window_get_current_screen()
	var screen_pos := DisplayServer.screen_get_position(screen_idx)
	var screen_size := DisplayServer.screen_get_size(screen_idx)
	
	win.position = screen_pos
	win.size = screen_size
	world_size = Vector2(screen_size)
	
	var usable := DisplayServer.screen_get_usable_rect(screen_idx)
	var taskbar_top := float(usable.position.y + usable.size.y)
	if taskbar_top <= 0.0 or taskbar_top >= float(screen_size.y):
		# Если система не вернула usable_rect для таскбара, используем дефолтный taskbar_offset
		ground_y = world_size.y - float(taskbar_offset) + ground_offset
	else:
		# Опускаем точно на верхний край таскбара + небольшой оффсет для идеального приземления ног
		ground_y = taskbar_top + ground_offset
	print("[Main] Оверлей %s на экране %s, usable=%s, ground_y=%.1f" % [Rect2i(screen_pos, screen_size), screen_idx, usable, ground_y])

func setup_screen_boundaries() -> void:
	var old := get_node_or_null("ScreenBoundaries")
	if old:
		old.queue_free()
	
	var bounds_body := StaticBody2D.new()
	bounds_body.name = "ScreenBoundaries"
	bounds_body.collision_layer = 1
	bounds_body.collision_mask = 0
	add_child(bounds_body)
	
	var floor_shape := RectangleShape2D.new()
	floor_shape.size = Vector2(world_size.x + 400.0, 64.0)
	var floor_col := CollisionShape2D.new()
	floor_col.shape = floor_shape
	floor_col.position = Vector2(world_size.x * 0.5, ground_y + 32.0)
	bounds_body.add_child(floor_col)
	
	var wall_shape := RectangleShape2D.new()
	wall_shape.size = Vector2(64.0, world_size.y + 400.0)
	
	var left_col := CollisionShape2D.new()
	left_col.shape = wall_shape
	left_col.position = Vector2(-32.0, world_size.y * 0.5)
	bounds_body.add_child(left_col)
	
	var right_col := CollisionShape2D.new()
	right_col.shape = wall_shape
	right_col.position = Vector2(world_size.x + 32.0, world_size.y * 0.5)
	bounds_body.add_child(right_col)

func _process(_delta: float) -> void:
	# 1. Проверяем сообщения от нативного фонового Win32-помощника (user:// — пишется и в экспорте)
	var msg_path := ProjectSettings.globalize_path(ipc_path(".window_msg.txt"))
	if FileAccess.file_exists(msg_path):
		var msg_content := FileAccess.get_file_as_string(msg_path).strip_edges().to_lower()
		DirAccess.remove_absolute(msg_path)
		if msg_content == "toggle_hud":
			toggle_hud_mode()
		elif msg_content == "exit":
			get_tree().quit()

	if not is_instance_valid(grid_overlay) or not is_instance_valid(block_manager):
		return
		
	var local_mouse := screen_to_world(DisplayServer.mouse_get_position())
	var hover_block = block_manager.has_block(block_manager.world_to_grid(local_mouse))
	
	if build_mode:
		grid_overlay.update_cursor(local_mouse, hover_block, true)
	else:
		grid_overlay.update_cursor(local_mouse, false, false)

	update_selective_clickthrough(local_mouse)

	_rects_timer += _delta
	if _rects_timer >= RECTS_REFRESH_SEC:
		_rects_timer = 0.0
		refresh_window_platforms()

func screen_to_world(global_mouse: Vector2i) -> Vector2:
	var local := Vector2(global_mouse - DisplayServer.window_get_position())
	return get_canvas_transform().affine_inverse() * local

func toggle_hud_mode() -> void:
	hud.visible = not hud.visible
	if not hud.visible and build_mode:
		build_mode = false
	update_hud()
	# passthrough пересчитается в следующем _process через update_selective_clickthrough
	print("[Main] Режим подсказок: ", "ВКЛ (Управление доступно)" if hud.visible else "ВЫКЛ (Свободный режим, клики проходят в систему!)")

func cycle_all_stickmen_layers() -> void:
	var next_layer_name := ""
	for sm in get_tree().get_nodes_in_group("stickmen"):
		if sm is Stickman:
			sm.cycle_depth_layer()
			match sm.depth_layer:
				Stickman.DepthLayer.FOREGROUND:
					next_layer_name = "ПЕРЕД БЛОКАМИ (Не застревает)"
				Stickman.DepthLayer.BLOCKS:
					next_layer_name = "НА СЛОЕ БЛОКОВ (Интерактив)"
				Stickman.DepthLayer.BACKGROUND:
					next_layer_name = "ЗА БЛОКАМИ (Тень)"
	print("[Main] Слой стикменов: ", next_layer_name)
	update_hud()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		# Аварийный безопасный выход без необходимости перезагрузки ПК
		if event.keycode == KEY_ESCAPE and event.shift_pressed:
			print("[Main] Выход из программы по Shift+Esc")
			get_tree().quit()
			return

		if event.keycode == KEY_H:
			toggle_hud_mode()
			return
			
		# Кнопки работают ТОЛЬКО в режиме подсказки (когда HUD включен)
		if not hud.visible:
			return
			
		if event.keycode == KEY_L:
			cycle_all_stickmen_layers()
		elif event.keycode == KEY_T:
			if not is_team_building:
				print("[Main] Запуск генерации большой структуры для команды стикменов (T)...")
				start_cooperative_build()
			else:
				print("[Main] Стикмены уже заняты командной стройкой!")
		elif event.keycode == KEY_B:
			build_mode = not build_mode
			update_hud()
			print("[Main] Ручной режим стройки: ", "ВКЛ" if build_mode else "ВЫКЛ")
		elif event.keycode == KEY_G:
			grid_overlay.toggle_full_grid()
		elif event.keycode == KEY_X:
			set_chaos_enabled(not allow_window_close)
			print("[Main] Хаос окон: ", "ВКЛ" if allow_window_close else "ВЫКЛ")
	
	if build_mode and event is InputEventMouseButton and event.is_pressed():
		var mouse_pos := screen_to_world(DisplayServer.mouse_get_position())
		var grid_pos := block_manager.world_to_grid(mouse_pos)
		if event.button_index == MOUSE_BUTTON_LEFT:
			# ЛКМ: Ставим выбранный строительный блок (или заделываем дыру в рабочем столе)
			if not block_manager.has_block(grid_pos):
				block_manager.place_block(grid_pos, selected_block_id)
			elif block_manager.get_block(grid_pos).block_type == "void":
				block_manager.break_block(grid_pos)
				block_manager.place_block(grid_pos, selected_block_id)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			# ПКМ: Проламываем рабочий стол (ставим черный блок пустоты "void")
			if not block_manager.has_block(grid_pos):
				block_manager.place_block(grid_pos, "void")
				print("[Main] Пролом рабочего стола (черная пустота void): ", grid_pos)
			else:
				# Если кликаем ПКМ по уже стоящему блоку или пустоте — удаляем/заделываем
				block_manager.break_block(grid_pos)

func initialize_stickman(sm: Stickman) -> void:
	sm.block_manager = block_manager
	sm.ai_service = ai_service
	sm.main_ref = self

## Запуск одной общей большой постройки для всех 5 стикменов
func start_cooperative_build(theme_hint: String = "") -> void:
	if is_team_building:
		return
		
	var stickmen: Array[Stickman] = []
	for sm in get_tree().get_nodes_in_group("stickmen"):
		if sm is Stickman:
			stickmen.append(sm)
			
	if stickmen.is_empty():
		print("[Main] На сцене нет стикменов для стройки!")
		return
		
	is_team_building = true
	for sm in stickmen:
		sm.is_busy_with_ai = true
		sm.switch_state(Stickman.State.WORKING)
		sm.velocity = Vector2.ZERO
		sm.play_animation("idle")
		
	if ai_status_label:
		ai_status_label.text = "ИИ: Проектирование большой структуры для команды из %d стикменов..." % stickmen.size()
		ai_status_label.modulate = Color(1.0, 0.7, 0.2)
		
	var available: Array[String] = []
	for bname in block_manager.block_names:
		available.append(bname)
		
	var on_bp: Callable = func(bp: StructureBlueprint):
		_execute_team_construction(bp, stickmen)
		
	ai_service.blueprint_ready.connect(on_bp, CONNECT_ONE_SHOT)
	ai_service.request_structure(available, theme_hint)

func _execute_team_construction(blueprint: StructureBlueprint, stickmen: Array[Stickman]) -> void:
	active_team_structure_name = blueprint.name
	if ai_status_label:
		ai_status_label.text = "ИИ: Команда из %d стикменов строит '%s'..." % [stickmen.size(), blueprint.name]
		ai_status_label.modulate = Color(1.0, 0.7, 0.2)
	print("[Main] Начинается совместное строительство '%s' силами %d стикменов!" % [blueprint.name, stickmen.size()])

	# 1. ФИЗИЧЕСКИЙ СНОС предыдущей командной постройки самими стикменами
	if not previous_team_blocks.is_empty():
		var demo_tasks: Array[Dictionary] = []
		for bpos in previous_team_blocks:
			var old := block_manager.get_block(bpos)
			# Дыры в столе команда не трогает — сносит только свои блоки
			if old != null and old.block_type != "void":
				demo_tasks.append({"grid_pos": bpos})
		previous_team_blocks.clear()
		if not demo_tasks.is_empty():
			if ai_status_label:
				ai_status_label.text = "ИИ: Команда разбирает старую постройку (%d блоков)..." % demo_tasks.size()
			print("[Main] Команда сносит старую постройку своими руками: %d блоков" % demo_tasks.size())
			_launch_team_phase(stickmen, demo_tasks, "demolish")
			await _await_team_idle(stickmen, 120.0)

	# 2. Вычисляем точку привязки (по центру экрана на уровне пола)
	var screen_cols := int(floor(world_size.x / float(block_size)))
	var origin_x: int = max(2, int((screen_cols - blueprint.width) * 0.5))
	var floor_gy := block_manager.floor_grid_y
	var ground_origin := Vector2i(origin_x, floor_gy)

	var all_tasks := blueprint.to_world_grid_blocks(ground_origin)
	for t in all_tasks:
		previous_team_blocks.append(t["grid_pos"])

	# 3. Сортируем стикменов слева направо по X
	stickmen.sort_custom(func(a, b): return a.global_position.x < b.global_position.x)
	var n := stickmen.size()

	# 4. Распределяем блоки по горизонтальным секторам между стикменами
	var width_per_worker: float = max(1.0, float(blueprint.width) / float(n))
	var worker_tasks: Array[Array] = []
	for i in range(n):
		worker_tasks.append([])

	for task in all_tasks:
		var pos: Vector2i = task["grid_pos"]
		var worker_idx := int(floor(float(pos.x - origin_x) / width_per_worker))
		worker_idx = clamp(worker_idx, 0, n - 1)
		worker_tasks[worker_idx].append(task)

	# 5. Запуск всех стикменов на одновременное строительство + ожидание финала
	_launch_team_phase(stickmen, worker_tasks_flat(stickmen, worker_tasks), "build", blueprint.name)
	var finished_clean := await _await_team_idle(stickmen, 300.0)
	if not finished_clean:
		print("[Main] Фаза стройки упёрлась в таймаут, workers освобождены принудительно")
	# 6. Добивка: один повторный проход по всем недостающим клеткам
	var wanted := {}
	for t in all_tasks:
		var wp: Vector2i = t["grid_pos"]
		wanted[wp] = str(t["type"])
	var missing_tasks: Array[Dictionary] = []
	for t in all_tasks:
		var want_pos: Vector2i = t["grid_pos"]
		var want_type: String = str(t["type"])
		var have := block_manager.get_block(want_pos)
		if have == null or have.block_type != want_type:
			missing_tasks.append({"grid_pos": want_pos, "type": want_type})
	if not missing_tasks.is_empty():
		print("[Main] Добивка: %d недостающих блоков, второй проход" % missing_tasks.size())
		_launch_team_phase(stickmen, missing_tasks, "build", blueprint.name)
		await _await_team_idle(stickmen, 180.0)
	# 7. Финальная зачистка: внутри рамки постройки не должно быть ничего лишнего
	# (пропущенные при сносе обломки, чужие леса) — иначе вид "незаконченности"
	var bx0 := 1 << 30
	var bx1 := -(1 << 30)
	var by0 := 1 << 30
	var by1 := -(1 << 30)
	for t in all_tasks:
		var gp: Vector2i = t["grid_pos"]
		bx0 = mini(bx0, gp.x)
		bx1 = maxi(bx1, gp.x)
		by0 = mini(by0, gp.y)
		by1 = maxi(by1, gp.y)
	var garbage: Array[Dictionary] = []
	for pos in block_manager.placed_blocks.keys():
		var p: Vector2i = pos
		if p.x < bx0 or p.x > bx1 or p.y < by0 or p.y > by1:
			continue
		var want: String = str(wanted.get(p, ""))
		var have2 := block_manager.get_block(p)
		if have2 == null:
			continue
		# Дыры void — повреждения стола, а не мусор стройки: не трогаем
		if have2.block_type == "void":
			continue
		if want == "" or have2.block_type != want:
			garbage.append({"grid_pos": p})
	if not garbage.is_empty():
		print("[Main] Зачистка: сношу %d лишних блоков внутри рамки" % garbage.size())
		_launch_team_phase(stickmen, garbage, "demolish")
		await _await_team_idle(stickmen, 90.0)
	# Подсчёт реально недостающих блоков для честного статуса
	var missing := 0
	for t in all_tasks:
		var want_pos2: Vector2i = t["grid_pos"]
		var want_type2: String = str(t["type"])
		var have3 := block_manager.get_block(want_pos2)
		if have3 == null or have3.block_type != want_type2:
			missing += 1
	is_team_building = false
	if ai_status_label:
		if missing == 0:
			ai_status_label.text = "ИИ: Структура '%s' завершена всеми стикменами! (T - новая)" % blueprint.name
			ai_status_label.modulate = Color(0.3, 1.0, 0.5)
		else:
			ai_status_label.text = "ИИ: '%s' готова частично, не хватило %d блоков (T - перестроить)" % [blueprint.name, missing]
			ai_status_label.modulate = Color(1.0, 0.7, 0.2)
	update_hud()

## Раскладывает задачи по секторам между рабочими и запускает фазу (снос/стройка)
func _launch_team_phase(stickmen: Array[Stickman], tasks: Array, mode: String, bp_name: String = "") -> void:
	stickmen.sort_custom(func(a, b): return a.global_position.x < b.global_position.x)
	var n := stickmen.size()
	var min_x := 1 << 30
	var max_x := -(1 << 30)
	for t in tasks:
		var gp: Vector2i = t["grid_pos"]
		min_x = mini(min_x, gp.x)
		max_x = maxi(max_x, gp.x)
	if min_x > max_x:
		return
	var span: float = maxf(1.0, float(max_x - min_x + 1) / float(n))
	var buckets: Array[Array] = []
	for i in range(n):
		buckets.append([])
	for t in tasks:
		var gp2: Vector2i = t["grid_pos"]
		var idx := clampi(int(floor(float(gp2.x - min_x) / span)), 0, n - 1)
		buckets[idx].append(t)
	for i in range(n):
		var sm := stickmen[i]
		if buckets[i].is_empty():
			sm.is_busy_with_ai = false
			if sm.current_state == Stickman.State.WORKING:
				sm.switch_state(Stickman.State.IDLE)
			continue
		sm.is_busy_with_ai = true
		sm.switch_state(Stickman.State.WORKING)
		sm.velocity = Vector2.ZERO
		if mode == "demolish":
			var dtasks: Array[Dictionary] = []
			for t in buckets[i]:
				dtasks.append(t)
			_team_worker_demolish(sm, dtasks)
		else:
			var btasks: Array[Dictionary] = []
			for t in buckets[i]:
				btasks.append(t)
			_team_worker_build(sm, btasks)

## Совместимость: старая структура worker_tasks[i] уже посекторная — разворачиваем в плоский список
func worker_tasks_flat(_stickmen: Array[Stickman], worker_tasks: Array[Array]) -> Array:
	var flat: Array = []
	for bucket in worker_tasks:
		for t in bucket:
			flat.append(t)
	return flat

func _team_worker_build(sm: Stickman, tasks: Array[Dictionary]) -> void:
	await sm.construct_structure(tasks)
	sm.is_busy_with_ai = false
	if sm.current_state == Stickman.State.WORKING:
		sm.switch_state(Stickman.State.IDLE)

func _team_worker_demolish(sm: Stickman, tasks: Array[Dictionary]) -> void:
	await sm.dismantle_tasks(tasks)
	sm.is_busy_with_ai = false
	if sm.current_state == Stickman.State.WORKING:
		sm.switch_state(Stickman.State.IDLE)

## Ждёт простоя команды; при таймауте принудительно освобождает (не висим вечно).
## Возвращает true если все закончили сами.
func _await_team_idle(stickmen: Array[Stickman], timeout_sec: float) -> bool:
	var elapsed := 0.0
	while elapsed < timeout_sec:
		var busy := false
		for sm in stickmen:
			if is_instance_valid(sm) and sm.is_busy_with_ai:
				busy = true
				break
		if not busy:
			return true
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	for sm in stickmen:
		if is_instance_valid(sm):
			sm.is_busy_with_ai = false
			sm.switch_state(Stickman.State.IDLE)
	return false

func _on_block_list_updated(names: Array[String]) -> void:
	if not names.is_empty():
		selected_block_id = names[0]
	update_hud()

func update_hud() -> void:
	if is_instance_valid(title_label):
		title_label.text = "★ Alan Becker Stick Figure Pet [окна v4]"
	if mode_label:
		if build_mode:
			mode_label.text = "РЕЖИМ: РУЧНАЯ СТРОЙКА (ЛКМ - блок, ПКМ - пролом рабочего стола [void])"
			mode_label.modulate = Color(0.3, 1.0, 0.4)
		else:
			var layer_str := "ПЕРЕД БЛОКАМИ"
			for sm in get_tree().get_nodes_in_group("stickmen"):
				if sm is Stickman:
					match sm.depth_layer:
						Stickman.DepthLayer.FOREGROUND: layer_str = "ПЕРЕД БЛОКАМИ"
						Stickman.DepthLayer.BLOCKS: layer_str = "НА БЛОКАХ"
						Stickman.DepthLayer.BACKGROUND: layer_str = "ЗА БЛОКАМИ"
					break
			mode_label.text = "ПОДСКАЗКА [T: ИИ | B: Ручная | L: Слой (%s) | H: Свободный режим | Shift+Esc: Выход]" % layer_str
			mode_label.modulate = Color(0.8, 0.9, 1.0)
	
	if ai_status_label:
		var free_count := 0
		var total_count := 0
		for sm in get_tree().get_nodes_in_group("stickmen"):
			if sm is Stickman:
				total_count += 1
				if not sm.is_busy_with_ai:
					free_count += 1
		
		var pname := "Автономный (Offline)"
		if is_instance_valid(ai_service):
			if ai_service.provider == AIService.Provider.GOOGLE_GEMINI:
				pname = "Gemini 3.5 Flash"
			elif ai_service.provider == AIService.Provider.OLLAMA:
				pname = "Ollama (" + ai_service.ollama_model + ")"
		
		if total_count == 0:
			ai_status_label.text = "ИИ [%s]: Нет стикменов на сцене" % pname
			ai_status_label.modulate = Color(1.0, 0.4, 0.4)
		elif free_count > 0:
			ai_status_label.text = "ИИ [%s]: Ожидание (%d/%d готово к стройке, нажмите T)" % [pname, free_count, total_count]
			ai_status_label.modulate = Color(0.4, 0.9, 1, 1)
		else:
			ai_status_label.text = "ИИ [%s]: Все стикмены заняты постройками..." % pname
			ai_status_label.modulate = Color(1.0, 0.7, 0.2)
	
	if blocks_label and is_instance_valid(block_manager):
		var count := block_manager.available_blocks.size()
		if count > 0:
			blocks_label.text = "Текстуры из папки: " + str(count) + " (" + ", ".join(block_manager.block_names.slice(0, 3)) + "...)"
		else:
			blocks_label.text = "Палитра материалов: " + ", ".join(block_manager.block_names)
		if is_instance_valid(window_platforms):
			blocks_label.text += " | Окон-платформ: %d" % window_platforms.get_child_count()

	if is_instance_valid(chaos_btn):
		chaos_btn.text = "Хаос окон: ВКЛ (X)" if allow_window_close else "Хаос окон: ВЫКЛ (X)"
	if is_instance_valid(help_label):
		help_label.text = "[T] Командная стройка | [B] Ручная | [L] Слой | [X] Хаос окон (%s) | [H] Свободный режим | Shift+Esc: Выход" % ("ВКЛ" if allow_window_close else "ВЫКЛ")

## WindowHelper нужен только как демон глобальных хоткеев (H / Shift+Esc):
## когда окно полностью прозрачно для кликов, Godot не получает ввод,
## и только helper может поймать клавиши и прислать .window_msg.txt.
## Флаги окна он больше не трогает — ими владеет GDExtension ниже.
func start_window_helper() -> void:
	var helper_exe := helper_exe_path()
	if helper_exe.is_empty():
		print("[Main] WindowHelper.exe не найден, хоткеи и платформы окон недоступны")
		return
	var native_hwnd: int = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
	var pid := OS.get_process_id()
	var cmd_path := ProjectSettings.globalize_path(ipc_path(".window_cmd.txt"))
	var msg_path := ProjectSettings.globalize_path(ipc_path(".window_msg.txt"))
	OS.create_process(helper_exe, [str(native_hwnd), str(pid), cmd_path, msg_path, "0", rects_path(), "500"])
	print("[Main] WindowHelper daemon запущен: HWND %d, PID %d" % [native_hwnd, pid])

## Helper ищется так: сначала распакованный из ресурсов (portable, работает
## с любого диска), затем рядом с игрой, затем в проекте (редактор)
func helper_exe_path() -> String:
	var deployed := ProjectSettings.globalize_path(ipc_path("bin/WindowHelper.exe"))
	if deploy_helper_exe(deployed):
		return deployed
	var beside := OS.get_executable_path().get_base_dir().path_join("Tools/WindowHelper.exe")
	if FileAccess.file_exists(beside):
		return beside
	var in_project := ProjectSettings.globalize_path("res://Tools/WindowHelper.exe")
	if FileAccess.file_exists(in_project):
		return in_project
	return ""

## Достаёт helper из res:// (включая .pck экспорта) в user://bin и держит свежим.
## Из .pck напрямую exe не запустить — нужна копия на диске.
func deploy_helper_exe(deployed_abs: String) -> bool:
	var bytes := WindowHelperEmbedded.get_bytes()
	if bytes.is_empty():
		return deploy_helper_from_file(deployed_abs)
	if FileAccess.file_exists(deployed_abs):
		var old := FileAccess.open(deployed_abs, FileAccess.READ)
		if old != null:
			var same := old.get_length() == bytes.size()
			old.close()
			if same:
				return true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ipc_path("bin")))
	var w := FileAccess.open(deployed_abs, FileAccess.WRITE)
	if w == null:
		return deploy_helper_from_file(deployed_abs)
	w.store_buffer(bytes)
	w.close()
	print("[Main] WindowHelper распакован (embedded) в: ", deployed_abs)
	return true

func deploy_helper_from_file(deployed_abs: String) -> bool:
	var src := "res://Tools/WindowHelper.exe"
	if not FileAccess.file_exists(src):
		return FileAccess.file_exists(deployed_abs)
	var r := FileAccess.open(src, FileAccess.READ)
	if r == null:
		return FileAccess.file_exists(deployed_abs)
	var fbytes := r.get_buffer(r.get_length())
	r.close()
	if fbytes.is_empty():
		return false
	if FileAccess.file_exists(deployed_abs):
		var old2 := FileAccess.open(deployed_abs, FileAccess.READ)
		if old2 != null:
			var same2 := old2.get_length() == fbytes.size()
			old2.close()
			if same2:
				return true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ipc_path("bin")))
	var w2 := FileAccess.open(deployed_abs, FileAccess.WRITE)
	if w2 == null:
		return false
	w2.store_buffer(fbytes)
	w2.close()
	print("[Main] WindowHelper распакован (файл) в: ", deployed_abs)
	return true

func set_system_clickthrough(enable_passthrough: bool) -> void:
	apply_passthrough(enable_passthrough)

func apply_passthrough(enable_passthrough: bool) -> void:
	if enable_passthrough == _passthrough_applied:
		return
	_passthrough_applied = enable_passthrough
	_pending_frames = 0
	if _has_native_passthrough and Engine.has_singleton("MousePassthrough"):
		# Единственный путь переключения: один флип флага на главном окне.
		# Через файл helper'а НЕ дублируем — иначе он дёргает весь tree окон,
		# делает SetForegroundWindow и даёт белую вспышку на каждый ховер.
		Engine.get_singleton("MousePassthrough").set_passthrough(get_window().get_window_id(), enable_passthrough)
	else:
		# Запасной путь, только если GDExtension недоступен
		var cmd_path := ProjectSettings.globalize_path(ipc_path(".window_cmd.txt"))
		var f := FileAccess.open(cmd_path, FileAccess.WRITE)
		if f:
			f.store_string("1" if enable_passthrough else "0")
			f.close()

## Дебаунс: состояние должно устояться HOVER_CONFIRM_FRAMES кадров подряд
## + пауза TOGGLE_COOLDOWN_MS после прошлого флипа. Иначе граница ховера
## дёргает DWM туда-сюда и мигает белым.
func request_passthrough(desired: bool) -> void:
	if desired == _passthrough_applied:
		_pending_frames = 0
		return
	if desired != _pending_passthrough:
		_pending_passthrough = desired
		_pending_frames = 0
	_pending_frames += 1
	if _pending_frames >= HOVER_CONFIRM_FRAMES and Time.get_ticks_msec() - _last_toggle_msec >= TOGGLE_COOLDOWN_MS:
		_last_toggle_msec = Time.get_ticks_msec()
		apply_passthrough(desired)

func rects_path() -> String:
	return ProjectSettings.globalize_path(ipc_path(".window_rects.txt"))

## IPC-файлы helper'а живут в user://: res:// в экспорте только для чтения,
## а helper'у и игре нужно и писать, и читать.
func ipc_path(file_name: String) -> String:
	return "user://".path_join(file_name)

## Читает дамп окон от helper'а и строит тонкие one-way платформы по верху окон.
## Стикмены стоят/ходят по окнам как по блокам; брошенный вверх падает на окно.
func refresh_window_platforms() -> void:
	if not is_instance_valid(window_platforms):
		return
	var rp := rects_path()
	if not FileAccess.file_exists(rp):
		return
	var text := FileAccess.get_file_as_string(rp).strip_edges()
	if text.is_empty() or not text.begins_with("["):
		return
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Array):
		return
	var items: Array = parsed
	var sig := ""
	var fresh: Array = []
	var count := 0
	for entry in items:
		if count >= MAX_WINDOW_PLATFORMS:
			break
		if not (entry is Dictionary):
			continue
		var hw: int = int(entry.get("hwnd", 0))
		var sx: int = int(entry.get("x", 0))
		var sy: int = int(entry.get("y", 0))
		var sw: int = int(entry.get("w", 0))
		var sh: int = int(entry.get("h", 0))
		if hw == 0 or sw < 60 or sh < 40:
			continue
		sig += "%d:%d,%d,%d,%d|" % [hw, sx, sy, sw, sh]
		# Углы через screen_to_world — корректно при любом масштабе вьюпорта
		var tl := screen_to_world(Vector2i(sx, sy))
		var tr := screen_to_world(Vector2i(sx + sw, sy))
		var bl := screen_to_world(Vector2i(sx, sy + sh))
		var ww: float = absf(tr.x - tl.x)
		var wh: float = absf(bl.y - tl.y)
		if ww < 4.0 or wh < 4.0:
			continue
		var cx: float = (tl.x + tr.x) * 0.5
		fresh.append({"hwnd": hw, "rect": Rect2(cx - ww * 0.5, tl.y, ww, wh)})
		count += 1
	if sig == _platforms_sig:
		return
	_platforms_sig = sig
	_window_rects = fresh
	write_platforms_debug(count)
	for child in window_platforms.get_children():
		child.queue_free()
	for item in _window_rects:
		var r: Rect2 = item["rect"]
		var shape := RectangleShape2D.new()
		shape.size = Vector2(r.size.x, 10.0)
		var col := CollisionShape2D.new()
		col.shape = shape
		col.position = Vector2(r.position.x + r.size.x * 0.5, r.position.y + 5.0)
		col.one_way_collision = true
		col.one_way_collision_margin = 8.0
		col.set_meta("hwnd", int(item["hwnd"]))
		window_platforms.add_child(col)
	_write_boot_log("refresh")

## Автодиагностика запуска: один файл со всеми ответами
func _write_boot_log(stage: String) -> void:
	var lines: Array[String] = []
	lines.append("build=окна v4 stage=" + stage)
	lines.append("user_dir=" + ProjectSettings.globalize_path("user://"))
	lines.append("helper=" + helper_exe_path())
	lines.append("rects_exists=" + str(FileAccess.file_exists(rects_path())))
	if is_instance_valid(block_manager):
		lines.append("textures=%d [%s]" % [block_manager.block_names.size(), ", ".join(block_manager.block_names)])
	if is_instance_valid(window_platforms):
		lines.append("platforms=%d" % window_platforms.get_child_count())
	var f := FileAccess.open(ProjectSettings.globalize_path(ipc_path(".boot_log.txt")), FileAccess.WRITE)
	if f:
		f.store_string("\n".join(lines) + "\n")
		f.close()

## Диагностика платформ: user://window_platforms_debug.txt + счётчик в HUD
func write_platforms_debug(entry_count: int) -> void:
	var dbg := ProjectSettings.globalize_path(ipc_path(".window_platforms_debug.txt"))
	var f := FileAccess.open(dbg, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("rects=%d sig_len=%d children=%d winpos=%s winsize=%s view=%s\n" % [
		entry_count, _platforms_sig.length(), window_platforms.get_child_count(),
		str(DisplayServer.window_get_position()), str(DisplayServer.window_get_size()),
		str(get_viewport_rect().size)])
	for i in range(mini(5, _window_rects.size())):
		var r: Rect2 = _window_rects[i]["rect"]
		f.store_string("  [%d] hwnd=%d world=%s\n" % [i, int(_window_rects[i]["hwnd"]), str(r)])
	f.close()
	print("[Main] Платформы окон: %d шт, коллизий: %d" % [entry_count, window_platforms.get_child_count()])

## HWND верхнего окна под мировой точкой (0 — нет окна)
func window_hwnd_at(world_pos: Vector2) -> int:
	for item in _window_rects:
		var r: Rect2 = item["rect"]
		if r.has_point(world_pos):
			return int(item["hwnd"])
	return 0

## Просьба helper'у вежливо закрыть окно (идёт через cmd-файл, passthrough не трогает)
func request_close_window(hwnd: int) -> void:
	if hwnd == 0:
		return
	var cmd_path := ProjectSettings.globalize_path(ipc_path(".window_cmd.txt"))
	var f := FileAccess.open(cmd_path, FileAccess.WRITE)
	if f:
		f.store_string("close:" + str(hwnd))
		f.close()

func _on_chaos_toggled(on: bool) -> void:
	allow_window_close = on
	update_hud()

func set_chaos_enabled(on: bool) -> void:
	allow_window_close = on
	if is_instance_valid(chaos_btn):
		chaos_btn.set_pressed_no_signal(on)
	update_hud()

## Каждый кадр решаем: пропускать клик в систему или ловить самим.
## Пустые места -> passthrough ON. Стикмены/блоки/HUD/drag/build_mode -> OFF.
func update_selective_clickthrough(world_mouse: Vector2) -> void:
	# В ручной стройке всё окно интерактивное (ставим блоки по пустому месту)
	if build_mode:
		request_passthrough(false)
		return
	# Пока тащим стикмена — держим захват, иначе release не долетит
	for sm in get_tree().get_nodes_in_group("stickmen"):
		if sm is Stickman and sm.is_dragging:
			request_passthrough(false)
			return
	var want_interactive := false
	# 1. HUD панель
	if hud.visible and is_instance_valid(hud_panel):
		var canvas_mouse: Vector2 = get_canvas_transform().affine_inverse() * (Vector2(DisplayServer.mouse_get_position() - DisplayServer.window_get_position()))
		if hud_panel.get_global_rect().has_point(canvas_mouse):
			want_interactive = true
	# 2. Стикмены
	if not want_interactive:
		for sm in get_tree().get_nodes_in_group("stickmen"):
			if sm is Stickman and sm.get_interaction_rect().grow(_hover_grow).has_point(world_mouse):
				want_interactive = true
				break
	# 3. Блоки (чтобы ломать/чинить их мышью). Дыры void — не блоки: клики сквозь них идут в систему
	if not want_interactive and is_instance_valid(block_manager):
		for pos in block_manager.placed_blocks:
			var b: Block = block_manager.placed_blocks[pos]
			if is_instance_valid(b) and b.block_type != "void" and (b as Block).get_rect_global().grow(2.0).has_point(world_mouse):
				want_interactive = true
				break
	request_passthrough(not want_interactive)
