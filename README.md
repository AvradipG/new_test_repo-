# Crystal Bowl Scanner (iPhone)

Scans a rock sample in 3D with an iPhone that has LiDAR (12 Pro or later Pro models, iOS 17+).

- Guided capture with Apple Object Capture: the dial around the rock fills in as each angle is covered.
- Second pass after flipping the rock, so the underside is captured.
- Model built on the phone (USDZ with colour).
- Measurements: principal axes a × b × c in mm and enclosed volume in cm³.
- Cross-sections: after every build the model is cut across its long axis every 2 mm. Each slice is a scaled PNG
  (10 mm scale bar, depth, area, perimeter, equivalent diameter), plus a contact sheet and a CSV. Any axis
  (a, b, c) and spacing (0.5–5 mm) can be cut on demand. Slices show the outer outline only; a surface scan
  cannot see inside the rock.
- Storage: photos (a few hundred MB) are deleted once the model is built unless "Keep photos" is on; a finished
  scan takes roughly 10–40 MB.
- Exports: USDZ, OBJ, PLY, STL (metres) and a text report, through the share sheet (Files, Drive, AirDrop, mail).
- Scans are also visible in the Files app under **On My iPhone › Crystal Bowl**.
- Google Drive: finished scans upload automatically to **My Drive › Crystal Bowl Scans** (one folder per scan with
  `manifest.json`, `model/`, `sections/`, optional `images/`, plus `index.json` listing all scans). Needs a Google Cloud
  iOS OAuth client ID for `com.avradip.crystalbowl` in `project.yml` (`CB_GOOGLE_CLIENT_ID`).

## How it is built

No Mac needed. Every push to the `crystal-bowl-ios` branch runs `.github/workflows/ios.yml` on a GitHub macOS runner:

1. `swift test` for the measurement maths in `Packages/ScanMath`.
2. `xcodegen` generates the Xcode project from `project.yml`.
3. `xcodebuild` builds an unsigned Release app for iPhone and packages `CrystalBowlScanner.ipa`.

Download the IPA from the run's **Artifacts** section.

## TestFlight (paid Apple Developer account)

The workflow signs the app and uploads it to App Store Connect when these repository secrets exist
(Settings › Secrets and variables › Actions):

| Secret | Where to find it |
| --- | --- |
| `APPLE_TEAM_ID` | developer.apple.com › Account › Membership details › Team ID |
| `ASC_KEY_ID` | App Store Connect › Users and Access › Integrations › App Store Connect API › Team Keys (Admin access) |
| `ASC_ISSUER_ID` | Same page, above the key list |
| `ASC_KEY_P8` | Full text of the downloaded `AuthKey_XXXX.p8` file |

The app record must exist first: App Store Connect › Apps › + › New App, bundle ID `com.avradip.crystalbowl`.
Each push then uploads a new build; install it from the TestFlight app on the iPhone.

## Installing on an iPhone from Windows (Sideloadly)

1. On the PC, install **iTunes** and **iCloud** from apple.com (the website versions, not the Microsoft Store ones), then **Sideloadly** from sideloadly.io.
2. Plug the iPhone in with a cable, unlock it and tap **Trust**.
3. Open Sideloadly, drag `CrystalBowlScanner.ipa` in, enter your Apple ID and click **Start**.
4. On the iPhone: **Settings › Privacy & Security › Developer Mode** → on, restart, confirm.
5. On the iPhone: **Settings › General › VPN & Device Management** → your Apple ID → **Trust**.
6. Open **Crystal Bowl** and allow the camera.

With a free Apple ID the app must be re-installed every 7 days (repeat step 3); with a paid developer Apple ID it lasts a year.

## Limits

- Scale comes from the phone's LiDAR. Check one axis against calipers before relying on it.
- Volume is exact only for a closed mesh; the app says when the mesh has gaps.
- Shiny, very dark or translucent rocks scan poorly; dull the surface or improve lighting.
