# Release notes

Newest first. The first section's bullet points are shown in the app's update banner,
so write them for the person using the app.

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
