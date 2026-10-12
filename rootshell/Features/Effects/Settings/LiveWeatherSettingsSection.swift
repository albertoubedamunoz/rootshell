// LiveWeatherSettingsSection.swift
// rootshell

#if !CHINA_BUILD
import SwiftUI
import UIKit

extension WeatherConditionKind {
    var localizedName: String {
        switch self {
        case .clear: return String(localized: "Clear", comment: "Weather condition")
        case .partlyCloudy: return String(localized: "Partly Cloudy", comment: "Weather condition")
        case .cloudy: return String(localized: "Cloudy", comment: "Weather condition")
        case .fog: return String(localized: "Fog", comment: "Weather condition")
        case .haze: return String(localized: "Haze", comment: "Weather condition")
        case .smoke: return String(localized: "Smoke", comment: "Weather condition")
        case .dust: return String(localized: "Dust", comment: "Weather condition")
        case .drizzle: return String(localized: "Drizzle", comment: "Weather condition")
        case .rain: return String(localized: "Rain", comment: "Weather condition")
        case .heavyRain: return String(localized: "Heavy Rain", comment: "Weather condition")
        case .snow: return String(localized: "Snow", comment: "Weather condition")
        case .heavySnow: return String(localized: "Heavy Snow", comment: "Weather condition")
        case .sleet: return String(localized: "Sleet", comment: "Weather condition")
        case .freezingRain: return String(localized: "Freezing Rain", comment: "Weather condition")
        case .thunderstorm: return String(localized: "Thunderstorms", comment: "Weather condition")
        case .windy: return String(localized: "Windy", comment: "Weather condition")
        }
    }

    func symbolName(night: Bool) -> String {
        switch self {
        case .clear: return night ? "moon.stars.fill" : "sun.max.fill"
        case .partlyCloudy: return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case .cloudy: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .haze: return night ? "moon.haze.fill" : "sun.haze.fill"
        case .smoke: return "smoke.fill"
        case .dust: return night ? "moon.dust.fill" : "sun.dust.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .rain: return "cloud.rain.fill"
        case .heavyRain: return "cloud.heavyrain.fill"
        case .snow, .heavySnow: return "cloud.snow.fill"
        case .sleet, .freezingRain: return "cloud.sleet.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        case .windy: return "wind"
        }
    }
}

extension WeatherSource {
    var displayName: String {
        switch self {
        case .nws: return String(localized: "National Weather Service", comment: "Weather data source")
        case .openMeteo: return String(localized: "Open-Meteo", comment: "Weather data source")
        case .metNorway: return String(localized: "MET Norway", comment: "Weather data source")
        }
    }

    var website: URL {
        switch self {
        case .nws: return URL(string: "https://www.weather.gov")!
        case .openMeteo: return URL(string: "https://open-meteo.com/")!
        case .metNorway: return URL(string: "https://api.met.no")!
        }
    }
}

extension WeatherSkyGeometry.PreviewTime {
    var displayName: String {
        switch self {
        case .sunrise: return String(localized: "Sunrise", comment: "Live Weather preview time of day")
        case .noon: return String(localized: "Midday", comment: "Live Weather preview time of day")
        case .sunset: return String(localized: "Sunset", comment: "Live Weather preview time of day")
        case .night: return String(localized: "Night", comment: "Live Weather preview time of day")
        }
    }
}

extension LiveWeatherConfiguration.Quality {
    var displayName: String {
        switch self {
        case .economical: return String(localized: "Economical", comment: "Live Weather render quality")
        case .balanced: return String(localized: "Balanced", comment: "Live Weather render quality")
        case .cinematic: return String(localized: "Cinematic", comment: "Live Weather render quality")
        }
    }
}

struct LiveWeatherSettingsSection: View {
    @ObservedObject var effect: LiveWeatherEffect
    let onShowcase: () -> Void
    @State private var now = Date()
    private var store: WeatherStore { .shared }

    private func binding<Value>(_ key: WritableKeyPath<LiveWeatherConfiguration, Value>) -> Binding<Value> {
        Binding(get: { effect.configuration[keyPath: key] }, set: { effect.configuration[keyPath: key] = $0 })
    }

    var body: some View {
        locationSection
        conditionsSection
        lookSection
        demoSection
        dataSection
    }

    // MARK: Location

    private var locationSection: some View {
        Section {
            Picker("Location", selection: binding(\.locationSource)) {
                Text("Device Location").tag(LiveWeatherConfiguration.LocationSource.device)
                Text("City").tag(LiveWeatherConfiguration.LocationSource.city)
            }
            .themedRow()
            .onChange(of: effect.configuration.locationSource) { _, source in
                if source == .device { store.requestLocationPermission() }
            }
            if effect.configuration.locationSource == .device {
                HStack {
                    Text("Current Location")
                    Spacer()
                    Text(deviceLocationLabel).foregroundStyle(.secondary)
                }
                .themedRow()
                if store.locationStatus == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .themedRow()
                }
            } else {
                NavigationLink {
                    WeatherCitySearchView { city in
                        var configuration = effect.configuration
                        configuration.city = city
                        configuration.locationSource = .city
                        effect.configuration = configuration
                    }
                } label: {
                    HStack {
                        Text("City")
                        Spacer()
                        Text(effect.configuration.city?.name ?? String(localized: "Choose…", comment: "Live Weather city placeholder"))
                            .foregroundStyle(.secondary)
                    }
                }
                .themedRow()
            }
        } header: {
            Text("Weather Location")
        } footer: {
            if effect.configuration.locationSource == .device && store.locationStatus == .denied {
                Text("Location access is off, so the sky is estimated from your time zone. Allow access in Settings, or choose a city.")
            } else {
                Text("Only an approximate position, rounded to about a kilometre, is sent to the weather service.")
            }
        }
    }

    private var deviceLocationLabel: String {
        switch store.locationStatus {
        case .located, .city:
            return store.locality ?? String(localized: "Located", comment: "Live Weather location status")
        case .estimated:
            return store.deviceCoordinate == nil
                ? String(localized: "Estimated", comment: "Live Weather location status")
                : (store.locality ?? String(localized: "Last Known", comment: "Live Weather location status"))
        case .denied:
            return String(localized: "Not Allowed", comment: "Live Weather location status")
        }
    }

    // MARK: Conditions

    // A TimelineView around the Section would collapse its rows into one, so
    // the clock ticks from the Refresh row instead.
    private var conditionsSection: some View {
        Section {
            if let snapshot = store.snapshot(for: effect.configuration.selection) {
                currentConditions(snapshot)
            } else {
                Text(emptyConditionsMessage)
                    .foregroundStyle(.secondary)
                    .themedRow()
            }
            statusRow
            Button {
                store.refreshNow()
            } label: {
                Label("Refresh Now", systemImage: "arrow.clockwise")
            }
            .disabled(effect.configuration.demo || store.manualRefreshAt > now || store.status == .fetching)
            .themedRow()
            .task {
                while !Task.isCancelled {
                    now = Date()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        } header: {
            Text("Current Conditions")
        } footer: {
            if !effect.configuration.demo, store.manualRefreshAt > now {
                Text("Weather refreshes about once an hour while the effect is on screen. You can refresh again \(relative(store.manualRefreshAt)).")
            } else {
                Text("Weather refreshes about once an hour while the effect is on screen.")
            }
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private func relative(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    private var emptyConditionsMessage: String {
        if effect.configuration.demo {
            return String(localized: "Demo Mode doesn't fetch weather.", comment: "Live Weather status")
        }
        if effect.configuration.locationSource == .device && store.deviceCoordinate == nil && store.locationStatus != .located {
            return String(localized: "Live Weather needs your location or a chosen city. Until then the sky follows your time zone.", comment: "Live Weather status")
        }
        if effect.configuration.locationSource == .city && effect.configuration.city == nil {
            return String(localized: "Choose a city to show its weather.", comment: "Live Weather status")
        }
        return String(localized: "Waiting for the first update…", comment: "Live Weather status")
    }

    @ViewBuilder
    private func currentConditions(_ snapshot: WeatherSnapshot) -> some View {
        let night = SolarCalculator.calculatePosition(date: now, latitude: snapshot.coordinate.latitude,
                                                      longitude: snapshot.coordinate.longitude).altitude < -3
        HStack(spacing: 12) {
            Image(systemName: snapshot.current.kind.symbolName(night: night))
                .symbolRenderingMode(.multicolor)
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.current.kind.localizedName)
                if let place = placeName(snapshot) {
                    Text(place).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let temperature = snapshot.current.temperature {
                Text(Measurement(value: temperature, unit: UnitTemperature.celsius),
                     format: .measurement(width: .abbreviated, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
                    .font(.title3)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .themedRow()
        HStack {
            Text("Updated")
            Spacer()
            Text(relative(snapshot.fetchedAt)).foregroundStyle(.secondary)
        }
        .themedRow()
        // Open-Meteo's licence asks for a link wherever its data is shown.
        Link(destination: snapshot.source.website) {
            HStack {
                Text("Source").foregroundStyle(.primary)
                Spacer()
                Text(snapshot.source.displayName).foregroundStyle(.secondary)
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
            }
        }
        .themedRow()
    }

    private func placeName(_ snapshot: WeatherSnapshot) -> String? {
        if effect.configuration.locationSource == .city, let city = effect.configuration.city { return city.name }
        return snapshot.placeName ?? store.locality
    }

    @ViewBuilder
    private var statusRow: some View {
        switch store.status {
        case .fetching:
            HStack(spacing: 8) {
                ProgressView()
                Text("Updating…").foregroundStyle(.secondary)
            }
            .themedRow()
        case .retrying(let date) where date > now && !effect.configuration.demo:
            Text("The weather service didn't respond. Trying again \(relative(date)).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .themedRow()
        default:
            EmptyView()
        }
    }

    // MARK: Look

    private var lookSection: some View {
        Section {
            Toggle("Stars", isOn: binding(\.showStars)).themedRow()
            Toggle("Sun and Moon", isOn: binding(\.showSunAndMoon)).themedRow()
            Toggle("Lightning Flashes", isOn: binding(\.lightningFlashes)).themedRow()
            AquariumSettingSlider(title: "Reading Protection", value: binding(\.readingProtection), range: 0...1).themedRow()
            Picker("Render Quality", selection: binding(\.quality)) {
                ForEach(LiveWeatherConfiguration.Quality.allCases, id: \.self) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
            .themedRow()
            Button(action: onShowcase) {
                Label("Full-screen Weather Preview", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .themedRow()
        } header: {
            Text("Weather Presentation")
        } footer: {
            Text("Stars appear on dark themes. Lightning is off when Reduce Motion or Dim Flashing Lights is on. Reduce Motion shows a still sky, and Battery Saver lowers quality automatically.")
        }
    }

    // MARK: Demo

    private var demoSection: some View {
        Section {
            Toggle("Demo Mode", isOn: binding(\.demo)).themedRow()
            if effect.configuration.demo {
                Picker("Condition", selection: Binding(get: { effect.previewCondition }, set: { effect.previewCondition = $0 })) {
                    Text("Cycle Through All").tag(WeatherConditionKind?.none)
                    ForEach(WeatherConditionKind.allCases, id: \.self) { kind in
                        Text(kind.localizedName).tag(WeatherConditionKind?.some(kind))
                    }
                }
                .themedRow()
                Picker("Time of Day", selection: Binding(get: { effect.previewTime }, set: { effect.previewTime = $0 })) {
                    Text("Now").tag(WeatherSkyGeometry.PreviewTime?.none)
                    ForEach(WeatherSkyGeometry.PreviewTime.allCases, id: \.self) { time in
                        Text(time.displayName).tag(WeatherSkyGeometry.PreviewTime?.some(time))
                    }
                }
                .themedRow()
            }
        } header: {
            Text("Weather Demo")
        } footer: {
            Text("Demo Mode shows each kind of weather in turn without contacting a weather service. The condition and time of day chosen here aren't saved.")
        }
    }

    // MARK: Attribution

    private var dataSection: some View {
        Section {
            Link(destination: WeatherSource.nws.website) {
                Label("NOAA National Weather Service", systemImage: "arrow.up.right.square")
            }
            .themedRow()
            Link(destination: WeatherSource.openMeteo.website) {
                Label("Weather data by Open-Meteo.com", systemImage: "arrow.up.right.square")
            }
            .themedRow()
            Link(destination: WeatherSource.metNorway.website) {
                Label("MET Norway", systemImage: "arrow.up.right.square")
            }
            .themedRow()
            Link(destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!) {
                Label("CC BY 4.0 License", systemImage: "arrow.up.right.square")
            }
            .themedRow()
        } header: {
            Text("Weather Data")
        } footer: {
            Text("US locations use data from the National Weather Service. Other locations, and US locations when it can't be reached, use Open-Meteo, with MET Norway as a backup. Open-Meteo and MET Norway data are licensed under CC BY 4.0, adapted and visualised by rootshell.")
        }
    }
}
#endif
