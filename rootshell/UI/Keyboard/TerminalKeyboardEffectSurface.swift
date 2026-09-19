#if !os(visionOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import Combine
import UIKit

/// Retains the SwiftUI subtree (including animation clocks, simulations and
/// players) while UIKit replaces the terminal's keyboard input hierarchy.
@MainActor
final class TerminalKeyboardEffectSurface {
    final class Appearance: ObservableObject {
        @Published var backgroundColor = UIColor.clear
    }
    let appearance = Appearance()
    private(set) var contentView: (UIView & UIContentView)?
    private var effectID: AnyHashable?

    func attach(to owner: UIView, above background: UIView, effectID: AnyHashable,
                backgroundColor: UIColor, makeContent: () -> AnyView) {
        if !appearance.backgroundColor.isEqual(backgroundColor) { appearance.backgroundColor = backgroundColor }
        if contentView == nil || self.effectID != effectID {
            contentView?.removeFromSuperview()
            let content = makeContent()
            let configuration = UIHostingConfiguration { content }
                .margins(.all, 0)
                .minSize(width: 0, height: 0)
            // Content configurations avoid manually parenting a hosting
            // controller into UIKit's changing input-controller hierarchy.
            let view = configuration.makeContentView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
            view.clipsToBounds = true
            view.layer.cornerCurve = .continuous
            contentView = view
            self.effectID = effectID
        }
        if let contentView, contentView.superview !== owner {
            owner.insertSubview(contentView, aboveSubview: background)
        }
    }

    func detach(from owner: UIView) {
        // An outgoing keyboard can receive late window/settings callbacks
        // after the same surface has already moved to the incoming keyboard.
        guard contentView?.superview === owner else { return }
        contentView?.removeFromSuperview()
    }
}
#endif
