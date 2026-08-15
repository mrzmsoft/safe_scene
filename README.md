# Safe Scene

A **100% offline, privacy-first** desktop video player for Windows that automatically **skips 18+ scenes** and **mutes profanity** using local AI inference — nothing ever leaves your machine.

> **Status:** All five roadmap phases are implemented. See [ROADMAP.md](ROADMAP.md) for the engineering plan, implementation prompts, and the JSON data specification.

---

## What it does

- Play any local video (`mp4`, `mkv`, `avi`, `mov`, …) with `media_kit` + `libmpv`.
- **Auto-skip explicit scenes** — NudeNet ONNX inference on keyframes flags nudity and the player jumps past it with a fade mask.
- **Auto-mute profanity** — whisper.cpp (`ggml-base.bin`) transcribes the audio and a local dictionary mutes flagged words.
- **Auto-load filter rules** — a `<name>.safe.json` next to your video is loaded by filename or content hash; otherwise you are offered a one-click scan.
- **Scene Editor** — review/edit/delete flagged segments, mark your own with `[`/`]`, save as Skip (`S`) or Mute (`M`), fine-tune start/end by ±100 ms, and preview with a 3 s lead-in.
- **Visual timeline** — red (skip) / yellow (mute) / purple (blackout) bands with hover tooltips on the seek bar.

## Architecture

```
┌───────────────────────────── Flutter Windows frontend ─────────────────────────────┐
│  UI & file pickers (file_picker) · playback (media_kit + libmpv)                  │
│  Filter engine (JSON rules → real-time skip/mute listener)                        │
│  Scene editor (hotkeys + seekbar markers)                                │
└───────────────────────────────────┬───────────────────────────────────────────────┘
                                    │  stdout JSON (PROGRESS: / RESULT:)
┌───────────────────────────────────▼───────────────────────────────────────────────┐
│  Local scanner sidecar (scanner_engine.exe — PyInstaller bundle)                  │
│  1. ffmpeg → 16 kHz WAV → whisper.cpp → word timestamps → profanity ⇒ MUTE        │
│  2. ffmpeg → 1.5 FPS keyframes → NudeNet ONNX → explicit frames ⇒ SKIP            │
│  Output: <video>.safe.json (750 ms buffer, 2.5 s merge window)                    │
└───────────────────────────────────────────────────────────────────────────────────┘
```

### Tech stack

| Layer | Technology |
|---|---|
| Frontend | Flutter (Windows desktop, Material 3 dark theme) |
| Playback | `media_kit`, `media_kit_video`, `media_kit_libs_windows_video` (libmpv) |
| Audio AI | `whisper.cpp` v1.9.2 (`whisper-cli.exe`) + `ggml-base.bin` (~148 MB) |
| Visual AI | ONNX Runtime (inside `scanner_engine.exe`) + `nudenet.onnx` (~12 MB) |
| Media processing | Bundled `ffmpeg.exe` / `ffprobe.exe` / `ffplay.exe` |
| Storage | Human-readable JSON (`*.safe.json`) — see ROADMAP §3 |

## Getting started

### Prerequisites
- Windows 10/11 (x64)
- Flutter SDK (stable) with the Windows desktop toolchain (Visual Studio C++ workload)

### Build the Flutter app
```powershell
flutter pub get
flutter run -d windows          # development
flutter build windows --release # production
```

### Build the scanner engine (binaries are already bundled in `assets/bin`)
```powershell
pip install pyinstaller faster-whisper onnxruntime numpy pillow
python -m PyInstaller --onefile --name scanner_engine `
  --collect-all faster_whisper --hidden-import=onnxruntime --hidden-import=PIL `
  scanner_engine.py
Copy-Item dist\scanner_engine.exe assets\bin\
```
The `whisper-cli.exe` comes from the official [whisper.cpp releases](https://github.com/ggml-org/whisper.cpp/releases) (`whisper-bin-x64.zip`).

### Visual ensemble (reduce false alerts & missed scenes)

The visual detector is **model-agnostic**: the scanner auto-detects any ONNX model you drop next to `nudenet.onnx` as either a YOLO-style detector or a softmax classifier. With **two or more** models present, the engine **fuses their per-frame votes** and **smooths them across neighbouring samples**, which removes most single-model false alerts (like a "SEXY" swimwear/romance frame) while a high-confidence (≥ 0.95) second vote recovers scenes one model under-detects.

To enable it, place a second offline model (e.g. a YOLOv8-NSFW ONNX export) into the models folder next to `nudenet.onnx`, then copy the bundled example into place:

```powershell
Copy-Item assets\models\visual_models.example.json assets\models\visual_models.json
```

The config sets a per-model `threshold` (and optional per-model `labels` file), the fusion `rule` (`consensus` default, or `all` / `any` / `majority`), the `confirm_confidence` / `hard_confidence` tiers, and the temporal `vote_window` / `min_votes` smoothing. Missing models are skipped, so a lone `nudenet.onnx` behaves exactly as before. Visual sampling is now **2.0 FPS** (was 1.5) to close the gaps that caused missed scenes.

### Installer (Inno Setup)
```powershell
iscc.exe safe_scene_installer.iss   # → dist\SafeScene_Setup_v1.0.0.exe
```

## Usage

1. Launch **Safe Scene**.
2. **Open Video File** to play any movie — a matching `<name>.safe.json` loads its rules instantly; otherwise a *"Auto-scan for Family Mode?"* prompt appears.
3. Or use the always-visible **Scan & Protect a Movie** button to scan any video you choose — a progress dialog streams live counters ("Visual Scenes Flagged", "Profanities Flagged") and the movie plays with the resulting rules when done.
4. The player automatically skips/mutes flagged windows (with a fade mask on skips).
5. Press `E` to open the Scene Editor: edit/delete segments, mark your own with `[`/`]` and save with `S`/`M`, fine-tune ±100 ms, preview.

### Keyboard shortcuts

| Key | Action |
|---|---|
| `Space` | Play / pause |
| `←` / `→` | Seek ±10 s |
| `F` / `Esc` | Toggle fullscreen / exit |
| `E` | Open / close Scene Editor |
| `[` / `]` | Mark segment start / end (editor open) |
| `S` / `M` | Save marked range as Skip / Mute (editor open) |

## Project layout

```
lib/
  controllers/safe_player_controller.dart   # rule enforcement (skip/mute/blackout)
  models/filter_segment.dart                # FilterSegment + FilterAction
  models/scan_progress.dart                 # ScanProgress / ScanResult
  screens/home_page.dart                    # file picker + auto-load/scan flow
  screens/video_player_page.dart            # player, overlays, hotkeys
  services/scanner_service.dart             # Process.start + PROGRESS:/RESULT: IPC
  widgets/safe_seek_bar.dart                # timeline with segment bands
  widgets/scan_dialog.dart                  # scan progress dialog
  widgets/scene_editor_drawer.dart          # segment list + fine-tune dialog
assets/
  bin/    # ffmpeg, ffprobe, ffplay, scanner_engine.exe, whisper-cli.exe + DLLs
  models/ # ggml-base.bin, nudenet.onnx
scanner_engine.py        # offline scanner sidecar (PyInstaller → scanner_engine.exe)
safe_scene_installer.iss # Inno Setup installer script
test/                    # Flutter unit/widget tests (25)
```

## Data specification

Scan results follow the `movie.safe.json` schema (see [ROADMAP.md §3](ROADMAP.md) for the full example). Each `segment` carries `start_ms`, `end_ms`, `action` (`skip`/`mute`/`blackout`), `category`, `confidence`, and `source` (`ai_nudenet` / `ai_whisper` / `manual`).

## Roadmap

See [ROADMAP.md](ROADMAP.md) — phase checklist, implementation prompts, and the JSON data specification.

