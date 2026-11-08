# Paper Quest (iPhone)

Track and gamify writing papers on the go. Built like the Crystal Bowl Scanner and Tidy Atlas: a SwiftUI app
generated with XcodeGen, built, signed and sent to TestFlight by GitHub Actions (no Mac needed).

- **Tree tracker**: paper → sections → subsections → components (equations, figures, tables, review flags, text
  checks). Marks as in Claude's task list: dashed circle (to do), spinning arc (in progress), green tick (done).
  Tap a mark to move it on; parents roll up from their children and show a progress bar and count.
- **Green–Christoffel** comes ready, built from the manuscript's object registry: 12 sections + Submission, 39
  equations, 7 figures, 2 tables, the open review flags (97 items).
- **Quest**: XP per item (+10), subsection (+30) and section (+100); levels; daily goal ring; streak; confetti and
  haptics when a subsection, section or the paper is finished; a "Next up" card.
- **Google Drive sync**: My Drive › Paper Quest › one folder per paper with `progress.json` (merged both ways, so an
  iPad and the iPhone stay in step) and `progress.md` (read by Claude through the Drive connector). With the Google
  Drive app's folder linked, Claude can send changes through `claude-inbox/`.
- **Manuscript**: opens the Firebase Manuscript Studio; copies `\eqref{…}` / `\ref{…}` for any object.

## Build and TestFlight
Every push to branch `paper-quest-ios` runs `.github/workflows/paper-quest.yml`: PaperCore tests, XcodeGen, unsigned
build, IPA + `version.json` on branch `ipa-paper-quest`, then signed upload to TestFlight with the same repository
secrets as Crystal Bowl (`ASC_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `APPLE_TEAM_ID`).

One-time setup:
1. App Store Connect › Apps › **+** › New App: iOS, name "Paper Quest", bundle ID `com.avradip.paperquest`
   (the first workflow run registers it), SKU `paperquest`.
2. Re-run the workflow (or push). TestFlight › Internal Testing › **+**: a group with automatic distribution, add yourself.
3. On the iPhone: TestFlight › Paper Quest › Install, and turn on Automatic Updates.
4. In the app: Settings › Google Drive › Connect.
