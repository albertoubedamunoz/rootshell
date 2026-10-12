// WeatherCitySearchView.swift
// rootshell

#if !CHINA_BUILD
import SwiftUI
import MapKit

struct WeatherCitySearchView: View {
    let onSelect: (WeatherCity) -> Void
    @State private var model = WeatherCitySearchModel()
    @State private var resolving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if model.query.isEmpty {
                Text("Search for a city or town.")
                    .foregroundStyle(.secondary)
                    .themedRow()
            } else if model.results.isEmpty {
                Text("No matching places.")
                    .foregroundStyle(.secondary)
                    .themedRow()
            }
            ForEach(Array(model.results.enumerated()), id: \.offset) { _, completion in
                Button {
                    guard !resolving else { return }
                    resolving = true
                    Task {
                        defer { resolving = false }
                        if let city = await model.resolve(completion) {
                            onSelect(city)
                            dismiss()
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(completion.title).foregroundStyle(.primary)
                        if !completion.subtitle.isEmpty {
                            Text(completion.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .themedRow()
            }
        }
        .themedList()
        .overlay { if resolving { ProgressView() } }
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("City"))
        .onChange(of: model.query) { _, _ in model.search() }
        .navigationTitle(String(localized: "Weather City", comment: "Live Weather city search title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
@Observable
final class WeatherCitySearchModel: NSObject, MKLocalSearchCompleterDelegate {
    var query = ""
    private(set) var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.resultTypes = .address
        completer.pointOfInterestFilter = .excludingAll
        completer.delegate = self
    }

    func search() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            completer.cancel()
            results = []
        } else {
            completer.queryFragment = trimmed
        }
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> WeatherCity? {
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        guard let item = try? await search.start().mapItems.first else { return nil }
        let coordinate: CLLocationCoordinate2D
        if #available(iOS 26.0, macCatalyst 26.0, visionOS 26.0, *) {
            coordinate = item.location.coordinate
        } else {
            coordinate = item.placemark.coordinate
        }
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        return WeatherCity(name: completion.title, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    // MapKit calls the delegate on the main thread.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { results = Array(completer.results.prefix(20)) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { results = [] }
    }
}
#endif
