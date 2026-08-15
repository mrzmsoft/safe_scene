# Safe Scene - Engineering Roadmap & Implementation Prompts

A 100% offline, privacy-first desktop media player built with Flutter (Windows) that uses local AI inference (Whisper.cpp + NudeNet ONNX + FFmpeg) to automatically detect, skip, and mute 18+ scenes and profanity in movies and web series.

---

## 1. System Architecture & Tech Stack

```
+-------------------------------------------------------------------------+
|                      FLUTTER WINDOWS FRONTEND                           |
|  - UI State & File Pickers (file_picker)                                |
|  - Video Rendering Engine (media_kit + libmpv)                          |
|  - Filter Engine (JSON loader, real-time timestamp listener)            |
|  - Manual Scene Editor (Hotkeys + Seekbar Markers)                      |
|  - Master PIN & Family Safety Controls                                  |
+------------------------------------+------------------------------------+
                                     | Standard I/O (JSON Streams)
                                     v
+-------------------------------------------------------------------------+
|                LOCAL SCANNER SIDECAR (C++ / Python CLI)                 |
|                                                                         |
|  [ Input Video (.mp4/.mkv) ]                                            |
|        |                                                                |
|        +---> Audio Extraction (FFmpeg CLI)                              |
|        |           |                                                    |
|        |           v                                                    |
|        |     Whisper.cpp (ggml-base.bin) ---> Word Timestamps           |
|        |           |                                                    |
|        |           v                                                    |
|        |     Profanity Regex / Dictionary -> [ MUTE Segments ]          |
|        |                                                                |
|        +---> Keyframe Sampling (1.5 FPS via FFmpeg)                     |
|                    |                                                    |
|                    v                                                    |
|              NudeNet / YOLO-NSFW (ONNX) ---> [ SKIP Segments ]          |
|                                                                         |
|  [ Output: movie_name.safe.json ]                                       |
+-------------------------------------------------------------------------+
```

### Core Technologies
* **Frontend Framework:** Flutter Desktop (Windows target, Release mode).
* **Video Playback Engine:** `media_kit`, `media_kit_video`, `media_kit_libs_windows_video` (native `libmpv` binding for zero-latency frame-accurate seeking).
* **Audio AI Engine:** `whisper.cpp` (C++ static binary with AVX2/DirectML) running `ggml-base.bin` (~140MB).
* **Visual AI Engine:** ONNX Runtime (`onnxruntime.dll` / C++ or standalone Python sidecar) running quantized `nudenet_320n.onnx` (~40MB).
* **Media Processor:** Bundled static `ffmpeg.exe` for high-speed keyframe and audio extraction.
* **Storage Format:** Local human-readable JSON schema (`*.safe` / `*.safe.json`).

---

## 2. Master Implementation Roadmap (Phases 1 - 5)

### Phase 1: Foundation & Video Playback Engine (Days 1–4)
- [x] Configure Flutter Windows desktop environment and verify C++ build tools.
- [x] Install and configure `media_kit` for Windows.
- [x] Build baseline player UI with native keyboard hotkeys (Space for Play/Pause, Left/Right for Seek, F/Esc for Fullscreen).
- [x] Implement data models (`FilterSegment`, `ScanResult`/`SafeMetadata`, `FilterAction`).
- [x] Build real-time playback position listener stream to trigger instant skip and volume mute (`SafePlayerController`).

### Phase 2: Offline AI Scanner Engine (Sidecar) (Days 5–10)
- [x] Build standalone `scanner_engine.py` worker script — ⚠️ compiled `scanner_engine.exe` **not yet produced** (needs PyInstaller, Phase 5).
- [x] Integrate FFmpeg audio extraction: 16kHz mono `.wav`.
- [x] Integrate whisper word-level timestamps (faster-whisper primary, whisper.cpp CLI fallback) — ⚠️ `whisper-cli.exe` **not yet bundled**.
- [x] Implement profanity regex and swearword dictionary filter mapping.
- [x] Integrate FFmpeg keyframe/scene extraction sampled at 1.5 FPS.
- [x] Run batch inference through `nudenet.onnx` and merge contiguous detections into safe skip intervals ($[t_{start} - 0.75s, t_{end} + 0.75s]$).
- [x] Pipe structured stdout stream (`PROGRESS:<0.0-1.0>`, `RESULT:<json>`) back to Flutter.

### Phase 3: Flutter Scanner Integration & Progress UI (Days 11–14)
- [x] Implement `ScannerService` in Flutter using `dart:io Process.start`.
- [x] Design sleek Scan Dialog with progress bar, estimated time remaining, and real-time category detection counters (`ScanDialogWidget` + `ScanProgress`).
- [x] Auto-save and auto-load `.safe` files alongside media files with matching hashes (engine writes, `findExistingRule` loads by name/hash).

### Phase 4: Interactive Scene Editor & Parent Controls (Days 15–18)
- [x] Build Parent PIN authentication (encrypted local storage via `flutter_secure_storage`, PBKDF2-HMAC-SHA256 verifier).
- [x] Develop Scene Inspector Timeline: visually display Red (Skip) and Yellow (Mute) markers over `media_kit` timeline (`SafeSeekBarWidget`).
- [x] Build In-Player Marker Hotkeys — ⚠️ `[`/`]` for segment start/end implemented (active while editor open); `S` (Skip) / `M` (Mute) keys **not yet mapped**.
- [ ] Implement segment fine-tuning dialog (adjust start/end by $\pm 100\text{ms}$) — **not yet built**; editor currently edits action/category only.

### Phase 5: Production Packaging & Performance Tuning (Days 19–22)
- [ ] Multi-thread CPU & DirectML GPU acceleration configuration — **not done**; ONNX engine is pinned to `CPUExecutionProvider` with default threads.
- [ ] Bundle static binaries (`ffmpeg.exe`, `scanner_engine.exe`, AI models) in `assets/bin/` and `assets/models/` — **partial**: `ffmpeg.exe`/`ffplay.exe`/`ffprobe.exe` + `ggml-base.bin` + `nudenet.onnx` present; `scanner_engine.exe` and `whisper-cli.exe` **missing** — without them the packaged app cannot run a real scan.
- [x] Build standalone Windows installer using **Inno Setup** (`safe_scene_installer.iss` → `dist/SafeScene_Setup_v1.0.0.exe`).

---

## 3. Data Specification (`movie.safe.json`)

```json
{
  "version": "1.0",
  "media_title": "Action_Movie_2026.mp4",
  "media_hash": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "duration_ms": 7200000,
  "settings": {
    "filter_nudity": true,
    "filter_profanity": true,
    "safety_buffer_ms": 750
  },
  "segments": [
    {
      "id": "seg_001",
      "start_ms": 142000,
      "end_ms": 147500,
      "action": "skip",
      "category": "explicit_nudity",
      "confidence": 0.96,
      "source": "ai_nudenet"
    },
    {
      "id": "seg_002",
      "start_ms": 210200,
      "end_ms": 211100,
      "action": "mute",
      "category": "profanity",
      "confidence": 1.0,
      "source": "ai_whisper"
    }
  ]
}
```

---

## 4. Step-by-Step AI Development Prompts

Use these prompts sequentially with your AI assistant or coding agent to generate the entire codebase:

### Prompt 1: Flutter Foundation & MediaKit Player Setup
```text
I am building a Flutter Windows desktop app called "Safe Scene". It is a local video player that automatically skips and mutes explicit scenes based on timestamp rules.

Requirements:
1. Provide pubspec.yaml with media_kit, media_kit_video, media_kit_libs_windows_video, file_picker, and flutter_secure_storage.
2. Implement FilterSegment model (start: Duration, end: Duration, action: enum {skip, mute, blackout}, category: String, source: String).
3. Implement SafePlayerController wrapping media_kit Player.
4. Listen to player.stream.position and evaluate if the current timestamp falls inside any FilterSegment:
   - If 'skip': perform player.seek(segment.end, exact: true) with a quick fade overlay.
   - If 'mute': set player.setVolume(0) and restore previous volume immediately after segment.end.
5. Create a clean Flutter Desktop video player page with custom overlay controls and keyboard shortcuts (Space, Left, Right, F for fullscreen).
```

### Prompt 2: Offline Scanner Engine (Python / Standalone Worker)
```text
Write a complete standalone Python script `scanner_engine.py` (designed to be compiled via PyInstaller into scanner_engine.exe for Safe Scene).

The script must operate 100% offline with zero internet access:
1. Accept CLI arguments: --input <video_path>, --output <json_path>, --models-dir <dir>.
2. Audio Analysis:
   - Use bundled ffmpeg to extract 16kHz mono audio: ffmpeg -i <input> -vn -ar 16000 -ac 1 -c:a pcm_s16le temp_audio.wav
   - Run faster-whisper (or whisper.cpp via subprocess) using ggml-base model to extract word-level timestamps.
   - Match words against a local profanity dictionary and generate "mute" segments.
3. Visual Analysis:
   - Extract frames at 1.5 FPS using ffmpeg: ffmpeg -i <input> -vf "fps=1.5" -q:v 2 temp_frames/frame_%06d.jpg
   - Run ONNX Runtime inference using nudenet / nsfw classifier model on each frame.
   - Identify frames with confidence > 0.65 and generate "skip" segments.
4. Post-Processing:
   - Merge overlapping or consecutive segments occurring within 2.5 seconds of each other.
   - Add a 750ms safety buffer to start and end times.
5. IPC Communication:
   - Emit progress lines to stdout in real-time: PROGRESS:0.45
   - Write final result to <video_name>.safe.json and print RESULT:<json_string>.
```

### Prompt 3: Flutter Scanner Process Manager & Real-Time Progress UI
```text
Write the Flutter service and UI to communicate with `scanner_engine.exe` for Safe Scene:

1. `ScannerService`:
   - Runs `Process.start` on the bundled scanner binary.
   - Parses stdout lines (`PROGRESS:<float>` and `RESULT:<json>`).
   - Yields a Stream<ScanProgress> (percentage, current phase: Audio/Video, segments found so far).
   - Handles graceful cancellation via Process.kill().
2. `ScanDialogWidget`:
   - Modern dark-themed dialog displaying a circular or linear smooth progress indicator.
   - Live counter cards: "Visual Scenes Flagged: X", "Profanities Flagged: Y".
   - "Cancel" and "Run in Background" buttons.
3. Auto-loader:
   - When a video is selected, check if a `.safe` or `.safe.json` file exists with matching name/hash.
   - If found, load rules immediately; otherwise prompt: "Would you like to auto-scan this movie for Family Mode?".
```

### Prompt 4: Parent Control, PIN Lock & Visual Timeline Overlay
```text
Implement Parent Controls and Timeline Overlays for the Safe Scene Flutter app:

1. `SecurityService`:
   - Store and verify a 4-digit Master PIN using flutter_secure_storage and bcrypt/crypto hashing.
   - Require PIN verification before opening the Scene Editor, modifying filter sensitivities, or disabling Safe Mode.
2. `SafeSeekBarWidget`:
   - Custom Flutter canvas timeline slider that replaces standard video slider.
   - Paint colored vertical notches/bands along the progress bar:
     - 🟥 Red bands for 'skip' segments.
     - 🟨 Yellow bands for 'mute' segments.
   - Tooltip on hover showing segment timestamp and category name.
3. `SceneEditorDrawer`:
   - Side panel showing an editable list of all flagged segments.
   - In-player hotkeys to mark start (`[`), end (`]`), and save new segment.
   - Buttons to test/preview flagged segments with a 3-second lead-in.
```

---

## 5. Inno Setup Windows Installer Script (`installer.iss`)

```pascal
[Setup]
AppName=Safe Scene
AppVersion=1.0.0
DefaultDirName={autopf}\SafeScene
DefaultGroupName=Safe Scene
OutputDir=dist
OutputBaseFilename=SafeScene_Setup_v1.0.0
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64

[Files]
; Flutter Desktop Release Build
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs
; Offline AI Binaries and Models
Source: "assets\bin\*"; DestDir: "{app}\assets\bin"; Flags: ignoreversion recursesubdirs
Source: "assets\models\*"; DestDir: "{app}\assets\models"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\Safe Scene"; Filename: "{app}\safe_scene.exe"
Name: "{autodesktop}\Safe Scene"; Filename: "{app}\safe_scene.exe"
```
