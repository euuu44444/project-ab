class_name CameraFollowSystem
extends SimSystem
## player/camera: followPlayerWithCamera(dt). The camera eases toward the player; render and audio read it, the
## simulation does not.


func _init(p_game: GameState) -> void:
	super(p_game, "followPlayerWithCamera")


## # port: followPlayerWithCamera. `cam += (player - cam) * Math.min(1, dt * 8)`
func run(dt: float) -> void:
	var p: PlayerState = game.player
	var cam: CameraState = game.camera
	var follow: float = JsMath.js_min(1.0, dt * 8.0)
	cam.x += (p.x - cam.x) * follow
	cam.y += (p.y - cam.y) * follow
