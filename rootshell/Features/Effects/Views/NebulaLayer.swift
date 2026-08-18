//
//  NebulaLayer.swift
//  rootshell
//
//  Renders subtle nebula clouds for deep night sky ambiance.
//  Adds colorful diffuse regions reminiscent of emission nebulae.
//

import SwiftUI

struct NebulaLayer: View {
    let visibility: Double

    // Predefined nebula positions and colors
    private let nebulae: [(center: UnitPoint, color: Color, size: CGFloat)] = [
        // Purple/magenta nebula (like Orion Nebula region)
        (UnitPoint(x: 0.2, y: 0.25), Color(red: 0.55, green: 0.25, blue: 0.55), 0.35),

        // Blue nebula (reflection nebula style)
        (UnitPoint(x: 0.75, y: 0.15), Color(red: 0.25, green: 0.35, blue: 0.55), 0.28),

        // Teal/cyan nebula
        (UnitPoint(x: 0.55, y: 0.45), Color(red: 0.3, green: 0.45, blue: 0.45), 0.25),

        // Rose/pink nebula
        (UnitPoint(x: 0.85, y: 0.55), Color(red: 0.5, green: 0.3, blue: 0.4), 0.22),

        // Deep blue (dark nebula hint)
        (UnitPoint(x: 0.35, y: 0.6), Color(red: 0.2, green: 0.25, blue: 0.4), 0.30),
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(0..<nebulae.count, id: \.self) { index in
                    let nebula = nebulae[index]
                    let nebulaSize = geometry.size.width * nebula.size

                    // Multiple overlapping circles for organic shape
                    ZStack {
                        // Main cloud
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        nebula.color.opacity(0.12),
                                        nebula.color.opacity(0.06),
                                        nebula.color.opacity(0.02),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: nebulaSize / 2
                                )
                            )
                            .frame(width: nebulaSize, height: nebulaSize)

                        // Secondary offset cloud for irregularity
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        nebula.color.opacity(0.08),
                                        nebula.color.opacity(0.03),
                                        Color.clear
                                    ],
                                    center: UnitPoint(x: 0.3, y: 0.4),
                                    startRadius: 0,
                                    endRadius: nebulaSize * 0.4
                                )
                            )
                            .frame(width: nebulaSize * 0.8, height: nebulaSize * 0.9)
                            .offset(x: nebulaSize * 0.1, y: -nebulaSize * 0.1)

                        // Tertiary wisp
                        Ellipse()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        nebula.color.opacity(0.06),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: nebulaSize * 0.3
                                )
                            )
                            .frame(width: nebulaSize * 0.6, height: nebulaSize * 0.3)
                            .rotationEffect(.degrees(Double(index) * 30 + 15))
                            .offset(x: -nebulaSize * 0.15, y: nebulaSize * 0.1)
                    }
                    .position(
                        x: geometry.size.width * nebula.center.x,
                        y: geometry.size.height * nebula.center.y
                    )
                    .blur(radius: 40)
                }
            }
        }
        .opacity(visibility * 0.25)
    }
}

// MARK: - Preview

#Preview("Nebulae") {
    ZStack {
        Color(red: 0.02, green: 0.02, blue: 0.05)
        NebulaLayer(visibility: 1.0)
    }
}
