import Foundation

/// Plain-language network readings. The key trick: timing the *router* separately from the
/// *internet* tells people whether a problem is their Wi-Fi or their internet provider.
enum NetworkInsights {
    enum Level: Equatable, Sendable {
        case checking, great, good, weakWiFi, slowInternet, internetDown, offline

        var title: String {
            switch self {
            case .checking: "Checking your connection…"
            case .great: "Your connection is great"
            case .good: "Your connection is good"
            case .weakWiFi: "Your Wi-Fi is the weak link"
            case .slowInternet: "Your internet is slow right now"
            case .internetDown: "Your internet isn't reachable"
            case .offline: "You're offline"
            }
        }

        var sentence: String {
            switch self {
            case .checking: "Measuring response time to your router and the internet."
            case .great: "Fast responses from both your router and the internet."
            case .good: "Everything's working. Responses are a little slower than ideal."
            case .weakWiFi: "The delay is between your Mac and your router, not your internet. Move closer to the router or away from walls and microwaves."
            case .slowInternet: "Your Wi-Fi is fine, but the internet itself is responding slowly. That's usually your provider or a busy network."
            case .internetDown: "Your Mac reaches the router, but not the internet. Try restarting the router, or check with your provider."
            case .offline: "Not connected to Wi-Fi or Ethernet."
            }
        }

        /// 0–100 for the ring.
        var quality: Double {
            switch self {
            case .checking: 0
            case .great: 100
            case .good: 75
            case .weakWiFi, .slowInternet: 40
            case .internetDown, .offline: 5
            }
        }
    }

    static func level(config: NetworkConfig, wifi: WiFiInfo?, router: PingResult?, internet: PingResult?) -> Level {
        guard config.isOnline else { return .offline }
        guard let internet else { return .checking }
        // Routers sometimes ignore ping; only blame Wi-Fi when we actually measured it.
        let routerMeasured = router?.reachable == true
        let weakSignal = (wifi?.rssi ?? 0) < -75 && wifi != nil
        let slowRouter = routerMeasured && ((router?.averageMs ?? 0) > 40 || (router?.lossPercent ?? 0) >= 20)

        if !internet.reachable {
            return routerMeasured ? .internetDown : (weakSignal ? .weakWiFi : .internetDown)
        }
        if slowRouter || weakSignal { return .weakWiFi }
        let latency = internet.averageMs ?? 0
        if latency > 120 || internet.lossPercent >= 10 { return .slowInternet }
        if latency > 50 || internet.lossPercent > 0 { return .good }
        return .great
    }

    enum Signal: Equatable, Sendable {
        case excellent, good, fair, weak

        var title: String {
            switch self {
            case .excellent: "Excellent"
            case .good: "Good"
            case .fair: "Fair"
            case .weak: "Weak"
            }
        }

        /// Filled bars out of 4, for the signal glyph.
        var bars: Int {
            switch self {
            case .excellent: 4
            case .good: 3
            case .fair: 2
            case .weak: 1
            }
        }
    }

    static func signal(rssi: Int) -> Signal {
        switch rssi {
        case (-55)...: .excellent
        case (-67)...: .good
        case (-75)...: .fair
        default: .weak
        }
    }

    // MARK: Speed test

    struct Activity: Identifiable, Equatable, Sendable {
        let name: String
        let supported: Bool
        var id: String { name }
    }

    /// What the measured speed is good for, in everyday terms.
    static func activities(for result: SpeedTestResult) -> [Activity] {
        let down = result.downloadMbps
        let up = result.uploadMbps
        let rpm = result.responsivenessRPM ?? 0
        return [
            Activity(name: "Browsing & email", supported: down >= 1),
            Activity(name: "HD video", supported: down >= 5),
            Activity(name: "4K streaming", supported: down >= 25),
            Activity(name: "Video calls", supported: up >= 3 && down >= 3 && rpm >= 200),
            Activity(name: "Online gaming", supported: rpm >= 800 && down >= 5),
            Activity(name: "Big downloads", supported: down >= 100),
        ]
    }

    static func speedVerdict(_ result: SpeedTestResult) -> String {
        switch result.downloadMbps {
        case 300...: "Very fast"
        case 100..<300: "Fast"
        case 25..<100: "Good"
        case 5..<25: "Basic"
        default: "Slow"
        }
    }

    static func responsivenessLabel(rpm: Double?) -> String {
        guard let rpm else { return "—" }
        switch rpm {
        case 800...: return "High"
        case 200..<800: return "Medium"
        default: return "Low"
        }
    }

    static func formatMbps(_ mbps: Double) -> String {
        mbps >= 100 ? String(format: "%.0f Mbps", mbps) : String(format: "%.1f Mbps", mbps)
    }

    // MARK: Data used

    struct Usage: Equatable, Sendable {
        let received: Double
        let sent: Double
        var total: Double { received + sent }
    }

    /// Integrates averaged rates over time. Each sample represents `sampleLength` seconds.
    static func usage(_ samples: [HistorySample], sampleLength: TimeInterval, since: Date) -> Usage {
        let window = samples.filter { $0.date >= since }
        return Usage(
            received: window.reduce(0) { $0 + $1.networkIn * sampleLength },
            sent: window.reduce(0) { $0 + $1.networkOut * sampleLength }
        )
    }
}
