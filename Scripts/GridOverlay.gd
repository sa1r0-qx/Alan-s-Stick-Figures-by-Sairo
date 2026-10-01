# Scripts/GridOverlay.gd
class_name GridOverlay
extends Node2D

@export var block_size: int = 32
@export var show_full_grid: bool = false
@export var grid_color: Color = Color(1.0, 1.0, 1.0, 0.15)
@export var hover_valid_color: Color = Color(0.2, 0.9, 0.3, 0.7)
@export var hover_occupied_color: Color = Color(0.95, 0.25, 0.25, 0.7)

var current_grid_pos: Vector2i = Vector2i.ZERO
var is_hovering: bool = false
var is_occupied: bool = false
var block_manager: BlockManager = null

func _ready() -> void:
	z_index = 100 # Рисуем поверх блоков

func update_cursor(mouse_pos: Vector2, occupied: bool, active: bool) -> void:
	is_hovering = active
	is_occupied = occupied
	if block_manager:
		current_grid_pos = block_manager.world_to_grid(mouse_pos)
	else:
		current_grid_pos = Vector2i(
			int(floor(mouse_pos.x / float(block_size))),
			int(floor(mouse_pos.y / float(block_size)))
		)
	queue_redraw()

func toggle_full_grid() -> void:
	show_full_grid = not show_full_grid
	queue_redraw()

func _draw() -> void:
	var viewport_size = get_viewport_rect().size
	
	# Отрисовка полной сетки (по желанию или по горячей клавише G)
	if show_full_grid:
		var cols = int(ceil(viewport_size.x / float(block_size)))
		for c in range(cols + 1):
			var x = float(c) * float(block_size)
			draw_line(Vector2(x, 0), Vector2(x, viewport_size.y), grid_color, 1.0)
			
		var base_y = block_manager.ground_y if block_manager else viewport_size.y
		var y = base_y
		while y >= 0:
			draw_line(Vector2(0, y), Vector2(viewport_size.x, y), grid_color, 1.0)
			y -= float(block_size)
		y = base_y + float(block_size)
		while y <= viewport_size.y:
			draw_line(Vector2(0, y), Vector2(viewport_size.x, y), grid_color, 1.0)
			y += float(block_size)
	
	# Отрисовка только при активном наведении на интерактивную область
	if is_hovering:
		var tile_rect: Rect2
		if block_manager:
			var pivot := block_manager.grid_to_world(current_grid_pos)
			tile_rect = Rect2(pivot.x - float(block_size) * 0.5, pivot.y - float(block_size), float(block_size), float(block_size))
		else:
			var tile_origin = Vector2(current_grid_pos * block_size)
			tile_rect = Rect2(tile_origin, Vector2(block_size, block_size))
		var color = hover_occupied_color if is_occupied else hover_valid_color
		
		# Полупрозрачная заливка
		draw_rect(tile_rect, Color(color.r, color.g, color.b, 0.25))
		# Четкая рамка
		draw_rect(tile_rect, color, false, 2.0)
