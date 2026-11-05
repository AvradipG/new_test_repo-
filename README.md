# Tidy Atlas (iPhone)

A private organizer for home and office, built for an ADHD brain. It reuses the Crystal Bowl Scanner's
setup (SwiftUI app generated with XcodeGen, built, signed and sent to TestFlight by GitHub Actions; no Mac needed).

- **Spaces**: places (Home, Office…) → rooms or segments ("desk corner") → storage spots (shelf, drawer, bin…).
- **Scan**: camera photos, photos from the library, or a walkthrough video (the sharpest frames are picked on the
  phone). Claude names and tags each thing, flags what's out of place, says where it should live, proposes storage
  spots and guesses the room size. Items seen again in overlapping photos are updated, not duplicated.
- **LiDAR room scan** (iPhone Pro with LiDAR): Apple RoomPlan measures the room; walls appear on the map and
  furniture (storage, bed, table, sofa…) becomes storage spots. The scan opens life-size in AR (Quick Look).
- **Rough 3D map** (SceneKit): dollhouse room, storage boxes, coloured dots (to sort / out of place / put away) and
  arcs to where each thing goes. Precision is deliberately not the goal.
- **Coaching**: Claude plans 1–5 minute steps grouped into carry trips, tuned to energy and minutes. Focus mode shows
  one step with a timer, Done / Skip / "Too big?" (Claude splits it), cheers, a daily streak and an optional daily nudge.
- **Find**: search everything, or ask Claude "where is my passport?".
- **AR organizer** (1.1): a live AR view of the room. "Tag & measure what I see" sends one frame to Claude and uses
  the LiDAR depth of the same instant to measure each thing and pin its label (name, size, where it goes) on the real
  object. Storage spots are placed at the crosshair; arcs in the room show where to carry things. The ARKit world map
  is saved per room, so the labels reappear in the same places next time.
- **Automatic sizes** (1.1): LiDAR-measured in AR with Crystal Bowl's ScanMath (`uprightSize`: height and smallest
  footprint rectangle of the thing's point cloud); otherwise Claude's estimate from the photo (shown with ≈).
- **Floor plan** (1.1): top-down map per room (walls from the LiDAR scan, spots, numbered things, arrows, legend).
- **Google Drive backup** (1.1, from Crystal Bowl): after every change and when the app opens or closes, My Drive ›
  Tidy Atlas gets `inventory.json` (the whole database, schema `tidy-atlas.inventory/1`), `inventory.csv`, and per
  room `room.json`, `floor-plan.png`, `room-scan.usdz`, `things/` thumbnails and, on Wi-Fi, `photos/`. Uploads run in
  iOS's background session (app closed, phone locked). Two routes, as in Crystal Bowl: a folder in the Google Drive
  app (no sign-in) or direct Google sign-in.

## Reused from the Crystal Bowl Scanner 1.10
`Packages/ScanMath` (unchanged, with its tests), `TidyAtlas/Drive.swift`, `DriveBackground.swift`, the folder copy
in `DriveSync.swift`, the Drive screens in `DriveViews.swift`, `CameraAssist.swift`, and the update banner/problem
report in `Updates.swift`.
- **Private**: all data stays in the iPhone's database (SwiftData) and Files › On My iPhone › Tidy Atlas. Photos and
  the item list go to Anthropic's API only when you scan, plan or ask, using your own key stored in the Keychain.
  Export the inventory as CSV from Settings.

## Claude
`TidyAtlas/ClaudeService.swift` calls the Messages API over HTTPS (Swift has no official SDK) with model
`claude-opus-5-5`, structured JSON output (`output_config.format`), and server-side refusal fallbacks
(`fallbacks: "default"`, beta `server-side-fallback-2026-07-01`). Request/response handling, prompts and schemas live
in `Packages/TidyCore` and are unit-tested.

## Build and TestFlight
Every push to branch `tidy-atlas-ios` runs `.github/workflows/tidy-atlas.yml` on a GitHub macOS runner: TidyCore
tests, XcodeGen, unsigned build, IPA + `version.json` on branch `ipa-tidy-atlas`, then signed upload to TestFlight.
It uses the same repository secrets as Crystal Bowl (`ASC_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `APPLE_TEAM_ID`).

One-time setup:
1. App Store Connect › Apps › **+** › New App: iOS, name "Tidy Atlas", bundle ID `com.avradip.tidyatlas`
   (the first workflow run registers it), SKU `tidyatlas`.
2. Re-run the workflow (or push). TestFlight › Internal Testing › **+**: a group with automatic distribution, add yourself.
3. On the iPhone: TestFlight › Tidy Atlas › Install, and turn on Automatic Updates.
4. In the app: Settings › Claude API key.
