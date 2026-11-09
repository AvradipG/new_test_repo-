import Foundation
import TidyCore
import SwiftData
import UIKit

/// What goes to Google Drive › Tidy Atlas: the whole database as JSON and CSV, and for every room a folder with
/// room.json, the floor plan, the LiDAR room scan, the thing thumbnails and (on Wi-Fi) the photos.
/// Generated files are only rewritten when their content changes, so unchanged files are never uploaded twice.
enum TidyPackage {
    static let rootFolder = "Tidy Atlas"
    static let mirror: URL = {
        let url = Storage.docs.appendingPathComponent("DriveMirror", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(60))
    }

    static func roomFolder(_ room: Room) -> String {
        "\(safe(room.place?.name ?? "Place")) - \(safe(room.name)) (\(room.uid.uuidString.prefix(6)))"
    }

    /// Writes `data` to the mirror only if it differs from what is there.
    @discardableResult
    static func write(_ data: Data, _ rel: String) -> URL {
        let url = mirror.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? Data(contentsOf: url)) != data { try? data.write(to: url, options: .atomic) }
        return url
    }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    static func f8601(_ d: Date?) -> Any { d.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull() }

    static func geo(_ g: GeoPoint?, rough: Bool) -> Any {
        guard let g else { return NSNull() }
        return ["latitude": (g.latitude * 1e7).rounded() / 1e7, "longitude": (g.longitude * 1e7).rounded() / 1e7,
                "precision": rough ? "rough (indoor GPS + compass, metres)" : "GPS fix"] as [String: Any]
    }

    static func placeFolder(_ place: Place) -> String {
        "places/\(safe(place.name)) (\(place.uid.uuidString.prefix(6)))"
    }

    /// GeoJSON of a place: its GPS point, and a rough point for every room and thing (for Google Earth, maps, GIS).
    @MainActor
    static func geoJSON(_ place: Place) -> [String: Any]? {
        guard let g = place.geo else { return nil }
        func point(_ p: GeoPoint, _ props: [String: Any]) -> [String: Any] {
            ["type": "Feature", "geometry": ["type": "Point", "coordinates": [p.longitude, p.latitude]], "properties": props]
        }
        var features: [[String: Any]] = [point(g, ["kind": "place", "name": place.name, "address": place.address ?? "",
                                                   "accuracy_m": place.geoAccuracyM ?? NSNull()])]
        for r in place.sortedRooms {
            if let rg = r.geo, r.fromHouseScan {
                features.append(point(rg, ["kind": "room", "name": r.name, "things": r.items.count, "to_sort": r.toSort.count]))
            }
            for it in r.items where r.fromHouseScan {
                if let ig = r.locate(unitX: it.posX, unitZ: it.posZ) {
                    features.append(point(ig, ["kind": "thing", "name": it.name, "room": r.name,
                                               "spot": jsonValue(r.zone(it.zoneID)?.name), "put_away": it.isSorted]))
                }
            }
        }
        return ["type": "FeatureCollection", "name": place.name, "features": features]
    }

    /// Every file of the Drive copy as (relative path, local file).
    @MainActor
    static func files(context: ModelContext, includePhotos: Bool) -> [(String, URL)] {
        let places = (try? context.fetch(FetchDescriptor<Place>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        var out: [(String, URL)] = []
        var placeList: [[String: Any]] = []
        var latest = Date.distantPast
        var allItems: [Item] = []

        for place in places {
            var roomList: [[String: Any]] = []
            for room in place.sortedRooms {
                let folder = "rooms/\(roomFolder(room))"
                let items = room.items.sorted { $0.createdAt < $1.createdAt }
                allItems += items
                for it in items { latest = max(latest, it.updatedAt) }
                for s in room.steps { if let d = s.completedAt { latest = max(latest, d) } }
                latest = max(latest, room.createdAt)
                let captureFile: [UUID: String] = Dictionary(uniqueKeysWithValues: room.captures.map { ($0.uid, $0.file) })
                func zoneName(_ id: UUID?) -> Any { jsonValue(room.zone(id)?.name) }
                let itemList: [[String: Any]] = items.map { it in
                    var e: [String: Any] = [
                        "id": it.uid.uuidString, "name": it.name, "quantity": it.quantity, "category": it.category,
                        "tags": it.tags, "notes": it.notes, "status": it.isSorted ? "put_away" : "to_sort",
                        "plan": it.actionRaw, "out_of_place": it.outOfPlace, "reason": it.reason,
                        "now_in": zoneName(it.zoneID), "should_live_in": zoneName(it.suggestedZoneID),
                        "position_in_room": ["x": it.posX, "y": it.posY, "z": it.posZ],
                        "updated_utc": f8601(it.updatedAt),
                        "location": room.fromHouseScan ? geo(room.locate(unitX: it.posX, unitZ: it.posZ), rough: true) : (NSNull() as Any),
                    ]
                    if let l = it.sizeLengthCM, let w = it.sizeWidthCM, let h = it.sizeHeightCM {
                        e["size_cm"] = ["length": l, "width": w, "height": h, "source": it.sizeSource ?? "estimate"]
                    }
                    if let t = it.thumbFile { e["thumbnail"] = "\(folder)/things/\(t)" }
                    if let c = it.captureID, let f = captureFile[c] { e["photo"] = "\(folder)/photos/\(f)" }
                    return e
                }
                let roomDict: [String: Any] = [
                    "id": room.uid.uuidString, "name": room.name, "type": room.roomType, "folder": folder,
                    "size_m": ["width": room.widthM, "depth": room.depthM, "height": room.heightM],
                    "size_source": room.sizeFromScan ? "LiDAR room scan" : "estimated from photos",
                    "clutter_score": room.clutterScore.map { $0 as Any } ?? NSNull(), "summary": room.summary,
                    "location": room.fromHouseScan ? geo(room.geo, rough: true) : (NSNull() as Any),
                    "scanned_with_whole_place": room.fromHouseScan,
                    "designs": room.sortedDesigns.map { d in
                        ["name": d.name, "style": d.style, "is_the_real_room": d.isCurrent, "rationale": d.rationale, "tips": d.tips,
                         "score_overall": d.scoreOverall.map { $0 as Any } ?? NSNull(),
                         "picture": d.renderFile.map { "\(folder)/designs/\($0)" as Any } ?? NSNull(),
                         "pieces": d.pieces.map { p in
                             ["kind": p.kind, "name": p.name, "x_m": p.x, "z_m": p.z, "y_m": p.y, "width_m": p.width, "depth_m": p.depth,
                              "height_m": p.height, "rotation_deg": p.rotationDeg, "on_wall": p.onWall, "source": p.source] as [String: Any]
                         }] as [String: Any]
                    },
                    "design_note": "Design positions are metres from the middle of the floor: x to the right, z towards the near wall; rotation clockwise seen from above.",
                    "photos": room.captures.sorted { $0.createdAt < $1.createdAt }.map { c in
                        ["file": "\(folder)/photos/\(c.file)", "taken_utc": f8601(c.createdAt),
                         "location": c.latitude.flatMap { lat in c.longitude.map { GeoPoint(latitude: lat, longitude: $0) } }
                            .map { geo($0, rough: false) } ?? NSNull()] as [String: Any]
                    },
                    "zones": room.zones.sorted { $0.createdAt < $1.createdAt }.map { z in
                        ["id": z.uid.uuidString, "name": z.name, "kind": z.kindRaw, "idea_not_set_up": z.isIdea,
                         "position_in_room": ["x": z.posX, "y": z.posY, "z": z.posZ],
                         "size_m": ["width": z.sizeW, "height": z.sizeH, "depth": z.sizeD]] as [String: Any]
                    },
                    "things": itemList,
                    "steps": room.steps.sorted { $0.sortKey < $1.sortKey }.map { s in
                        ["title": s.title, "detail": s.detail, "minutes": s.minutes, "trip": s.trip,
                         "status": s.statusRaw, "completed_utc": f8601(s.completedAt)] as [String: Any]
                    },
                ]
                roomList.append(roomDict)
                out.append(("\(folder)/room.json", write(json(roomDict), "\(folder)/room.json")))
                if let png = FloorPlan.image(for: room).pngData() {
                    out.append(("\(folder)/floor-plan.png", write(png, "\(folder)/floor-plan.png")))
                }
                if let f = room.usdzFile, FileManager.default.fileExists(atPath: Storage.roomScanURL(f).path) {
                    out.append(("\(folder)/room-scan.usdz", Storage.roomScanURL(f)))
                }
                for it in items {
                    if let t = it.thumbFile, FileManager.default.fileExists(atPath: Storage.thumbURL(t).path) {
                        out.append(("\(folder)/things/\(t)", Storage.thumbURL(t)))
                    }
                }
                for d in room.designs {
                    if let f = d.renderFile, FileManager.default.fileExists(atPath: Storage.designURL(f).path) {
                        out.append(("\(folder)/designs/\(f)", Storage.designURL(f)))
                    }
                }
                if includePhotos {
                    for c in room.captures where FileManager.default.fileExists(atPath: Storage.captureURL(c.file).path) {
                        out.append(("\(folder)/photos/\(c.file)", Storage.captureURL(c.file)))
                    }
                }
            }
            let pf = placeFolder(place)
            var placeDict: [String: Any] = ["name": place.name, "kind": place.kindRaw, "rooms": roomList,
                                            "folder": pf, "address": jsonValue(place.address),
                                            "location": geo(place.geo, rough: false),
                                            "altitude_m": place.altitude.map { $0 as Any } ?? NSNull(),
                                            "accuracy_m": place.geoAccuracyM.map { $0 as Any } ?? NSNull(),
                                            "floor_level": place.floorLevel.map { $0 as Any } ?? NSNull(),
                                            "scan_minus_z_bearing_deg": place.northBearing.map { $0 as Any } ?? NSNull(),
                                            "whole_place_scanned_utc": f8601(place.houseScannedAt)]
            if let gj = geoJSON(place) {
                out.append(("\(pf)/place.geojson", write(json(gj), "\(pf)/place.geojson")))
                placeDict["geojson"] = "\(pf)/place.geojson"
            }
            if let png = PlacePlan.image(for: place)?.pngData() {
                out.append(("\(pf)/place-plan.png", write(png, "\(pf)/place-plan.png")))
            }
            if let f = place.houseScanFile, FileManager.default.fileExists(atPath: Storage.roomScanURL(f).path) {
                out.append(("\(pf)/place-scan.usdz", Storage.roomScanURL(f)))
            }
            placeList.append(placeDict)
        }

        let inventory: [String: Any] = [
            "schema": "tidy-atlas.inventory/1",
            "about": "Everything Tidy Atlas knows: places > rooms > storage spots (zones), things and tidy steps. Positions are 0-1 inside the room (x left to right, z far wall to near, y floor to ceiling). Sizes in cm; source LiDAR = measured, estimate = Claude's guess from the photo.",
            "last_change_utc": latest == .distantPast ? (NSNull() as Any) : f8601(latest),
            "app": ["name": "Tidy Atlas (iPhone)", "version": AppInfo.version],
            "counts": ["places": places.count, "rooms": places.reduce(0) { $0 + $1.rooms.count }, "things": allItems.count,
                       "to_sort": allItems.filter { !$0.isSorted }.count],
            "places": placeList,
        ]
        out.insert(("inventory.json", write(json(inventory), "inventory.json")), at: 0)
        if let csv = InventoryExport.csvText(items: allItems) {
            out.insert(("inventory.csv", write(Data(csv.utf8), "inventory.csv")), at: 1)
        }
        out.insert(("README.txt", write(Data(readme.utf8), "README.txt")), at: 0)
        var seen = Set<String>()
        return out.filter { seen.insert($0.0).inserted }
    }

    static let readme = """
    Tidy Atlas
    ==========
    Written by the Tidy Atlas iPhone app, updated automatically.

    inventory.json   the whole database: places > rooms > storage spots, things (name, tags, where it is, where it
                     should live, size in cm, status) and tidy steps. Schema tidy-atlas.inventory/1.
    inventory.csv    the same things as a spreadsheet.
    places/<place> (<id>)/
        place.geojson    GPS point of the place and rough points for every room and thing (Google Earth, maps, GIS)
        place-plan.png   every room of the whole-place LiDAR scan in its real position, with a north arrow
        place-scan.usdz  the whole place in 3D (open on a Mac or iPhone; AR on iPhone)
    rooms/<place> - <room> (<id>)/
        room.json        that room only
        floor-plan.png   top-down map: storage spots, numbered things, dashed arrows to where they go
        room-scan.usdz   the LiDAR room scan (open on a Mac or iPhone; AR on iPhone)
        things/          a cut-out picture of every thing
        designs/         "how it will look" pictures of the room's designs (the designs themselves are in room.json)
        photos/          the photos Claude looked at (only when photo upload is on, on Wi-Fi)
    """
}

/// Upload state, stored next to the database so uploads resume after a restart.
enum DriveStateStore {
    static func url(_ name: String) -> URL { Storage.docs.appendingPathComponent(name) }
    static func load(_ name: String) -> DriveSync {
        (try? Data(contentsOf: url(name))).flatMap { try? JSONDecoder().decode(DriveSync.self, from: $0) } ?? DriveSync()
    }
    static func save(_ s: DriveSync, _ name: String) {
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url(name), options: .atomic) }
    }
    static let api = "drive-state.json"
    static let folder = "drive-folder-state.json"
}

/// Automatic upload to Google Drive, adapted from Crystal Bowl's DriveSyncModel: every file is handed to iOS's
/// background uploader, so it carries on with the app closed or the phone locked.
extension Organizer {
    static let uploadPhotosKey = "drive.uploadPhotos"
    static let folderBookmarkKey = "drive.folderBookmark"

    var uploadPhotos: Bool { UserDefaults.standard.object(forKey: Self.uploadPhotosKey) as? Bool ?? true }

    func refreshDriveAccount() {
        driveSignedIn = GoogleAuth.shared.isSignedIn
        driveEmail = GoogleAuth.shared.email
        // One place on Drive only: once signed in, the Files-folder copy stops.
        if driveSignedIn && UserDefaults.standard.data(forKey: Self.folderBookmarkKey) != nil { unlinkFolder() }
        refreshFolderLink()
        let s = DriveStateStore.load(driveSignedIn ? DriveStateStore.api : DriveStateStore.folder)
        lastDriveSync = s.lastSync
    }

    func signInToDrive() async {
        do {
            try await GoogleAuth.shared.signIn()
            refreshDriveAccount()
            await syncDrive()
        } catch {
            refreshDriveAccount()
            let text = error.localizedDescription
            if !text.lowercased().contains("cancel") { driveStatus = "Google sign-in didn't work: \(text)" }
        }
    }

    func signOutOfDrive() {
        GoogleAuth.shared.signOut()
        refreshDriveAccount()
    }

    /// Waits a few seconds so a burst of changes becomes one upload.
    func scheduleDriveSync() {
        pendingSync?.cancel()
        pendingSync = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await syncDrive()
        }
    }

    /// Uploads (or copies to the Drive folder) every file Drive doesn't have yet.
    func syncDrive() async {
        if folderLinked && !driveSignedIn {
            await syncToFolder()
            return
        }
        guard driveSignedIn, !isSyncing else { return }
        isSyncing = true
        let bg = UIApplication.shared.beginBackgroundTask(withName: "drive-upload")
        defer {
            isSyncing = false
            UIApplication.shared.endBackgroundTask(bg)
        }
        var state = DriveStateStore.load(DriveStateStore.api)
        do {
            let photos = uploadPhotos ? await NetworkState.isUnmetered() : false
            let files = TidyPackage.files(context: container.mainContext, includePhotos: photos)
            let running = await DriveBackground.shared.inFlight()
            let client = DriveClient()
            let root = try await client.folder(named: TidyPackage.rootFolder, in: "root")
            if state.folderID != root {
                state = DriveSync()
                state.folderID = root
            }
            var folders = state.folders ?? [:]
            folders[""] = root
            func folder(for rel: String) async throws -> String {
                let dir = (rel as NSString).deletingLastPathComponent
                if let id = folders[dir] { return id }
                let parent = try await folder(for: dir)
                let id = try await client.folder(named: (dir as NSString).lastPathComponent, in: parent)
                folders[dir] = id
                return id
            }
            let todo = files.filter { rel, url in
                !running.contains(rel) && (state.files[rel].map { Self.changed(url, $0) } ?? true)
            }
            for (n, (rel, url)) in todo.enumerated() {
                driveStatus = "Handing files to iOS for upload: \(n + 1) of \(todo.count)…"
                let a = try FileManager.default.attributesOfItem(atPath: url.path)
                let item = DriveBackground.Item(rel: rel, size: (a[.size] as? NSNumber)?.int64Value ?? 0,
                                                modified: a[.modificationDate] as? Date ?? Date())
                let parent = try await folder(for: rel)
                let sessionURL: URL
                if let existing = state.files[rel]?.id,
                   let u = try? await client.startUpload(url, name: url.lastPathComponent, parent: parent, existingID: existing) {
                    sessionURL = u
                } else {
                    sessionURL = try await client.startUpload(url, name: url.lastPathComponent, parent: parent, existingID: nil)
                }
                DriveBackground.shared.submit(item, to: sessionURL, file: url, mime: DriveClient.mimeType(for: url.pathExtension))
                state.folders = folders
                DriveStateStore.save(state, DriveStateStore.api)
            }
            state.folders = folders
            state.photos = photos
            DriveStateStore.save(state, DriveStateStore.api)
            pendingUploads = todo.count + running.count
            await finishDriveUpload()
        } catch {
            driveStatus = "Upload paused: \(error.localizedDescription). It carries on by itself when the phone is online."
            AppDelegate.scheduleUploadTask()
        }
    }

    static func changed(_ url: URL, _ rec: DriveFileRecord) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let mod = a[.modificationDate] as? Date ?? .distantPast
        return size != rec.size || abs(mod.timeIntervalSince(rec.modified)) > 1
    }

    /// Called (also with the app in the background) each time iOS finishes uploading one file.
    func backgroundUploadFinished(_ item: DriveBackground.Item, fileID: String?) {
        var state = DriveStateStore.load(DriveStateStore.api)
        if let fileID {
            state.files[item.rel] = DriveFileRecord(id: fileID, size: item.size, modified: item.modified)
            DriveStateStore.save(state, DriveStateStore.api)
        } else {
            AppDelegate.scheduleUploadTask() // retried later; nothing is lost
        }
        pendingUploads = max(0, pendingUploads - 1)
        driveStatus = pendingUploads > 0
            ? "Uploading \(pendingUploads) file\(pendingUploads == 1 ? "" : "s"). It carries on in the background, also with the phone locked."
            : nil
    }

    /// Marks the upload complete once iOS has nothing left in flight.
    func finishDriveUpload() async {
        let running = await DriveBackground.shared.inFlight()
        if running.isEmpty {
            var state = DriveStateStore.load(DriveStateStore.api)
            state.complete = true
            state.lastSync = Date()
            DriveStateStore.save(state, DriveStateStore.api)
            lastDriveSync = state.lastSync
            pendingUploads = 0
            driveStatus = nil
        } else {
            pendingUploads = running.count
            driveStatus = "Uploading \(running.count) file\(running.count == 1 ? "" : "s"). It carries on in the background, also with the phone locked."
        }
    }

    // MARK: Files-app folder (the Google Drive app uploads it; no Google sign-in in this app)

    func refreshFolderLink() {
        if let url = Self.resolveFolder() {
            folderLinked = true
            folderName = url.lastPathComponent
        } else {
            folderLinked = false
            folderName = nil
        }
    }

    static func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: folderBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: folderBookmarkKey)
            }
        }
        return url
    }

    func linkFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.folderBookmarkKey)
            DriveStateStore.save(DriveSync(), DriveStateStore.folder) // a new folder: copy everything again
            refreshFolderLink()
            Task { await syncToFolder() }
        } catch {
            driveStatus = "Couldn't keep access to that folder: \(error.localizedDescription)"
        }
    }

    func unlinkFolder() {
        UserDefaults.standard.removeObject(forKey: Self.folderBookmarkKey)
        refreshFolderLink()
    }

    func syncToFolder() async {
        guard let root = Self.resolveFolder(), !isSyncing else { return }
        isSyncing = true
        let bg = UIApplication.shared.beginBackgroundTask(withName: "drive-folder-copy")
        defer {
            isSyncing = false
            UIApplication.shared.endBackgroundTask(bg)
        }
        var state = DriveStateStore.load(DriveStateStore.folder)
        let photos = uploadPhotos ? await NetworkState.isUnmetered() : false
        let files = TidyPackage.files(context: container.mainContext, includePhotos: photos)
        let todo = files.filter { rel, url in state.files[rel].map { Self.changed(url, $0) } ?? true }
        guard !todo.isEmpty else {
            driveStatus = nil
            return
        }
        driveStatus = "Copying \(todo.count) file\(todo.count == 1 ? "" : "s") to the Drive folder…"
        let copied: Result<[String: DriveFileRecord], Error> = await Task.detached {
            do {
                var done: [String: DriveFileRecord] = [:]
                try FolderCopy.withAccess(root) {
                    for (rel, url) in todo {
                        try FolderCopy.copy(url, to: root.appendingPathComponent(rel))
                        done[rel] = FolderCopy.record(url)
                    }
                }
                return .success(done)
            } catch {
                return .failure(error)
            }
        }.value
        switch copied {
        case let .failure(error):
            driveStatus = "Copy paused: \(error.localizedDescription). It retries when you next open the app."
        case let .success(done):
            state.files.merge(done) { _, new in new }
            state.complete = true
            state.lastSync = Date()
            DriveStateStore.save(state, DriveStateStore.folder)
            lastDriveSync = state.lastSync
            driveStatus = nil
        }
    }
}

/// Copied from Crystal Bowl's FolderSync: coordinated writes into a folder of the Google Drive app.
enum FolderCopy {
    static func withAccess(_ root: URL, _ body: () throws -> Void) throws {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        try body()
    }

    static func copy(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(writingItemAt: dst, options: .forReplacing, error: &coordinationError) { url in
            do {
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                try fm.copyItem(at: src, to: url)
            } catch {
                copyError = error
            }
        }
        if let e = coordinationError ?? copyError { throw e }
    }

    static func record(_ url: URL) -> DriveFileRecord {
        let a = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        return DriveFileRecord(id: "", size: (a[.size] as? NSNumber)?.int64Value ?? 0, modified: a[.modificationDate] as? Date ?? Date())
    }
}
