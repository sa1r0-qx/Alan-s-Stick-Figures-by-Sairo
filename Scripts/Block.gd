# Scripts/Block.gd
class_name Block
extends StaticBody2D

signal block_clicked(grid_pos: Vector2i, mouse_button: int)

@export var block_size: int = 32
@export var block_type: String = "default"

var grid_position: Vector2i = Vector2i.ZERO
var is_destroying: bool = false

@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var sprite: Sprite2D = $Sprite2D
@onready var color_rect: ColorRect = $ColorRect
@onready var border_rect: ReferenceRect = $ReferenceRect

func _ready() -> void:
	var shape = RectangleShape2D.new()
	shape.size = Vector2(block_size, block_size)
	collision_shape.shape = shape
	collision_shape.position = Vector2(0, -block_size * 0.5)
	collision_shape.one_way_collision = true
	collision_shape.one_way_collision_margin = 8.0
	
	if block_type == "void":
		z_index = -1
		collision_layer = 0
		collision_mask = 0
		collision_shape.disabled = true
	else:
		z_index = 0
		collision_layer = 2
		collision_mask = 0
		collision_shape.disabled = false

	if color_rect:
		color_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		color_rect.position = Vector2(-block_size * 0.5, -block_size)
		color_rect.size = Vector2(block_size, block_size)
	if border_rect:
		border_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		border_rect.position = Vector2(-block_size * 0.5, -block_size)
		border_rect.size = Vector2(block_size, block_size)
		border_rect.visible = false # Обводки выключены по просьбе: чистые текстуры без рамки
	if sprite:
		sprite.position = Vector2(0, -block_size * 0.5)

func setup(pos: Vector2i, size: int, type_id: String, texture: Texture2D, color: Color) -> void:
	grid_position = pos
	block_size = size
	block_type = type_id
	
	var parent_bm = get_parent()
	if parent_bm and parent_bm.has_method("grid_to_world"):
		position = parent_bm.grid_to_world(grid_position)
	else:
		position = Vector2((grid_position.x + 0.5) * block_size, (grid_position.y + 1) * block_size)
	
	if not is_inside_tree():
		await ready
		
	var shape = RectangleShape2D.new()
	shape.size = Vector2(block_size, block_size)
	collision_shape.shape = shape
	collision_shape.position = Vector2(0, -block_size * 0.5)
	collision_shape.one_way_collision = true
	collision_shape.one_way_collision_margin = 8.0
	
	if color_rect:
		color_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		color_rect.position = Vector2(-block_size * 0.5, -block_size)
		color_rect.size = Vector2(block_size, block_size)
	if border_rect:
		border_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		border_rect.position = Vector2(-block_size * 0.5, -block_size)
		border_rect.size = Vector2(block_size, block_size)
	
	if type_id == "void":
		z_index = -1
		collision_layer = 0
		collision_mask = 0
		collision_shape.disabled = true
		sprite.visible = false
		color_rect.visible = true
		color_rect.color = Color.BLACK
	else:
		z_index = 0
		collision_layer = 2
		collision_mask = 0
		collision_shape.disabled = false
		if texture != null:
			color_rect.visible = false
			sprite.visible = true
			sprite.texture = texture
			sprite.centered = true
			sprite.position = Vector2(0, -block_size * 0.5)
			# Масштабируем текстуру под block_size
			var tex_size = texture.get_size()
			if tex_size.x > 0 and tex_size.y > 0:
				sprite.scale = Vector2(float(block_size) / tex_size.x, float(block_size) / tex_size.y)
		else:
			sprite.visible = false
			color_rect.visible = true
			color_rect.color = color
		
	if border_rect:
		border_rect.visible = false # Без обводки: только текстура/цвет блока

func destroy_as_void() -> void:
	if is_destroying:
		return
	is_destroying = true
	# Отключаем коллизию сразу
	collision_shape.set_deferred("disabled", true)
	
	# Эффект черной пустоты (Alan Becker канон)
	sprite.visible = false
	if border_rect:
		border_rect.visible = false
	color_rect.visible = true
	color_rect.color = Color.BLACK
	
	var tween = create_tween().set_parallel(true)
	tween.tween_property(self, "scale", Vector2.ZERO, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tween.tween_property(color_rect, "modulate:a", 0.0, 0.25)
	await tween.finished
	queue_free()

func get_rect_global() -> Rect2:
	return Rect2(global_position.x - block_size * 0.5, global_position.y - block_size, block_size, block_size)
