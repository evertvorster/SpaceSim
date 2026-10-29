extends SceneTree
## **The current cloud field's STATISTICS, per morphology VERDICT** — the baseline a redesigned field must match.
##
## A cloud field is not judged by its formula. It is judged by what it *produces*: how much of the sphere is
## cloudy, how that coverage is distributed, how much structure there is at each scale, and whether the bands
## run east-west. Those are the numbers an eye cannot report, and the ones a rewrite has to hold.
##
## Run it on demand (a probe, not a suite member):
##
##     godot-double-mono --headless --path . --script res://tests/probe_cloud_field_stats.gd
##
## ## Why it bakes by VERDICT and not by body
##
## The verdict (`BANDED` / `SHREDDED` / `FEATURELESS`) is the derivation's output and the thing a rewrite must
## not move — `SpacesimCloudModel.morphology()` has its own tests. What this probe asks is the *next* question:
## given that verdict, what field does it produce? Baking per verdict answers it without a scene, a rendering
## device or a body's content, which is why this probe runs in seconds headless.
##
## ## What is measured, and why each one
##
## - **coverage at the calibrated threshold** — the percentile `threshold_for()` picks so the drawn coverage is
##   the authored one, and therefore what the calibrated albedo is fitted to. A field that moves it moves
##   Earth's 0.302.
## - **the percentile table, summarised** — the distribution's *shape*, not only its mean. Cumulus and cirrus
##   want different shapes: clumps are bimodal (mostly clear or mostly thick), streaks are graded.
## - **the variogram** — `E[|f(x + s) − f(x)|²]` along longitude at several scales, in log-log. Its slope is
##   the spectral slope: a field that has lost its small scales shows up here and nowhere else.
## - **the anisotropy** — variance along latitude against variance along longitude. Bands run east-west, so a
##   banded body must vary far more across latitude than along it, and this ratio is well below 1. **This is
##   also the number that says cirrus**: `EDDY_STRETCH` is 3.0 today, which squeezes the eddy domain 3:1 and
##   therefore *manufactures* east-west elongation.

const WIDTH := 128
const HEIGHT := 64
## The scales the variogram is taken at, in texels — log-spaced, and coarse enough that the smallest still
## spans several texels (below that a difference is sampling noise rather than structure).
const SCALES := [4, 8, 16, 32]

## One morphology per verdict, with the `ratio` each verdict comes from. The numbers are the model's own
## boundary values: `BANDED` is a giant's small ratio, `SHREDDED` is Earth's, `FEATURELESS` is Venus's.
const CASES := [
	["BANDED", SpacesimCloudModel.Banding.BANDED, 0.045],
	["SHREDDED", SpacesimCloudModel.Banding.SHREDDED, 0.104],
	["FEATURELESS", SpacesimCloudModel.Banding.FEATURELESS, 0.0],
]


func _init() -> void:
	print("STATS cloud field, %dx%d, by verdict" % [WIDTH, HEIGHT])
	print("%-11s %6s  %6s %6s %6s %6s  %8s %7s  %7s" % [
		"verdict", "cover", "p10", "p50", "p90", "max", "variog16", "slope", "anis"
	])
	for case in CASES:
		_report(String(case[0]), _morphology(int(case[1]), float(case[2])))
	quit(0)


func _report(name: String, morphology: SpacesimCloudModel.Morphology) -> void:
	var seed_value := 999
	var image := SpacesimCloudField.bake(seed_value, morphology, WIDTH, HEIGHT)
	if image == null:
		print("%-11s NO BAKE" % name)
		return
	var values := PackedFloat32Array()
	values.resize(WIDTH * HEIGHT)
	for row in HEIGHT:
		for column in WIDTH:
			values[row * WIDTH + column] = image.get_pixel(column, row).r
	# **Half the sphere cloudy**, which is the middle of what a coverage says: the point of the number is the
	# ranking between verdicts and the shape beside it, not any one body's authored fraction.
	var threshold := SpacesimCloudMaps.threshold_for(image, 0.5)
	var covered := 0
	for value in values:
		if value >= threshold:
			covered += 1
	var quantiles := SpacesimSurfaceDistribution.quantiles_of(image)
	print("%-11s %6.3f  %.3f  %.3f  %.3f  %.3f  %8.5f %7.3f  %7.3f" % [
		name,
		float(covered) / float(values.size()),
		SpacesimSurfaceDistribution.value_at(quantiles, 0.1),
		SpacesimSurfaceDistribution.value_at(quantiles, 0.5),
		SpacesimSurfaceDistribution.value_at(quantiles, 0.9),
		SpacesimSurfaceDistribution.value_at(quantiles, 1.0),
		_variogram(values, 16),
		_variogram_slope(values),
		_anisotropy(values),
	])


## `E[|f(x + s) − f(x)|²]` along longitude, over the middle half of the latitudes.
func _variogram(values: PackedFloat32Array, scale: int) -> float:
	var total := 0.0
	var count := 0
	for row in range(HEIGHT / 4, (HEIGHT * 3) / 4):
		for column in range(0, WIDTH - scale):
			var delta := values[row * WIDTH + column + scale] - values[row * WIDTH + column]
			total += delta * delta
			count += 1
	return total / float(maxi(count, 1))


## **The variogram's log-log slope** — the spectral slope, in the one form a picture cannot show.
func _variogram_slope(values: PackedFloat32Array) -> float:
	var xs := PackedFloat32Array()
	var ys := PackedFloat32Array()
	for scale in SCALES:
		var value := _variogram(values, int(scale))
		if value > 1.0e-12:
			xs.append(log(float(scale)))
			ys.append(log(value))
	if xs.size() < 2:
		return 0.0
	var mx := 0.0
	var my := 0.0
	for index in xs.size():
		mx += xs[index]
		my += ys[index]
	mx /= float(xs.size())
	my /= float(xs.size())
	var numerator := 0.0
	var denominator := 0.0
	for index in xs.size():
		numerator += (xs[index] - mx) * (ys[index] - my)
		denominator += (xs[index] - mx) * (xs[index] - mx)
	return 0.0 if denominator <= 0.0 else numerator / denominator


## Longitude variance over latitude variance, at a one-texel step both ways. **Bands run east-west**, so a
## banded body's ratio is well below 1; an isotropic field sits near 1 and a *streaked* one is below it for a
## different reason — which is why it is reported beside the variogram and not instead of it.
func _anisotropy(values: PackedFloat32Array) -> float:
	var along := 0.0
	var across := 0.0
	for row in range(1, HEIGHT - 1):
		for column in range(1, WIDTH - 1):
			var east := values[row * WIDTH + column + 1] - values[row * WIDTH + column]
			var north := values[(row + 1) * WIDTH + column] - values[row * WIDTH + column]
			along += east * east
			across += north * north
	if across <= 0.0:
		return 0.0
	return along / across


func _morphology(banding: int, ratio: float) -> SpacesimCloudModel.Morphology:
	var morphology := SpacesimCloudModel.Morphology.new()
	morphology.banding = banding
	morphology.ratio = ratio
	# The scale the field sizes its features in, and the cells per hemisphere: a giant's are fine and many, a
	# shredded body's are fewer and coarser. Derived numbers in the game; held fixed here so the *verdict* is
	# the only thing varying between runs.
	morphology.eddy_angular_scale = 0.06
	morphology.cells = 8.0 if banding == SpacesimCloudModel.Banding.BANDED else 3.0
	return morphology
