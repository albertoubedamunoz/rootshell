import SwiftUI

/// Opens the appropriate App Store listing only when the user chooses to review.
struct SettingsReviewLink: View {
    private var reviewURL: URL {
        #if CHINA_BUILD
        let appID = "6763402687"
        #else
        let appID = "6755794662"
        #endif
        return URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")!
    }

    var body: some View {
        #if APPSTORE
        Link(destination: reviewURL) {
            HStack(spacing: 12) {
                SettingsIcon(systemName: "star.bubble")
                Text("Write a Review")
            }
        }
        .themedRow()
        #endif
    }
}
