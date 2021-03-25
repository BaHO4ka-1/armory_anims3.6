package armory.renderpath;

import kha.FastFloat;
import kha.graphics4.TextureFormat;
import kha.graphics4.Usage;

import iron.data.WorldData;
import iron.math.Vec2;
import iron.math.Vec3;

import armory.math.Helper;

/**
	Utility class to control the Nishita sky model.
**/
class Nishita {

	public static var data: NishitaData = null;

	/**
		Recompute the nishita lookup table. Call this function after updating
		the sky density settings.
	**/
	public static function recompute(world: WorldData) {
		if (world == null || world.raw.sun_direction == null) return;
		if (data == null) data = new NishitaData();

		// TODO
		data.computeLUT(new Vec3(1.0, 1.0, 1.0));
	}
}

/**
	This class holds the precalculated result of the inner scattering integral
	of the Nishita sky model. The outer integral is calculated in
	[`armory/Shaders/std/sky.glsl`](https://github.com/armory3d/armory/blob/master/Shaders/std/sky.glsl).

	@see `armory.renderpath.Nishita`
**/
class NishitaData {

	public var lut: kha.Image;

	/**
		The amount of individual sample heights stored in the LUT (and the width
		of the LUT image).
	**/
	public static var lutHeightSteps = 128;
	/**
		The amount of individual sun angle steps stored in the LUT (and the
		height of the LUT image).
	**/
	public static var lutAngleSteps = 128;

	/**
		Amount of steps for calculating the inner scattering integral. Heigher
		values are more precise but take longer to compute.
	**/
	public static var jSteps = 8;

	/** Radius of the atmosphere in meters. **/
	public static var radiusAtmo = 6420000;
	/**
		Radius of the planet in meters. The default value is the earth radius as
		defined in Cycles.
	**/
	public static var radiusPlanet = 6360000;

	/** Rayleigh scattering scale parameter. **/
	public static var rayleighScale = 8e3;
	/** Mie scattering scale parameter. **/
	public static var mieScale = 1.2e3;

	public function new() {}

	/** Approximates the density of ozone for a given sample height. **/
	function getOzoneDensity(height: FastFloat): FastFloat {
		// Values are taken from Cycles code
		if (height < 10000.0 || height >= 40000.0) {
			return 0.0;
		}
		if (height < 25000.0) {
			return (height - 10000.0) / 15000.0;
		}
		return -((height - 40000.0) / 15000.0);
	}

	/**
		Ray-sphere intersection test that assumes the sphere is centered at the
		origin. There is no intersection when result.x > result.y. Otherwise
		this function returns the distances to the two intersection points,
		which might be equal.
	**/
	function raySphereIntersection(rayOrigin: Vec3, rayDirection: Vec3, sphereRadius: Int): Vec2 {
		// Algorithm is described here: https://en.wikipedia.org/wiki/Line%E2%80%93sphere_intersection
		var a = rayDirection.dot(rayDirection);
		var b = 2.0 * rayDirection.dot(rayOrigin);
		var c = rayOrigin.dot(rayOrigin) - (sphereRadius * sphereRadius);
		var d = (b * b) - 4.0 * a * c;

		// Ray does not intersect the sphere
		if (d < 0.0) return new Vec2(1e5, -1e5);

		return new Vec2(
			(-b - Math.sqrt(d)) / (2.0 * a),
			(-b + Math.sqrt(d)) / (2.0 * a)
		);
	}

	/**
		Computes the LUT texture for the given density values.
		@param density 3D vector of air density, dust density, ozone density
	**/
	public function computeLUT(density: Vec3) {
		var imageData = new haxe.io.Float32Array(lutHeightSteps * lutAngleSteps * 4);

		for (x in 0...lutHeightSteps) {
			var height = (x / (lutHeightSteps - 1));

			// Use quadratic height for better horizon precision
			height *= height;
			height *= radiusAtmo; // Denormalize

			for (y in 0...lutAngleSteps) {
				var sunTheta = y / (lutAngleSteps - 1) * 2 - 1;

				// Improve horizon precision
				// See https://sebh.github.io/publications/egsr2020.pdf (5.3)
				sunTheta = Helper.sign(sunTheta) * sunTheta * sunTheta;
				sunTheta = sunTheta * Math.PI / 2 + Math.PI / 2; // Denormalize

				var jODepth = sampleSecondaryRay(height, sunTheta, density);

				var pixelIndex = (x + y * lutHeightSteps) * 4;
				imageData[pixelIndex + 0] = jODepth.x;
				imageData[pixelIndex + 1] = jODepth.y;
				imageData[pixelIndex + 2] = jODepth.z;
				imageData[pixelIndex + 3] = 1.0; // Unused
			}
		}

		lut = kha.Image.fromBytes(imageData.view.buffer, lutHeightSteps, lutAngleSteps, TextureFormat.RGBA128, Usage.StaticUsage);
	}

	/**
		Calculates the integral for the secondary ray.
	**/
	public function sampleSecondaryRay(height: FastFloat, sunTheta: FastFloat, density: Vec3): Vec3 {
		// Reconstruct values from the shader
		var iPos = new Vec3(0, 0, height + radiusPlanet);
		var pSun = new Vec3(0.0, Math.sin(sunTheta), Math.cos(sunTheta)).normalize();

		var jTime: FastFloat = 0.0;
		var jStepSize: FastFloat = raySphereIntersection(iPos, pSun, radiusAtmo).y / jSteps;

		// Optical depth accumulators for the secondary ray (Rayleigh, Mie, ozone)
		var jODepth = new Vec3();

		for (i in 0...jSteps) {

			// Calculate the secondary ray sample position and height
			var jPos = iPos.clone().add(pSun.clone().mult(jTime + jStepSize * 0.5));
			var jHeight = jPos.length() - radiusPlanet;

			// Accumulate optical depth
			var optDepthRayleigh = Math.exp(-jHeight / rayleighScale) * density.x;
			var optDepthMie = Math.exp(-jHeight / mieScale) * density.y;
			var optDepthOzone = getOzoneDensity(jHeight) * density.z;
			jODepth.addf(optDepthRayleigh, optDepthMie, optDepthOzone);

			jTime += jStepSize;
		}

		return jODepth.mult(jStepSize);
	}
}
