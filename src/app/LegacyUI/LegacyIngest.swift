// SPDX-License-Identifier: GPL-2.0-or-later
//
// APK ingestion for the iOS 12.2 shell.
//
// Upstream's pipeline lives in TranslationLayerStore, which is iOS 15+ (Combine,
// the main actor) even though the work itself is C behind husk_tl_*. The shell
// therefore carries its own copy of the same steps, writing the same files into
// the same folder layout: exactly what LegacyStore already does for reading
// (LegacyStore.loadApp mirrors TranslationLayerStore.load for the same reason).
// That keeps the iOS 15 path untouched and gives 12.2 the same library entries,
// labels and icons.
//
// One deliberate difference: an adaptive icon is an XML description that
// upstream composes into a PNG, and that composition needs the resource table
// walker in ApkMetadata's icon path. Here an XML icon is skipped and every app
// that ships one also ships the flat bitmap older launchers use, so the fallback
// is the bitmap rather than nothing.

import Foundation
import UIKit

enum LegacyIngest {
    /// Where the scan version is recorded. Must match
    /// TranslationLayerStore.scanVersion: a folder written here has to look
    /// freshly scanned to the iOS 15 store if the same library is ever opened on
    /// a newer system, or it would be re-scanned for nothing.
    private static let scanVersion = 8

    /// Copy APKs (or bundle files) in, describe them, and return the new app's
    /// folder name. Synthesised work: nothing here blocks a caller's thread
    /// beyond the file copy, so callers run it off the main queue.
    static func copy(_ urls: [URL]) -> String? {
        let fm = FileManager.default
        let root = TranslationLayer.root
        guard !urls.isEmpty else { return nil }

        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for url in urls {
                // Security-scoped: the picker's URL is only readable inside this pair.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                if BundleUnpacker.extensions.contains(url.pathExtension.lowercased()) {
                    let names = try BundleUnpacker.unpack(url, into: dir)
                    HuskLog.log("tl", "unpacked \(url.lastPathComponent): \(names.joined(separator: ", "))")
                    continue
                }

                var name = url.lastPathComponent
                // An expansion file goes to obb/ under its own name: the runtime
                // finds it there when the game asks for Android/obb/<package>/<name>.
                let isOBB = name.lowercased().hasSuffix(".obb")
                if !isOBB && !name.lowercased().hasSuffix(".apk") { name += ".apk" }
                let dest: URL
                if isOBB {
                    let obb = dir.appendingPathComponent("obb", isDirectory: true)
                    try fm.createDirectory(at: obb, withIntermediateDirectories: true)
                    dest = obb.appendingPathComponent(name)
                } else {
                    dest = dir.appendingPathComponent(name)
                }
                // Coordinated, so a file that lives in iCloud and is not on the
                // phone yet is downloaded first.
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                    do { try fm.copyItem(at: readable, to: dest) } catch { copyError = error }
                }
                if let failure = coordinationError ?? copyError { throw failure }
            }
        } catch {
            try? fm.removeItem(at: dir)
            HuskLog.log("tl", "FAILED to add: \(error.localizedDescription)")
            return nil
        }

        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".apk") }
        guard !names.isEmpty else {
            try? fm.removeItem(at: dir)
            HuskLog.log("tl", "nothing to install: no APK inside what was picked")
            return nil
        }
        // Same order the runtime takes them in: the app first, then what it
        // cannot run without, then the splits it does not need.
        let apks = names
            .sorted { a, b in
                let ra = BundleUnpacker.rank(a, siblings: names)
                let rb = BundleUnpacker.rank(b, siblings: names)
                return ra != rb ? ra < rb : a < b
            }
            .map { dir.appendingPathComponent($0).path }

        describe(apks, into: dir)
        let json = scan(apks)
        try? Data(json.utf8).write(to: dir.appendingPathComponent("report.json"))
        try? "\(scanVersion)".write(to: dir.appendingPathComponent("scan-version.txt"),
                                     atomically: true, encoding: .utf8)
        HuskLog.log("tl", "installed \(dir.lastPathComponent) (\(names.count) apk)")

        return dir.lastPathComponent
    }

    // MARK: metadata

    /// Label, package name and icon, written into the app's folder.
    private static func describe(_ apks: [String], into dir: URL) {
        // The base APK carries the label and the icon; a config split's manifest
        // names neither. The base is usually called base.apk, and otherwise
        // usually the biggest.
        func size(_ path: String) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?
                .intValue ?? 0
        }
        let ordered = apks.sorted { a, b in
            let aBase = (a as NSString).lastPathComponent == "base.apk"
            let bBase = (b as NSString).lastPathComponent == "base.apk"
            return aBase != bBase ? aBase : size(a) > size(b)
        }

        for apk in ordered {
            guard let manifest = entry(apk, "AndroidManifest.xml", limit: 8 << 20),
                  let arsc = entry(apk, "resources.arsc", limit: 64 << 20) else { continue }
            let info = ApkMetadata.read(manifest: manifest, resources: arsc)
            guard info.label != nil || info.iconEntry != nil else { continue }

            if let package = ApkMetadata.packageName(manifest) {
                try? package.write(to: dir.appendingPathComponent("package.txt"),
                                   atomically: true, encoding: .utf8)
            }
            if let label = info.label {
                try? label.write(to: dir.appendingPathComponent("label.txt"),
                                 atomically: true, encoding: .utf8)
            }
            // Stored as PNG whatever it was, so the icon view needs no WebP.
            // An adaptive icon is XML and is skipped (see the file header).
            if let iconEntry = info.iconEntry, !iconEntry.hasSuffix(".xml"),
               let data = entry(apk, iconEntry, limit: 16 << 20),
               let png = UIImage(data: data)?.pngData() {
                try? png.write(to: dir.appendingPathComponent("icon.png"))
            }
            HuskLog.log("tl", "\((apk as NSString).lastPathComponent): "
                            + "label=\(info.label ?? "?") icon=\(info.iconEntry ?? "-")")
        }
    }

    /// One entry out of an APK (a zip), by name.
    private static func entry(_ apk: String, _ name: String, limit: Int) -> Data? {
        var length = 0
        guard let bytes = husk_tl_read_entry(apk, name, limit, &length) else { return nil }
        defer { husk_tl_free(bytes) }
        return Data(bytes: bytes, count: length)
    }

    /// The report `LegacyStore` displays: the same JSON the iOS 15 store writes.
    private static func scan(_ paths: [String]) -> String {
        let owned = paths.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        let pointers = owned.map { UnsafePointer<CChar>($0) }
        let raw = pointers.withUnsafeBufferPointer {
            husk_tl_scan($0.baseAddress, Int32($0.count))
        }
        defer { husk_tl_free(raw) }
        return raw.map { String(cString: $0) } ?? "{}"
    }
}
