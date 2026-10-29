extends SceneTree
func _init() -> void:
	var p := SpacesimSurfaceField.plan("planet:earth", 6.371e6)
	print("plan: seed %d  ridge_frequency %.3f  ridge_octaves %d  ridge_strength %.3f" % [
		p.seed, p.ridge_frequency, p.ridge_octaves, p.ridge_strength])
	print("      gain %.4f  lacunarity %.2f  belt_width %.4f  plate_phase %.3f  amplitude %.1f m" % [
		p.gain, p.lacunarity, p.belt_width, p.plate_phase, p.amplitude])
	print("      warp_freq %.2f  warp_octaves %d  warp_strength %.3f  warp_bounding %.5f" % [
		p.warp_frequency, p.warp_octaves, p.warp_strength, p.warp_bounding])
	# What surface_relief actually contributes, at the field's own weights.
	var normaliser := 0.0
	var w := 1.0
	for i in p.ridge_octaves:
		normaliser += w
		w *= p.gain
	print("  map's ridge normaliser (sum of gain^j for %d octaves) = %.5f" % [p.ridge_octaves, normaliser])
	# A crest's amplitude is ridge_strength * crest; crest is 1.0 only on a plate boundary, 0 elsewhere.
	for octave in range(p.ridge_octaves, p.ridge_octaves + 6):
		var amplitude := pow(p.gain, float(octave)) / normaliser
		var feature := 1.0 / (p.ridge_frequency * pow(2.0, float(octave)))
		# **The feature is an ANGLE**, so its length is `feature × radius` — the first version of this probe multiplied it
		# by the *amplitude* and printed a column of nonsense.
		print("  octave %2d: field units %.6f  = %7.2f m at crest 1.0  (feature %6.1f km on Earth)" % [
			octave, amplitude * p.ridge_strength,
			amplitude * p.ridge_strength * p.amplitude,
			feature * 6.371e6 / 1000.0])
	quit()
