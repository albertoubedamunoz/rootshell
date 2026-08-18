//
//  VideoBackgroundView.swift
//  rootshell
//
//  SwiftUI view for video background effect
//

import SwiftUI

/// SwiftUI view that renders a video background effect
struct VideoBackgroundView: View {
    @ObservedObject var effect: VideoBackgroundEffect
    var effectManager = EffectManager.shared

    var body: some View {
        GeometryReader { geometry in
            VideoPlayerRepresentable(
                videoURL: effect.videoInfo.videoURL,
                aspectMode: effect.videoInfo.aspectMode,
                aspectAlignment: effect.videoInfo.aspectAlignment,
                seamlessLoop: effect.videoInfo.seamlessLoop,
                crossfadeDuration: effect.videoInfo.crossfadeDuration,
                playbackRate: effect.speed,
                themeTintEnabled: effect.themeTintEnabled,
                themeTintAmount: effect.themeTintAmount,
                themeColors: effect.themeColors
            )
            .id("\(effect.videoInfo.id)-\(effect.videoInfo.seamlessLoop ? "seamless" : "crossfade")")
            .opacity(effect.intensity)
            .blendMode(effectManager.isLightTheme ? .multiply : .plusLighter)
        }
        .allowsHitTesting(false)
    }
}

/// UIViewRepresentable wrapper for VideoBackgroundUIView
struct VideoPlayerRepresentable: UIViewRepresentable {
    let videoURL: URL
    let aspectMode: VideoAspectMode
    let aspectAlignment: VideoAspectAlignment
    let seamlessLoop: Bool
    let crossfadeDuration: TimeInterval
    let playbackRate: Double
    let themeTintEnabled: Bool
    let themeTintAmount: Double
    let themeColors: EffectThemeColors

    func makeUIView(context: Context) -> VideoBackgroundUIView {
        VideoBackgroundUIView(
            videoURL: videoURL,
            aspectMode: aspectMode,
            aspectAlignment: aspectAlignment,
            seamlessLoop: seamlessLoop,
            crossfadeDuration: crossfadeDuration,
            playbackRate: playbackRate,
            themeTintEnabled: themeTintEnabled,
            themeTintAmount: themeTintAmount,
            themeColors: themeColors
        )
    }

    func updateUIView(_ uiView: VideoBackgroundUIView, context: Context) {
        uiView.updatePlaybackRate(playbackRate)
        uiView.updateThemeTint(
            enabled: themeTintEnabled,
            amount: themeTintAmount,
            themeColors: themeColors
        )
    }
}
