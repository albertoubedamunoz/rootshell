import SwiftUI
import UIKit

#if !targetEnvironment(macCatalyst) && !os(visionOS)

private struct FullScreenLaunchNoticeModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Setting(Settings.Window.fullScreenMode) private var fullScreenModeEnabled
    @Setting(Settings.Window.fullScreenLaunchNoticeDismissed) private var neverRemindAgain
    @State private var isPresented = false

    // Process lifetime, not a preference: remind on each launch, never on
    // subsequent foreground transitions or when enabling the setting in-app.
    @MainActor private static var didCheckLaunch = false

    func body(content: Content) -> some View {
        // Keep the notice in the root safe area, outside MainView's fullscreen
        // layout, so the Dynamic Island/notch cannot obscure it in either orientation.
        ZStack(alignment: .top) {
            content

            if isPresented && fullScreenModeEnabled && !neverRemindAgain && scenePhase == .active {
                GeometryReader { geometry in
                    notice
                        .frame(maxHeight: max(0, geometry.size.height - 24), alignment: .top)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                    .task {
                        do {
                            try await Task.sleep(for: .seconds(voiceOverEnabled ? 20 : 8))
                        } catch {
                            return
                        }
                        isPresented = false
                    }
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active,
                  UIDevice.current.userInterfaceIdiom == .phone,
                  !Self.didCheckLaunch else { return }
            Self.didCheckLaunch = true
            isPresented = fullScreenModeEnabled && !neverRemindAgain
        }
        .onChange(of: fullScreenModeEnabled) { _, enabled in
            if !enabled { isPresented = false }
        }
    }

    private var notice: some View {
        // Use the card's natural height when it fits; otherwise keep the card
        // within the safe area and scroll its contents, including every action.
        ViewThatFits(in: .vertical) {
            noticeContent
            ScrollView(.vertical) {
                noticeContent
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: 440, alignment: .leading)
        .bannerBackground()
        .accessibilityElement(children: .contain)
    }

    private var noticeContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text("Full Screen is on")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Dismiss") {
                    isPresented = false
                }
                .font(.subheadline)
                .frame(minHeight: 44)
                .buttonStyle(.plain)
            }

            Text("Content may appear behind the Dynamic Island or notch.")
                .font(.subheadline)

            Text("Settings → Appearance → Window → Full Screen")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Turn Off Full Screen") {
                fullScreenModeEnabled = false
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Button("Never Remind Me Again") {
                neverRemindAgain = true
                isPresented = false
            }
            .font(.subheadline)
            .frame(minHeight: 44)
            .buttonStyle(.plain)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
    }
}

#endif

extension View {
    @ViewBuilder
    func fullScreenLaunchNotice() -> some View {
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            modifier(FullScreenLaunchNoticeModifier())
        } else {
            self
        }
        #else
        self
        #endif
    }
}
