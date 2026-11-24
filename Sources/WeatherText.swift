import Foundation

/// Підписи до погоди (українська / англійська).
enum WeatherText {
    static func weekday(_ d: Date, short: Bool = true) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        if cal.isDateInToday(d) { return short ? L.t("Сьог.", "Today") : L.t("Сьогодні", "Today") }
        if cal.isDateInTomorrow(d) && !short { return L.t("Завтра", "Tomorrow") }
        let i = cal.component(.weekday, from: d) - 1
        let uk = short ? ["Нд", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"] : ["Неділя", "Понеділок", "Вівторок", "Середа", "Четвер", "П’ятниця", "Субота"]
        let en = short ? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] : ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let ru = short ? ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"] : ["Воскресенье", "Понедельник", "Вторник", "Среда", "Четверг", "Пятница", "Суббота"]
        return (L.lang == "uk" ? uk : L.lang == "ru" ? ru : en)[i]
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = L.locale; f.dateFormat = "d MMM"
        return f.string(from: d)
    }

    static func temp(_ t: Int) -> String { (t > 0 ? "+" : t < 0 ? "−" : "") + "\(abs(t))°" }

    /// WMO weather code → опис.
    static func describe(_ c: Int) -> String {
        switch c {
        case 0: return L.t("Ясно", "Clear")
        case 1: return L.t("Переважно ясно", "Mostly clear")
        case 2: return L.t("Мінлива хмарність", "Partly cloudy")
        case 3: return L.t("Хмарно", "Overcast")
        case 45, 48: return L.t("Туман", "Fog")
        case 51, 53, 55: return L.t("Мряка", "Drizzle")
        case 56, 57: return L.t("Крижана мряка", "Freezing drizzle")
        case 61: return L.t("Невеликий дощ", "Light rain")
        case 63: return L.t("Дощ", "Rain")
        case 65: return L.t("Сильний дощ", "Heavy rain")
        case 66, 67: return L.t("Крижаний дощ", "Freezing rain")
        case 71: return L.t("Невеликий сніг", "Light snow")
        case 73: return L.t("Сніг", "Snow")
        case 75: return L.t("Сильний сніг", "Heavy snow")
        case 77: return L.t("Снігова крупа", "Snow grains")
        case 80, 81: return L.t("Злива", "Showers")
        case 82: return L.t("Сильна злива", "Heavy showers")
        case 85, 86: return L.t("Снігопад", "Snow showers")
        case 95: return L.t("Гроза", "Thunderstorm")
        case 96, 99: return L.t("Гроза з градом", "Thunderstorm with hail")
        default: return "—"
        }
    }
}
