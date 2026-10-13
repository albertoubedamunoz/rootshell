// WeatherGPUTypes.swift
// rootshell

#if !CHINA_BUILD
import Foundation

// SIMD4-only records keep Swift and Metal layouts identical. The matching
// structs live at the top of Weather.metal.
nonisolated struct WeatherUniforms: Sendable {
    var cameraForward: SIMD4<Float>  // xyz, tan(half width)
    var cameraRight: SIMD4<Float>    // xyz, tan(half height)
    var cameraUp: SIMD4<Float>       // xyz, animation phase (s)
    var sunDirection: SIMD4<Float>   // xyz, altitude (rad)
    var moonDirection: SIMD4<Float>  // xyz, visible illuminated fraction
    var sunRadiance: SIMD4<Float>    // rgb at the ground, disc radius (rad)
    var keyLight: SIMD4<Float>       // xyz of the light on the clouds, moon disc radius (rad)
    var keyColor: SIMD4<Float>       // rgb, exposure
    var clouds: SIMD4<Float>         // low cover, high cover, density, towering
    var precipitation: SIMD4<Float>  // rain, snow, sleet mix, gustiness
    var atmosphere: SIMD4<Float>     // fog, haze, flash, star visibility
    var hazeTint: SIMD4<Float>       // rgb, Milky Way strength
    var wind: SIMD4<Float>           // cloud drift x, z (km), screen-space wind, strength
    var cloudShift: SIMD4<Float>     // uv shift xy, jitter frame, history valid
    var strike: SIMD4<Float>         // uv xy, glow radius, glow (HDR)
    var viewport: SIMD4<Float>       // width, height, 1/width, 1/height
    var composition: SIMD4<Float>    // intensity, reading protection, light theme, sun and moon
    var equatorialX: SIMD4<Float>    // rows taking equatorial unit vectors to world space
    var equatorialY: SIMD4<Float>
    var equatorialZ: SIMD4<Float>
    var galaxy: SIMD4<Float>         // galactic north pole xyz, cloud steps
    var galaxyCenter: SIMD4<Float>   // xyz, reserved
    var rainColor: SIMD4<Float>      // display rgb, reserved
    var snowColor: SIMD4<Float>      // display rgb, reserved
    var scene: SIMD4<Float>          // visible height fraction, its reciprocal, reserved, reserved
    var cloudForm: SIMD4<Float>      // mid cover, low base (km), cumuliform, reserved
}

nonisolated struct WeatherStar: Sendable {
    var equatorial: SIMD4<Float>     // unit vector, visual magnitude
    var color: SIMD4<Float>          // rgb, twinkle seed
}

nonisolated func wxV4(_ v: SIMD3<Float>, _ w: Float) -> SIMD4<Float> { SIMD4(v.x, v.y, v.z, w) }
#endif
