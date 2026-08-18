import CoreGraphics
import Foundation
import Combine

@MainActor
@Observable
final class TitlebarLayoutManager {
    static let shared = TitlebarLayoutManager()

    private(set) var leadingInset: CGFloat

    private static let leadingInsetKey = "titlebarLeadingInset"

    private init() {
        let savedInset = UserDefaults.standard.double(forKey: Self.leadingInsetKey)
        if savedInset > 0 {
            leadingInset = savedInset
        } else {
            leadingInset = 0
        }
    }

    func updateLeadingInset(_ inset: CGFloat) {
        let clampedInset = max(0, inset)
        guard clampedInset > 0 else { return }
        guard abs(clampedInset - leadingInset) > 0.5 else { return }
        leadingInset = clampedInset
        UserDefaults.standard.set(clampedInset, forKey: Self.leadingInsetKey)
    }
}
