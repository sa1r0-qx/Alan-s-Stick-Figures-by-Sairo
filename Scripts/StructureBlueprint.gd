# Scripts/StructureBlueprint.gd
class_name StructureBlueprint
extends RefCounted

var name: String = "Structure"
var width: int = 5
var height: int = 4
# Список блоков: Array[Dictionary], где каждый элемент: {"x": int, "y": int, "type": String}
var blocks: Array[Dictionary] = []
# План движений и действий ИИ: Array[Dictionary], например:
# {"action": "walk_to", "x": 0}
# {"action": "place", "x": 0, "y": 0, "type": "stone"}
# {"action": "scaffold_up"}
# {"action": "jump_down"}
var steps: Array[Dictionary] = []

func _init(p_name: String = "Structure", p_width: int = 5, p_height: int = 4) -> void:
	name = p_name
	width = p_width
	height = p_height
	blocks = []
	steps = []

func add_block(x: int, y: int, block_type: String) -> void:
	blocks.append({
		"x": x,
		"y": y,
		"type": block_type
	})

func add_step(step_dict: Dictionary) -> void:
	steps.append(step_dict)

## Преобразует чертеж в мировые координаты сетки
func to_world_grid_blocks(ground_origin: Vector2i) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for b in blocks:
		var grid_x = ground_origin.x + b["x"]
		var grid_y = ground_origin.y - b["y"]
		result.append({
			"grid_pos": Vector2i(grid_x, grid_y),
			"type": b["type"]
		})
	return result

## Преобразует сгенерированный ИИ пошаговый план движений в мировые координаты
func to_world_steps(ground_origin: Vector2i) -> Array[Dictionary]:
	if steps.is_empty():
		generate_default_steps()
		
	var world_steps: Array[Dictionary] = []
	for s in steps:
		var action = str(s.get("action", ""))
		match action:
			"walk_to":
				world_steps.append({
					"action": "walk_to",
					"grid_x": ground_origin.x + int(s.get("x", 0))
				})
			"place":
				var bx = int(s.get("x", 0))
				var by = int(s.get("y", 0))
				world_steps.append({
					"action": "place",
					"grid_pos": Vector2i(ground_origin.x + bx, ground_origin.y - by),
					"type": str(s.get("type", "stone"))
				})
			"break":
				var bx = int(s.get("x", 0))
				var by = int(s.get("y", 0))
				world_steps.append({
					"action": "break",
					"grid_pos": Vector2i(ground_origin.x + bx, ground_origin.y - by)
				})
			"scaffold_up":
				world_steps.append({"action": "scaffold_up"})
			"jump_down":
				world_steps.append({"action": "jump_down"})
	return world_steps

## Автогенерация последовательного плана, если модель вернула только блоки
func generate_default_steps() -> void:
	steps.clear()
	# Сортируем снизу вверх (y=0, 1, 2...)
	var sorted_blocks = blocks.duplicate()
	sorted_blocks.sort_custom(func(a, b): return int(a["y"]) - int(b["y"]))
	
	var current_y = 0
	var is_elevated = false
	
	for b in sorted_blocks:
		var by = int(b["y"])
		var bx = int(b["x"])
		
		# Если блоки перешли на верхний ярус (y >= 3) и мы еще не поднялись
		if by >= 3 and not is_elevated:
			steps.append({"action": "scaffold_up"})
			is_elevated = true
		elif by < 2 and is_elevated:
			# Если блок снова внизу — спрыгиваем!
			steps.append({"action": "jump_down"})
			is_elevated = false
			
		steps.append({
			"action": "place",
			"x": bx,
			"y": by,
			"type": b["type"]
		})
		
	# Всегда завершаем постройку спуском на землю!
	steps.append({"action": "jump_down"})
