//
//  TmuxPreviewView.swift
//  rootshell
//
//  Lightweight read-only Ghostty surface for rendering tmux pane previews.
//

import UIKit
import SwiftUI
import GhosttyKit
import os

extension Ghostty {

    /// A minimal UIView hosting a read-only Ghostty surface for previewing tmux pane content.
    /// No keyboard input, gestures, sessions, or scrollback — just renders ANSI text.
    class TmuxPreviewView: UIView {

        private nonisolated static let logger = Logger(
            subsystem: "com.rootshell",
            category: "TmuxPreviewView"
        )

        private weak var ghosttyApp: Ghostty.App?
        private var surface: ghostty_surface_t?
        private var slaveFd: Int32 = -1
        private var hasSized = false

        override class var layerClass: AnyClass { CAMetalLayer.self }

        init(ghosttyApp: Ghostty.App) {
            self.ghosttyApp = ghosttyApp
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            isOpaque = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil && surface == nil {
                createSurface()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()

            // Sync Ghostty's IOSurfaceLayer sublayer frames to match our bounds
            if let sublayers = layer.sublayers {
                for sublayer in sublayers {
                    if sublayer.frame != bounds {
                        sublayer.frame = bounds
                    }
                }
            }

            guard let surface = surface else { return }
            let size = bounds.size
            guard size.width > 0 && size.height > 0 else { return }

            let scale = contentScaleFactor
            let fbWidth = UInt32(size.width * scale)
            let fbHeight = UInt32(size.height * scale)

            ghostty_surface_set_content_scale(surface, scale, scale)
            ghostty_surface_set_size(surface, fbWidth, fbHeight)
            hasSized = true
        }

        private func createSurface() {
            guard let app = ghosttyApp?.app else {
                Self.logger.error("Cannot create preview surface: app pointer is nil")
                return
            }

            var cfg = ghostty_surface_config_new()
            cfg.platform_tag = GHOSTTY_PLATFORM_IOS
            cfg.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
                uiview: Unmanaged.passUnretained(self).toOpaque()
            ))
            cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
            cfg.scale_factor = contentScaleFactor
            cfg.use_external_io = true

            guard let newSurface = ghostty_surface_new(app, &cfg) else {
                Self.logger.error("Failed to create preview surface")
                return
            }

            self.surface = newSurface
            self.slaveFd = ghostty_surface_get_slave_fd(newSurface)
            ghosttyApp?.registerSurface(newSurface)
        }

        /// Write ANSI text content to the surface for rendering.
        func writeContent(_ ansiText: String) {
            guard slaveFd >= 0, surface != nil else { return }
            // Clear screen + home cursor so stale content from a previous session is erased
            let clearPrefix = "\u{1b}[2J\u{1b}[H"
            // Terminal expects \r\n for proper line positioning; tmux capture-pane outputs \n only
            let normalized = (clearPrefix + ansiText).replacingOccurrences(of: "\n", with: "\r\n")
            guard let data = normalized.data(using: .utf8) else { return }

            // Write the ANSI content to the slave fd
            data.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress else { return }
                var written = 0
                let total = buffer.count
                while written < total {
                    let n = write(slaveFd, ptr.advanced(by: written), total - written)
                    if n <= 0 { break }
                    written += n
                }
            }

            // Tick the app to process the written data through the terminal emulator,
            // then draw the surface to render it to the Metal layer.
            ghosttyApp?.appTick()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, let surface = self.surface,
                      self.ghosttyApp?.isInBackground != true,
                      !Ghostty.isSecureDrawProhibitedAtomic else { return }
                self.ghosttyApp?.appTick()
                ghostty_surface_draw(surface)
            }
        }

        func cleanup() {
            guard let surface = self.surface else { return }
            ghosttyApp?.unregisterSurface(surface)
            self.surface = nil
            self.slaveFd = -1

            TerminalView.ghosttyAPIQueue.async {
                ghostty_surface_free(surface)
            }
        }

        deinit {
            // cleanup() should be called explicitly before deallocation,
            // but guard against leaks if it wasn't
            if surface != nil {
                Self.logger.warning("TmuxPreviewView deallocated without cleanup()")
            }
        }
    }
}

// MARK: - SwiftUI Wrapper

struct TmuxPreviewContainer: UIViewRepresentable {
    let content: String
    let previewSize: CGSize
    @EnvironmentObject var ghosttyApp: Ghostty.App

    func makeUIView(context: Context) -> Ghostty.TmuxPreviewView {
        Ghostty.TmuxPreviewView(ghosttyApp: ghosttyApp)
    }

    func updateUIView(_ uiView: Ghostty.TmuxPreviewView, context: Context) {
        // Only write when the content actually changes (handles SwiftUI view reuse)
        guard context.coordinator.writtenContent != content else { return }
        context.coordinator.writtenContent = content

        // Delay to allow didMoveToWindow + layoutSubviews to fire first,
        // so the surface exists and has been sized before we write content.
        let contentToWrite = content
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Verify content hasn't changed again before the delayed write fires
            guard context.coordinator.writtenContent == contentToWrite else { return }
            uiView.writeContent(contentToWrite)
        }
    }

    static func dismantleUIView(_ uiView: Ghostty.TmuxPreviewView, coordinator: Coordinator) {
        uiView.cleanup()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var writtenContent: String?
    }
}
