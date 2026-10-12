//
//  PhotoBackgroundView.swift
//  rootshell
//
//  SwiftUI view for photo background effect with optional Ken Burns animation
//

import SwiftUI

struct PhotoBackgroundView: View {
    @ObservedObject var effect: PhotoBackgroundEffect
    var effectManager = EffectManager.shared
    @Environment(\.terminalEffectBottomInset) private var bottomInset

    var body: some View {
        GeometryReader { geometry in
            // The photo fills the area above the keyboard, easing with it.
            let size = CGSize(width: geometry.size.width, height: max(1, geometry.size.height - bottomInset))
            Group {
                if let image = effect.filteredImage {
                    if effect.kenBurnsEnabled {
                        KenBurnsImageView(
                            image: image,
                            speed: effect.speed,
                            size: size
                        )
                        .opacity(effect.intensity)
                        .blendMode(effectManager.isLightTheme ? .multiply : .plusLighter)
                    } else {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size.width, height: size.height)
                            .clipped()
                            .opacity(effect.intensity)
                            .blendMode(effectManager.isLightTheme ? .multiply : .plusLighter)
                    }
                }
            }
            .animation(.easeOut(duration: EffectSceneFraction.duration), value: bottomInset)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Ken Burns Animation

private struct KenBurnsImageView: View {
    let image: UIImage
    let speed: Double
    let size: CGSize

    @Environment(\.terminalEffectRetainsState) private var retainsState
    @State private var hasStarted = false
    @State private var currentScale: CGFloat = 1.0
    @State private var currentOffset: CGSize = .zero
    // The repeating timer holds a copy of this view; State reads stay current.
    @State private var frameSize: CGSize = .zero
    @State private var keyframeStartScale: CGFloat = 1.0
    @State private var timer: Timer?

    private var cycleDuration: Double {
        20.0 / max(speed, 0.25)
    }

    /// Pan that keeps the zoomed photo covering the frame.
    private static func panLimit(scale: CGFloat, size: CGSize) -> CGSize {
        CGSize(width: (scale - 1.0) * size.width * 0.4, height: (scale - 1.0) * size.height * 0.4)
    }

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .scaleEffect(currentScale)
            .offset(currentOffset)
            .clipped()
            .onAppear {
                frameSize = size
                if !retainsState || !hasStarted {
                    animateToNextKeyframe(in: size)
                    hasStarted = true
                }
                startTimer()
            }
            .onChange(of: size) { _, newSize in
                frameSize = newSize
                // The scale is still easing from the keyframe's start, so the
                // smaller of the two bounds the pan until the keyframe ends.
                let limit = Self.panLimit(scale: min(keyframeStartScale, currentScale), size: newSize)
                let clamped = CGSize(width: min(max(currentOffset.width, -limit.width), limit.width),
                                     height: min(max(currentOffset.height, -limit.height), limit.height))
                guard clamped != currentOffset else { return }
                // Matches the frame's keyboard easing, so the pan stays in bounds throughout.
                withAnimation(.easeOut(duration: EffectSceneFraction.duration)) {
                    currentOffset = clamped
                }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
            .onChange(of: speed) { _, _ in
                // Restart timer with new duration
                timer?.invalidate()
                startTimer()
            }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: cycleDuration, repeats: true) { _ in
            animateToNextKeyframe(in: frameSize)
        }
    }

    private func animateToNextKeyframe(in size: CGSize) {
        let targetScale = CGFloat.random(in: 1.0...1.25)
        let limit = Self.panLimit(scale: targetScale, size: size)

        let targetOffset = CGSize(
            width: CGFloat.random(in: -limit.width...limit.width),
            height: CGFloat.random(in: -limit.height...limit.height)
        )

        keyframeStartScale = currentScale
        withAnimation(.easeInOut(duration: cycleDuration)) {
            currentScale = targetScale
            currentOffset = targetOffset
        }
    }
}
