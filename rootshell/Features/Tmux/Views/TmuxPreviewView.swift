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

        /// Cell size in points once the surface has been sized; nil before.
        var cellSize: CGSize? {
            guard let surface, hasSized else { return nil }
            let size = ghostty_surface_size(surface)
            guard size.cell_width_px > 0, size.cell_height_px > 0 else { return nil }
            let scale = max(contentScaleFactor, 1)
            return CGSize(width: CGFloat(size.cell_width_px) / scale, height: CGFloat(size.cell_height_px) / scale)
        }

        /// The grid this surface actually renders into. Content wider than
        /// `columns` wraps, so callers sizing a surface to hold a captured
        /// screen must check this rather than trusting their own arithmetic
        /// (padding and rounding both eat columns).
        var gridSize: (columns: Int, rows: Int)? {
            guard let surface, hasSized else { return nil }
            let size = ghostty_surface_size(surface)
            guard size.columns > 0, size.rows > 0 else { return nil }
            return (Int(size.columns), Int(size.rows))
        }

        /// Write ANSI text content to the surface for rendering.
        func writeContent(_ ansiText: String) {
            // Clear screen + home cursor so stale content from a previous session is erased
            let clearPrefix = "\u{1b}[2J\u{1b}[H"
            // Terminal expects \r\n for proper line positioning; tmux capture-pane outputs \n only
            writeToSurface((clearPrefix + ansiText).replacingOccurrences(of: "\n", with: "\r\n"))
        }

        /// Replace the whole screen atomically (synchronized output), leaving
        /// the cursor at `cursor` or hidden. For live previews that repaint
        /// on every change: no intermediate blank frame is ever shown.
        func writeFrame(_ ansiText: String, cursor: (x: Int, y: Int, visible: Bool)?) {
            var text = "\u{1b}[?2026h\u{1b}[?25l\u{1b}[0m\u{1b}[H\u{1b}[2J"
            text += ansiText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            text += "\u{1b}[0m"
            if let cursor, cursor.visible {
                text += "\u{1b}[\(cursor.y + 1);\(cursor.x + 1)H\u{1b}[?25h"
            }
            text += "\u{1b}[?2026l"
            writeToSurface(text)
        }

        /// A frame is far larger than the pipe to the emulator: a coloured
        /// full screen runs to tens of KB against a pipe buffer of 16-64 KB,
        /// so `write` returns short and the rest MUST follow later. Dropping
        /// the remainder used to cut a frame mid-sequence — inside the
        /// synchronized-update wrapper that means the screen never repaints
        /// again, which is a preview that flashes once and then stays blank.
        private var pending = Data()
        /// A frame was cut short: the next one must abort its leftovers.
        private var pendingIsPartial = false
        private var drawScheduled = false
        private var flushScheduled = false

        private func writeToSurface(_ normalized: String) {
            guard slaveFd >= 0, surface != nil else { return }
            var text = ""
            if pendingIsPartial {
                // CAN abandons any half-written control sequence, then leave
                // synchronized output so this frame can paint.
                text = "\u{18}\u{1b}[?2026l"
            }
            text += normalized
            guard let data = text.data(using: .utf8), !data.isEmpty else { return }
            // A newer frame supersedes whatever is still queued: the preview
            // wants the latest screen, not every screen.
            pending = data
            pendingIsPartial = false
            flushPendingWrites()
        }

        /// Push as much of the queued frame as the pipe accepts. Callers on a
        /// display link call this every tick, so a frame too large for one
        /// write completes over the next few. Returns true when nothing is left.
        @discardableResult
        func flushPendingWrites() -> Bool {
            guard slaveFd >= 0, surface != nil else {
                pending.removeAll()
                pendingIsPartial = false
                return true
            }
            guard !pending.isEmpty else { return true }
            var written = 0
            pending.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress else { return }
                while written < buffer.count {
                    let n = write(slaveFd, ptr.advanced(by: written), buffer.count - written)
                    if n <= 0 { break }
                    written += n
                }
            }
            if written > 0 {
                pending.removeFirst(written)
                pendingIsPartial = !pending.isEmpty
                // Tick the app to process the written data through the terminal
                // emulator, then draw the surface to render it to the Metal layer.
                ghosttyApp?.appTick()
                scheduleDraw()
            }
            // Not every caller is on a display link, and the pipe drains on
            // the emulator's own thread: come back for the rest either way.
            if !pending.isEmpty { scheduleFlush() }
            return pending.isEmpty
        }

        private func scheduleFlush() {
            guard !flushScheduled else { return }
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                guard let self else { return }
                self.flushScheduled = false
                self.flushPendingWrites()
            }
        }

        private func scheduleDraw() {
            guard !drawScheduled else { return }
            drawScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.drawScheduled = false
                guard let surface = self.surface,
                      self.ghosttyApp?.isInBackground != true,
                      !Ghostty.isSecureDrawProhibitedAtomic else { return }
                self.ghosttyApp?.appTick()
                ghostty_surface_draw(surface)
            }
        }

        func cleanup() {
            pending.removeAll()
            pendingIsPartial = false
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
