//
//  MilkyWayLayer.swift
//  rootshell
//
//  Renders a subtle Milky Way galaxy band across the night sky.
//  Uses a curved gradient path to simulate the galaxy's arc.
//

import SwiftUI

struct MilkyWayLayer: View {
    let visibility: Double

    var body: some View {
        Canvas { context, size in
            // Draw the Milky Way as a curved band across the sky
            // Diagonal band from lower-left to upper-right
            let bandPath = createMilkyWayPath(size: size)

            // Multi-layer gradient for depth
            context.fill(
                bandPath,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(white: 1.0, opacity: 0.02),
                        Color(white: 1.0, opacity: 0.06),
                        Color(white: 1.0, opacity: 0.08),
                        Color(white: 1.0, opacity: 0.06),
                        Color(white: 1.0, opacity: 0.03),
                        Color(white: 1.0, opacity: 0.02)
                    ]),
                    startPoint: CGPoint(x: 0, y: size.height),
                    endPoint: CGPoint(x: size.width, y: 0)
                )
            )

            // Add subtle color variation (slight blue-purple tint)
            let colorTintPath = createMilkyWayPath(size: size)
            context.fill(
                colorTintPath,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.6, green: 0.65, blue: 0.8, opacity: 0.02),
                        Color(red: 0.7, green: 0.7, blue: 0.85, opacity: 0.04),
                        Color(red: 0.75, green: 0.72, blue: 0.9, opacity: 0.03),
                        Color(red: 0.6, green: 0.65, blue: 0.8, opacity: 0.02)
                    ]),
                    startPoint: CGPoint(x: size.width * 0.3, y: size.height * 0.7),
                    endPoint: CGPoint(x: size.width * 0.7, y: size.height * 0.2)
                )
            )

            // Dense central region (galactic core simulation)
            let corePath = createGalacticCorePath(size: size)
            context.fill(
                corePath,
                with: .radialGradient(
                    Gradient(colors: [
                        Color(white: 1.0, opacity: 0.08),
                        Color(white: 1.0, opacity: 0.04),
                        Color.clear
                    ]),
                    center: CGPoint(x: size.width * 0.45, y: size.height * 0.35),
                    startRadius: 0,
                    endRadius: size.width * 0.25
                )
            )
        }
        .blur(radius: 25)
        .opacity(visibility * 0.5)
    }

    /// Create the main Milky Way band path
    private func createMilkyWayPath(size: CGSize) -> Path {
        var path = Path()

        // Main band - curved from lower-left to upper-right
        path.move(to: CGPoint(x: 0, y: size.height * 0.75))

        // Upper edge of band
        path.addQuadCurve(
            to: CGPoint(x: size.width, y: size.height * 0.05),
            control: CGPoint(x: size.width * 0.5, y: size.height * 0.25)
        )

        // Right edge
        path.addLine(to: CGPoint(x: size.width, y: size.height * 0.18))

        // Lower edge of band (wider band)
        path.addQuadCurve(
            to: CGPoint(x: 0, y: size.height * 0.85),
            control: CGPoint(x: size.width * 0.5, y: size.height * 0.42)
        )

        path.closeSubpath()

        return path
    }

    /// Create the galactic core region (brighter center)
    private func createGalacticCorePath(size: CGSize) -> Path {
        var path = Path()

        // Elliptical core region
        let coreCenter = CGPoint(x: size.width * 0.45, y: size.height * 0.35)
        let coreWidth: CGFloat = size.width * 0.3
        let coreHeight: CGFloat = size.height * 0.15

        path.addEllipse(in: CGRect(
            x: coreCenter.x - coreWidth / 2,
            y: coreCenter.y - coreHeight / 2,
            width: coreWidth,
            height: coreHeight
        ))

        return path
    }
}

// MARK: - Preview

#Preview("Milky Way") {
    ZStack {
        Color(red: 0.02, green: 0.02, blue: 0.05)
        MilkyWayLayer(visibility: 1.0)
    }
}
