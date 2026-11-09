# Tidy Atlas: notes for Claude

Private iPhone organizer (SwiftUI, SwiftData, iOS 17+) for an owner with ADHD: scan rooms and things with photos,
walkthrough video or LiDAR (RoomPlan), Claude tags items and suggests homes, a rough 3D map, tiny-step plans and a
focus mode. Same owner and same delivery loop as the Crystal Bowl Scanner (branch `crystal-bowl-ios` of this repo):
plain-language requests, each ending with a push that reaches the phone through TestFlight.

## Layout
- `TidyAtlas/`: app. `Models.swift` (SwiftData: Place → Room → Zone/Item/TidyStep/Capture; links between items and
  zones are UUIDs), `Organizer.swift` (scan pipeline, merge into the database, LiDAR scan, plan, focus, ask),
  `ClaudeService.swift` (Keychain key, HTTPS call), `MediaTools.swift` (downscale, video frames, camera),
  `RoomScanner.swift` (RoomPlan), `Room3DView.swift` (SceneKit map), `HomeView`, `RoomView` (+ editors),
  `FocusView`, `FindView`, `SettingsView`, `Updates.swift` (update banner, problem report), `Theme.swift`.
- `Packages/TidyCore/`: platform-independent logic with XCTest tests: prompts and JSON schemas, Claude request body
  and response parsing, `MergePlanner` (resolves "i3"/"z2"/"new-1" refs, clamps, de-duplicates), streaks, thumbnail
  crop maths, RoomPlan layout maths, `DepthMeasure` (LiDAR depth in a photo box → AR-world points → sizes).
- `Packages/ScanMath/`: copied unchanged from Crystal Bowl 1.10 (keep it in step with `crystal-bowl-ios` when that
  package changes there; its tests run in this workflow too).
- AR: `ARRoomView.swift` (ARKit session, depth snapshot, labels/arcs via `SceneShapes.swift`, world map per room in
  Documents/WorldMaps; depth per photo in Documents/Depth via `DepthStore`).
- Whole-place scan: `HouseScanner.swift` (one ARSession kept running across rooms with
  `RoomCaptureView(frame:arSession:)` and `stop(pauseARSession: false)`, `RoomBuilder` per room,
  `StructureBuilder` to merge; geotag = GPS fix + compass bearing of the scan's −Z axis at the start), applied by
  `Organizer.applyHouseScan`. Rooms of one scan share a frame: `RoomLayout.originX/originZ` place them in it.
  `Place.locate` / `Room.locate` turn scan positions into GPS with `GeoMath` (TidyCore, tested).
  `LocationService.swift` (GPS, compass, reverse geocoding, never prompts except when a scan starts or in Settings),
  `PlaceView.swift` (map, whole-place 3D, `PlacePlan` floor plan, AR Quick Look of the place USDZ).
- Design studio: `DesignStudio.swift` (designs per room = `DesignVariant` with JSON `[DesignPiece]`; draggable
  `PlanEditor`, `PieceInspector`, `CatalogSheet`, Vastu/Feng Shui/walkway overlays), `Design3D.swift` (procedural
  SceneKit furniture, USDZ for AR, picture prompt), `DesignChat.swift` (`Organizer.designChat`: room + designs +
  conversation → `DesignAI.Answer`; proposals become new designs). Pure logic in TidyCore `Design.swift`
  (`DesignPiece`, `FurnitureCatalog`, `DesignGeometry`, `SpaceWisdom`) and `DesignAI.swift`; image editing for
  "how it will look" in `OpenAIImageWire` (ChatGPT only, model `gpt-image-1` unless set in UserDefaults
  `ai.openai.imageModel`).
- Corrections and history (1.5): `Room.placement` (scan origin, or hand correction `mapX/mapZ/mapRotationDeg`) via
  TidyCore `RoomPlacement`; `PlaceMapEditor.swift` (drag/turn rooms, put rooms on the map, `RoomNameSheet`). Each
  scan is a `ScanRecord` (place USDZ + every room's raw `CapturedRoom` JSON, never deleted); adding/rescanning rooms
  relocalizes to `Place.worldMapFile` in `HouseScanModel.begin()` (falls back to hand placement);
  `OrganizerPlaces.swift` (restore, re-read saved scans, rebuild place model, room-name suggestions, kitchen
  organiser, shopping list). Raw scans are saved by `applyRoomScan(keepRaw:)`.
- Plans and designs per AI: `TidyPlan` records (provider, version, parent, feedback; steps carry `planID`;
  `Room.activePlanID` picks the shown plan), `DesignVariant.provider/parentID/version`; `AIService.call(only:)` pins
  a provider; `AIProviderPicker` in the UI.
- Nested storage: `Zone.parentID` (TidyCore `StorageTree` for paths, children, loop-safe moves), `StorageTreeView.swift`,
  "Photo inside this spot" = `Organizer.scan(inside:)`. Kitchen: `KitchenView.swift`, `Zone.kitchenZone`,
  `Item.expiresAt`, TidyCore `Kitchen`. Shopping: `ShoppingItem`, `ShoppingView` (tab).
- Drive: `Drive.swift`, `DriveBackground.swift` (from Crystal Bowl), `DriveSync.swift` (`TidyPackage` export written
  to Documents/DriveMirror only when content changes; upload state in drive-state.json / drive-folder-state.json),
  `DriveViews.swift`. `FloorPlan.swift` draws the plan PNG.
- `project.yml`: XcodeGen spec (bundle ID `com.avradip.tidyatlas`); the Xcode project is generated in CI.
- `ReleaseNotes.md`: newest section first; its bullets show in the app's update banner.

## Shipping a change
1. Change the code; add/adjust a TidyCore test when the logic there changes.
2. Add a user-facing bullet under a new top section in `ReleaseNotes.md`; bump `MARKETING_VERSION` for visible changes.
3. Commit and push to branch `tidy-atlas-ios` of `AvradipG/new_test_repo-` (never `main`, never `crystal-bowl-ios`).
4. `.github/workflows/tidy-atlas.yml` tests, builds, publishes the IPA to `ipa-tidy-atlas`, and uploads to TestFlight.
   It shares the `ios-build` concurrency group with Crystal Bowl, so builds queue.
5. Compiler errors appear as annotations: `gh api repos/AvradipG/new_test_repo-/check-runs/<job id>/annotations`.
   A red run means the owner gets nothing: fix and push again before reporting back.
6. Done means the run's notice "Build N uploaded to App Store Connect".

## AI keys and sign-ins (must survive every update)
- Claude and ChatGPT keys live in the Keychain via `KeyStore` (service `com.avradip.tidyatlas.keys`, accounts
  `claude` / `chatgpt`, synchronizable with iCloud Keychain). The Google refresh token and email use `Keychain` in
  `Drive.swift` (service `TidyAtlas`, synchronizable). The Drive folder bookmark, AI preference and ChatGPT model live
  in UserDefaults. Never rename these services, accounts or UserDefaults keys, never move keys into files, SwiftData
  or the build (the IPA is public on the `ipa-tidy-atlas` branch), and keep the bundle ID: any of these would make
  the owner re-enter keys after an update.
- `AIService` (`AIService.swift`) routes every call by `AIPreference`, falling back to the other service on
  rate limits, outages, refusals and unreadable answers. OpenAI uses the Responses API with strict JSON schema
  (`OpenAIWire` in TidyCore); the model is the one typed in Settings, or the newest full GPT model the key can use.

## Data compatibility
SwiftData migrates added properties automatically when they have default values. Never rename or remove stored
properties; add new ones with defaults.
