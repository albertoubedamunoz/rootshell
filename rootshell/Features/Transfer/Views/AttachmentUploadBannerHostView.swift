//
//  AttachmentUploadBannerHostView.swift
//  rootshell
//
//  UIKit wrapper for hosting AttachmentUploadBannerView inside TerminalScrollView.
//

import SwiftUI
import UIKit

@MainActor
final class AttachmentUploadBannerHostView: SwiftUIBannerHostView<AttachmentUploadBannerView> {

    private(set) var currentState: AttachmentUploadBannerState?
    var onCancel: (() -> Void)?

    init() {
        super.init(layout: .topCentered)
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Updates the banner with new state; nil hides it.
    func update(state: AttachmentUploadBannerState?) {
        if state == currentState { return }
        currentState = state
        update(content: state.map { AttachmentUploadBannerView(state: $0, onCancel: onCancel) })
    }
}
