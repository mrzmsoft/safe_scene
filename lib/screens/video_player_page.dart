import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../controllers/safe_player_controller.dart';
import '../models/filter_segment.dart';
import '../services/security_service.dart';
import '../widgets/safe_seek_bar.dart';
import '../widgets/scene_editor_drawer.dart';

/// A self-contained desktop video player screen.
///
/// Renders the media_kit video surface with a minimal set of custom overlay
/// controls (top bar with title & fullscreen, centered play/pause, bottom
/// seek/volume bar) plus the Safe Scene filter overlays (skip fade + blackout).
///
/// Keyboard shortcuts:
/// * `Space` – play / pause
/// * `←` / `→` – seek backwards / forwards by 10 seconds
/// * `F` – toggle fullscreen
/// * `Esc` – exit fullscreen
/// * `E` – open the Scene Editor (PIN required)
/// * `[` / `]` – mark segment start / end inside the editor
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.controller,
    this.media,
    this.autoplay = true,
    this.title,
  });

  /// The filter-aware playback controller.
  final SafePlayerController controller;

  /// Optional media to load automatically on startup.
  final Media? media;

  /// Whether to start playing right away.
  final bool autoplay;

  /// Optional display title for the top bar.
  final String? title;

  static const Duration seekStep = Duration(seconds: 10);

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> with WindowListener {
  final FocusNode _focusNode = FocusNode();
  late final VideoController _videoController;
  final List<StreamSubscription<dynamic>> _subs = [];

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  double _volume = 100.0;
  bool _fullscreen = false;
  bool _controlsVisible = true;
  Timer? _hideControlsTimer;

  // Scene editor / parent controls state.
  final SecurityService _security = SecurityService();
  bool _editorOpen = false;
  Duration? _markStart;
  Duration? _markEnd;

  static const Duration _previewLeadIn = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _videoController = VideoController(widget.controller.player);
    windowManager.addListener(this);

    _subs
      ..add(
        widget.controller.player.stream.playing.listen(
          (v) => setState(() => _playing = v),
        ),
      )
      ..add(
        widget.controller.player.stream.duration.listen(
          (v) => setState(() => _duration = v),
        ),
      )
      ..add(
        widget.controller.player.stream.position.listen(
          (v) => setState(() => _position = v),
        ),
      )
      ..add(
        widget.controller.player.stream.buffering.listen(
          (v) => setState(() => _buffering = v),
        ),
      )
      ..add(
        widget.controller.player.stream.volume.listen(
          (v) => setState(() => _volume = v),
        ),
      );

    final media = widget.media;
    if (media != null) {
      widget.controller.open(media, play: widget.autoplay).catchError((
        Object e,
      ) {
        debugPrint('SafeScene: failed to open media: $e');
      });
    }

    windowManager.isFullScreen().then((v) {
      if (mounted) setState(() => _fullscreen = v);
    });
    _scheduleAutoHide();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _hideControlsTimer?.cancel();
    windowManager.removeListener(this);
    _focusNode.dispose();
    super.dispose();
  }
  // ---- WindowListener -----------------------------------------------------

  @override
  void onWindowEnterFullScreen() {
    if (mounted) setState(() => _fullscreen = true);
  }

  @override
  void onWindowLeaveFullScreen() {
    if (mounted) setState(() => _fullscreen = false);
  }

  // ---- Controls visibility ------------------------------------------------

  void _scheduleAutoHide() {
    _hideControlsTimer?.cancel();
    if (_playing) {
      _hideControlsTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && !_fullscreen) setState(() => _controlsVisible = false);
      });
    }
  }

  void _pokeControls() {
    setState(() => _controlsVisible = true);
    _scheduleAutoHide();
  }

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    windowManager.setFullScreen(_fullscreen);
  }

  Future<void> _exitFullscreen() async {
    if (await windowManager.isFullScreen()) {
      await windowManager.setFullScreen(false);
    }
  }

  // ---- Scene Editor / Parent Controls ---------------------------------------

  /// Opens the Scene Editor after verifying the Master PIN.
  Future<void> _openEditor() async {
    final ok = await _security.requirePin(
      context,
      message: 'Enter your Master PIN to open the Scene Editor. The editor '
          'lets you view, add and edit the segments being filtered.',
    );
    if (ok && mounted) setState(() => _editorOpen = true);
  }

  void _closeEditor() {
    if (mounted) setState(() => _editorOpen = false);
  }

  /// Marks the start (or end) of a new segment at the current position.
  void _markSegment({required bool isStart}) {
    setState(() {
      if (isStart) {
        _markStart = _position;
      } else {
        _markEnd = _position;
      }
    });
  }

  /// Seeks to `start - 3s` (never below zero) and starts playback.
  void _previewSegment(FilterSegment segment) {
    var target = segment.start - _previewLeadIn;
    if (target < Duration.zero) target = Duration.zero;
    widget.controller.seek(target);
    widget.controller.play();
    _pokeControls();
  }

  void _clearMarks() {
    setState(() {
      _markStart = null;
      _markEnd = null;
    });
  }

  // ---- Keyboard shortcuts -------------------------------------------------

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.space) {
      widget.controller.togglePlay();
      _pokeControls();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      widget.controller
          .seek(_position - VideoPlayerPage.seekStep)
          .then((_) => _pokeControls());
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      widget.controller
          .seek(_position + VideoPlayerPage.seekStep)
          .then((_) => _pokeControls());
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape) {
      _exitFullscreen();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyE) {
      _editorOpen ? _closeEditor() : _openEditor();
      return KeyEventResult.handled;
    }

    // Segment marking hotkeys (only active while the editor is open).
    if (_editorOpen) {
      if (key == LogicalKeyboardKey.bracketLeft) {
        _markSegment(isStart: true);
        _pokeControls();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.bracketRight) {
        _markSegment(isStart: false);
        _pokeControls();
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: MouseRegion(
        onHover: (_) => _pokeControls(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _pokeControls(),
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Video surface.
                Video(controller: _videoController, controls: NoVideoControls),

                // Buffering indicator.
                if (_buffering) const _BufferingIndicator(),

                // Fade overlay that masks skip jumps.
                ValueListenableBuilder<bool>(
                  valueListenable: widget.controller.isFading,
                  builder: (context, fading, _) => AnimatedOpacity(
                    opacity: fading ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 120),
                    child: const ColoredBox(color: Colors.black),
                  ),
                ),

                // Blackout overlay while inside a blackout segment.
                ValueListenableBuilder<FilterSegment?>(
                  valueListenable: widget.controller.currentSegment,
                  builder: (context, segment, _) {
                    final blackout =
                        segment != null &&
                        segment.action == FilterAction.blackout;
                    return AnimatedOpacity(
                      opacity: blackout ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: const ColoredBox(color: Colors.black),
                    );
                  },
                ),

                // Overlay controls.
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _buildControls(context),
                  ),
                ),

                // Scene Editor side panel (PIN-gated).
                if (_editorOpen) ...[
                  // Scrim behind the drawer.
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: _closeEditor,
                      child: const ColoredBox(color: Colors.black38),
                    ),
                  ),
                  // Drawer itself.
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: SceneEditorDrawer(
                      controller: widget.controller,
                      markStart: _markStart,
                      markEnd: _markEnd,
                      onPreview: _previewSegment,
                      onClose: _closeEditor,
                      onClearMarks: _clearMarks,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    return Column(
      children: [
        // Top gradient bar: back, title, active-filter badge, editor, fullscreen.
        _TopBar(
          title: widget.title ?? 'Safe Scene',
          segment: widget.controller.currentSegment.value,
          fullscreen: _fullscreen,
          editorOpen: _editorOpen,
          onBack: () => Navigator.of(context).maybePop(),
          onEdit: _openEditor,
          onFullscreen: _toggleFullscreen,
        ),
        const Spacer(),
        // Center play / pause.
        _PlayPauseButton(
          playing: _playing,
          onPressed: widget.controller.togglePlay,
        ),
        const Spacer(),
        // Bottom bar: custom timeline seek bar + time + volume.
        _BottomBar(
          position: _position,
          duration: _duration,
          volume: _volume,
          segments: widget.controller.segments,
          onSeek: (d) => widget.controller.seek(d),
          onVolume: (v) => widget.controller.setVolume(v),
        ),
      ],
    );
  }
}

/// A small spinning indicator shown while the media is buffering.
class _BufferingIndicator extends StatelessWidget {
  const _BufferingIndicator();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 48,
        height: 48,
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );
  }
}

/// The top gradient overlay bar with back button, title, active filter badge,
/// the Scene Editor toggle and the fullscreen toggle.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.segment,
    required this.fullscreen,
    required this.editorOpen,
    required this.onBack,
    required this.onEdit,
    required this.onFullscreen,
  });

  final String title;
  final FilterSegment? segment;
  final bool fullscreen;
  final bool editorOpen;
  final VoidCallback onBack;
  final VoidCallback onEdit;
  final VoidCallback onFullscreen;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: 'Back',
            onPressed: onBack,
          ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (segment != null) _ActiveFilterBadge(segment: segment!),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              editorOpen ? Icons.edit_off : Icons.edit,
              color: editorOpen ? Colors.lightBlueAccent : Colors.white,
            ),
            tooltip: editorOpen ? 'Close Scene Editor (E)' : 'Scene Editor (E)',
            onPressed: onEdit,
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: Icon(
              fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              color: Colors.white,
            ),
            tooltip: fullscreen ? 'Exit fullscreen (Esc)' : 'Fullscreen (F)',
            onPressed: onFullscreen,
          ),
        ],
      ),
    );
  }
}

/// Small pill that identifies the rule currently being enforced.
class _ActiveFilterBadge extends StatelessWidget {
  const _ActiveFilterBadge({required this.segment});

  final FilterSegment segment;

  @override
  Widget build(BuildContext context) {
    final Color color;
    switch (segment.action) {
      case FilterAction.skip:
        color = Colors.redAccent;
      case FilterAction.mute:
        color = Colors.amber;
      case FilterAction.blackout:
        color = Colors.deepPurpleAccent;
    }
    final icon = switch (segment.action) {
      FilterAction.skip => Icons.fast_forward,
      FilterAction.mute => Icons.volume_off,
      FilterAction.blackout => Icons.visibility_off,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            segment.category,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// The centered play / pause control.
class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.playing, required this.onPressed});

  final bool playing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Icon(
              playing ? Icons.pause : Icons.play_arrow,
              size: 56,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// The bottom gradient bar with the custom timeline seek bar, time labels and
/// the volume control.
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.position,
    required this.duration,
    required this.volume,
    required this.segments,
    required this.onSeek,
    required this.onVolume,
  });

  final Duration position;
  final Duration duration;
  final double volume;
  final List<FilterSegment> segments;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolume;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                formatTimestamp(position),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SafeSeekBarWidget(
                  position: position,
                  duration: duration,
                  segments: segments,
                  onSeek: onSeek,
                  height: 44,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatTimestamp(duration),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
          Row(
            children: [
              Icon(
                volume == 0 ? Icons.volume_off : Icons.volume_up,
                color: Colors.white,
                size: 20,
              ),
              Expanded(
                child: Slider(value: volume, max: 100, onChanged: onVolume),
              ),
              Text(
                '${volume.round()}%',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Formats a [Duration] as `h:mm:ss` or `m:ss`.
String formatTimestamp(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  String two(int n) => n.toString().padLeft(2, '0');
  if (h > 0) return '$h:${two(m)}:${two(s)}';
  return '${two(m)}:${two(s)}';
}
