class_name SpacesimStarCatalogue
extends RefCounted
## The real sky, loaded from `addons/spacesim/sky/hyg_v44.stars` into three textures the shader can
## read. See `PROVENANCE.md` beside the data for the source, its licence and the calibration.
##
## **This is Sol calibration data, not shipped content.** SpaceSim ships no Sol: the catalogue is the
## measured sky the *generator* will be calibrated against, and the real one is the only way to know
## what "accurate" means before a generator exists.
##
## The stars arrive **bucketed by cube-face cell** — the stars of a cell are contiguous, and a table
## says where each cell's run starts and how long it is. That is what lets the shader test one cell's
## handful of stars instead of 119,613 of them.
##
## Ten bytes a star on disk becomes 21 on the GPU (16 for the direction and magnitude, 4 for the
## colour, plus padding), which is 2.4 MB for the whole sky. That is the price of not compressing
## something that is read once per pixel per star.

const MAGIC := "SPSSSKY1"
const VERSION := 1
const RECORD_BYTES := 10
const CELL_BYTES := 8

## Texels across the star and colour textures. 512 gives 234 rows for 119,613 stars; a wider texture
## is fewer rows and the same cost.
const STAR_WIDTH := 512

const FORMAT_STAR := Image.FORMAT_RGBAF   ## x, y, z, magnitude
const FORMAT_COLOUR := Image.FORMAT_RF    ## B-V
const FORMAT_CELL := Image.FORMAT_RGF     ## offset, count

var count := 0
var grid := 0
var cell_count := 0
var stars_texture: ImageTexture
var colour_texture: ImageTexture
var cells_texture: ImageTexture


## Load and upload. Returns false and says why rather than half-loading.
func load_file(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("SpacesimStarCatalogue: cannot read %s" % path)
		return false
	var blob := file.get_buffer(file.get_length())
	file.close()

	if blob.size() < 24 or blob.slice(0, 8).get_string_from_ascii() != MAGIC:
		push_error("SpacesimStarCatalogue: %s is not a star catalogue" % path)
		return false
	var version := blob.decode_u32(8)
	if version != VERSION:
		push_error("SpacesimStarCatalogue: %s is version %d, this build reads %d"
			% [path, version, VERSION])
		return false

	grid = blob.decode_u32(12)
	count = blob.decode_u32(16)
	cell_count = blob.decode_u32(20)
	var expect := 24 + count * RECORD_BYTES + cell_count * CELL_BYTES
	if blob.size() != expect:
		push_error("SpacesimStarCatalogue: %s is %d bytes, header implies %d"
			% [path, blob.size(), expect])
		return false

	var stars := _decode_stars(blob)
	var colours := _decode_colours(blob)
	var cells := _decode_cells(blob, 24 + count * RECORD_BYTES)

	stars_texture = ImageTexture.create_from_image(stars)
	colour_texture = ImageTexture.create_from_image(colours)
	cells_texture = ImageTexture.create_from_image(cells)
	return true


func star_image_size() -> Vector2:
	return Vector2(stars_texture.get_width(), stars_texture.get_height())


func colour_image_size() -> Vector2:
	return Vector2(colour_texture.get_width(), colour_texture.get_height())


func cell_image_size() -> Vector2:
	return Vector2(cells_texture.get_width(), cells_texture.get_height())


func _rows(n: int, width: int) -> int:
	return (n + width - 1) / width


func _decode_stars(blob: PackedByteArray) -> Image:
	var width := STAR_WIDTH
	var image := Image.create_empty(width, _rows(count, width), false, FORMAT_STAR)
	var base := 24
	for i in count:
		var at := base + i * RECORD_BYTES
		# int16 -> the unit direction the file was reduced to, kept as a float so the shader does not
		# have to undo the scaling on every read.
		var x := float(blob.decode_s16(at)) / 32767.0
		var y := float(blob.decode_s16(at + 2)) / 32767.0
		var z := float(blob.decode_s16(at + 4)) / 32767.0
		var mag := float(blob.decode_s16(at + 6)) / 1000.0
		image.set_pixel(i % width, i / width, Color(x, y, z, mag))
	return image


func _decode_colours(blob: PackedByteArray) -> Image:
	var width := STAR_WIDTH
	var image := Image.create_empty(width, _rows(count, width), false, FORMAT_COLOUR)
	var base := 24
	for i in count:
		var ci := float(blob.decode_s16(base + i * RECORD_BYTES + 8)) / 1000.0
		image.set_pixel(i % width, i / width, Color(ci, 0.0, 0.0, 1.0))
	return image


func _decode_cells(blob: PackedByteArray, base: int) -> Image:
	# One texel a cell, laid out as a plain grid; the shader indexes it with its own cell number, so
	# the shape of the image only has to be consistent, not meaningful.
	var width := 256
	var image := Image.create_empty(width, _rows(cell_count, width), false, FORMAT_CELL)
	for i in cell_count:
		var at := base + i * CELL_BYTES
		image.set_pixel(i % width, i / width,
			Color(blob.decode_u32(at), blob.decode_u32(at + 4), 0.0, 1.0))
	return image
