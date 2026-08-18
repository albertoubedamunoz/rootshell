import SwiftUI

/// Renders a profile's icon in any of its three forms (SF Symbol, Nerd
/// Font glyph, host favicon). Shared by the profile browse rows, the
/// editor preview, and the icon picker grid.
struct ProfileIconView: View {
    private struct FaviconLoadID: Hashable {
        let domain: String
        let shouldRetryCachedFailure: Bool
    }

    let icon: ProfileIcon
    var tint: Color = .accentColor
    var size: CGFloat = 17
    /// Host used to resolve the favicon variant; ignored for other kinds
    var host: String?

    @State private var faviconImage: UIImage?

    init(icon: ProfileIcon, tint: Color = .accentColor, size: CGFloat = 17, host: String? = nil) {
        self.icon = icon
        self.tint = tint
        self.size = size
        self.host = host
    }

    init(storageString: String?, tint: Color = .accentColor, size: CGFloat = 17, host: String? = nil) {
        self.init(icon: ProfileIcon(storageString: storageString), tint: tint, size: size, host: host)
    }

    var body: some View {
        switch icon {
        case .symbol(let name):
            // Unknown names (typos, schemes from newer app versions) fall back to the star
            Image(systemName: UIImage(systemName: name) != nil ? name : "star.fill")
                .font(.system(size: size))
                .foregroundColor(tint)
        case .nerd(let scalar):
            Text(String(scalar))
                .font(.custom(ProfileIcon.nerdFontName, size: size))
                .foregroundColor(tint)
        case .favicon:
            faviconBody
        }
    }

    /// Domain the favicon variant resolves against: the icon's own custom
    /// host when set, otherwise the profile host passed by the caller
    private var faviconDomain: String {
        if case .favicon(let customHost) = icon, let customHost {
            return customHost
        }
        return (host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A custom hostname is an explicit user choice, so a persisted fetch
    /// failure from before the profile arrived via iCloud must not suppress a
    /// fresh request on this device.
    private var shouldRetryCachedFailure: Bool {
        if case .favicon(let customHost) = icon {
            return customHost != nil
        }
        return false
    }

    private var faviconLoadID: FaviconLoadID {
        FaviconLoadID(
            domain: faviconDomain,
            shouldRetryCachedFailure: shouldRetryCachedFailure
        )
    }

    @ViewBuilder
    private var faviconBody: some View {
        ZStack {
            if let faviconImage {
                Image(uiImage: faviconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
            } else {
                Image(systemName: "star.fill")
                    .font(.system(size: size))
                    .foregroundColor(tint)
            }
        }
        .frame(width: size + 3, height: size + 3)
        .task(id: faviconLoadID) {
            await loadFavicon()
        }
    }

    private func loadFavicon() async {
        // Drop the previous host's icon so a failed fetch shows the placeholder
        faviconImage = nil
        let domain = faviconDomain
        guard !domain.isEmpty else { return }
        if let cached = FaviconManager.shared.cachedFavicon(for: domain),
           let uiImage = UIImage(data: cached) {
            faviconImage = uiImage
            return
        }
        // task(id:) cancels this task when the host changes; the fetch does
        // not observe cancellation, so re-check before writing the result
        if let data = await FaviconManager.shared.favicon(
            for: domain,
            retryCachedFailure: shouldRetryCachedFailure
        ),
           let uiImage = UIImage(data: data),
           !Task.isCancelled {
            faviconImage = uiImage
        }
    }
}
