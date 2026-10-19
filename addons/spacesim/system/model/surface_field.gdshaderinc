// **The surface height field, as GLSL** — and the *single* implementation of it.
//
// Two consumers, and neither is a reimplementation:
//
//  - `SpacesimSurfaceGpu` compiles it inside a compute kernel and bakes the whole-body map from it;
//  - the surface shader will `#include` it for the detail below the map's own Nyquist.
//
// The GDScript side (`SpacesimSurfaceField`) owns the **numbers** — the frequencies, the octave counts, the
// strengths, the FBM normalisers — and hands them over as a `SurfacePlan`. A constant typed in here would
// be a second copy of a number the plan already knows, and it would drift away from the one the tests
// check.
//
// **Everything is sampled on the UNIT SPHERE**, never in world metres: a planet is millions of metres
// across and the field is tens of features, so world sampling lands adjacent pixels in unrelated voxels —
// a cloud of dots rather than structure, and worse at astronomical coordinates where a float has metres of
// resolution. The unit direction is the one coordinate this field has.
//
// ## Land is not cloud, and the mechanisms are not the cloud field's
//
// The only thing this shares with the cloud field is `noise.gdshaderinc` — a FastNoiseLite primitive, which
// is a *noise function*, not weather. Everything the clouds are built from is wrong here, and none of it is
// used:
//
//  - **no zonal stretch.** `SpacesimCloudField` squeezes latitude so its features are drawn out east-west,
//    because a jet does that. **Land has no jet**: a continent is as wide as it is, and a stretched one
//    would read as weather painted onto the ground.
//  - **no advection, no eddies, no vortices.** A cloud is carried and torn; a plate is not. What moves rock
//    is tectonic, and it moves it at plate boundaries.
//  - **no bands.** Latitude structure in a cloud field is a circulation cell. Here latitude enters through
//    nothing at all — a body's land would look the same from any axis, because a rotating sphere tessellates
//    the same way whichever way you spin it.
//
// What replaces them is **geology, in three mechanisms:**
//
//  - **Plates** — a Voronoi partition of the sphere (`Procedural Generation` §"Voronoi": *"a planet's biome
//    or terrain zones are a partition of a sphere, and spherical Voronoi is the honest way to make one"*).
//    Each plate carries a level, standing or sagging, which is what makes the elevation histogram
//    **bimodal** — continents and ocean basins, which is Earth's own hypsometric signature and the reason a
//    single fbm never looks like a planet.
//  - **Mountain belts along the boundaries**, because that is where rock is deformed: `ridged` noise
//    multiplied by how close the sample is to a plate edge, and by nothing else.
//  - **Ridged noise for the crests themselves** (`1 - |n|`, squared), which is the one mechanism that reads
//    as "mountain" rather than as "bumpy".
//  - **A region term**, slower than a plate, multiplied into the level — so one continent stands higher than
//    another and one basin floods deeper, with the plate interiors still flat. Added 2026-10-19 because
//    nothing in the field was slower than a plate, and a planet of one place repeated is what that looks like.
//
// **The result is a field, not a height in metres, and it is not sea-levelled.** The datum is 0 and the
// spread is about ±1; sea level is a *percentile* of this distribution, measured after the bake, so the
// field cannot pre-empt where the ocean goes. Metres are the host's business (`plan.amplitude`).

struct SurfacePlan {
	int seed;
	float continent_frequency;
	int continent_octaves;
	float ridge_frequency;
	int ridge_octaves;
	float warp_frequency;
	int warp_octaves;
	float warp_strength;
	float ridge_strength;
	float continent_share;
	float plate_bias_share;
	float belt_width;
	float plate_phase;
	float gain;
	float lacunarity;
	float continent_bounding;
	float warp_bounding;
	float region_frequency;
	int region_octaves;
	float region_share;
	float region_bounding;
	float mottle_plain_gain;
};

// **How many plates.** Fourteen, which is Earth's count of major plates, and it is a *shape* number rather
// than a derived one: nothing in a body's composition says how it fractured. A rock with no air will want
// craters and few plates, an ice shell long cracks — those are the next mechanisms, and this is the seam
// they join at.
const int SURFACE_PLATES = 14;
// `pi * (3 - sqrt(5))`, the golden angle: successive Fibonacci points turn by this much, which is what
// makes them quasi-uniform on the sphere.
const float SURFACE_GOLDEN_ANGLE = 2.3999632297286535;


// **A plate's centre: a Fibonacci lattice, turned by the body's own phase.**
//
// A lattice rather than a hash, deliberately: it is *exactly* the same arithmetic in GDScript and in GLSL
// (no integer mixing to agree on, which is where a cross-language invariant usually breaks), and it needs
// no buffer to carry it — which matters because the fragment shader will want this field too, and a
// fragment shader cannot read the compute kernel's `shared` memory. What the lattice gives up in
// irregularity, the domain warp below restores: the distance test is made from the **warped** direction, so
// the cells come out irregular while the centres stay put.
vec3 surface_plate_centre(int index, float phase) {
	float z = 1.0 - (2.0 * float(index) + 1.0) / float(SURFACE_PLATES);
	float ring = sqrt(max(1.0 - z * z, 0.0));
	float angle = float(index) * SURFACE_GOLDEN_ANGLE + phase;
	return vec3(ring * cos(angle), z, ring * sin(angle));
}


// **Whether a plate stands or sags**, on -1..1 — the bimodality itself.
//
// `sin` of an irrational multiple of the index, saturated through a clamp so a plate is either clearly up or
// clearly down and the crossing between them is smooth rather than an exact sign test (a sign test on a
// nearly-zero argument is the one way this could come out different on the CPU and the GPU).
//
// **The bias is what keeps this from being a 50/50 coin.** The planet's *water* is content's ocean fraction
// and the sea level is a percentile of this field, so the area split is forced either way — but a field with
// as many plates up as down puts that percentile in the middle of the gap between the two modes, which
// drowns every standing plate to its peaks and puts every coastline on a plate boundary. A standing minority
// is the default instead (about a quarter of the plates reach +1, half sit at -1, and the rest are between),
// which is what a look at Earth's own hypsometry asks for: a floor with most of the area, and a minority
// standing clear of it. What the fraction of *water* is stays content's business.
float surface_plate_level(int index, float phase) {
	return clamp(3.0 * sin(float(index) * 12.9898 + phase * 7.0) - 0.55, -1.0, 1.0);
}


// **The two things the plates decide**: the level of the one you are standing on, and how close to a
// boundary you are (1 at an edge, 0 well inside).
void surface_plates(vec3 q, float phase, float belt_width, out float level, out float belt) {
	float nearest = 2.0;
	float second = 2.0;
	int nearest_index = 0;
	for (int index = 0; index < SURFACE_PLATES; index++) {
		// `1 - dot` is a monotone stand-in for the angle: 0 at the centre, 2 at the antipode.
		float distance = 1.0 - dot(q, surface_plate_centre(index, phase));
		if (distance < nearest) {
			second = nearest;
			nearest = distance;
			nearest_index = index;
		} else if (distance < second) {
			second = distance;
		}
	}
	level = surface_plate_level(nearest_index, phase);
	// The gap between the nearest two centres is zero *on* the boundary and grows inward, so it is the
	// boundary distance without an edge distance function.
	belt = 1.0 - smoothstep(0.0, max(belt_width, 1.0e-4), second - nearest);
}


// **Ridged multifractal**: crests where the noise crosses zero, sharp because the absolute value is, and
// smooth on the flanks because the square of `1 - |n|` is.
//
// **Each rung is one octave through `fnl_fbm3`, not a bare `fnl_os2s3`** — the fbm wrapper is what applies
// the R3 rotation every other sample of this generator gets, so a bare lattice call would be a *different
// field* under the same seed. One octave also makes `fractal_bounding` exactly 1, so the rung comes back on
// [-1, 1] and the weighting below is the whole of the shape.
float surface_ridged3(vec3 p, int seed, int octaves, float gain, float lacunarity) {
	float sum = 0.0;
	float amplitude = 1.0;
	float weight = 0.0;
	float frequency = 1.0;
	for (int octave = 0; octave < octaves; octave++) {
		// **Not `sample`**: that is a RESERVED WORD in GLSL, and the error it produces names the wrong
		// thing entirely — *"syntax error, unexpected SAMPLE, expecting COMMA or SEMICOLON"* on a line that
		// looks correct. `filter`, `input`, `output`, `common`, `partition` and `active` are in the same set.
		float rung = fnl_fbm3(p, seed + octave, frequency, 1, gain, lacunarity, 1.0);
		float ridge = 1.0 - abs(rung);
		sum += amplitude * ridge * ridge;
		weight += amplitude;
		amplitude *= gain;
		frequency *= lacunarity;
	}
	return sum / weight;
}


// **The field.** `unit` must be a unit vector; the return is the field's own value, about ±1.
float surface_height(vec3 unit, SurfacePlan plan) {
	// **The domain warp, as a vec3**: three samples of one generator through three different swizzles of
	// the same position, which decorrelates them without a second generator (Planet 3D's trick). A scalar
	// warp displaces everything along one direction and looks extruded. This is also what makes the plate
	// cells irregular without jittering their centres.
	vec3 warp = vec3(
		fnl_fbm3(unit.yzx, plan.seed + 101, plan.warp_frequency, plan.warp_octaves,
			plan.gain, plan.lacunarity, plan.warp_bounding),
		fnl_fbm3(unit.zxy, plan.seed + 211, plan.warp_frequency, plan.warp_octaves,
			plan.gain, plan.lacunarity, plan.warp_bounding),
		fnl_fbm3(unit.xyz, plan.seed + 307, plan.warp_frequency, plan.warp_octaves,
			plan.gain, plan.lacunarity, plan.warp_bounding)
	);
	// Back onto the sphere, because the field is a function of *direction* and nothing else may shift.
	vec3 q = normalize(unit + plan.warp_strength * warp);

	float level;
	float belt;
	surface_plates(q, plan.plate_phase, plan.belt_width, level, belt);

	// **The region term: what makes one continent stand higher than another, and one basin sit deeper.**
	// Evert, 2026-10-19: *"the noise is far too uniform. It needs an extra slow octave to make higher and
	// lower peaks, as well as create flat areas."* Nothing in the field was slower than a plate, so every
	// continent had the same relief budget and the same grain — a planet of one place repeated.
	//
	// **Multiplied into the level rather than added to it**, because the property asked for is a *scaling* of
	// ground that is already flat: a standing plate stands higher where the region is high and lower where it
	// is low, a sagging plate floods deeper somewhere than elsewhere, and the interior of a plate stays flat
	// while a slow field varies across it. An additive term would tilt those interiors instead of scaling
	// them, which is the opposite of a plain.
	float region = fnl_fbm3(
		q, plan.seed + 733, plan.region_frequency, plan.region_octaves,
		plan.gain, plan.lacunarity, plan.region_bounding
	);
	float standing = level * (1.0 + plan.region_share * region);

	// **How much texture this ground is allowed.** `surface_plates` gives a plate a *constant* level, so a
	// plate interior has no shape of its own at all — `variation` is its whole character, and it was laid over
	// every plate at one strength. Evert, 2026-10-19: *"for most of the planet the mottling should be much
	// less, so we have some flat plains too... it stretches all the way to the coast, so it needs to be less at
	// low altitudes."* So the low ground gets a fraction of it and the uplands keep the grain.
	//
	// **The proxy is the plate level, deliberately, and NOT the sea level.** Sea level is a *percentile of this
	// field*, measured after the bake, so attenuating by it would be circular — the attenuation would move the
	// percentile that decided the attenuation, and a second bake would be needed to settle it. Plate level is
	// causal, needs nothing measured, and already means "this ground is low".
	float mottle = mix(plan.mottle_plain_gain, 1.0, smoothstep(-0.5, 0.5, level));

	// **Structure within a plate**: the broad shape inside a continent, not the continents themselves —
	// those are the plate levels, and a low-frequency fbm big enough to make its own continents would
	// fight them and produce a planet that is neither.
	float variation = fnl_fbm3(
		q, plan.seed + 577, plan.continent_frequency, plan.continent_octaves,
		plan.gain, plan.lacunarity, plan.continent_bounding
	);
	float mountains = surface_ridged3(
		q * plan.ridge_frequency, plan.seed + 991, plan.ridge_octaves, plan.gain, plan.lacunarity
	);
	// Squared, so a belt is a *chain* with a crest rather than a wide band of hills.
	float crest = belt * belt;

	// **The ridges are not scaled by `mottle`**: they are already gated to plate boundaries by `crest`, and a
	// belt that vanished over a low plate would leave a plain with no edge, which is the one place a plain
	// should have relief.
	return plan.plate_bias_share * standing
		+ plan.continent_share * mottle * variation
		+ plan.ridge_strength * mountains * crest;
}


// ===== THE LADDER: THE FIELD'S OWN OCTAVES, BELOW WHAT THE MAP COULD HOLD ==========================
//
// **`surface_height` is a sum of octaves, and a bake stops at the octave its width can resolve.** The rest of
// the sum is still a formula, and this is where it is evaluated. So the ladder is not a second texture: it is the
// *same* fbm at octaves the map never carried, with the field's own seeds, frequencies and amplitudes.
//
// **Why that is a correction and not a nicety.** Evert, 2026-10-19: *"my idea for this texture was that it
// contains both large and small features, and since the shader is a mathematical function, it should not matter if
// it's drawing the whole texture or a smaller patch at a higher detail."* The ladder did not do that. It ran its
// own `fnl_fbm3` from the map's Nyquist with its own seeds and its own frequencies, and — the part that decided
// the picture — **its own normalisation, which re-inflated every rung to one octave's full amplitude.**
//
// The field's spectrum falls at `gain` per octave, so the octave at a 30 m wavelength (the nineteenth) carries
// 0.5^19 of the first one's amplitude: **about 2 cm of Earth's 8,919 m range.** Renormalised, those octaves were
// drawn at full strength instead, and that is what covered the near ground in uniform grain and tilted the normal
// far enough to catch sunlight past the terminator. Reproduced octave for octave, at their own weights, they are
// what the field says they are: almost nothing.
//
// **The honest consequence, stated here so nobody rediscovers it as a bug:** with this spectrum there is
// *almost no detail below the map*, at any distance. Real terrain is rougher than a `gain` of 0.5 (its amplitude
// falls more like 0.7 per octave, which is what makes a 30 m hill metres tall rather than centimetres), so if the
// ground should have fine relief, the FIELD's spectrum is what has to change — one constant, and a look change to
// the map as well, which is why it is its own decision.
//
// **Band-limited by the PIXEL FOOTPRINT, never by distance.** A rung is faded out where a pixel is too big to
// resolve it: `fade = 1 - smoothstep(feature*0.25, feature*0.5, footprint)` — full while a pixel holds four
// samples per feature, gone by two, which is the sampling limit. Detail finer than the sampling rate is not "more
// detail", it is aliasing, and it is also what makes a distant body free.
float surface_detail(
	vec3 unit, int seed, float base_frequency, int first_octave, int octaves,
	float gain, float lacunarity, float bounding, float footprint
) {
	if (octaves <= 0 || first_octave < 0) {
		return 0.0;
	}
	float sum = 0.0;
	for (int rung = 0; rung < octaves; rung++) {
		int octave = first_octave + rung;
		// The octave's own frequency and feature size, in radians on the unit sphere.
		float frequency = base_frequency * exp2(float(octave));
		float feature = 1.0 / frequency;
		float fade = 1.0 - smoothstep(feature * 0.25, feature * 0.5, footprint);
		if (fade > 0.0) {
			// `seed + octave` and the same frequency the map's octave `octave` had, because `fnl_fbm3` applies its
			// transform once and then scales by the lacunarity — so this IS octave `octave` of the field's fbm.
			sum += fnl_fbm3(unit, seed + octave, frequency, 1, gain, lacunarity, 1.0)
				* bounding * pow(gain, float(octave)) * fade;
		}
	}
	return sum;
}


// The feature size, in radians on the unit sphere, of the finest thing the map can hold -- **two texels of a
// map `width` wide**. The ladder starts there, so it can never duplicate what the map already shows, and it
// moves when the map refines because the host recomputes it.
float surface_map_feature(int width) {
	return 2.0 * 6.283185307179586 / float(max(width, 1));
}
