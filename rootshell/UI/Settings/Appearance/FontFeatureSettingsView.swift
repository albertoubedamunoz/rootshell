import SwiftUI
import CoreText
import UIKit

struct FontFeatureSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @ObservedObject private var fontManager = FontManager.shared
    @State private var features: [FontFeature] = []
    /// Detected affected glyphs per feature tag
    @State private var affectedGlyphs: [String: String] = [:]

    var body: some View {
        List {
            if features.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Text("No Stylistic Features")
                            .font(.headline)
                        Text("The current font does not expose any stylistic set or alternate glyph features.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .themedRow()
                }
            } else {
                ForEach(features) { feature in
                    featureRow(feature)
                        .themedRow()
                }
            }
        }
        .listStyle(.plain)
        .themedList()
        .navigationTitle("Stylistic Sets")
        .toolbar { SettingsScreenPinMenu(groups: [.font]) }
        .onAppear { refreshFeatures() }
        .onChange(of: fontManager.currentFontFamily) { refreshFeatures() }
    }

    private func refreshFeatures() {
        features = fontManager.discoverFeatures(for: fontManager.currentFontFamily)
        detectAllAffectedGlyphs()
    }

    // MARK: - Feature Row

    @ViewBuilder
    private func featureRow(_ feature: FontFeature) -> some View {
        let isEnabled = fontManager.enabledFeatureTags(for: fontManager.currentFontFamily).contains(feature.tag)
        let glyphs = affectedGlyphs[feature.tag] ?? ""

        VStack(alignment: .leading, spacing: 8) {
            // Tag + name label
            HStack(spacing: 0) {
                Text(feature.tag)
                    .font(.system(.body, design: .monospaced).bold())
                Text(" \u{2014} ")
                    .foregroundColor(.secondary)
                Text(feature.name)
                    .foregroundColor(.secondary)

                Spacer()

                if isEnabled {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                        .font(.body.weight(.semibold))
                }
            }

            // Preview box: off (gray) vs on (black)
            if !glyphs.isEmpty {
                HStack(spacing: 24) {
                    Text(glyphs)
                        .font(previewFont(feature: feature, enabled: false, size: 44))
                        .foregroundColor(Color(.systemGray3))
                    Text(glyphs)
                        .font(previewFont(feature: feature, enabled: true, size: 44))
                        .foregroundColor(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(10)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            fontManager.setFeatureEnabled(feature.tag, enabled: !isEnabled, for: fontManager.currentFontFamily)
        }
    }

    // MARK: - Preview Font

    private func previewFont(feature: FontFeature, enabled: Bool, size: CGFloat) -> Font {
        guard let familyName = fontManager.currentFontFamily else {
            return .system(size: size, design: .monospaced)
        }

        let selectorValue = enabled ? feature.aatSelectorOn : feature.aatSelectorOff
        let featureSettings: [[UIFontDescriptor.FeatureKey: Int]] = [
            [.type: feature.aatTypeID, .selector: selectorValue]
        ]

        // Resolve base font first (gets Regular face), then add feature settings
        // to its descriptor. Adding .family + .featureSettings together can resolve
        // to an italic face.
        let baseFont = UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: familyName]), size: size)
        let descriptor = baseFont.fontDescriptor.addingAttributes([
            .featureSettings: featureSettings
        ])

        let uiFont = UIFont(descriptor: descriptor, size: size)
        return Font(uiFont)
    }

    // MARK: - Affected Glyph Detection

    /// Characters to test for glyph differences when a feature is toggled.
    private static let candidateChars = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ@{}[]|!?&*#$%^~`'\";:.,<>/\\-_=+()"

    private func detectAllAffectedGlyphs() {
        guard let familyName = fontManager.currentFontFamily else {
            affectedGlyphs = [:]
            return
        }

        var results: [String: String] = [:]
        for feature in features {
            results[feature.tag] = detectAffectedGlyphs(feature: feature, familyName: familyName)
        }
        affectedGlyphs = results
    }

    /// Compare bitmap renders of each candidate character with the feature on vs off
    /// to find which glyphs are actually altered by this feature.
    private func detectAffectedGlyphs(feature: FontFeature, familyName: String) -> String {
        let renderSize: CGFloat = 24
        let ctxSize = Int(ceil(renderSize * 1.5))

        // Resolve base font first (Regular face), then add feature settings
        let baseFont = UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: familyName]), size: renderSize)

        let offDesc = baseFont.fontDescriptor.addingAttributes([
            .featureSettings: [[UIFontDescriptor.FeatureKey.type: feature.aatTypeID,
                                UIFontDescriptor.FeatureKey.selector: feature.aatSelectorOff]]
        ])
        let onDesc = baseFont.fontDescriptor.addingAttributes([
            .featureSettings: [[UIFontDescriptor.FeatureKey.type: feature.aatTypeID,
                                UIFontDescriptor.FeatureKey.selector: feature.aatSelectorOn]]
        ])

        let offFont = UIFont(descriptor: offDesc, size: renderSize)
        let onFont = UIFont(descriptor: onDesc, size: renderSize)

        var affected: [Character] = []

        for char in Self.candidateChars {
            let str = String(char)
            let offPixels = renderGlyphPixels(str, font: offFont, contextSize: ctxSize)
            let onPixels = renderGlyphPixels(str, font: onFont, contextSize: ctxSize)

            if offPixels != onPixels {
                affected.append(char)
            }
        }

        return String(affected)
    }

    /// Render a single character into a tiny grayscale bitmap and return the raw pixel data.
    private func renderGlyphPixels(_ string: String, font: UIFont, contextSize: Int) -> [UInt8] {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: contextSize,
            height: contextSize,
            bitsPerComponent: 8,
            bytesPerRow: contextSize,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }

        // White background
        context.setFillColor(gray: 1.0, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: contextSize, height: contextSize))

        // Draw the character
        let attrString = NSAttributedString(
            string: string,
            attributes: [.font: font, .foregroundColor: UIColor.black]
        )
        let line = CTLineCreateWithAttributedString(attrString)
        context.textPosition = CGPoint(x: 2, y: 6)
        CTLineDraw(line, context)

        // Extract pixel data
        guard let data = context.data else { return [] }
        let byteCount = contextSize * contextSize
        let buffer = data.bindMemory(to: UInt8.self, capacity: byteCount)
        return Array(UnsafeBufferPointer(start: buffer, count: byteCount))
    }
}
