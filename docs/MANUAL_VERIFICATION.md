# AuraWall — Manual Verification Checklist & Walkthrough Summary

This guide covers the interactive macOS GUI, WindowServer, Space/Mission Control, multi-display hardware, and power-management behaviors of **AuraWall** that require physical or visual verification beyond headless automated tests.

---

## 1. Build, Launch & Walkthrough Summary

1. **Build & Package the `.app` Bundle**
   ```bash
   cd /Users/holastre/Documents/antigravity_projects/aurawall
   bash ./scripts/bundle.sh
   ```
   - **Expected**: Script completes with exit code `0`, producing a signed `arm64` bundle at `build/AuraWall.app`.
   - Verify bundle metadata if desired:
     ```bash
     plutil -lint build/AuraWall.app/Contents/Info.plist
     codesign --verify --deep --strict build/AuraWall.app
     ```

2. **Launch AuraWall**
   ```bash
   open build/AuraWall.app
   ```
   - **Expected**:
     - The main window opens with frameless dark translucent chrome (`#09090B`), transparent titlebar, and traffic-light buttons positioned cleanly to the left of the floating `GlassPillNavBar` (`Search`, `Home`, `Explore`, `My Media`, `Import`, `Settings`).
     - An AuraWall status icon appears in the macOS Menu Bar.
     - The Dock icon is visible while the main window is open (`NSApp.activationPolicy() == .regular`).
     - Initial Home shelves (`Live Videos`, `Trending Wallhaven`, `Recommended For You`) and Hero Carousel populate automatically without requiring any API keys.

---

## 2. Live Desktop Video Playback Behind Icons & Spaces

1. **Apply a Live Video Wallpaper**
   - On **Home**, select a video in the Hero Carousel or `Live Videos` shelf and click **Apply Wallpaper** (or open its detail sheet).
   - **Expected**:
     - Download progress is shown if the asset is not yet cached; once downloaded, `DesktopVideoWindow` plays muted, seamlessly looping video behind Finder desktop icons.
     - **Click-through (`ignoresMouseEvents`)**: Clicking, dragging selection rectangles, or right-clicking desktop icons/files on the desktop interacts normally with Finder — `DesktopVideoWindow` never intercepts mouse or keyboard events.
2. **Spaces & Mission Control**
   - Swipe between macOS Spaces or open Mission Control (`Ctrl+Up` / trackpad gesture), and create a second Space.
   - **Expected**: Video continues playing smoothly behind desktop icons across all Spaces (`canJoinAllSpaces`, `stationary`) and remains at desktop level during Mission Control transitions.
3. **Menu Bar Tinting (`extractFirstFrameStill`)**
   - Confirm in **Settings** that `Extract first-frame still for macOS menu bar tinting & smooth transitions` is enabled.
   - Apply a bright video vs. a dark video.
   - **Expected**: `WallpaperEngine` extracts the first frame via `AVAssetImageGenerator` and sets it via `NSWorkspace.shared.setDesktopImageURL`, causing the translucent macOS Menu Bar to tint naturally to match the video.
4. **Scaling Modes (`.fill` vs. `.fit`)**
   - Open `WallpaperDetailSheet` for an image or video and switch between **Fill** and **Fit**, then apply.
   - **Expected**: `.fill` crops proportionally to fill the screen without letterboxing; `.fit` preserves the full frame with black letterbox/pillarbox fill (`AVLayerVideoGravity.resizeAspect` / `NSColor.black` fill).
5. **Static Image GPU Teardown**
   - Apply a static image from `Trending Wallhaven`.
   - **Expected**: All active `DesktopVideoWindow` instances tear down immediately (freeing GPU/decoder memory), Menu Bar status updates to **Static** with a blue dot, and the static image displays cleanly on the desktop.

---

## 3. Multi-Display Switching, Independent vs. Mirror Mode & Physical Hotplug

*(Requires at least one external monitor or virtual/Sidecar display.)*

1. **Independent Per-Display Assignment**
   - Open the Menu Bar popover (or **Displays** toggle) and switch to **Independent**.
   - In `WallpaperDetailSheet` or Home/Explore target display picker, assign a **Live Video** to Display 1 and a **Static Image** to Display 2.
   - **Expected**:
     - Display 1 plays live video while Display 2 shows the static image.
     - Menu Bar status reports **Playing** (green dot) rather than **Static** even if the primary display holds the static image and Display 2 plays the video.
2. **Mirror All ↔ Independent Mode Transition**
   - Switch **Mirror All** -> apply a live video -> toggle back to **Independent**.
   - **Expected**: In **Mirror All**, all connected displays play the mirrored video; toggling back to **Independent** preserves live video playback across both primary and secondary monitors rather than tearing down secondary screens.
3. **Physical Monitor Unplug / Replug & Resolution Change**
   - While in **Independent** mode with wallpapers on both displays, unplug the external monitor.
   - **Expected**: AuraWall tears down the disconnected display's `DesktopVideoWindow` cleanly without crashing.
   - Replug the external monitor.
   - **Expected**: `DisplayManager` detects `didChangeScreenParametersNotification` and restores the saved assignment on the reconnected monitor.
   - Change display scaled resolution in **System Settings → Displays**.
   - **Expected**: `DesktopVideoWindow` resizes smoothly to match the updated screen frame.

---

## 4. Smart Power Saving

1. **AC → Battery Transition & Session Override**
   - While a live video is playing, unplug MacBook MagSafe/USB-C AC power.
   - **Expected**: Within seconds (`IOKit.ps`), desktop video pauses and Menu Bar popover shows **Paused — On Battery** (orange dot) along with the **Play on Battery Anyway (Override)** button.
   - Click **Play on Battery Anyway (Override)**.
   - **Expected**: Video resumes playback immediately; button toggles to **Restore Battery Power Saving**.
   - Plug AC power back in.
   - **Expected**: Battery override automatically resets and playback remains active (`Playing`).
2. **Per-Display Fullscreen App Occlusion**
   - Open an app (e.g., Safari or QuickTime Player) and enter macOS fullscreen (`Ctrl+Cmd+F`) on the display playing a live video.
   - **Expected**: That display's video pauses (`Paused — Fullscreen App`). In a multi-display setup where Display 1 plays a video (fullscreen-occluded) and Display 2 shows a static image, the Menu Bar accurately reports **Paused — Fullscreen App** (not `Playing`).
   - Exit fullscreen (`Esc` / `Ctrl+Cmd+F`).
   - **Expected**: Video resumes automatically (`Playing`).
3. **Screen Lock & Sleep / Wake**
   - Press `Ctrl+Cmd+Q` to lock the screen (or close the MacBook lid for a few seconds), then unlock/wake.
   - **Expected**: Playback pauses on lock/sleep (`Paused — Display Asleep / Locked`) and resumes cleanly upon unlock/wake.

---

## 5. Wallper-Inspired UI, Imports, Settings & Menu Bar Background Mode

1. **Navigation, Hero Carousel & Explore**
   - Verify clicking **Search** in the floating glass pill switches to **Explore** and focuses the search bar.
   - In **Home**, step through Hero Carousel items and verify muted inline video preview pauses when opening **Explore**, **My Media**, `WallpaperDetailSheet`, or **Settings**.
   - In **Explore**, test keyword search, source chips (`Starter`, `Wallhaven`, `Pexels`, `Pixabay`, `Custom Feed`), media type (`All`, `Videos`, `Images`), resolution/aspect/tag filters, and **Load More** pagination.
2. **Local Media Import (`NSOpenPanel` & Drag-and-Drop)**
   - Click **Import** in the floating pill bar and select valid `.mp4`, `.mov`, `.jpg`, `.png`, and `.heic` files via `NSOpenPanel`.
   - Drag and drop media files directly from Finder onto the AuraWall window (verify drop overlay appears).
   - **Expected**: Valid files appear under **My Media → Imported** with extracted thumbnails/dimensions and persist across app restarts. Unsupported or 0-byte files are skipped with a clear error banner.
   - Delete an imported wallpaper from **My Media** and verify it is removed from Imported, Favorites, and Recents.
3. **Settings, `0600` Secrets, Custom Feed & Cache Cleanup**
   - Open **Settings** (`gearshape`):
     - Enter optional Pexels/Pixabay/Wallhaven keys (if available) and click **Save Settings**.
     - Verify permissions in Terminal:
       ```bash
       ls -la "$HOME/Library/Application Support/AuraWall/secrets.json"
       ```
       Must show `-rw-------` (`0600`).
     - Test **Custom JSON Feed** URL validation (rejects invalid schemes; valid HTTPS/local HTTP feed loads into shelves/Explore).
     - Click **Clear Unused Cache** and verify it displays `"Freed <size> of unused cache."` (or an explicit `"Failed to clear cache: ..."` error message if simulated unwritable) while preserving currently active desktop and imported wallpapers.
4. **Menu Bar Background Mode (`Works in background`) & Clean Quit**
   - Ensure `Keep running in menu bar when main window is closed (hide Dock icon)` is enabled in **Settings**.
   - Close the main window (`Cmd+W` or red traffic-light button).
   - **Expected**:
     - The Dock icon disappears (`.accessory` mode).
     - Desktop live video continues playing uninterrupted.
     - Menu Bar popover shows **Works in background** with green indicator, active wallpaper thumbnail, live status, **Pause / Resume**, **Next / Random**, **Displays** mode toggle, **Favorites** quick-strip, **Open AuraWall**, and **Quit**.
   - Click **Open AuraWall** in the Menu Bar popover.
   - **Expected**: Main window reopens and the Dock icon returns (`.regular` mode).
   - Click **Quit** in the Menu Bar popover (or `Cmd+Q`).
   - **Expected**: All `DesktopVideoWindow` instances tear down cleanly and the process exits with code `0`.

---

## 6. Automated Verification Baseline Reference

Run the following commands from `/Users/holastre/Documents/antigravity_projects/aurawall` to reproduce the automated verification baseline (isolated temp directories and `CFFIXED_USER_HOME`; zero host desktop or `~/Library` mutations):

```bash
# 1. Core unit & Tier 5 adversarial test suite (offline)
swift test --disable-sandbox

# 2. Live feed smoke checks (Wallhaven SFW + Apple Starter Live Video)
AURAWALL_RUN_LIVE_SMOKE=1 swift test --disable-sandbox --filter LiveSmoke

# 3. Signed arm64 .app bundle build
bash ./scripts/bundle.sh

# 4. Full E2E suite (Tiers 1–4 + SwiftE2E + .app bundle + live smoke checks)
bash ./scripts/e2e_run.sh --full --tier all

# 5. Full E2E suite in offline mode (mock HTTP server + fixtures only)
bash ./scripts/e2e_run.sh --full --tier all --no-live
```
