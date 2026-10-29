extends SceneTree
## **Where a cloud bake's time goes on the MAIN THREAD** — the GPU dispatch, the read-back, or the GDScript passes
## over the image that measure it. Evert, 2026-10-29: *"while the cloud layer was baking, there was a significant drop
## in frame rates."* A refinement lands inside a frame, so whatever is slow here is a stall the flight sees.
func _init() -> void:
	for width in [1024, 2048, 4096]:
		var height: int = width / 2
		var image := Image.create_empty(width, height, false, Image.FORMAT_L8)
		# A field-ish ramp, so the histogram is not degenerate.
		var data := image.get_data()
		for index in data.size():
			data[index] = int((float((index * 7919) % 4096) / 4096.0) * 255.0)
		image.set_data(width, height, false, Image.FORMAT_L8, data)
		# The OLD shape: three full passes plus a subsampled one.
		var t := Time.get_ticks_usec()
		var threshold := SpacesimCloudMaps.threshold_for(image, 0.5)
		var exceed := SpacesimCloudMaps.mean_exceedance(image, threshold)
		var opacity := SpacesimCloudMaps.mean_opacity(
			image, threshold, SpacesimCloudMaps.column_depth(exceed, 1000.0)
		)
		var quantiles := SpacesimSurfaceDistribution.quantiles_of(image)
		var old_us := Time.get_ticks_usec() - t
		# The NEW shape: one subsampled histogram, four numbers out of it.
		t = Time.get_ticks_usec()
		var measured := SpacesimCloudMaps.measure(image, 0.5, 1000.0)
		var new_us := Time.get_ticks_usec() - t
		print("BAKE %4dx%-4d %8d texels   old %7.1f ms   one histogram %6.1f ms   (threshold %.3f/%.3f  exceed %.3f/%.3f  opacity %.3f/%.3f)" % [
			width, height, width * height, old_us / 1000.0, new_us / 1000.0,
			threshold, float(measured["threshold"]),
			exceed, float(measured["exceedance"]),
			opacity, float(measured["opacity"]),
		])
	quit(0)
