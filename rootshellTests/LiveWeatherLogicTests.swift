import XCTest

final class LiveWeatherLogicTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: Condition mapping

    func testNWSIconURLYieldsCodesAndChances() {
        let codes = NWSConditionMapping.iconCodes(from: "https://api.weather.gov/icons/land/night/tsra_hi,40/rain,60?size=medium")
        XCTAssertEqual(codes.map(\.code), ["tsra_hi", "rain"])
        XCTAssertEqual(codes.map(\.chance), [0.4, 0.6])
        XCTAssertEqual(NWSConditionMapping.iconCodes(from: "https://api.weather.gov/icons/land/day/ovc?size=small").map(\.code), ["ovc"])
        XCTAssertTrue(NWSConditionMapping.iconCodes(from: "not a url").isEmpty)
    }

    func testNWSIconCodes() {
        XCTAssertEqual(NWSConditionMapping.reading(iconCode: "skc")?.kind, .clear)
        XCTAssertEqual(NWSConditionMapping.reading(iconCode: "ovc")?.cloudCover, 1)
        XCTAssertEqual(NWSConditionMapping.reading(iconCode: "wind_bkn")?.kind, .windy)
        XCTAssertEqual(NWSConditionMapping.reading(iconCode: "tsra")?.thunder, true)
        XCTAssertEqual(NWSConditionMapping.reading(iconCode: "rain_fzra")?.kind, .freezingRain)
        XCTAssertEqual(NWSConditionMapping.reading(iconCode: "blizzard")?.kind, .heavySnow)
        XCTAssertEqual(NWSConditionMapping.reading(iconCode: "smoke")?.kind, .smoke)
        XCTAssertNil(NWSConditionMapping.reading(iconCode: "nonsense"))
    }

    func testMETARPhenomenaPickTheMostSignificant() {
        func kind(_ phenomena: [(String, String?, String?)]) -> WeatherConditionKind? {
            NWSConditionMapping.reading(phenomena: phenomena.map { (weather: $0.0, intensity: $0.1, modifier: $0.2) })?.kind
        }
        XCTAssertEqual(kind([("rain", "light", nil), ("thunderstorms", nil, nil)]), .thunderstorm)
        XCTAssertEqual(kind([("snow", nil, nil), ("rain", nil, nil)]), .sleet)
        XCTAssertEqual(kind([("drizzle", "light", "freezing")]), .freezingRain)
        XCTAssertEqual(kind([("rain", "heavy", nil)]), .heavyRain)
        XCTAssertEqual(kind([("snow", nil, "blowing")]), .heavySnow)
        XCTAssertEqual(kind([("fog_mist", nil, nil)]), .fog)
        XCTAssertEqual(kind([("haze", nil, nil)]), .haze)
        XCTAssertNil(kind([]))
    }

    func testCloudLayersUseTheDensestLayer() {
        XCTAssertEqual(NWSConditionMapping.cloudCover(layerAmounts: ["FEW", "BKN", "SCT"]), 0.75)
        XCTAssertEqual(NWSConditionMapping.cloudCover(layerAmounts: ["CLR"]), 0)
        XCTAssertNil(NWSConditionMapping.cloudCover(layerAmounts: []))
    }

    func testWindTextAndCompass() {
        XCTAssertEqual(NWSConditionMapping.windSpeed(text: "5 to 15 mph")!, 15 * 0.44704, accuracy: 0.001)
        XCTAssertEqual(NWSConditionMapping.windSpeed(text: "18 km/h")!, 5, accuracy: 0.001)
        XCTAssertEqual(NWSConditionMapping.degrees(compass: "SW"), 225)
        XCTAssertEqual(NWSConditionMapping.degrees(compass: "nnw"), 337.5)
        XCTAssertNil(NWSConditionMapping.degrees(compass: "VRB"))
        XCTAssertEqual(NWSConditionMapping.metresPerSecond(36, unitCode: "wmoUnit:km_h-1"), 10, accuracy: 0.001)
    }

    func testMETNorwaySymbols() {
        XCTAssertEqual(METNorwayConditionMapping.reading(symbolCode: "heavyrainshowersandthunder_day")?.kind, .thunderstorm)
        XCTAssertEqual(METNorwayConditionMapping.reading(symbolCode: "lightssleetshowersandthunder_night")?.kind, .thunderstorm)
        XCTAssertEqual(METNorwayConditionMapping.reading(symbolCode: "lightsnow")?.kind, .snow)
        XCTAssertEqual(METNorwayConditionMapping.reading(symbolCode: "lightsnow")?.precipitationRate, 0.4)
        XCTAssertEqual(METNorwayConditionMapping.reading(symbolCode: "heavysnow")?.kind, .heavySnow)
        XCTAssertEqual(METNorwayConditionMapping.reading(symbolCode: "sleetshowers_day")?.kind, .sleet)
        XCTAssertEqual(METNorwayConditionMapping.reading(symbolCode: "clearsky_polartwilight")?.kind, .clear)
        XCTAssertEqual(METNorwayConditionMapping.reading(symbolCode: "fog")?.kind, .fog)
        XCTAssertNil(METNorwayConditionMapping.reading(symbolCode: "mystery"))
    }

    func testOpenMeteoWeatherCodes() {
        XCTAssertEqual(OpenMeteoConditionMapping.reading(weatherCode: 0)?.kind, .clear)
        XCTAssertEqual(OpenMeteoConditionMapping.reading(weatherCode: 2)?.kind, .partlyCloudy)
        XCTAssertEqual(OpenMeteoConditionMapping.reading(weatherCode: 48)?.kind, .fog)
        XCTAssertEqual(OpenMeteoConditionMapping.reading(weatherCode: 57)?.kind, .freezingRain)
        XCTAssertEqual(OpenMeteoConditionMapping.reading(weatherCode: 65)?.kind, .heavyRain)
        XCTAssertEqual(OpenMeteoConditionMapping.reading(weatherCode: 77)?.kind, .snow)
        XCTAssertEqual(OpenMeteoConditionMapping.reading(weatherCode: 86)?.kind, .heavySnow)
        XCTAssertEqual(OpenMeteoConditionMapping.reading(weatherCode: 97)?.thunder, true)
        XCTAssertNil(OpenMeteoConditionMapping.reading(weatherCode: 42))
    }

    func testNWSCoverage() {
        XCTAssertTrue(NWSCoverage.contains(WeatherCoordinate(latitude: 40.71, longitude: -74.01)))   // New York
        XCTAssertTrue(NWSCoverage.contains(WeatherCoordinate(latitude: 21.31, longitude: -157.86)))  // Honolulu
        XCTAssertTrue(NWSCoverage.contains(WeatherCoordinate(latitude: 61.22, longitude: -149.90)))  // Anchorage
        XCTAssertTrue(NWSCoverage.contains(WeatherCoordinate(latitude: 18.47, longitude: -66.11)))   // San Juan
        XCTAssertFalse(NWSCoverage.contains(WeatherCoordinate(latitude: 48.86, longitude: 2.35)))    // Paris
        XCTAssertFalse(NWSCoverage.contains(WeatherCoordinate(latitude: -33.87, longitude: 151.21))) // Sydney
    }

    func testCoordinateRoundingAndKey() {
        let c = WeatherCoordinate(latitude: 37.33412, longitude: -122.00911)
        XCTAssertEqual(c.latitude, 37.33)
        XCTAssertEqual(c.longitude, -122.01)
        XCTAssertEqual(c.key, "37.33,-122.01")
        XCTAssertEqual(WeatherCoordinate(latitude: 95, longitude: 190).latitude, 90)
        XCTAssertEqual(WeatherCoordinate(latitude: 0, longitude: 190).longitude, -170)
    }

    // MARK: Parsers

    func testMETNorwayForecastParsing() throws {
        let json = """
        {"type":"Feature","properties":{"timeseries":[
          {"time":"2025-10-09T08:00:00Z","data":{"instant":{"details":{"air_temperature":9.5,"cloud_area_fraction":100,
             "cloud_area_fraction_low":80,"cloud_area_fraction_medium":20,"cloud_area_fraction_high":10,"fog_area_fraction":0,
             "wind_speed":6.0,"wind_speed_of_gust":11.0,"wind_from_direction":250}},
           "next_1_hours":{"summary":{"symbol_code":"rain"},"details":{"precipitation_amount":1.4,"probability_of_precipitation":90,"probability_of_thunder":2}}}},
          {"time":"2025-10-09T09:00:00Z","data":{"instant":{"details":{"cloud_area_fraction":40,"wind_speed":4.0,"wind_from_direction":270}},
           "next_1_hours":{"summary":{"symbol_code":"partlycloudy_day"},"details":{"precipitation_amount":0}}}},
          {"time":"2025-10-09T12:00:00Z","data":{"instant":{"details":{"cloud_area_fraction":95}},
           "next_6_hours":{"summary":{"symbol_code":"heavyrain"},"details":{"precipitation_amount":30}}}}
        ]}}
        """
        let now = WeatherHTTP.isoDate("2025-10-09T08:20:00Z")!
        let coordinate = WeatherCoordinate(latitude: 59.91, longitude: 10.75)
        let snapshot = try METNorwayClient.snapshot(from: Data(json.utf8), coordinate: coordinate, now: now, expires: nil)
        XCTAssertEqual(snapshot.source, .metNorway)
        XCTAssertEqual(snapshot.current.kind, .rain)
        XCTAssertEqual(snapshot.current.cloudLow, 0.8)
        XCTAssertEqual(snapshot.current.precipitationRate, 1.4)
        XCTAssertEqual(snapshot.current.precipitationChance, 0.9)
        XCTAssertEqual(snapshot.current.windGust, 11)
        XCTAssertEqual(snapshot.hourly.map(\.kind), [.partlyCloudy, .heavyRain])
        // Six-hour totals become an hourly rate.
        XCTAssertEqual(snapshot.hourly.last?.precipitationRate, 5)
    }

    func testOpenMeteoForecastParsing() throws {
        let json = """
        {"latitude":48.85,"longitude":2.36,
         "current":{"time":1791808200,"interval":900,"temperature_2m":12.5,"weather_code":63,"cloud_cover":100,
           "cloud_cover_low":90,"cloud_cover_mid":40,"cloud_cover_high":null,"precipitation":0.5,"visibility":9000,
           "wind_speed_10m":5.5,"wind_direction_10m":220,"wind_gusts_10m":9.8},
         "hourly":{"time":[1791806400,1791810000,1791813600],"weather_code":[63,2,95],"cloud_cover":[100,45,90],
           "precipitation":[1.2,0.0,6.0],"precipitation_probability":[90,10,70],"visibility":[8000,null,20000]}}
        """
        let now = Date(timeIntervalSince1970: 1_791_808_300)
        let coordinate = WeatherCoordinate(latitude: 48.86, longitude: 2.35)
        let snapshot = try OpenMeteoClient.snapshot(from: Data(json.utf8), coordinate: coordinate, now: now)
        XCTAssertEqual(snapshot.source, .openMeteo)
        XCTAssertEqual(snapshot.current.kind, .rain)
        // 0.5 mm in the last 15 minutes.
        XCTAssertEqual(snapshot.current.precipitationRate, 2)
        XCTAssertEqual(snapshot.current.cloudLow, 0.9)
        XCTAssertNil(snapshot.current.cloudHigh)
        XCTAssertEqual(snapshot.current.windGust, 9.8)
        // The 12:00 row is behind the 12:30 current conditions.
        XCTAssertEqual(snapshot.hourly.map(\.kind), [.partlyCloudy, .thunderstorm])
        XCTAssertEqual(snapshot.hourly.first?.precipitationChance, 0.1)
        XCTAssertNil(snapshot.hourly.first?.visibility)
        XCTAssertEqual(snapshot.hourly.last?.thunderChance, 0.8)
        XCTAssertEqual(snapshot.hourly.last?.precipitationRate, 6)

        // Without a current block, the latest hourly row stands in.
        let hourlyOnly = """
        {"hourly":{"time":[1791806400,1791810000],"weather_code":[3,61],"cloud_cover":[95,100]}}
        """
        let fallback = try OpenMeteoClient.snapshot(from: Data(hourlyOnly.utf8), coordinate: coordinate, now: now)
        XCTAssertEqual(fallback.current.kind, .cloudy)
        XCTAssertEqual(fallback.hourly.map(\.kind), [.rain])
    }

    func testNWSObservationParsing() throws {
        let json = """
        {"properties":{"timestamp":"2025-10-09T15:53:00+00:00","icon":"https://api.weather.gov/icons/land/day/rain?size=medium",
          "presentWeather":[{"intensity":"light","modifier":null,"weather":"rain","rawString":"-RA"}],
          "cloudLayers":[{"base":{"value":900},"amount":"OVC"}],
          "temperature":{"unitCode":"wmoUnit:degC","value":12.2},
          "windDirection":{"value":200},"windSpeed":{"unitCode":"wmoUnit:km_h-1","value":18},
          "windGust":{"value":null},"visibility":{"value":8000},"precipitationLastHour":{"unitCode":"wmoUnit:mm","value":null}}}
        """
        let data = Data(json.utf8)
        let now = WeatherHTTP.isoDate("2025-10-09T16:10:00Z")!
        let sample = try XCTUnwrap(NWSClient.observation(from: data, now: now))
        XCTAssertEqual(sample.kind, .rain)
        XCTAssertEqual(sample.cloudCover, 1)
        XCTAssertEqual(sample.windSpeed!, 5, accuracy: 0.001)
        XCTAssertEqual(sample.windFrom, 200)
        XCTAssertEqual(sample.temperature, 12.2)
        XCTAssertEqual(sample.precipitationRate, 0.8)
        // A stale report doesn't describe now.
        XCTAssertNil(NWSClient.observation(from: data, now: now.addingTimeInterval(3 * 3600)))
    }

    func testNWSHourlyParsing() throws {
        let json = """
        {"properties":{"periods":[
          {"startTime":"2025-10-09T09:00:00-07:00","isDaytime":true,"temperature":11,"temperatureUnit":"C",
           "probabilityOfPrecipitation":{"value":60},"windSpeed":"10 to 20 km/h","windDirection":"SW",
           "icon":"https://api.weather.gov/icons/land/day/rain_showers,60?size=small","shortForecast":"Heavy Rain"},
          {"startTime":"2025-10-09T10:00:00-07:00","isDaytime":true,"temperature":{"unitCode":"wmoUnit:degF","value":59},
           "probabilityOfPrecipitation":{"value":0},"windSpeed":"5 km/h","windDirection":"W",
           "icon":"https://api.weather.gov/icons/land/day/sct?size=small","shortForecast":"Partly Sunny"}
        ]}}
        """
        let now = WeatherHTTP.isoDate("2025-10-09T15:30:00Z")!
        let samples = try NWSClient.hourly(from: Data(json.utf8), now: now)
        XCTAssertEqual(samples.map(\.kind), [.heavyRain, .partlyCloudy])
        XCTAssertEqual(samples[0].precipitationChance, 0.6)
        XCTAssertEqual(samples[0].windSpeed!, 20 / 3.6, accuracy: 0.001)
        XCTAssertEqual(samples[0].windFrom, 225)
        XCTAssertEqual(samples[1].temperature!, 15, accuracy: 0.001)
        XCTAssertNil(samples[1].precipitationChance)
    }

    // MARK: Fetch policy

    func testPolicySchedulesWithinTheJitterWindow() {
        var policy = WeatherFetchPolicy()
        XCTAssertEqual(policy.nextDue(now: t0), t0)
        policy.recordStarted(now: t0)
        policy.recordSuccess(now: t0, expiresAt: nil, changed: true, jitter: 0)
        XCTAssertEqual(policy.nextDue(now: t0), t0.addingTimeInterval(WeatherTuning.baseInterval))
        policy.recordSuccess(now: t0, expiresAt: nil, changed: true, jitter: 1)
        XCTAssertEqual(policy.nextDue(now: t0), t0.addingTimeInterval(WeatherTuning.baseInterval + WeatherTuning.jitterWindow))
    }

    func testPolicyNeverFetchesBeforeExpires() {
        var policy = WeatherFetchPolicy()
        let expires = t0.addingTimeInterval(2 * 3600)
        policy.recordStarted(now: t0)
        policy.recordSuccess(now: t0, expiresAt: expires, changed: true, jitter: 0)
        XCTAssertGreaterThanOrEqual(policy.nextDue(now: t0), expires)
        XCTAssertGreaterThanOrEqual(policy.manualAvailableAt(now: t0.addingTimeInterval(3600)), expires)
        XCTAssertFalse(policy.requestManualRefresh(now: t0.addingTimeInterval(3600)))
    }

    func testPolicyStretchesWhenNothingChanges() {
        var policy = WeatherFetchPolicy()
        policy.recordSuccess(now: t0, expiresAt: nil, changed: false, jitter: 0)
        policy.recordSuccess(now: t0, expiresAt: nil, changed: false, jitter: 0)
        XCTAssertEqual(policy.nextDue(now: t0), t0.addingTimeInterval(WeatherTuning.stableInterval))
    }

    func testPolicyBacksOffExponentiallyWithACap() {
        var policy = WeatherFetchPolicy()
        policy.recordFailure(now: t0)
        XCTAssertEqual(policy.nextDue(now: t0), t0.addingTimeInterval(120))
        policy.recordFailure(now: t0)
        XCTAssertEqual(policy.nextDue(now: t0), t0.addingTimeInterval(240))
        for _ in 0..<10 { policy.recordFailure(now: t0) }
        XCTAssertEqual(policy.nextDue(now: t0), t0.addingTimeInterval(WeatherTuning.backoffMax))
    }

    func testRateLimitSurvivesManualRefreshButFailuresDoNot() {
        var policy = WeatherFetchPolicy()
        policy.recordStarted(now: t0)
        policy.recordRateLimited(retryAfterSeconds: 600, now: t0)
        XCTAssertFalse(policy.requestManualRefresh(now: t0.addingTimeInterval(300)))
        XCTAssertTrue(policy.requestManualRefresh(now: t0.addingTimeInterval(601)))

        var failing = WeatherFetchPolicy()
        failing.recordStarted(now: t0)
        failing.recordFailure(now: t0)
        XCTAssertFalse(failing.requestManualRefresh(now: t0.addingTimeInterval(10)))
        XCTAssertTrue(failing.requestManualRefresh(now: t0.addingTimeInterval(31)))
        XCTAssertEqual(failing.nextDue(now: t0.addingTimeInterval(31)), t0.addingTimeInterval(31))
    }

    func testLocationChangeKeepsARealRateLimit() {
        var policy = WeatherFetchPolicy()
        policy.recordRateLimited(retryAfterSeconds: 900, now: t0)
        policy.invalidateLocation()
        XCTAssertEqual(policy.nextDue(now: t0), t0.addingTimeInterval(900))
        var failing = WeatherFetchPolicy()
        failing.recordFailure(now: t0)
        failing.invalidateLocation()
        XCTAssertEqual(failing.nextDue(now: t0), t0)
    }

    func testDailyCapWaitsForTheNextDay() {
        var policy = WeatherFetchPolicy()
        for _ in 0..<WeatherTuning.dailyCap { policy.recordStarted(now: t0) }
        let due = policy.nextDue(now: t0)
        XCTAssertGreaterThan(due, t0)
        XCTAssertEqual(due.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400), 0)
    }

    // MARK: Timeline and animation

    private func sample(_ kind: WeatherConditionKind, at offset: TimeInterval, cover: Double) -> WeatherSample {
        WeatherSample(date: t0.addingTimeInterval(offset), kind: kind, cloudCover: cover, windSpeed: 4, windFrom: 250)
    }

    func testTimelineHoldsCurrentThenFollowsTheForecast() {
        let snapshot = WeatherSnapshot(
            coordinate: WeatherCoordinate(latitude: 1, longitude: 1), source: .metNorway,
            current: sample(.clear, at: 0, cover: 0),
            hourly: [sample(.rain, at: 3600, cover: 1), sample(.rain, at: 7200, cover: 1)],
            fetchedAt: t0, expiresAt: nil, placeName: nil)
        let current = WeatherVisualState.target(for: snapshot.current)
        let rain = WeatherVisualState.target(for: snapshot.hourly[1])
        XCTAssertEqual(WeatherTimeline.target(at: t0.addingTimeInterval(600), snapshot: snapshot), current)
        XCTAssertEqual(WeatherTimeline.target(at: t0.addingTimeInterval(3 * 3600), snapshot: snapshot), rain)
        let a = WeatherTimeline.target(at: t0.addingTimeInterval(2_400), snapshot: snapshot).cloudLow
        let b = WeatherTimeline.target(at: t0.addingTimeInterval(3_000), snapshot: snapshot).cloudLow
        XCTAssertGreaterThan(b, a)
    }

    func testAnimatorRetargetsWithoutAJump() {
        let clear = WeatherVisualState.target(for: sample(.clear, at: 0, cover: 0))
        let storm = WeatherVisualState.target(for: sample(.thunderstorm, at: 0, cover: 1))
        var animator = WeatherVisualAnimator()
        animator.begin(from: clear, at: 0, duration: 10)
        XCTAssertEqual(animator.apply(storm, at: 0), clear)
        XCTAssertEqual(animator.apply(storm, at: 10), storm)
        let midway = animator.apply(storm, at: 5)
        animator.begin(from: midway, at: 5, duration: 10)
        XCTAssertEqual(animator.apply(clear, at: 5), midway)
        XCTAssertFalse(animator.isActive(at: 15))
    }

    func testVisualTargetsReflectConditions() {
        let fog = WeatherVisualState.target(for: WeatherVisualState.demoSample(.fog, date: t0))
        XCTAssertGreaterThan(fog.fog, 0.8)
        let storm = WeatherVisualState.target(for: WeatherVisualState.demoSample(.thunderstorm, date: t0))
        XCTAssertGreaterThan(storm.lightning, 0.5)
        XCTAssertGreaterThan(storm.rain, 0.5)
        let snow = WeatherVisualState.target(for: WeatherVisualState.demoSample(.heavySnow, date: t0))
        XCTAssertGreaterThan(snow.snow, 0.8)
        XCTAssertEqual(snow.rain, 0)
        // A westerly drifts toward the east.
        XCTAssertGreaterThan(WeatherVisualState.target(for: sample(.clear, at: 0, cover: 0)).windEast, 0)
    }

    // MARK: Lightning

    func testLightningStrikesAreSpacedAndBounded() {
        var last: Double?
        for slot in Int64(0)..<5_000 {
            guard let strike = LightningSchedule.strike(inSlot: slot, rate: 1) else { continue }
            if let last { XCTAssertGreaterThanOrEqual(strike.time - last, 6) }
            last = strike.time
            var peak = 0.0
            for step in 0..<120 { peak = max(peak, LightningSchedule.flash(at: strike.time + Double(step) * 0.01, strike: strike)) }
            XCTAssertLessThanOrEqual(peak, 1)
            XCTAssertGreaterThan(peak, 0.5)
            XCTAssertEqual(LightningSchedule.flash(at: strike.time + LightningSchedule.flashDuration - 0.001, strike: strike), 0, accuracy: 0.001)
            XCTAssertEqual(LightningSchedule.flash(at: strike.time + LightningSchedule.flashDuration + 0.001, strike: strike), 0)
        }
        XCTAssertNotNil(last)
        XCTAssertNil(LightningSchedule.strike(inSlot: 3, rate: 0))
    }

    func testBoltStaysBetweenCloudAndGround() {
        var segments: [LightningSegment] = []
        LightningSchedule.buildBolt(seed: 42, top: SIMD2(0.5, 0.3), bottomY: 1.04, into: &segments)
        XCTAssertGreaterThanOrEqual(segments.count, 32)
        XCTAssertLessThanOrEqual(segments.count, 96)
        XCTAssertEqual(segments[0].ends.y, 0.3, accuracy: 0.0001)
        for segment in segments {
            XCTAssertGreaterThan(segment.ends.y, 0.15)
            XCTAssertLessThan(segment.ends.w, 1.3)
        }
    }

    // MARK: Sky geometry

    func testZenithStarMapsStraightUp() {
        let latitude = 40.0, longitude = -105.0
        let lst = WeatherSkyGeometry.greenwichSiderealDegrees(t0) + longitude
        let rows = WeatherSkyGeometry.equatorialRows(date: t0, latitude: latitude, longitude: longitude)
        let star = WeatherSkyGeometry.equatorialVector(rightAscension: lst, declination: latitude)
        let world = WeatherSkyGeometry.apply(rows, star)
        XCTAssertEqual(world.y, 1, accuracy: 0.0001)
        let pole = WeatherSkyGeometry.apply(rows, SIMD3(0, 0, 1))
        XCTAssertEqual(pole.y, Float(sin(latitude * .pi / 180)), accuracy: 0.0001)
        XCTAssertLessThan(pole.z, 0) // north is -z
    }

    func testCameraProjectionRoundTrips() {
        let camera = WeatherCamera(aspect: 16 / 10, azimuth: 180)
        for uv in [SIMD2<Float>(0.5, 0.5), SIMD2(0.1, 0.9), SIMD2(0.8, 0.2)] {
            let projected = camera.project(camera.ray(uv: uv))!
            XCTAssertEqual(projected.x, uv.x, accuracy: 0.0005)
            XCTAssertEqual(projected.y, uv.y, accuracy: 0.0005)
        }
        // The horizon sits just above the bottom edge.
        XCTAssertLessThan(camera.ray(uv: SIMD2(0.5, 1)).y, 0)
        XCTAssertGreaterThan(camera.ray(uv: SIMD2(0.5, 0.92)).y, 0)
    }

    func testSunTransmittanceReddensTowardTheHorizon() {
        let high = WeatherSkyGeometry.sunTransmittance(direction: WeatherSkyGeometry.direction(azimuth: 180, altitude: 60), height: 0)
        let low = WeatherSkyGeometry.sunTransmittance(direction: WeatherSkyGeometry.direction(azimuth: 180, altitude: 2), height: 0)
        XCTAssertGreaterThan(high.z, 0.7)
        XCTAssertGreaterThan(low.x, low.z)
        XCTAssertEqual(WeatherSkyGeometry.sunTransmittance(direction: WeatherSkyGeometry.direction(azimuth: 180, altitude: -10), height: 0), .zero)
    }

    func testPreviewTimesFindNoonAndSunset() {
        // A synthetic day: altitude peaks at t0 + 3 h.
        let altitude: (Date) -> Double = { 50 * cos(($0.timeIntervalSince(self.t0) - 3 * 3600) / 86_400 * 2 * .pi) }
        let noon = WeatherSkyGeometry.previewDate(.noon, around: t0, altitude: altitude)
        XCTAssertEqual(noon.timeIntervalSince(t0), 3 * 3600, accuracy: 600)
        let sunset = WeatherSkyGeometry.previewDate(.sunset, around: t0, altitude: altitude)
        XCTAssertGreaterThan(sunset, noon)
        XCTAssertLessThan(altitude(sunset.addingTimeInterval(600)), 3)
    }
}
