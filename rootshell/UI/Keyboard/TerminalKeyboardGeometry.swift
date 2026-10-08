import Foundation
import CoreGraphics

/// Keyboard notifications can describe the system keyboard without its input
/// accessory after reloadInputViews. Include the accessory's actual placement,
/// without adding its height twice when the notification already includes it.
nonisolated enum TerminalKeyboardGeometry {
    /// Frames must share coordinates. Window origins need not be zero, and a
    /// tabletop workspace may end above the keyboard altogether.
    static func overlapHeight(keyboard: CGRect, container: CGRect, requireFullWidth: Bool = true) -> CGFloat {
        guard !keyboard.isNull, !keyboard.isEmpty, !container.isNull, !container.isEmpty,
              !requireFullWidth || (keyboard.minX <= container.minX + 50 && keyboard.maxX >= container.maxX - 50)
        else { return 0 }
        let overlap = keyboard.intersection(container)
        return overlap.isNull || overlap.isEmpty ? 0 : overlap.height
    }

    static func isDocked(keyboard: CGRect, container: CGRect) -> Bool {
        overlapHeight(keyboard: keyboard, container: container) > 100
            && abs(keyboard.maxY - container.maxY) < 50
    }

    static func inputRegion(_ region: CGRect?, in container: CGRect) -> CGRect {
        guard let region else { return container }
        let intersection = container.intersection(region)
        return intersection.isNull || intersection.isEmpty ? .zero : intersection
    }

    static func includingAccessory(keyboard: CGRect, accessory: CGRect?, container: CGRect) -> CGRect {
        guard let accessory,
              !keyboard.isNull, !keyboard.isEmpty,
              !accessory.isNull, !accessory.isEmpty,
              keyboard.width >= container.width - 50,
              accessory.width >= container.width - 50,
              keyboard.intersects(container), accessory.intersects(container),
              // Only the row adjoining/inside the keyboard's top edge belongs
              // to this placement. During show/hide the accessory can still be
              // at its old position while the notification gives the destination.
              accessory.maxY >= keyboard.minY - 2,
              accessory.minY <= keyboard.minY + 2 else { return keyboard }
        return keyboard.union(accessory)
    }
}
