import CoreGraphics

/// Stabilizes measurements that feed back into the discovery picker's layout.
nonisolated enum SessionPickerGeometry {
    /// Returns a new height only when it differs visibly from the retained one.
    /// Compare before rounding: tiny changes around a rounding boundary must
    /// not alternate between adjacent pixels and keep invalidating layout.
    static func updatedHeight(
        previous: CGFloat?,
        measured: CGFloat,
        displayScale: CGFloat
    ) -> CGFloat? {
        guard measured.isFinite else { return nil }
        let scale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
        let height = max(0, measured)
        if let previous, abs(height - previous) < 1 / scale {
            return nil
        }

        let aligned = (height * scale).rounded() / scale
        guard aligned.isFinite, aligned != previous else { return nil }
        return aligned
    }
}
