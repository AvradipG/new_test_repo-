# Crystal Bowl Scanner: notes for Claude

iPhone app (SwiftUI, iOS 17+, LiDAR) that scans a rock sample of up to about 10 cm with Apple Object Capture,
builds the model on the phone, measures it and cuts cross-sections. The owner is a digital-rock geoscientist,
new to app development. The owner asks for fixes and improvements often and in plain words ("the button is too
small", "make the slices clearer"); each request should end with a push that reaches their phone through TestFlight.
No Mac is needed for that: GitHub builds, signs and uploads in the cloud. A MacBook exists but is optional.

## Layout
- `CrystalBowl/`: app code. `AppModel.swift` (capture and reconstruction flow), `Views.swift` (all screens),
  `CrossSections.swift` (slice PNG/CSV output), `MeshTools.swift` (Model I/O load, measure, export),
  `ScanStore.swift` (scan folders in Documents/Scans), `Updates.swift` (update check, About, problem report),
  `CaptureGuide.swift` (hand-held guidance: Core Motion heading and camera tilt, coverage map, haptics, gap advice).
- `Packages/ScanMath/`: platform-independent maths (principal axes, volume, mesh slicing) with XCTest tests.
- `project.yml`: XcodeGen spec; the Xcode project is generated in CI and not committed.
- `ReleaseNotes.md`: newest section first. Its bullets are shown in the app's update banner.

## Shipping a correction
1. Change the code. Add or update a ScanMath test when the change touches measurement maths.
2. Add a user-facing bullet under a new top section in `ReleaseNotes.md`. Bump `MARKETING_VERSION` in
   `project.yml` for visible changes; the build number is the GitHub run number and goes up by itself.
3. Commit and push to branch `crystal-bowl-ios` of `AvradipG/new_test_repo-` (never to `main`, which is
   the owner's profile repository).
4. `.github/workflows/ios.yml` runs on a macOS runner: ScanMath tests, unsigned build, IPA published to the
   `ipa` branch with `version.json`, then signed TestFlight upload when the App Store Connect secrets exist.
5. Watch with `gh run watch`. Logs and artifacts can't be downloaded from the cloud sandbox; compiler
   errors are emitted as annotations: `gh api repos/AvradipG/new_test_repo-/check-runs/<job id>/annotations`.
   A red run means the owner gets nothing: fix it and push again before reporting back.
6. Done means the run shows the notice "Build N uploaded to App Store Connect". The phone picks it up from
   TestFlight 5–15 minutes later (automatic updates are on). Tell the owner the build number and what changed.

Start every change from the latest `crystal-bowl-ios`, in the cloud as well. Builds queue, so pushing several
small fixes in a row is fine. Agents without `gh` can check runs at
`https://api.github.com/repos/AvradipG/new_test_repo-/actions/runs?branch=crystal-bowl-ios` (public).

## Google Drive package
`Drive.swift` (OAuth PKCE sign-in, Drive REST client, manifest) and `DriveSyncModel.swift` (upload queue).
Scope is `drive.file`: the app sees only what it created. Layout in My Drive:
`Crystal Bowl Scans/index.json`, `README.txt`, and one folder `<scan id>_<sample>/` per scan with
`manifest.json` (schema `crystal-bowl.scan/0.1`, uploaded last), `model/`, `sections/`, optional `images/`.
The iOS OAuth client ID (bundle ID `com.avradip.crystalbowl`) is not a secret: set it as `CB_GOOGLE_CLIENT_ID`
in `project.yml`, or as the repository variable `GOOGLE_IOS_CLIENT_ID`, which overrides it. The project brief is in Drive:
`DRA_Handoff/PROJECT_BRIEF_Crystal_Bowl_Design_Requirements_2026-10-27_v0.2.md` (see sections 12–13).

## Data compatibility
Scans live in the app's Documents folder and survive updates. `scan.json` is decoded into `Scan`; add new
fields as optionals so older scans still load. Never rename or remove existing keys.

## Problem reports
The app's About screen copies a report (version, commit, device, iOS, latest scan numbers). Start a fix by
checking out the commit named in the report.
