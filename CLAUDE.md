# Paper Quest: notes for Claude

Private iPhone/iPad app (SwiftUI, iOS 17+) to track and gamify writing scientific papers on the go. Each paper is a
tree (sections → subsections → components such as equations, figures, tables, review flags, text checks) with
Claude-style marks: dashed circle = to do, spinning arc = in progress, green tick = done ("done" means the owner is
satisfied, so never tick things for them unless they ask). XP, levels, daily goal, streak, confetti.
Same owner and delivery loop as the Crystal Bowl Scanner (`crystal-bowl-ios`) and Tidy Atlas (`tidy-atlas-ios`):
plain-language requests, each ending with a push that reaches the phone through TestFlight.

## Owner's standing rules
- Manuscript work uses the Firebase Manuscript Studio (https://manuscript-studio-181489801873.web.app/write/,
  Firestore database `manuscript-studio`, paper `green-christoffel-writing`) and this app. **Never use the Floot
  project "Green–Christoffel Manuscript Studio"** (said by the owner on 2026-11-07: "The floot app is not being used.
  Don't ever use it.").
- Sync goes through Google Drive (My Drive › Paper Quest). Claude reads it with the Google Drive connector.

## Layout
- `Packages/PaperCore/`: all logic, platform-independent, with XCTest tests. `Model.swift` (Status, Node, Win,
  Paper, PaperJSON), `Tree.swift` (roll-up marks, counts, rows, next up, find), `Quest.swift` (Points/XP, Level,
  Streak, Celebration, `Edit` = every change, `Merge` = two copies → one), `Inbox.swift` (Claude inbox ops,
  Markdown export, Drive README), `Templates.swift` (Green–Christoffel from the manuscript's object registry,
  generic article).
- `PaperQuest/`: app. `Store.swift` (papers in Documents/Papers/<id>.json, edits, celebrations), `DriveSync.swift`
  (pull–merge–push, both routes, inbox), `Drive.swift` (Google sign-in + REST, from Crystal Bowl), `HomeView`,
  `PaperView` (tree), `NodeSheet` (item details), `SettingsView` (+ Drive setup, chip), `Theme.swift` (marks,
  bars, rings, confetti, Safari view), `Updates.swift` (update banner, problem report).
- `project.yml`: XcodeGen spec (bundle ID `com.avradip.paperquest`); the Xcode project is generated in CI.
- `ReleaseNotes.md`: newest section first; its bullets show in the app's update banner.

## Drive layout (what Claude reads and writes through the connector)
My Drive › Paper Quest › `<title> (<paper id>)` › `progress.json` (schema `paper-quest.progress/1`),
`progress.md` (checklist with ids, counts, XP, streak, next up), `claude-inbox/` (Claude's change files).
- Read progress: `progress.md`. Node ids are stable (Green–Christoffel: `gc/eq:harmonic`, `gc/sec-results/text/2`).
- Ask for changes: create a JSON file in `claude-inbox` (format in `Packages/PaperCore/Sources/PaperCore/Inbox.swift`
  and in the folder's README.txt). The app applies each file once. This works only when the app is linked through
  the Google Drive app's folder: with direct sign-in (drive.file scope) the app cannot see files Claude creates.

## Shipping a change
1. Change the code; add/adjust a PaperCore test when the logic there changes.
2. Add a user-facing bullet under a new top section in `ReleaseNotes.md`; bump `MARKETING_VERSION` for visible changes.
3. Commit and push to branch `paper-quest-ios` of `AvradipG/new_test_repo-` (never `main`, `crystal-bowl-ios` or
   `tidy-atlas-ios`).
4. `.github/workflows/paper-quest.yml` tests, builds, publishes the IPA to `ipa-paper-quest`, and uploads to
   TestFlight. It shares the `ios-build` concurrency group with the other apps, so builds queue.
5. Compiler errors appear as annotations: `gh api repos/AvradipG/new_test_repo-/check-runs/<job id>/annotations`.
   A red run means the owner gets nothing: fix and push again before reporting back.
6. Done means the run's notice "Build N uploaded to App Store Connect".

## Must survive every update
The Google refresh token and email live in the Keychain (service `PaperQuest`, synchronizable); the folder bookmark,
daily goal and expansion state in UserDefaults. Never rename those, never change the bundle ID. Paper files are
JSON with lenient decoding: add fields with defaults, never rename or remove them.
