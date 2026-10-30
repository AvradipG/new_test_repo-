# Crystal Bowl Scanner: notes for coding agents

The project notes live in [CLAUDE.md](CLAUDE.md) and apply to every agent (Codex, Claude Code, others). Read it first.

The short version:
- Work on branch `crystal-bowl-ios` of `AvradipG/new_test_repo-`. Never push to `main`.
- Every push to `crystal-bowl-ios` builds the app on GitHub and uploads it to TestFlight; the owner's iPhone updates itself.
- Add a user-facing bullet to `ReleaseNotes.md` and bump `MARKETING_VERSION` in `project.yml` for visible changes.
- A change is finished when the GitHub run is green and reports "uploaded to App Store Connect".
