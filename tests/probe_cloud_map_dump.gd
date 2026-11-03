extends Node
## **The baked cloud map, as a file** — because "is the seam in the field or in the sampling" is a question
## about the data, and the render cannot answer it.
##
##     timeout 60 xvfb-run -a godot-double-mono --headless --path . res://tests/probe_cloud_map_dump.tscn /tmp/out
##
## Writes `<out>/<body>.png` for the bodies asked for, at a fixed resolution, plus a row/column difference
## table: a vertical seam shows as an anomalous difference between the first and last columns, and a latitude
## step shows as one between two adjacent rows.

const SOL_PATH := "res://systems/sol.tres"
const WIDTH := 1024
const BODIES := ["planet:jupiter", "planet:earth"]
const OUT := "/tmp"


func _ready() -> void:
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	var scene := SpacesimSystemScene.from_content(sol)
	scene.build(self)
	var materials := SpacesimMaterialTable.engine_table()
	var luminosity := SpacesimStarModel.luminosity(scene.star().content)
	for id in BODIES:
		var body := scene.body_by_id(id)
		if body == null:
			continue
		var morphology := SpacesimCloudModel.morphology(
			body.content, materials, luminosity, body.position.distance_to(scene.star().position)
		)
		var image := SpacesimCloudField.bake(
			SpacesimCloudField.seed_for(id, 0), morphology, WIDTH, WIDTH / 2
		)
		var path := "%s/%s.png" % [OUT, id.replace(":", "_")]
		image.save_png(path)
		print("%s -> %s (%dx%d)" % [id, path, image.get_width(), image.get_height()])
		_seams(image, id)
	# No cache and no cache-close here: nothing in this probe bakes through `SpacesimCloudMaps`, so there is
	# no task in flight and no `RenderingDevice` to free. `checkpoint` is reached either way.
	scene.container.free()
	get_tree().quit()


## **Adjacent-column and adjacent-row differences**, so a seam or a latitude step is a number rather than an
## impression. The wrap pair is compared against the columns next to it; a row step is compared against the
## rows next to it, which is what tells a *step* from the field's ordinary steepness.
func _seams(image: Image, id: String) -> void:
	var data := image.get_data()
	var width := image.get_width()
	var height := image.get_height()
	var worst_column := 0.0
	var worst_column_at := 0
	var worst_wrap := 0.0
	var wrap_at := 0
	for row in range(height / 8, height * 7 / 8):
		for column in range(width - 1):
			var step := absf(float(data[row * width + column + 1]) - float(data[row * width + column]))
			if step > worst_column:
				worst_column = step
				worst_column_at = row
		var wrap := absf(float(data[row * width]) - float(data[row * width + width - 1]))
		if wrap > worst_wrap:
			worst_wrap = wrap
			wrap_at = row
	# A LATITUDE STEP is a row pair that stands out from its neighbours in the same column band: the mean
	# |Δ| between row r and r+1, against the mean of the rows either side of it.
	var worst_row := 0.0
	var worst_row_at := 0
	var row_steps := PackedFloat32Array()
	for row in range(height - 1):
		var total := 0.0
		for column in range(width):
			total += absf(float(data[(row + 1) * width + column]) - float(data[row * width + column]))
		row_steps.append(total / float(width))
	for row in range(1, row_steps.size() - 1):
		var local := (row_steps[row - 1] + row_steps[row] + row_steps[row + 1]) / 3.0
		var excess := row_steps[row] / maxf(local, 1.0e-6)
		if excess > worst_row:
			worst_row = excess
			worst_row_at = row
	print("  %s: worst adjacent-column step %.0f at row %d; wrap step %.0f at row %d (%.2fx of a column step)" % [
		id, worst_column, worst_column_at, worst_wrap, wrap_at, worst_wrap / maxf(worst_column, 1.0e-6)])
	print("  %s: the row that stands out most from its neighbours is %.2fx their mean, at row %d of %d (%s)" % [
		id, worst_row, worst_row_at, height,
		"NORTH" if worst_row_at < height / 2 else "SOUTH"])
