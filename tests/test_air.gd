extends RefCounted
## **The air march's parameter arithmetic** — the one part of the pass a headless run can assert.
##
## `Atmospheres` §9a is precise about what is testable here and what is not: the picture is flown, the source is
## compiled by `tests/shader_check.sh`, and the *arithmetic* is a pure function. This is that function's test,
## and it exists because the fault it guards is silent — a backwards `eye_offset` produces a frame that looks
## exactly like a pass that did nothing at all.


func run(h, _root: Node) -> void:
	print("  air march")
	_test_eye_is_relative_to_the_body(h)
	_test_direction_rotates_without_translating(h)
	_test_the_scene_names_a_subject(h)


## **`eye_offset` points from the body to the eye**: `basis.inverse() * (eye - body)`.
##
## Two checks, and the second is the one that catches the tempting mistake. With the camera at +10 on X looking
## back along -X, the body is 10 m in front of it and so sits at **+10 on Z in view space** (the camera looks
## down -Z), not -10. A vector the wrong way round puts the body behind the camera, and the march then finds
## nothing.
func _test_eye_is_relative_to_the_body(h) -> void:
	var eye := Vector3(10.0, 0.0, 0.0)
	var body := Vector3.ZERO
	# Facing -X from +X: the basis the camera has, and its inverse, which is what the pass is handed.
	var facing := Basis.looking_at(Vector3(-1.0, 0.0, 0.0), Vector3.UP)
	var offset := SpacesimAtmospherePass.view_offset(facing.inverse(), eye, body)
	h.check_near(offset.length(), 10.0, "the body is 10 m away in view space", 1.0e-4)
	h.check_near(offset.z, 10.0, "and in front of the camera, not behind it (+Z, %.3f)" % offset.z, 1.0e-4)
	# And it is the *body's* centre relative to the eye, not the eye's relative to the body.
	h.check_near(
		SpacesimAtmospherePass.view_offset(facing.inverse(), body, eye).z, -10.0,
		"with the two swapped the vector flips, which is the fault this pins", 1.0e-4
	)


## A direction is **rotated, never translated**: the eye's own position must not enter it, and neither may the
## body's. The same world direction from two different places gives the same view-space direction.
func _test_direction_rotates_without_translating(h) -> void:
	var basis := Basis.looking_at(Vector3(-1.0, 0.0, 0.0), Vector3.UP).inverse()
	var one := SpacesimAtmospherePass.view_direction(basis, Vector3(-1.0, 0.0, 0.0))
	var two := SpacesimAtmospherePass.view_direction(basis, Vector3(-7.0, 0.0, 0.0))
	h.check_near(one.length(), 1.0, "a direction comes back unit-length", 1.0e-4)
	# **Forward is -Z in view space**, which is the convention the march's ray uses
	# (`direction = normalize(vec3(ndc.x * tan_x, ndc.y * tan_y, -1.0))`). Asserting +Z here would pin the
	# opposite of what the shader does, and the test would be the thing that was wrong.
	h.check_near(one.z, -1.0, "the star straight ahead lands on -Z, which is forward", 1.0e-4)
	h.check(one.is_equal_approx(two), "and its magnitude does not scale the answer")


## **The scene must name nobody for a body without air**, and the nearest of those that have it otherwise. A pass
## given no subject is off, which is the state most frames are in.
func _test_the_scene_names_a_subject(h) -> void:
	var scene := SpacesimSystemScene.new()
	var with_air := SpacesimSceneBody.new()
	with_air.name = "WithAir"
	with_air.position = Vector3(100.0, 0.0, 0.0)
	with_air.sky_top = 1.0e5
	with_air.air_scale_height = 8.5e3
	var without := SpacesimSceneBody.new()
	without.name = "Without"
	without.position = Vector3(10.0, 0.0, 0.0)
	scene.bodies = [with_air, without]
	h.check(scene.air_subject(Vector3.ZERO) == with_air,
		"the nearest body WITH air is the subject, not the nearest body")
	with_air.sky_top = 0.0
	h.check(scene.air_subject(Vector3.ZERO) == null,
		"and with no air anywhere there is no subject at all")
