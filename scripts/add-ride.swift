#!/usr/bin/env swift
//
// add-ride.swift — Garmin (Edge 840) GPX → full ride pipeline.
//
// Drop a GPX named "NNNN-slug-words.gpx" (e.g. 0001-nevers-and-the-loire-bridges.gpx)
// into BikeToLunarStaticContent/Files/gpx/, then run this. For each NEW GPX it:
//   1. derives the ride stats and appends an entry to data/distance.json
//      (id = the number, title = title-cased slug, url = /blog/<base>/),
//   2. renders a route map to BikeToLunarStaticContent/Images/maps/<base>.jpg
//      (via generate-gpx-map.swift), and
//   3. writes a published blog post content/blog/<base>.md dated today, with the
//      map image + {{ ride }} / {{ weather }} stat cards.
//
// Usage:
//   swift scripts/add-ride.swift                 # process every new GPX in Files/gpx
//   swift scripts/add-ride.swift 0001            # process that number
//   swift scripts/add-ride.swift path/to.gpx     # process one specific NNNN-slug.gpx
//   [--title S --country S --route S --url S --calories N --weather S
//    --weather-temp N --wind N --humidity N --image-base URL
//    --no-map --no-post --no-weather --dry-run --force]
//
// Weather (conditions/temp/wind/humidity) is fetched automatically from the ride
// midpoint via get-weather.swift (Open-Meteo) unless --weather is given or
// --no-weather is set.
// A single-file run honours the --title/--country/--route/… overrides; a batch run
// derives everything from the filename + GPX (+ geocoded country).
//
// GPS-derived: date, distance, elapsed/moving minutes, avg/max speed, elevation
// gain/loss, temperature (if <gpxtpx:atemp>). calories & weather are never in a
// GPX — pass them as flags or edit later. moving_minutes/max_speed approximate
// Garmin's FIT-computed values.

import Foundation
import CoreLocation

// MARK: - Options / argument parsing

struct Options {
    var input: String?          // a number (0001), a .gpx path, or nil (scan Files/gpx)
    var title: String?
    var country: String?
    var route: String?
    var url: String?
    var calories: Int?
    var weather: String?
    var weatherTemp: Int?
    var wind: Int?
    var humidity: Int?
    var imageBase = "https://images.biketolunar.com/maps"
    var noMap = false
    var noPost = false
    var noWeather = false
    var dryRun = false
    var force = false
}

func parseArguments() -> Options {
    var o = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg.hasPrefix("--") {
            let key = String(arg.dropFirst(2))
            if key == "dry-run" { o.dryRun = true; i += 1; continue }
            if key == "force"   { o.force = true;  i += 1; continue }
            if key == "no-map"     { o.noMap = true;     i += 1; continue }
            if key == "no-post"    { o.noPost = true;    i += 1; continue }
            if key == "no-weather" { o.noWeather = true; i += 1; continue }
            let value = (i + 1 < args.count) ? args[i + 1] : ""
            switch key {
            case "title":        o.title = value
            case "country":      o.country = value
            case "route":        o.route = value
            case "url":          o.url = value
            case "calories":     o.calories = Int(value)
            case "weather":      o.weather = value
            case "weather-temp": o.weatherTemp = Int(value)
            case "wind":         o.wind = Int(value)
            case "humidity":     o.humidity = Int(value)
            case "image-base":   o.imageBase = value
            default: break
            }
            i += 2
        } else if o.input == nil {
            o.input = arg; i += 1
        } else {
            i += 1
        }
    }
    return o
}

func warn(_ msg: String) { FileHandle.standardError.write(Data((msg + "\n").utf8)) }
func die(_ msg: String) -> Never { warn(msg); exit(1) }

// MARK: - GPX parsing (SAX; non-namespace-aware → qualified element names)

struct TrackPoint {
    let coord: CLLocationCoordinate2D
    var ele: Double?
    var time: Date?
    var atemp: Double?
    var speed: Double?   // m/s, from gpxtpx:speed (TrackPointExtension v2), if present
}

final class GPXParser: NSObject, XMLParserDelegate {
    var points: [TrackPoint] = []
    var trackName: String?
    var metadataTime: Date?

    private var text = ""
    private var lat: Double?, lon: Double?
    private var ele: Double?, time: Date?, atemp: Double?, speed: Double?
    private var inTrk = false, inMetadata = false, metaTimeDone = false

    private let isoPlain = ISO8601DateFormatter()
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private func date(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }

    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String] = [:]) {
        text = ""
        switch el {
        case "trkpt", "rtept":
            if let la = a["lat"], let lo = a["lon"], let laD = Double(la), let loD = Double(lo) {
                lat = laD; lon = loD; ele = nil; time = nil; atemp = nil; speed = nil
            }
        case "trk": inTrk = true
        case "metadata": inMetadata = true
        default: break
        }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch el {
        case "ele": ele = Double(t)
        case "time":
            let d = date(t)
            if inMetadata && !metaTimeDone { metadataTime = d; metaTimeDone = true }
            else { time = d }
        case "gpxtpx:atemp": atemp = Double(t)
        case "gpxtpx:speed": speed = Double(t)
        case "name": if inTrk, trackName == nil, !t.isEmpty { trackName = t }
        case "trk": inTrk = false
        case "metadata": inMetadata = false
        case "trkpt", "rtept":
            if let la = lat, let lo = lon {
                points.append(TrackPoint(coord: CLLocationCoordinate2D(latitude: la, longitude: lo),
                                         ele: ele, time: time, atemp: atemp, speed: speed))
            }
            lat = nil; lon = nil
        default: break
        }
        text = ""
    }
}

// MARK: - Ride model + format-matching serializer (2-space, semantic key order)

struct Ride: Codable {
    var id: String
    var date: String
    var distance: Double
    var country: String?
    var route: String?
    var title: String?
    var url: String?
    var moving_minutes: Int?
    var elapsed_minutes: Int?
    var avg_speed: Double?
    var max_speed: Double?
    var elevation_gain: Int?
    var elevation_loss: Int?
    var calories: Int?
    var temperature: Int?
    var weather: String?
    var weather_temp: Int?
    var wind_speed: Int?
    var humidity: Int?
}

func jsonEscape(_ s: String) -> String {
    var out = ""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if u.value < 0x20 { out += String(format: "\\u%04x", u.value) }
            else { out.unicodeScalars.append(u) }
        }
    }
    return out
}
func num1(_ d: Double) -> String { String(format: "%.1f", d) }

func serialize(_ rides: [Ride]) -> String {
    var objs: [String] = []
    for r in rides {
        var f: [String] = []
        func str(_ k: String, _ v: String?) { if let v = v { f.append("    \"\(k)\": \"\(jsonEscape(v))\"") } }
        func dbl(_ k: String, _ v: Double?) { if let v = v { f.append("    \"\(k)\": \(num1(v))") } }
        func int(_ k: String, _ v: Int?)    { if let v = v { f.append("    \"\(k)\": \(v)") } }
        f.append("    \"id\": \"\(jsonEscape(r.id))\"")
        f.append("    \"date\": \"\(jsonEscape(r.date))\"")
        f.append("    \"distance\": \(num1(r.distance))")
        str("country", r.country); str("route", r.route); str("title", r.title); str("url", r.url)
        int("moving_minutes", r.moving_minutes); int("elapsed_minutes", r.elapsed_minutes)
        dbl("avg_speed", r.avg_speed); dbl("max_speed", r.max_speed)
        int("elevation_gain", r.elevation_gain); int("elevation_loss", r.elevation_loss)
        int("calories", r.calories); int("temperature", r.temperature)
        str("weather", r.weather); int("weather_temp", r.weather_temp)
        int("wind_speed", r.wind_speed); int("humidity", r.humidity)
        objs.append("  {\n" + f.joined(separator: ",\n") + "\n  }")
    }
    return "[\n" + objs.joined(separator: ",\n") + "\n]\n"
}

// CLGeocoder is deprecated on macOS 26 but still functional and returns clean
// English country names. Isolating it in a deprecation-annotated helper keeps
// the rest of the build warning-free; pass --country to skip geocoding entirely.
@available(*, deprecated, message: "uses CLGeocoder — deprecated on macOS 26 but retained intentionally")
func reverseGeocodeCountry(_ location: CLLocation) -> String? {
    let geocoder = CLGeocoder()
    var result: String?
    var done = false
    geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "en_US")) { placemarks, _ in
        result = placemarks?.first?.country
        done = true
    }
    let deadline = Date().addingTimeInterval(10)
    while !done && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    return result
}

// MARK: - Pipeline helpers

func slugify(_ s: String) -> String {
    let low = s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US")).lowercased()
    var out = ""; var dash = false
    for ch in low {
        if ch.isLetter || ch.isNumber { out.append(ch); dash = false }
        else if !dash { out.append("-"); dash = true }
    }
    return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

// "0001-nevers-and-the-loire-bridges" → (id: "0001", slug: "nevers-and-the-loire-bridges")
func parseBase(_ base: String) -> (id: String, slug: String)? {
    guard let dash = base.firstIndex(of: "-") else { return nil }
    let id = String(base[..<dash])
    let slug = String(base[base.index(after: dash)...])
    guard !id.isEmpty, id.allSatisfy({ $0.isNumber }), !slug.isEmpty else { return nil }
    return (id, slug)
}

func titlecase(_ slug: String) -> String {
    slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
}

func tomlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

// Parse a GPX + compute a Ride (also prints a one-line summary). nil on skip.
func rideFromGPX(_ gpxURL: URL, id: String, title: String, base: String,
                 country flagCountry: String?, route: String?, url flagURL: String?,
                 calories: Int?, weather: String?, weatherTemp: Int?, wind: Int?, humidity: Int?,
                 weatherAuto: Bool, weatherScript: URL) -> Ride? {
    guard let data = try? Data(contentsOf: gpxURL) else { warn("⚠️  Could not read \(gpxURL.path)"); return nil }
    let gpx = GPXParser(); let xml = XMLParser(data: data); xml.delegate = gpx; xml.parse()
    let pts = gpx.points
    guard pts.count >= 2 else { warn("⚠️  No track points in \(gpxURL.lastPathComponent)"); return nil }

    var meters = 0.0
    for i in 1..<pts.count {
        let a = CLLocation(latitude: pts[i-1].coord.latitude, longitude: pts[i-1].coord.longitude)
        let b = CLLocation(latitude: pts[i].coord.latitude, longitude: pts[i].coord.longitude)
        meters += b.distance(from: a)
    }
    let distanceKm = (meters / 1000.0 * 10).rounded() / 10

    let times = pts.compactMap { $0.time }
    guard times.count >= 2 else { warn("⚠️  \(gpxURL.lastPathComponent) has no per-point <time> — skipping."); return nil }
    let startTime = gpx.metadataTime ?? times.first!
    let elapsedSec = times.last!.timeIntervalSince(times.first!)

    var movingSec = 0.0, maxSpeedKmh = 0.0
    for i in 1..<pts.count {
        guard let t0 = pts[i-1].time, let t1 = pts[i].time else { continue }
        let dt = t1.timeIntervalSince(t0); if dt <= 0 { continue }
        let a = CLLocation(latitude: pts[i-1].coord.latitude, longitude: pts[i-1].coord.longitude)
        let b = CLLocation(latitude: pts[i].coord.latitude, longitude: pts[i].coord.longitude)
        let ms = a.distance(from: b) / dt
        if ms >= 1.0 { movingSec += dt }                 // ~1 m/s auto-pause threshold
        let kmh = ms * 3.6
        if kmh <= 90 { maxSpeedKmh = max(maxSpeedKmh, kmh) }   // drop GPS spikes
    }
    let recSpeeds = pts.compactMap { $0.speed }
    if let m = recSpeeds.max(), m > 0 { maxSpeedKmh = m * 3.6 }
    let movingSecEff = movingSec > 0 ? movingSec : elapsedSec
    let avgSpeedKmh = movingSecEff > 0 ? (distanceKm / (movingSecEff / 3600.0)) : 0

    var gain = 0.0, loss = 0.0, ref: Double?
    for p in pts {
        guard let e = p.ele else { continue }
        guard let r = ref else { ref = e; continue }
        let d = e - r
        if d >= 2 { gain += d; ref = e } else if d <= -2 { loss += -d; ref = e }
    }
    let atemps = pts.compactMap { $0.atemp }
    let temperature: Int? = atemps.isEmpty ? nil : Int((atemps.reduce(0, +) / Double(atemps.count)).rounded())

    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = TimeZone(identifier: "UTC")
    let dateStr = df.string(from: startTime)

    var country = flagCountry
    if country == nil {
        country = reverseGeocodeCountry(CLLocation(latitude: pts[0].coord.latitude, longitude: pts[0].coord.longitude))
        if country == nil { warn("⚠️  Could not auto-detect country for \(id); pass --country. Leaving it empty.") }
    }

    var wxText = weather, wxTemp = weatherTemp, wxWind = wind, wxHum = humidity
    if wxText == nil && weatherAuto {
        let mid = pts[pts.count / 2]
        let midTime = mid.time ?? times.first!
        if let w = fetchWeather(lat: mid.coord.latitude, lon: mid.coord.longitude, time: midTime, script: weatherScript) {
            wxText = w.weather
            if wxTemp == nil { wxTemp = w.weather_temp }
            if wxWind == nil { wxWind = w.wind_speed }
            if wxHum == nil { wxHum = w.humidity }
        } else {
            warn("⚠️  Weather not fetched for \(id) (needs network). Leaving it empty.")
        }
    }

    let ride = Ride(
        id: id, date: dateStr, distance: distanceKm,
        country: country, route: route, title: title, url: flagURL ?? "/blog/\(base)/",
        moving_minutes: Int((movingSecEff / 60).rounded()),
        elapsed_minutes: Int((elapsedSec / 60).rounded()),
        avg_speed: (avgSpeedKmh * 10).rounded() / 10,
        max_speed: (maxSpeedKmh * 10).rounded() / 10,
        elevation_gain: Int(gain.rounded()), elevation_loss: Int(loss.rounded()),
        calories: calories, temperature: temperature,
        weather: wxText, weather_temp: wxTemp, wind_speed: wxWind, humidity: wxHum)

    print("""
      \(id)  \(title)  (\(pts.count) pts)
        \(dateStr) · \(num1(distanceKm)) km · moving \(ride.moving_minutes ?? 0) min · avg \(num1(ride.avg_speed ?? 0)) / max \(num1(ride.max_speed ?? 0)) km/h
        ascent/descent \(ride.elevation_gain ?? 0)/\(ride.elevation_loss ?? 0) m · \(temperature.map { "\($0)°C" } ?? "no temp") · \(country ?? "no country")
        weather \(ride.weather ?? "—")\(ride.weather_temp.map { ", \($0)°C" } ?? "")\(ride.wind_speed.map { ", wind \($0)" } ?? "")\(ride.humidity.map { ", \($0)% hum" } ?? "")
    """)
    return ride
}

// Auto weather: shell out to get-weather.swift for the ride midpoint (Open-Meteo).
struct FetchedWeather: Decodable { let weather: String; let weather_temp: Int?; let wind_speed: Int?; let humidity: Int? }
func fetchWeather(lat: Double, lon: Double, time: Date, script: URL) -> FetchedWeather? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["swift", script.path, "--lat", String(lat), "--lon", String(lon),
                   "--time", ISO8601DateFormatter().string(from: time), "--json"]
    let pipe = Pipe(); p.standardOutput = pipe
    do { try p.run() } catch { warn("⚠️  Could not launch get-weather: \(error)"); return nil }
    let deadline = Date().addingTimeInterval(30)
    while p.isRunning && Date() < deadline { usleep(200_000) }
    if p.isRunning { p.terminate(); warn("⚠️  get-weather timed out."); return nil }
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    guard p.terminationStatus == 0, let w = try? JSONDecoder().decode(FetchedWeather.self, from: out) else { return nil }
    return w
}

// Shell out to generate-gpx-map.swift; verify the file was actually written
// (that script can exit 0 even when the snapshot fails).
func generateMap(gpx: URL, out: URL, script: URL, lineColor: String) -> Bool {
    try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["swift", script.path, gpx.path, out.path,
                   "--line-color", lineColor, "--map-type", "standard", "--width", "1600"]
    do { try p.run() }
    catch { warn("⚠️  Could not launch map generator: \(error)"); return false }
    let deadline = Date().addingTimeInterval(120)
    while p.isRunning && Date() < deadline { usleep(200_000) }
    if p.isRunning { p.terminate(); warn("⚠️  Map generator timed out — terminated."); return false }
    let size = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int) ?? 0
    return size > 0
}

func writePost(at postURL: URL, title: String, id: String, base: String,
               ride: Ride, imageBase: String, today: String, force: Bool) {
    if FileManager.default.fileExists(atPath: postURL.path) && !force {
        warn("⚠️  Post \(postURL.lastPathComponent) exists — skipping (use --force)."); return
    }
    var desc = "A \(num1(ride.distance)) km ride"
    if let r = ride.route { desc += " along \(r)" }
    if let c = ride.country { desc += " in \(c)" }
    desc += "."
    let md = """
    +++
    title = "\(tomlEscape(title))"
    date = \(today)
    description = "\(tomlEscape(desc))"

    [taxonomies]
    tags = ["Rides"]
    +++

    _Ride write-up coming soon._

    ## Map

    ![Map of \(title)](\(imageBase)/\(base).jpg)

    {{ ride(id="\(id)") }}

    {{ weather(id="\(id)") }}
    """
    do { try md.write(to: postURL, atomically: true, encoding: .utf8); print("    ✍️  \(postURL.path)") }
    catch { warn("⚠️  Failed to write \(postURL.path): \(error)") }
}

// MARK: - Main

let o = parseArguments()

let repoRoot    = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let distanceURL = repoRoot.appendingPathComponent("data/distance.json")
let blogDir     = repoRoot.appendingPathComponent("content/blog")
let mapScript     = repoRoot.appendingPathComponent("scripts/generate-gpx-map.swift")
let weatherScript = repoRoot.appendingPathComponent("scripts/get-weather.swift")
let staticRoot  = repoRoot.deletingLastPathComponent().appendingPathComponent("BikeToLunarStaticContent")
let gpxDir      = staticRoot.appendingPathComponent("Files/gpx")
let mapsDir     = staticRoot.appendingPathComponent("Images/maps")

let todayFmt = DateFormatter(); todayFmt.dateFormat = "yyyy-MM-dd"   // local tz → "today"
let today = todayFmt.string(from: Date())

var rides: [Ride] = []
if let existing = try? Data(contentsOf: distanceURL) {
    do { rides = try JSONDecoder().decode([Ride].self, from: existing) }
    catch { die("Could not parse \(distanceURL.path): \(error)") }
}
let existingIDs = Set(rides.map { $0.id })

func gpxInDir() -> [URL] {
    let all = (try? FileManager.default.contentsOfDirectory(at: gpxDir, includingPropertiesForKeys: nil)) ?? []
    return all.filter { $0.pathExtension.lowercased() == "gpx" }
              .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

// Resolve which GPX files to process
var toProcess: [URL] = []
if let input = o.input {
    if input.lowercased().hasSuffix(".gpx") {
        toProcess = [URL(fileURLWithPath: input)]
    } else {
        toProcess = gpxInDir().filter { parseBase($0.deletingPathExtension().lastPathComponent)?.id == input }
        if toProcess.isEmpty { die("No GPX named \(input)-<slug>.gpx in \(gpxDir.path)") }
    }
} else {
    toProcess = gpxInDir().filter {
        guard let p = parseBase($0.deletingPathExtension().lastPathComponent) else { return false }
        return !existingIDs.contains(p.id)
    }
    if toProcess.isEmpty { print("No new GPX in \(gpxDir.path) — all numbers already in distance.json."); exit(0) }
}
let single = toProcess.count == 1

print("Processing \(toProcess.count) ride\(toProcess.count == 1 ? "" : "s")\(o.dryRun ? " (dry-run)" : "")…")

var added: [Ride] = []
for gpxURL in toProcess {
    let base = gpxURL.deletingPathExtension().lastPathComponent
    guard let parsed = parseBase(base) else {
        warn("⚠️  Skipping \(gpxURL.lastPathComponent) — filename must be NNNN-slug.gpx"); continue
    }
    let id = parsed.id
    let title = (single ? o.title : nil) ?? titlecase(parsed.slug)
    if existingIDs.contains(id) && !o.force {
        warn("⚠️  id \(id) already in distance.json — skipping (use --force)."); continue
    }
    guard let ride = rideFromGPX(gpxURL, id: id, title: title, base: base,
        country: single ? o.country : nil, route: single ? o.route : nil, url: single ? o.url : nil,
        calories: single ? o.calories : nil, weather: single ? o.weather : nil,
        weatherTemp: single ? o.weatherTemp : nil, wind: single ? o.wind : nil,
        humidity: single ? o.humidity : nil,
        weatherAuto: !o.noWeather, weatherScript: weatherScript) else { continue }

    if !o.dryRun && !o.noMap {
        let mapOut = mapsDir.appendingPathComponent("\(base).jpg")
        if generateMap(gpx: gpxURL, out: mapOut, script: mapScript, lineColor: "ff6b35") {
            print("    🗺️  \(mapOut.path)")
        } else {
            warn("⚠️  Map not generated for \(base) (generate-gpx-map needs network for Apple Maps). Post still references it.")
        }
    }
    if !o.dryRun && !o.noPost {
        writePost(at: blogDir.appendingPathComponent("\(base).md"), title: title, id: id, base: base,
                  ride: ride, imageBase: o.imageBase, today: today, force: o.force)
    }
    added.append(ride)
}

if added.isEmpty { print("Nothing added."); exit(0) }

if o.dryRun {
    print("\n--dry-run: would add \(added.count) entr\(added.count == 1 ? "y" : "ies") + map(s) + post(s). No files written.\n")
    print(serialize(added))
    exit(0)
}

// Merge into distance.json (replace any --force'd ids), sort by date, write.
for r in added { rides.removeAll { $0.id == r.id } }
rides.append(contentsOf: added)
rides.sort { $0.date < $1.date }
do {
    try serialize(rides).write(to: distanceURL, atomically: true, encoding: .utf8)
    print("\n✅ distance.json now has \(rides.count) rides (added \(added.count)).")
} catch { die("Failed to write \(distanceURL.path): \(error)") }
