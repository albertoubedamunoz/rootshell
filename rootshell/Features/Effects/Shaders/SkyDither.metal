//
//  SkyDither.metal
//  rootshell
//
//  Metal shader for blue noise dithering to eliminate gradient banding.
//  Uses interleaved gradient noise (Jorge Jimenez, SIGGRAPH 2014) which
//  produces visually pleasing dither patterns that don't exhibit the
//  structured artifacts of Bayer matrix dithering.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Blue noise dithering shader to eliminate gradient banding
///
/// Applies interleaved gradient noise to add +/- 0.5 LSB at 8-bit precision,
/// breaking up quantization artifacts in smooth gradients. The noise pattern
/// is designed to be visually imperceptible while completely eliminating
/// visible banding.
///
/// Parameters:
/// - position: Current pixel position (provided by SwiftUI)
/// - color: Input color from the gradient
/// - size: View dimensions (unused but required for consistency)
/// - time: Elapsed time for subtle temporal variation
[[ stitchable ]] half4 skyDither(
    float2 position,
    half4 color,
    float2 size,
    float time
) {
    // Interleaved gradient noise (Jorge Jimenez, SIGGRAPH 2014)
    // This produces high-quality blue noise distribution without
    // requiring a texture lookup. The magic numbers are carefully
    // chosen to produce minimal correlation between pixels.
    float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
    float noise = fract(magic.z * fract(dot(position, magic.xy)));

    // Add subtle temporal variation to prevent static noise patterns
    // from becoming visible during animation. The 0.1 multiplier keeps
    // the variation subtle enough to not cause flickering.
    noise = fract(noise + time * 0.1);

    // Convert to signed noise in range [-0.5/255, +0.5/255]
    // This is exactly 1 LSB at 8-bit precision - enough to break
    // up banding but completely invisible to the eye.
    float ditherAmount = (noise - 0.5) / 255.0;

    // Apply dither to RGB channels only (preserve alpha)
    half3 ditheredColor = color.rgb + half(ditherAmount);

    return half4(ditheredColor, color.a);
}

// 4x4 Bayer matrix normalized to [-0.5, 0.5] range (at file scope)
// This classic ordered dithering pattern produces a distinctive
// crosshatch pattern when visible, but at low intensity is
// imperceptible and eliminates banding effectively.
constant float bayerMatrix[16] = {
    -0.5,     0.25,    -0.375,   0.375,
     0.0,    -0.25,     0.125,  -0.125,
    -0.3125,  0.4375,  -0.4375,  0.3125,
     0.1875, -0.0625,   0.0625, -0.1875
};

/// Alternative ordered (Bayer) dithering for a more structured look
///
/// Uses a 4x4 Bayer matrix which produces a more regular, less noisy
/// appearance. Some users may prefer this for certain aesthetics,
/// though it can show visible patterns at very low intensity.
///
/// Parameters:
/// - position: Current pixel position (provided by SwiftUI)
/// - color: Input color from the gradient
/// - size: View dimensions (unused)
[[ stitchable ]] half4 skyDitherBayer(
    float2 position,
    half4 color,
    float2 size
) {
    int x = int(position.x) % 4;
    int y = int(position.y) % 4;
    float threshold = bayerMatrix[y * 4 + x];

    // Scale to 1 LSB at 8-bit precision
    float ditherAmount = threshold / 255.0;

    half3 ditheredColor = color.rgb + half(ditherAmount);

    return half4(ditheredColor, color.a);
}
