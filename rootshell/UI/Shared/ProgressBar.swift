import SwiftUI

/// Progress bar overlay for terminals
/// Displays progress indicators triggered by OSC 9;4 escape sequences
struct ProgressBar: View {
    let report: Ghostty.Action.ProgressReport

    var body: some View {
        switch report.state {
        case .remove:
            EmptyView()

        case .set:
            // Determinate progress bar
            if let progress = report.progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.3))

                        // Progress fill
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: geometry.size.width * CGFloat(progress) / 100.0)
                    }
                }
                .frame(height: 2)
            }

        case .error:
            // Error state - red bar
            BouncingProgressBar(color: .red)
                .frame(height: 2)

        case .indeterminate:
            // Indeterminate/waiting state - blue bar
            BouncingProgressBar(color: .accentColor)
                .frame(height: 2)

        case .pause:
            // Pause state - orange bar
            BouncingProgressBar(color: .orange)
                .frame(height: 2)
        }
    }

    /// Get the color for the current state
    private var stateColor: Color {
        switch report.state {
        case .error:
            return .red
        case .pause:
            return .orange
        default:
            return .accentColor
        }
    }
}

/// Animated bouncing progress bar for indeterminate states
private struct BouncingProgressBar: View {
    let color: Color
    @State private var position: CGFloat = 0

    private let barWidthRatio: CGFloat = 0.25  // Bar is 25% of total width

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background with 30% opacity
                Rectangle()
                    .fill(color.opacity(0.3))

                // Animated bar
                Rectangle()
                    .fill(color)
                    .frame(width: geometry.size.width * barWidthRatio)
                    .offset(x: position * (geometry.size.width * (1 - barWidthRatio)))
            }
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.2)
                .repeatForever(autoreverses: true)
            ) {
                position = 1  // Animate from 0 to 1 and back
            }
        }
    }
}
