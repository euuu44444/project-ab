class_name SimUtil
extends RefCounted
## Small helpers of the original that several systems share (the game's own utility functions, not Math.*).


## # port: dist2. `const x=ax-bx,y=ay-by;return x*x+y*y;` (the squared distance; no square root)
static func dist2(ax: float, ay: float, bx: float, by: float) -> float:
	var dx: float = ax - bx
	var dy: float = ay - by
	return dx * dx + dy * dy


## `x || 1` for a number: 1 when x is 0, -0 or NaN, else x.
static func or_one(x: float) -> float:
	if x == 0.0 or is_nan(x):
		return 1.0
	return x


## JavaScript truthiness of a value that came out of a loosely typed dictionary (a contract flag): false for false, 0, -0, NaN and
## null; true for the rest.
static func truthy(value: Variant) -> bool:
	if value is bool:
		return value
	if value is float or value is int:
		return float(value) != 0.0 and not is_nan(float(value))
	return value != null


## `x || 0` for a number: 0 when x is 0, -0 or NaN (a -0 becomes +0), else x.
static func or_zero(x: float) -> float:
	if x == 0.0 or is_nan(x):
		return 0.0
	return x


## # port: segmentCircleHit. Does the segment (x1, y1)-(x2, y2) touch the circle at (cx, cy) with radius `radius`? A segment shorter than
## 1e-3 (len2 <= 1e-6) counts as a point.
static func segment_circle_hit(x1: float, y1: float, x2: float, y2: float, cx: float, cy: float, radius: float) -> bool:
	var dx: float = x2 - x1
	var dy: float = y2 - y1
	var len2: float = dx * dx + dy * dy
	if len2 <= 1e-6:
		return dist2(x1, y1, cx, cy) <= radius * radius
	var t: float = JsMath.clamp(((cx - x1) * dx + (cy - y1) * dy) / len2, 0.0, 1.0)
	var qx: float = x1 + dx * t
	var qy: float = y1 + dy * t
	return dist2(qx, qy, cx, cy) <= radius * radius
