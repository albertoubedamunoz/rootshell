//
//  HardwareKeyIllustrations.swift
//  rootshell
//
//  Procedural illustrations for HardwareKeyPromptView: a little YubiKey that
//  glides up to its port and asks to be let in, and a sonar-ringed touch
//  contact for the touch phase. Pure SwiftUI shapes, no assets, modeled on
//  the YubiKey 5C profile: matte black body, protruding silver USB-C
//  connector, centered gold touch disc, rimmed keyring hole.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI

/// The gold gradient shared by the key's touch contact and the touch-phase disc.
private let contactGold = LinearGradient(
    colors: [
        Color(red: 0.95, green: 0.78, blue: 0.34),
        Color(red: 0.80, green: 0.62, blue: 0.20),
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)

/// Deeper gold used for rims and the disc's embossed ring.
private let rimGold = Color(red: 0.63, green: 0.47, blue: 0.13)

/// Brushed-metal gradient for the USB-C connector shield.
private let connectorSilver = LinearGradient(
    colors: [
        Color(white: 0.88),
        Color(white: 0.62),
    ],
    startPoint: .top,
    endPoint: .bottom
)

/// Gold touch contact with an embossed ring, shared by the key body and the
/// touch-phase illustration.
struct GoldContactDisc: View {
    var diameter: CGFloat

    var body: some View {
        Circle()
            .fill(contactGold)
            .overlay(
                Circle()
                    .inset(by: diameter * 0.18)
                    .stroke(rimGold.opacity(0.6), lineWidth: 1)
            )
            .frame(width: diameter, height: diameter)
    }
}

/// Side profile of a YubiKey 5C: black body with keyring hole and gold touch
/// disc, silver USB-C connector protruding toward the port. ~72x22.
struct YubiKeyShapeView: View {
    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.28), Color(white: 0.10)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                HStack {
                    Circle()
                        .fill(.black.opacity(0.7))
                        .overlay(Circle().strokeBorder(rimGold.opacity(0.8), lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .padding(.leading, 6)
                    Spacer()
                }
                GoldContactDisc(diameter: 13)
            }
            .frame(width: 60, height: 22)

            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(connectorSilver)
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(Color(white: 0.45), lineWidth: 0.5)
                )
                .frame(width: 12, height: 10)
        }
    }
}

/// The side of a device with a port slot, for the key to aim at. One slot
/// shape serves both USB-C and Lightning.
private struct PortSlotView: View {
    var body: some View {
        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: 3,
                bottomLeadingRadius: 3,
                style: .continuous
            )
            .fill(.secondary.opacity(0.35))
            // Sized to just fit the connector so it reads as a USB-C receptacle.
            Capsule()
                .fill(.black.opacity(0.55))
                .frame(width: 4, height: 13)
        }
        .frame(width: 10, height: 60)
    }
}

/// Insert phase: the key glides toward the slot, bumps, recoils with a small
/// tilt, retreats, and waits before trying again.
struct YubiKeyInsertIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Pose {
        var x: CGFloat = -34
        var tiltDegrees: Double = 0
    }

    var body: some View {
        HStack(spacing: 2) {
            if reduceMotion {
                YubiKeyShapeView()
                    .offset(x: -10)
            } else {
                YubiKeyShapeView()
                    .keyframeAnimator(initialValue: Pose()) { view, pose in
                        view
                            .offset(x: pose.x)
                            .rotationEffect(.degrees(pose.tiltDegrees))
                    } keyframes: { _ in
                        // Both tracks total 3.4s so the loop stays in sync.
                        KeyframeTrack(\.x) {
                            SpringKeyframe(-4, duration: 0.7, spring: .smooth)
                            LinearKeyframe(0, duration: 0.12)
                            SpringKeyframe(-12, duration: 0.38, spring: .bouncy)
                            SpringKeyframe(-34, duration: 0.8, spring: .smooth)
                            LinearKeyframe(-34, duration: 1.4)
                        }
                        KeyframeTrack(\.tiltDegrees) {
                            LinearKeyframe(0, duration: 0.82)
                            SpringKeyframe(-4, duration: 0.15, spring: .bouncy)
                            SpringKeyframe(3, duration: 0.2, spring: .bouncy)
                            SpringKeyframe(0, duration: 0.4, spring: .smooth)
                            LinearKeyframe(0, duration: 1.83)
                        }
                    }
            }
            PortSlotView()
        }
        .frame(width: 120, height: 60, alignment: .trailing)
    }
}

/// Touch phase: the gold contact with expanding sonar rings and a fingertip
/// nudging toward it.
struct YubiKeyTouchIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    Canvas { g, size in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        // Three rings phase-offset by a third of the cycle so
                        // the stagger never drifts.
                        for i in 0..<3 {
                            let p = ((t / 1.8) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                            let radius = 14 + p * 20
                            let rect = CGRect(
                                x: center.x - radius,
                                y: center.y - radius,
                                width: radius * 2,
                                height: radius * 2
                            )
                            g.stroke(
                                Circle().path(in: rect),
                                with: .color(.orange.opacity((1 - p) * 0.55)),
                                lineWidth: 2
                            )
                        }
                    }
                }
            }
            GoldContactDisc(diameter: 26)
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
                .offset(x: 18, y: 14)
                .symbolEffect(.wiggle, options: .repeat(.periodic(delay: 2.0)), isActive: !reduceMotion)
        }
        .frame(width: 120, height: 60)
    }
}

#Preview("Insert") {
    YubiKeyInsertIllustration()
        .padding()
}

#Preview("Touch") {
    YubiKeyTouchIllustration()
        .padding()
}
