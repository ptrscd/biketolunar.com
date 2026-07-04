#!/usr/bin/env swift
//
// get-weather.swift — historical weather from Open-Meteo (free, no API key).
//
// Usage:
//   swift scripts/get-weather.swift --lat 47.0 --lon 3.15 --time 2026-06-25T13:37:00Z [--json]
//   swift scripts/get-weather.swift path/to.gpx [--json]   # uses the ride's MIDPOINT point + time
//
// Prints conditions text + temperature (°C), wind (km/h) and humidity (%) for the
// hour nearest the given time. Recent dates use the forecast host, older ones the
// ERA5 archive — same params, same JSON. Weather data by Open-Meteo.com (CC BY 4.0).

import Foundation

func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

func parseISO(_ s: String) -> Date? {
    let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return frac.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

// MARK: - Arguments

var lat: Double?, lon: Double?, timeStr: String?, gpxPath: String?, jsonOut = false
do {
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--json" { jsonOut = true; i += 1; continue }
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            let val = (i + 1 < args.count) ? args[i + 1] : ""
            switch key {
            case "lat":  lat = Double(val)
            case "lon":  lon = Double(val)
            case "time": timeStr = val
            default: break
            }
            i += 2
        } else if gpxPath == nil { gpxPath = a; i += 1 }
        else { i += 1 }
    }
}

// MARK: - GPX midpoint (optional)

if let gpxPath = gpxPath {
    final class MidParser: NSObject, XMLParserDelegate {
        struct P { let lat: Double; let lon: Double; var time: Date? }
        var pts: [P] = []
        private var lat: Double?, lon: Double?, time: Date?, text = ""
        private let isoFrac: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
        }()
        private let isoPlain = ISO8601DateFormatter()
        func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String] = [:]) {
            text = ""
            if el == "trkpt" || el == "rtept", let la = a["lat"], let lo = a["lon"],
               let laD = Double(la), let loD = Double(lo) { lat = laD; lon = loD; time = nil }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
        func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if el == "time" { time = isoFrac.date(from: t) ?? isoPlain.date(from: t) }
            else if el == "trkpt" || el == "rtept", let la = lat, let lo = lon {
                pts.append(P(lat: la, lon: lo, time: time)); lat = nil; lon = nil
            }
            text = ""
        }
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: gpxPath)) else { die("Could not read GPX: \(gpxPath)") }
    let mp = MidParser(); let xml = XMLParser(data: data); xml.delegate = mp; xml.parse()
    guard !mp.pts.isEmpty else { die("No track points in \(gpxPath)") }
    let mid = mp.pts[mp.pts.count / 2]
    lat = mid.lat; lon = mid.lon
    guard let t = mid.time else { die("GPX has no per-point <time> — can't pick a weather hour.") }
    timeStr = ISO8601DateFormatter().string(from: t)
}

guard let latitude = lat, let longitude = lon, let ts = timeStr, let when = parseISO(ts) else {
    die("Usage: get-weather.swift --lat X --lon Y --time ISO8601 [--json]  |  get-weather.swift file.gpx [--json]")
}

// MARK: - Fetch

let dfDate = DateFormatter(); dfDate.dateFormat = "yyyy-MM-dd"; dfDate.timeZone = TimeZone(identifier: "UTC")
let dfHour = DateFormatter(); dfHour.dateFormat = "yyyy-MM-dd'T'HH:00"; dfHour.timeZone = TimeZone(identifier: "UTC")
let rideDate = dfDate.string(from: when)
let hourKey = dfHour.string(from: when)

let daysAgo = Int(Date().timeIntervalSince(when) / 86400)
let host = daysAgo <= 90 ? "https://api.open-meteo.com/v1/forecast"
                         : "https://archive-api.open-meteo.com/v1/archive"

var comps = URLComponents(string: host)!
comps.queryItems = [
    .init(name: "latitude", value: String(latitude)),
    .init(name: "longitude", value: String(longitude)),
    .init(name: "start_date", value: rideDate),
    .init(name: "end_date", value: rideDate),
    .init(name: "hourly", value: "temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code"),
    .init(name: "timezone", value: "UTC"),
    .init(name: "wind_speed_unit", value: "kmh"),
    .init(name: "temperature_unit", value: "celsius"),
]
guard let url = comps.url else { die("Could not build request URL") }
guard let data = try? Data(contentsOf: url) else { die("Weather fetch failed (no network?) — \(url.absoluteString)") }

struct Response: Decodable {
    struct Hourly: Decodable {
        let time: [String]
        let temperature_2m: [Double?]
        let relative_humidity_2m: [Double?]
        let wind_speed_10m: [Double?]
        let weather_code: [Int?]
    }
    let hourly: Hourly
}
guard let resp = try? JSONDecoder().decode(Response.self, from: data) else {
    die("Could not parse Open-Meteo response")
}
guard let idx = resp.hourly.time.firstIndex(of: hourKey) else {
    die("No weather for hour \(hourKey) UTC in the response")
}

func wmoLabel(_ c: Int) -> String {
    switch c {
    case 0:  return "Clear"
    case 1:  return "Mainly clear"
    case 2:  return "Partly cloudy"
    case 3:  return "Overcast"
    case 45: return "Fog"
    case 48: return "Rime fog"
    case 51: return "Light drizzle"
    case 53: return "Drizzle"
    case 55: return "Heavy drizzle"
    case 56: return "Light freezing drizzle"
    case 57: return "Freezing drizzle"
    case 61: return "Light rain"
    case 63: return "Rain"
    case 65: return "Heavy rain"
    case 66: return "Light freezing rain"
    case 67: return "Freezing rain"
    case 71: return "Light snow"
    case 73: return "Snow"
    case 75: return "Heavy snow"
    case 77: return "Snow grains"
    case 80: return "Light rain showers"
    case 81: return "Rain showers"
    case 82: return "Violent rain showers"
    case 85: return "Light snow showers"
    case 86: return "Snow showers"
    case 95: return "Thunderstorm"
    case 96: return "Thunderstorm with hail"
    case 99: return "Thunderstorm with heavy hail"
    default: return "Unknown"
    }
}

let tempI = resp.hourly.temperature_2m[idx].map { Int($0.rounded()) }
let humI  = resp.hourly.relative_humidity_2m[idx].map { Int($0.rounded()) }
let windI = resp.hourly.wind_speed_10m[idx].map { Int($0.rounded()) }
let label = wmoLabel(resp.hourly.weather_code[idx] ?? -1)

func jsonEscape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

if jsonOut {
    var parts = ["\"weather\": \"\(jsonEscape(label))\""]
    if let t = tempI { parts.append("\"weather_temp\": \(t)") }
    if let w = windI { parts.append("\"wind_speed\": \(w)") }
    if let h = humI  { parts.append("\"humidity\": \(h)") }
    print("{" + parts.joined(separator: ", ") + "}")
} else {
    print("\(label) · \(tempI.map { "\($0)°C" } ?? "—") · wind \(windI.map { "\($0) km/h" } ?? "—") · humidity \(humI.map { "\($0)%" } ?? "—")")
    print("(hour \(hourKey) UTC · \(daysAgo <= 90 ? "forecast" : "archive") · Open-Meteo)")
}
