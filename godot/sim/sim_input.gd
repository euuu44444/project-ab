class_name SimInput
extends RefCounted
## The player's movement input: the sim's explicit version of the original's global `input` (keys + touch stick).
##
## key_left / key_right / key_up / key_down are "KeyA or ArrowLeft" and so on (the original asks `keys.has("KeyA") ||
## keys.has("ArrowLeft")`, so pressing both counts once). move_x / move_y is the touch stick, already divided by
## MOVE_STICK_MAX (|stick| <= 1). The host sets these fields before each step; resolve() computes the movement vector.

var key_left: bool = false
var key_right: bool = false
var key_up: bool = false
var key_down: bool = false
var move_x: float = 0.0
var move_y: float = 0.0
## Result of resolve(): the movement vector, normalised if its length is above 1. Doubles, not a Vector2 (float32).
var out_x: float = 0.0
var out_y: float = 0.0


## # port: inputVector. Keys add +-1 per axis, the stick is added, and a vector longer than 1 is divided by its length
## (Math.hypot, V8's algorithm).
func resolve() -> void:
	var x: float = 0.0
	var y: float = 0.0
	if key_left:
		x -= 1.0
	if key_right:
		x += 1.0
	if key_up:
		y -= 1.0
	if key_down:
		y += 1.0
	x += move_x
	y += move_y
	var m: float = JsMath.hypot(x, y)
	if m > 1.0:
		out_x = x / m
		out_y = y / m
	else:
		out_x = x
		out_y = y


## # port: clearTransientInput (the part that belongs to the sim: keys and stick).
func clear() -> void:
	key_left = false
	key_right = false
	key_up = false
	key_down = false
	move_x = 0.0
	move_y = 0.0
	out_x = 0.0
	out_y = 0.0
