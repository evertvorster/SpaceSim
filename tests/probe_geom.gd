extends SceneTree
func _initialize() -> void:
	var sol: SpacesimSolarSystem = load("res://systems/sol.tres")
	var scene := SpacesimSystemScene.from_content(sol)
	var root := Node3D.new()
	get_root().add_child(root)
	scene.build(root)
	var saturn := scene.body_by_id("planet:saturn")
	var view := scene.rings[1]
	var band: SpacesimPopulation = sol.population_by_id("population:ring_b")
	var cloud := SpacesimParticleCloud.of(band)
	var C := saturn.node.global_position
	var R := saturn.radius
	var normal := (view.global_transform.basis * Vector3(0,0,1)).normalized()
	# his pose: 164 Mm out, ~25 degrees above the ring plane
	var eye := C + (normal * 0.42 + Vector3(0,0,1).cross(normal).normalized() * 0.91).normalized() * 1.64e8
	var dir := (eye - C).normalized()
	var deck_r := R + 30000.0
	var in_near := 0
	var in_far := 0
	var dot_before_deck := 0
	var dot_after_deck := 0
	for i in range(0, cloud.size(), 37):
		var P: Vector3 = view.global_transform * cloud.positions[i]
		var v := (P - eye)
		var t_p := v.length()
		var vhat := v / t_p
		# ray-sphere against the deck shell
		var b := (eye - C).dot(vhat)
		var c := (eye - C).length_squared() - deck_r * deck_r
		var disc := b * b - c
		if disc <= 0.0:
			continue
		var t_deck := -b - sqrt(disc)
		if t_deck <= 0.0:
			continue
		if (P - C).dot(dir) > 0.0:
			in_near += 1
		else:
			in_far += 1
		if t_p < t_deck: dot_before_deck += 1
		else: dot_after_deck += 1
	print("particles whose ray crosses the deck shell: %d" % (in_near + in_far))
	print("  classified near: %d   far: %d" % [in_near, in_far])
	print("  along the ray: BEFORE the deck's near face: %d   after it: %d" % [dot_before_deck, dot_after_deck])
	quit()
