# Release notes

Newest first. The first section's bullet points are shown in the app's update banner,
so write them for the person using the app.

## 2.0
- Scan and AR in one app: a new AR view tab stands several scanned samples on the real table side by side
- In AR: real size, or bigger or smaller (10 % to 500 %); pinch to resize, twist or use the dial to turn, drag to move
- Measure in 3D: sizes drawn on the sample (height, length, width, cylinder or sphere diameter, micro-CT clearance), each switchable
- Core plugs and balls are recognised automatically: diameter, length, radius and how straight the axis stands
- Blue millimetre ruler beside the sample and a 360° protractor (as in SliceLock) that keeps the exact turn angle, with the Rot_pos/neg name
- Sample sheet: true-scale virtual photos (four sides, top, bottom) with a ruler, saved and sent to Google Drive
- Cross-section images now have millimetre rulers along two edges

## 1.10
- Fixed: orange or empty sectors on the ring now turn green. Hold the phone still on one and the app takes the photo itself, even when the 3D camera had decided it had enough
- New shutter button (Photo here) for any spot you want covered
- Tap the rock on screen to focus and brighten it, as in the Camera app; the camera keeps that spot sharp as you move
- In poor light the phone's light comes on softly by itself; tap the light button to switch it off or on
- Clearer start: the phone finds the table first, then puts a box round the rock on it
- See a finished scan life-size on the table in AR, next to the real rock

## 1.9
- Google Drive upload is always on and keeps going in the background: switch apps or lock the phone and iOS finishes the upload
- A notification tells you when a scan is safely on Google Drive
- One tidy place: My Drive › Crystal Bowl Scans, one folder per scan named by date and sample
- index.json in that folder lists every scan with its date, sizes and micro-CT cylinder, so other software finds scans by itself

## 1.8
- Building the 3D model now runs in the background: keep using the app or other apps, or lock the phone. If iOS pauses it, it continues when you open the app
- Dimensions come first: a notice (and notification) tells you the height, footprint and the cylinder the rock needs, which is enough to centre it in the micro-CT
- New "Dimensions only" scan: one walk round the rock is enough
- Steadier sizes: a × b × c are now the smallest box round the rock, loose fragments are left out, and repeat scans of one Sample ID are compared (mean ± spread)
- A caliper check carries over to later scans with the same Sample ID; tap Repair on older scans to re-measure them
- Blurred photos are spotted while you scan (buzz and hint), shown as gaps and left out of the model
- Close-up camera for surface patterns: uses all lenses, keeps the rock in focus, zooms to it, tap to focus
- Connect Google Drive by tapping it on the home screen and choosing a folder in the Google Drive app: no sign-in setup
- Touch and hold a scan to rename, share, copy its dimensions or delete it; search your scans
- No more Apple Vision Pro warning emails with each new version

## 1.7
- Every slice now has its size even when its outline is open: widest diameter, narrowest width and extents in mm
- New height profile: horizontal slices up the rock as it stood, with the width at every height
- Upright size on the scan page: height, footprint length x width and widest distance across
- Every export carries a dimensions.json with all overall sizes, including each shared slice stack
- Older scans: tap Repair (or Add full dimensions on the home screen) to re-measure and re-cut them from the saved model

## 1.6
- Cross-sections now join exactly coincident texture-seam vertices, so intact surfaces are less likely to appear as broken outlines
- Open or empty sections show measurements unavailable instead of misleading zero area; real gaps are not automatically filled
- Re-cut an existing scan to export full contour coordinates, scale provenance and open/closed status alongside the PNGs and CSV
- Section depth is explicitly a model-axis coordinate; holders and billets still require separate identification

## 1.5
- Vibration guide while scanning by hand: a tick for each photo, a buzz to slow down, keep going the same way or change height
- A coverage ring shows where photos are missing; after a pass the app tells you exactly where to stand to fill the gaps
- Scale check: enter one length measured with calipers and the measurements are corrected
- New colourful home screen; share all model files in one tap; the scan page shows and opens its Google Drive folder
- Sample names keep the letters you type (no forced capitals)
- Original photos upload to Drive on Wi-Fi by default, so the model can be rebuilt at full detail on a Mac

## 1.4
- Building a 3D model no longer stops at 100%: the app goes on to measure the sample and cut the cross-sections
- A scan that stopped at 100% shows its model: open it and tap Measure

## 1.3
- Finished scans upload to Google Drive › Crystal Bowl Scans by themselves
- Each scan folder has a manifest.json, the model in USDZ, OBJ, PLY and STL, and the cross-sections
- Original photos can also be uploaded (Wi-Fi only); they are kept on the phone until uploaded

## 1.2
- The app tells you when a newer version is ready and what changed
- New About and updates screen shows the installed version
- Report a problem: copies a ready-made message to paste into the Claude chat

## 1.1
- Cross-sections every 2 mm along the long axis after each scan, with a slider viewer
- Cut new stacks across any axis at 0.5–5 mm spacing; share as PNG + CSV
- Capture photos are deleted after the model is built to save space

## 1.0
- First version: guided capture with flip pass, on-phone model, measurements and exports
