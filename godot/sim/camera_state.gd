class_name CameraState
extends RefCounted
## game.camera of the original: the world position the view is centred on. prev_x / prev_y are the values before the
## last fixed step (capturePreviousTransforms), which the renderer interpolates from.

var x: float = 0.0
var y: float = 0.0
var prev_x: float = 0.0
var prev_y: float = 0.0
