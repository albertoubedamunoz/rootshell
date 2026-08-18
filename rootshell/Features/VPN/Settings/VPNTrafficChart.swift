//
//  VPNTrafficChart.swift
//  rootshell
//
//  Overlaid area chart showing download/upload rates over time,
//  computed from VPNTrafficSnapshot cumulative byte counters.
//

import SwiftUI
import Charts

struct VPNTrafficChart: View {
    let snapshots: [VPNTrafficSnapshot]

    var body: some View {
        let rates = computeRates(from: snapshots)
        VStack(alignment: .leading, spacing: 6) {
            legend(rates: rates)
            chart(rates: rates)
                .frame(height: 120)
        }
    }

    // MARK: - Chart

    private func chart(rates: [TrafficRate]) -> some View {
        let now = Date()
        let windowStart = now.addingTimeInterval(-300)  // 5 minutes ago

        let seriesData = rates.flatMap { rate in
            [
                SeriesPoint(date: rate.date, mbps: rate.downloadMbps, series: "Down"),
                SeriesPoint(date: rate.date, mbps: rate.uploadMbps, series: "Up"),
            ]
        }

        return Chart(seriesData) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Mbps", point.mbps)
            )
            .foregroundStyle(by: .value("Direction", point.series))
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale([
            "Down": Color.blue,
            "Up": Color.orange,
        ])
        .chartLegend(.hidden)
        .chartXScale(domain: windowStart...now)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(formatMbps(v))
                    }
                }
            }
        }
        .chartXAxis(.hidden)
    }

    // MARK: - Legend

    private func legend(rates: [TrafficRate]) -> some View {
        let currentDown = rates.last?.downloadMbps ?? 0
        let currentUp = rates.last?.uploadMbps ?? 0
        return HStack(spacing: 16) {
            HStack(spacing: 4) {
                Circle().fill(.blue).frame(width: 8, height: 8)
                Text("Down").font(.caption).foregroundStyle(.secondary)
                Text(formatMbps(currentDown)).font(.caption.monospacedDigit())
            }
            HStack(spacing: 4) {
                Circle().fill(.orange).frame(width: 8, height: 8)
                Text("Up").font(.caption).foregroundStyle(.secondary)
                Text(formatMbps(currentUp)).font(.caption.monospacedDigit())
            }
        }
    }

    // MARK: - Rate Computation

    private func computeRates(from snapshots: [VPNTrafficSnapshot]) -> [TrafficRate] {
        guard snapshots.count >= 2 else { return [] }

        var rates: [TrafficRate] = []
        for i in 1..<snapshots.count {
            let prev = snapshots[i - 1]
            let curr = snapshots[i]
            let dt = curr.timestamp.timeIntervalSince(prev.timestamp)
            guard dt > 0 else { continue }

            let downDelta = max(0, curr.bytesIn - prev.bytesIn)
            let upDelta = max(0, curr.bytesOut - prev.bytesOut)

            // Convert bytes/sec to megabits/sec (bytes * 8 / 1_000_000)
            let downMbps = (Double(downDelta) / dt) * 8.0 / 1_000_000.0
            let upMbps = (Double(upDelta) / dt) * 8.0 / 1_000_000.0

            rates.append(TrafficRate(
                date: curr.timestamp,
                downloadMbps: downMbps,
                uploadMbps: upMbps
            ))
        }
        return rates
    }

    // MARK: - Formatting

    private func formatMbps(_ mbps: Double) -> String {
        if mbps < 0.001 {
            return "0"
        } else if mbps < 1 {
            return String(format: "%.0f Kbps", mbps * 1000)
        } else if mbps < 10 {
            return String(format: "%.1f Mbps", mbps)
        } else {
            return String(format: "%.0f Mbps", mbps)
        }
    }
}

// MARK: - Models

private struct TrafficRate: Identifiable {
    let date: Date
    let downloadMbps: Double
    let uploadMbps: Double

    var id: Date { date }
}

private struct SeriesPoint: Identifiable {
    let date: Date
    let mbps: Double
    let series: String

    var id: String { "\(series)-\(date.timeIntervalSince1970)" }
}
