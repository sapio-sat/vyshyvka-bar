import AppKit
import Carbon
import IOKit.ps

// Все источники данных событийные: ни одного цикла опроса.

// MARK: - Батарея (уведомления IOKit Power Sources)

struct BatteryState: Equatable {
    var percent: Int
    var charging: Bool
    var onAC: Bool
    var lowPower = false
}

final class BatteryMonitor {
    var onChange: ((BatteryState) -> Void)?
    private var source: CFRunLoopSource?

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx = ctx else { return }
            let me = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            me.onChange?(BatteryMonitor.read())
        }, ctx)?.takeRetainedValue()
        if let s = source { CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode) }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.onChange?(BatteryMonitor.read())
        }
        onChange?(BatteryMonitor.read())
    }

    static func read() -> BatteryState {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            return BatteryState(percent: max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur,
                                charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                                onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
        return BatteryState(percent: -1, charging: false, onAC: true)
    }
}

// MARK: - Часы (один таймер на границу минуты)

final class Clock {
    var onChange: ((String) -> Void)?
    private var timer: Timer?
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"          // местное время и часовой пояс системы
        return f
    }()

    func start() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(tick), name: .NSSystemClockDidChange, object: nil)
        nc.addObserver(self, selector: #selector(tick), name: .NSSystemTimeZoneDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(tick),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        tick()
    }

    @objc func tick() {
        fmt.timeZone = TimeZone.current
        onChange?(fmt.string(from: Date()))
        timer?.invalidate()
        let now = Date().timeIntervalSinceReferenceDate
        let next = Date(timeIntervalSinceReferenceDate: (floor(now / 60) + 1) * 60 + 0.05)
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in self?.tick() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

// MARK: - Погода (Open-Meteo, без ключа и геолокации; раз в 10 минут)

struct Weather: Equatable {
    var celsius: Int
    var code: Int
    var isDay: Bool
    var feels: Int = 0
    var humidity: Int = 0
    var wind: Double = 0            // м/с
    var days: [WeatherDay] = []
    var hours: [WeatherHour] = []
    var updated = Date()
}

struct WeatherDay: Equatable {
    var date: Date
    var code: Int
    var max: Int
    var min: Int
    var precip: Int                 // ймовірність опадів, %
    var wind: Double                // макс. вітер, м/с
    var uv: Double
    var sunrise: String             // "07:12"
    var sunset: String
}

struct WeatherHour: Equatable {
    var hour: String                // "14"
    var code: Int
    var celsius: Int
    var precip: Int
    var isDay: Bool
}

final class WeatherService {
    var onChange: ((Weather?) -> Void)?
    private var timer: Timer?
    private var last: (Weather, Date)?

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cityChanged), name: City.changed, object: nil)
        let t = Timer(timeInterval: 600, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    static var url: URL {
        let c = City.current
        return URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(c.lat)&longitude=\(c.lon)"
            + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"
            + "&hourly=temperature_2m,weather_code,precipitation_probability,is_day"
            + "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,wind_speed_10m_max,uv_index_max"
            + "&forecast_days=7&wind_speed_unit=ms&timezone=auto")!
    }

    static func parse(_ data: Data) -> Weather? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let c = j["current"] as? [String: Any],
              let t = (c["temperature_2m"] as? NSNumber)?.doubleValue else { return nil }
        func num(_ o: Any?) -> Double? { (o as? NSNumber)?.doubleValue }
        func arr(_ d: [String: Any]?, _ k: String) -> [Any] { (d?[k] as? [Any]) ?? [] }
        var w = Weather(celsius: Int(t.rounded()), code: (c["weather_code"] as? NSNumber)?.intValue ?? 0,
                        isDay: ((c["is_day"] as? NSNumber)?.intValue ?? 1) == 1)
        w.feels = Int((num(c["apparent_temperature"]) ?? t).rounded())
        w.humidity = Int(num(c["relative_humidity_2m"]) ?? 0)
        w.wind = num(c["wind_speed_10m"]) ?? 0

        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.locale = Locale(identifier: "en_US_POSIX")
        if let tz = j["timezone"] as? String { df.timeZone = TimeZone(identifier: tz) }
        let d = j["daily"] as? [String: Any]
        let dates = arr(d, "time")
        for i in 0..<dates.count {
            guard let ds = dates[i] as? String, let date = df.date(from: ds) else { continue }
            func at(_ k: String) -> Double? { let a = arr(d, k); return i < a.count ? num(a[i]) : nil }
            func hm(_ k: String) -> String { let a = arr(d, k); return (i < a.count ? a[i] as? String : nil).map { String($0.suffix(5)) } ?? "—" }
            w.days.append(WeatherDay(date: date, code: Int(at("weather_code") ?? 3), max: Int((at("temperature_2m_max") ?? 0).rounded()),
                                     min: Int((at("temperature_2m_min") ?? 0).rounded()), precip: Int(at("precipitation_probability_max") ?? 0),
                                     wind: at("wind_speed_10m_max") ?? 0, uv: at("uv_index_max") ?? 0,
                                     sunrise: hm("sunrise"), sunset: hm("sunset")))
        }
        // 24 години, починаючи з поточної
        let h = j["hourly"] as? [String: Any]
        let times = arr(h, "time").compactMap { $0 as? String }
        let nowHour = ((c["time"] as? String) ?? "").prefix(13)          // "2026-11-24T14"
        let start = times.firstIndex { $0.hasPrefix(nowHour) } ?? 0
        for i in start..<min(start + 24, times.count) {
            func at(_ k: String) -> Double? { let a = arr(h, k); return i < a.count ? num(a[i]) : nil }
            let hh = String(times[i].dropFirst(11).prefix(2))
            w.hours.append(WeatherHour(hour: hh, code: Int(at("weather_code") ?? 3), celsius: Int((at("temperature_2m") ?? 0).rounded()),
                                       precip: Int(at("precipitation_probability") ?? 0), isDay: (at("is_day") ?? 1) == 1))
        }
        return w
    }

    /// Останні отримані дані (для вікна погоди).
    var latest: Weather? { last?.0 }

    @objc private func cityChanged() { last = nil; onChange?(nil); refresh() }

    @objc func refresh() {
        let req = URLRequest(url: Self.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let d = data, let w = Self.parse(d) { self.last = (w, Date()) }
                // Нет свежих данных дольше часа → честное «н/д», а не устаревшая цифра
                if let (w, at) = self.last, Date().timeIntervalSince(at) < 3600 { self.onChange?(w) }
                else { self.onChange?(nil) }
            }
        }.resume()
    }
}

// MARK: - Раскладка (Text Input Sources + системное уведомление о смене)

final class InputSource {
    var onChange: ((String) -> Void)?

    private static let labels = ["uk": "УКР", "ru": "РУС", "en": "ENG", "de": "DEU", "fr": "FRA", "pl": "POL"]

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(changed),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        changed()
    }

    @objc func changed() {
        DispatchQueue.main.async { self.onChange?(Self.currentLabel()) }
    }

    private static func prop<T>(_ s: TISInputSource, _ k: CFString) -> T? {
        guard let p = TISGetInputSourceProperty(s, k) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue() as? T
    }

    static func currentLabel() -> String {
        let s = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let langs: [String] = prop(s, kTISPropertyInputSourceLanguages) ?? []
        if let l = langs.first, let t = labels[l] { return t }
        let name: String = prop(s, kTISPropertyLocalizedName) ?? "?"
        return String(name.prefix(3)).uppercased()
    }

    /// Следующая включённая раскладка (циклически).
    func next() {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        let all = (TISCreateInputSourceList(filter, false).takeRetainedValue() as? [TISInputSource] ?? [])
            .filter { (Self.prop($0, kTISPropertyInputSourceType) as String?) == (kTISTypeKeyboardLayout as String) }
        guard !all.isEmpty else { return }
        let cur = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let curID: String? = Self.prop(cur, kTISPropertyInputSourceID)
        let i = all.firstIndex { (Self.prop($0, kTISPropertyInputSourceID) as String?) == curID } ?? -1
        TISSelectInputSource(all[(i + 1) % all.count])
        changed()
    }
}
