#!/usr/bin/env swift
//
// generate-gpx-map.swift
// Renders a GPX file as a beautiful Apple Maps image (PNG).
// Run with: swift scripts/generate-gpx-map.swift input.gpx output.png [options]
//
// Each generator stays runnable on its own, just like your other scripts.
//

import Foundation
import CoreLocation
import MapKit

// MARK: - Simple argument parsing (no dependencies)
struct Options {
	var inputPath: String?
	var outputPath: String?
	var mapType: String = "standard"
	var lineColor: String = "007AFF"
	var lineWidth: Double = 5.0
	var width: Int = 1400
	var height: Int = 0          // 0 = auto aspect ratio
	var padding: Double = 0.12
}

func parseArguments() -> Options {
	var opts = Options()
	let args = CommandLine.arguments.dropFirst()
	var i = args.startIndex

	while i < args.endIndex {
		let arg = args[i]
		if arg.hasPrefix("--") {
			let key = String(arg.dropFirst(2))
			let value = (i + 1 < args.endIndex) ? args[i + 1] : ""
			switch key {
			case "map-type":      opts.mapType = value
			case "line-color":    opts.lineColor = value
			case "line-width":    opts.lineWidth = Double(value) ?? opts.lineWidth
			case "width":         opts.width = Int(value) ?? opts.width
			case "height":        opts.height = Int(value) ?? opts.height
			case "padding":       opts.padding = Double(value) ?? opts.padding
			default: break
			}
			if !value.isEmpty { i = args.index(after: i) }
		} else if opts.inputPath == nil {
			opts.inputPath = arg
		} else if opts.outputPath == nil {
			opts.outputPath = arg
		}
		i = args.index(after: i)
	}
	return opts
}

let options = parseArguments()

guard let inputPath = options.inputPath, let outputPath = options.outputPath else {
	print("Usage: swift generate-gpx-map.swift <input.gpx> <output.png> [options]")
	print("Options:")
	print("  --map-type standard|satellite|hybrid|muted")
	print("  --line-color 007AFF          (hex)")
	print("  --line-width 5.0")
	print("  --width 1400")
	print("  --height 0                   (0 = auto)")
	print("  --padding 0.12")
	exit(1)
}

let inputURL = URL(fileURLWithPath: inputPath)
let outputURL = URL(fileURLWithPath: outputPath)

// MARK: - Minimal GPX Parser (no external dependencies)
final class GPXPointCollector: NSObject, XMLParserDelegate {
	var coordinates: [CLLocationCoordinate2D] = []

	private var currentElement = ""
	private var currentLat: Double?
	private var currentLon: Double?

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
		currentElement = elementName

		if elementName == "trkpt" || elementName == "rtept" {
			if let latStr = attributeDict["lat"], let lonStr = attributeDict["lon"],
			   let lat = Double(latStr), let lon = Double(lonStr) {
				currentLat = lat
				currentLon = lon
			}
		}
	}

	func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
		if (elementName == "trkpt" || elementName == "rtept"),
		   let lat = currentLat, let lon = currentLon {
			coordinates.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
			currentLat = nil
			currentLon = nil
		}
		currentElement = ""
	}
}

print("Parsing GPX: \(inputURL.lastPathComponent)")
guard let data = try? Data(contentsOf: inputURL) else {
	FileHandle.standardError.write(Data("Could not read GPX file\n".utf8))
	exit(1)
}

let parser = XMLParser(data: data)
let collector = GPXPointCollector()
parser.delegate = collector
parser.parse()

let coordinates = collector.coordinates
guard !coordinates.isEmpty else {
	FileHandle.standardError.write(Data("No track or route points found in GPX\n".utf8))
	exit(1)
}
print("Found \(coordinates.count) points")

// MARK: - Region calculation with padding
func regionThatFits(_ coords: [CLLocationCoordinate2D], padding: Double) -> MKCoordinateRegion {
	let lats = coords.map { $0.latitude }
	let lons = coords.map { $0.longitude }
	let minLat = lats.min()!, maxLat = lats.max()!
	let minLon = lons.min()!, maxLon = lons.max()!

	if maxLon - minLon > 180 {
		print("⚠️  Route may cross the antimeridian — bounding box may be off")
	}

	let center = CLLocationCoordinate2D(
		latitude: (minLat + maxLat) / 2,
		longitude: (minLon + maxLon) / 2
	)

	let latDelta = max((maxLat - minLat) * (1 + padding), 0.001)
	let lonDelta = max((maxLon - minLon) * (1 + padding), 0.001)

	return MKCoordinateRegion(
		center: center,
		span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
	)
}

let region = regionThatFits(coordinates, padding: options.padding)

// Auto aspect ratio if height not specified
func computeSize(region: MKCoordinateRegion, width: Int, height: Int) -> CGSize {
	if height > 0 { return CGSize(width: width, height: height) }
	let aspect = region.span.longitudeDelta / region.span.latitudeDelta
	let corrected = aspect * cos(region.center.latitude * .pi / 180)
	let h = Double(width) / max(corrected, 0.6)
	return CGSize(width: width, height: Int(h))
}

let size = computeSize(region: region, width: options.width, height: options.height)

// MARK: - Map snapshot + polyline drawing
let mapType: MKMapType = {
	switch options.mapType.lowercased() {
	case "satellite": return .satellite
	case "hybrid":    return .hybrid
	case "muted":     return .mutedStandard
	default:          return .standard
	}
}()

let snapshotOptions = MKMapSnapshotter.Options()
snapshotOptions.region = region
snapshotOptions.size = size
snapshotOptions.mapType = mapType
snapshotOptions.showsBuildings = true

print("Generating Apple Maps snapshot (\(Int(size.width))×\(Int(size.height)))...")

let snapshotter = MKMapSnapshotter(options: snapshotOptions)
let semaphore = DispatchSemaphore(value: 0)

snapshotter.start { snapshot, error in
	defer { semaphore.signal() }

	if let error = error {
		FileHandle.standardError.write(Data("Snapshot failed: \(error.localizedDescription)\n".utf8))
		return
	}
	guard let snapshot = snapshot else { return }

	// Draw route on top of the map image
	let finalImage = NSImage(size: size)
	finalImage.lockFocus()

	// Base map
	snapshot.image.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)

	if let ctx = NSGraphicsContext.current?.cgContext {
		// Route styling
		let color = colorFromHex(options.lineColor)
		ctx.setStrokeColor(color.cgColor)
		ctx.setLineWidth(options.lineWidth)
		ctx.setLineJoin(.round)
		ctx.setLineCap(.round)
		ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: NSColor.black.withAlphaComponent(0.35).cgColor)

		ctx.beginPath()
		var first = true
		for coord in coordinates {
			let pt = snapshot.point(for: coord)
			if first {
				ctx.move(to: pt)
				first = false
			} else {
				ctx.addLine(to: pt)
			}
		}
		ctx.strokePath()
	}

	finalImage.unlockFocus()

	// Save as PNG, or JPEG when the output path ends in .jpg/.jpeg
	if let tiff = finalImage.tiffRepresentation,
	   let bitmap = NSBitmapImageRep(data: tiff),
	   let pngData = (["jpg", "jpeg"].contains(outputURL.pathExtension.lowercased()) ? bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) : bitmap.representation(using: .png, properties: [:])) {
		do {
			try pngData.write(to: outputURL)
			print("✅ Exported: \(outputURL.path)")
		} catch {
			FileHandle.standardError.write(Data("Failed to write image: \(error)\n".utf8))
		}
	}
}

if semaphore.wait(timeout: .now() + 60) == .timedOut {
	FileHandle.standardError.write(Data("Snapshot timed out (no network for Apple Maps?)\n".utf8))
	exit(1)
}

// MARK: - Helper
func colorFromHex(_ hex: String) -> NSColor {
	let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
	var rgb: UInt64 = 0
	Scanner(string: sanitized).scanHexInt64(&rgb)
	let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
	let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
	let b = CGFloat(rgb & 0x0000FF) / 255.0
	return NSColor(red: r, green: g, blue: b, alpha: 1.0)
}