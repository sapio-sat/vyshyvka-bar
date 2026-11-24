import AppKit

/// Місто для погоди. Зберігається в UserDefaults (домен ua.vyshyvka.bar):
///   defaults write ua.vyshyvka.bar cityName "Львів"
///   defaults write ua.vyshyvka.bar cityLat -float 49.8397
///   defaults write ua.vyshyvka.bar cityLon -float 24.0297
/// Обирається під час установки (install.sh), у вікні першого запуску або в меню ◆ → «Місто погоди».
struct City: Equatable {
    var name: String
    var lat: Double
    var lon: Double

    static let changed = Notification.Name("ua.vyshyvka.bar.cityChanged")

    /// Підказки до введення; будь-яке місто світу — пошуком (Open-Meteo Geocoding).
    static let presets: [City] = [
        City(name: "Київ", lat: 50.4501, lon: 30.5234),
        City(name: "Вінниця", lat: 49.2331, lon: 28.4682),
        City(name: "Дніпро", lat: 48.4647, lon: 35.0462),
        City(name: "Житомир", lat: 50.2547, lon: 28.6587),
        City(name: "Запоріжжя", lat: 47.8388, lon: 35.1396),
        City(name: "Івано-Франківськ", lat: 48.9226, lon: 24.7111),
        City(name: "Кривий Ріг", lat: 47.9105, lon: 33.3918),
        City(name: "Кропивницький", lat: 48.5079, lon: 32.2623),
        City(name: "Луцьк", lat: 50.7472, lon: 25.3254),
        City(name: "Львів", lat: 49.8397, lon: 24.0297),
        City(name: "Миколаїв", lat: 46.9750, lon: 31.9946),
        City(name: "Одеса", lat: 46.4825, lon: 30.7233),
        City(name: "Полтава", lat: 49.5883, lon: 34.5514),
        City(name: "Рівне", lat: 50.6199, lon: 26.2516),
        City(name: "Суми", lat: 50.9077, lon: 34.7981),
        City(name: "Тернопіль", lat: 49.5535, lon: 25.5948),
        City(name: "Ужгород", lat: 48.6208, lon: 22.2879),
        City(name: "Харків", lat: 49.9935, lon: 36.2304),
        City(name: "Херсон", lat: 46.6354, lon: 32.6169),
        City(name: "Хмельницький", lat: 49.4229, lon: 26.9871),
        City(name: "Черкаси", lat: 49.4444, lon: 32.0598),
        City(name: "Чернівці", lat: 48.2921, lon: 25.9358),
        City(name: "Чернігів", lat: 51.4982, lon: 31.2893),
    ]
    static let world: [City] = [
        City(name: "Warszawa", lat: 52.2297, lon: 21.0122),
        City(name: "Berlin", lat: 52.5200, lon: 13.4050),
        City(name: "London", lat: 51.5074, lon: -0.1278),
        City(name: "Paris", lat: 48.8566, lon: 2.3522),
        City(name: "Praha", lat: 50.0755, lon: 14.4378),
        City(name: "Vilnius", lat: 54.6872, lon: 25.2797),
        City(name: "Toronto", lat: 43.6532, lon: -79.3832),
        City(name: "New York", lat: 40.7128, lon: -74.0060),
    ]
    static let fallback = presets[0]

    /// nil — місто ще не обране (тоді погода для Києва, а при першому запуску з'явиться вибір).
    static var saved: City? {
        let d = UserDefaults.standard
        guard let n = d.string(forKey: "cityName"), d.object(forKey: "cityLat") != nil, d.object(forKey: "cityLon") != nil
        else { return nil }
        return City(name: n, lat: d.double(forKey: "cityLat"), lon: d.double(forKey: "cityLon"))
    }
    static var current: City { saved ?? fallback }

    func save() {
        let d = UserDefaults.standard
        d.set(name, forKey: "cityName"); d.set(lat, forKey: "cityLat"); d.set(lon, forKey: "cityLon")
        NotificationCenter.default.post(name: City.changed, object: nil)
    }

    /// Пошук міста за назвою (будь-якою мовою). Open-Meteo Geocoding, без ключа.
    static func search(_ query: String, completion: @escaping ([(City, String)]) -> Void) {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: query), .init(name: "count", value: "8"),
                        .init(name: "language", value: L.lang), .init(name: "format", value: "json")]
        URLSession.shared.dataTask(with: c.url!) { data, _, _ in
            var out: [(City, String)] = []
            if let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let rs = j["results"] as? [[String: Any]] {
                for r in rs {
                    guard let n = r["name"] as? String, let la = (r["latitude"] as? NSNumber)?.doubleValue,
                          let lo = (r["longitude"] as? NSNumber)?.doubleValue else { continue }
                    let detail = [r["admin1"] as? String, r["country"] as? String].compactMap { $0 }.joined(separator: ", ")
                    out.append((City(name: n, lat: la, lon: lo), detail))
                }
            }
            DispatchQueue.main.async { completion(out) }
        }.resume()
    }
}

