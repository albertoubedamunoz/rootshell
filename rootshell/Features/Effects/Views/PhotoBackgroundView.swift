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

    var body: some View {
        GeometryReader { geometry in
            if let image = effect.filteredImage {
                if effect.kenBurnsEnabled {
                    KenBurnsImageView(
                        image: image,
                        speed: effect.speed,
                        size: geometry.size
                    )
                    .opacity(effect.intensity)
                    .blendMode(effectManager.isLightTheme ? .multiply : .plusLighter)
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .opacity(effect.intensity)
                        .blendMode(effectManager.isLightTheme ? .multiply : .plusLighter)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Ken Burns Animation

private struct KenBurnsImageView: View {
    let image: UIImage
    let speed: Double
    let size: CGSize

    @State private var currentScale: CGFloat = 1.0
    @State private var currentOffset: CGSize = .zero
    @State private var timer: Timer?

    private var cycleDuration: Double {
        20.0 / max(speed, 0.25)
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
                animateToNextKeyframe()
                startTimer()
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
            animateToNextKeyframe()
        }
    }

    private func animateToNextKeyframe() {
        let targetScale = CGFloat.random(in: 1.0...1.25)

        let maxOffsetX = (targetScale - 1.0) * size.width * 0.4
        let maxOffsetY = (targetScale - 1.0) * size.height * 0.4

        let targetOffset = CGSize(
            width: CGFloat.random(in: -maxOffsetX...maxOffsetX),
            height: CGFloat.random(in: -maxOffsetY...maxOffsetY)
        )

        withAnimation(.easeInOut(duration: cycleDuration)) {
            currentScale = targetScale
            currentOffset = targetOffset
        }
    }
}
