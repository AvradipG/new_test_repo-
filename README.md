# Crystal Bowl Scanner (iPhone)

Scans a rock sample in 3D with an iPhone that has LiDAR (12 Pro or later Pro models, iOS 17+).

- Guided capture with Apple Object Capture: the dial around the rock fills in as each angle is covered.
- Second pass after flipping the rock, so the underside is captured.
- Model built on the phone (USDZ with colour).
- Measurements: principal axes a × b × c in mm and enclosed volume in cm³.
- Exports: USDZ, OBJ, PLY, STL (metres) and a text report, through the share sheet (Files, Drive, AirDrop, mail).
- Scans are also visible in the Files app under **On My iPhone › Crystal Bowl**.

## How it is built

No Mac needed. Every push to the `crystal-bowl-ios` branch runs `.github/workflows/ios.yml` on a GitHub macOS runner:

1. `swift test` for the measurement maths in `Packages/ScanMath`.
2. `xcodegen` generates the Xcode project from `project.yml`.
3. `xcodebuild` builds an unsigned Release app for iPhone and packages `CrystalBowlScanner.ipa`.

Download the IPA from the run's **Artifacts** section.

## Installing on an iPhone from Windows (free Apple ID)

1. On the PC, install **iTunes** and **iCloud** from apple.com (the website versions, not the Microsoft Store ones), then **Sideloadly** from sideloadly.io.
2. Plug the iPhone in with a cable, unlock it and tap **Trust**.
3. Open Sideloadly, drag `CrystalBowlScanner.ipa` in, enter your Apple ID and click **Start**.
4. On the iPhone: **Settings › Privacy & Security › Developer Mode** → on, restart, confirm.
5. On the iPhone: **Settings › General › VPN & Device Management** → your Apple ID → **Trust**.
6. Open **Crystal Bowl** and allow the camera.

With a free Apple ID the app must be re-installed every 7 days (repeat step 3). A paid Apple Developer account removes that limit and allows TestFlight for other users.

## Limits

- Scale comes from the phone's LiDAR. Check one axis against calipers before relying on it.
- Volume is exact only for a closed mesh; the app says when the mesh has gaps.
- Shiny, very dark or translucent rocks scan poorly; dull the surface or improve lighting.
