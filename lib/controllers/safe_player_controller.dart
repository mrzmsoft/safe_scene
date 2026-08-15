import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../models/filter_segment.dart';

/// High level controller that wraps a media_kit [Player] and automatically
/// enforces a set of [FilterSegment] rules against the live playback position.
///
/// Listens to `player.stream.position` and:
/// * **skip**     - seeks straight to `segment.end` and flashes the fade overlay
///                 (via [isFading]) to mask the jump.
/// * **mute**     - remembers the current volume, mutes, and restores it the
///                 moment the position leaves the segment.
/// * **blackout** - only exposed through [currentSegment] so the UI layer can
///                 hide the video surface for the window.
class SafePlayerController {
  SafePlayerController({
    List<FilterSegment> segments = const [],
    void Function(FilterSegment segment)? onSkip,
  }) : player = Player(),
       _segments = List.of(segments),
       _onSkip = onSkip {
    segmentsNotifier.value = List.unmodifiable(_segments);
    _positionSub = player.stream.position.listen(_onPosition);

    // If the current media is swapped or playback stops, make sure any active
    // mute is released so the next file starts at a healthy volume.
    player.stream.playing.listen((playing) {
      if (!playing) {
        _releaseAllMutes();
      }
    });
  }

  /// The underlying media_kit [Player]. Exposed so the UI can attach a
  /// `package:media_kit_video` [VideoController] to it for rendering.
  final Player player;

  /// The set of rules being enforced (mutable so the Scene Editor can edit
  /// the list at runtime).
  final List<FilterSegment> _segments;

  /// Emits the current (read only) segment list so the seek bar and the Scene
  /// Editor drawer can rebuild whenever a segment is added / edited / deleted.
  final ValueNotifier<List<FilterSegment>> segmentsNotifier =
      ValueNotifier<List<FilterSegment>>(const []);

  /// Optional callback fired right after a skip occurs.
  final void Function(FilterSegment segment)? _onSkip;

  /// The segment the playback position is currently inside of, if any.
  ///
  /// The UI can watch this to render the blackout overlay, show a badge, etc.
  final ValueNotifier<FilterSegment?> currentSegment =
      ValueNotifier<FilterSegment?>(null);

  /// Briefly set to `true` when a skip happens so the UI can render a quick
  /// black fade that hides the jump cut. Automatically flips back to `false`.
  final ValueNotifier<bool> isFading = ValueNotifier<bool>(false);

  /// Segments that are currently keeping the volume muted.
  final Set<FilterSegment> _activeMutes = <FilterSegment>{};

  /// Segments that have already been skipped for the current pass, preventing
  /// repeated seeks while the position is (briefly) still inside the window.
  final Set<FilterSegment> _skipped = <FilterSegment>{};

  /// Volume (0-100) to restore after every active mute has ended.
  double _restoreVolume = 100.0;

  StreamSubscription<Duration>? _positionSub;
  Timer? _fadeTimer;

  bool _isDisposed = false;
  bool get isDisposed => _isDisposed;

  /// The enforced segments (read only).
  List<FilterSegment> get segments => List.unmodifiable(_segments);

  /// Adds [segment] to the enforced rule set.
  void addSegment(FilterSegment segment) {
    _segments.add(segment);
    _notifySegments();
  }

  /// Removes the first segment equal to [segment] from the rule set.
  void removeSegment(FilterSegment segment) {
    final index = _indexOf(segment);
    if (index >= 0) _segments.removeAt(index);
    _notifySegments();
  }

  /// Replaces [old] with [updated] in the rule set. No-op if [old] is absent.
  void updateSegment(FilterSegment old, FilterSegment updated) {
    final index = _indexOf(old);
    if (index >= 0) _segments[index] = updated;
    _notifySegments();
  }

  /// Clears all segments and replaces them with [segments].
  void replaceSegments(List<FilterSegment> segments) {
    _segments
      ..clear()
      ..addAll(segments);
    _notifySegments();
  }

  int _indexOf(FilterSegment segment) {
    for (var i = 0; i < _segments.length; i++) {
      if (_segments[i] == segment) return i;
    }
    return -1;
  }

  void _notifySegments() {
    segmentsNotifier.value = List.unmodifiable(_segments);
  }

  /// Opens and loads [media] into the player. If [play] is true playback
  /// starts immediately.
  Future<void> open(Media media, {bool play = true}) {
    _releaseAllMutes();
    _skipped.clear();
    return player.open(media, play: play);
  }

  /// Resolves a media path and opens it. See [open].
  Future<void> openPath(String path, {bool play = true}) {
    return open(Media(path), play: play);
  }

  // Convenience wrappers around the underlying [Player].

  Future<void> play() => player.play();
  Future<void> pause() => player.pause();
  Future<void> togglePlay() => player.playOrPause();
  Future<void> seek(Duration position) => player.seek(position);
  Future<void> stop() => player.stop();
  Future<void> setVolume(double volume) => player.setVolume(volume);

  /// Evaluates each position update against the rule set.
  void _onPosition(Duration position) {
    FilterSegment? active;

    for (final segment in _segments) {
      final inside = segment.contains(position);

      switch (segment.action) {
        case FilterAction.skip:
          if (inside) {
            // Defensive: guard against re-seeking until we actually leave the
            // window. After `player.seek(end)` the position lands on `end`
            // which is outside the half-open segment, so this only matters for
            // the frames between the decision and the real seek landing.
            if (!_skipped.contains(segment)) {
              _skipped.add(segment);
              _handleSkip(segment);
            }
            active ??= segment;
          } else {
            _skipped.remove(segment);
          }
          break;

        case FilterAction.mute:
          if (inside) {
            _handleMute(segment);
            active ??= segment;
          } else {
            _releaseMute(segment);
          }
          break;

        case FilterAction.blackout:
          if (inside) active ??= segment;
          break;
      }
    }

    currentSegment.value = active;
  }

  void _handleSkip(FilterSegment segment) {
    _triggerFade();

    // Note: media_kit 1.2.6's `Player.seek` has no `exact` named parameter;
    // libmpv already performs accurate (non keyframe-snapped) seeking by
    // default, so this is equivalent to the requested `seek(end, exact: true)`.
    player
        .seek(segment.end)
        .then((_) {
          _onSkip?.call(segment);
        })
        .catchError((Object error, StackTrace stack) {
          debugPrint('SafeScene: skip seek failed: $error');
        });
  }

  void _handleMute(FilterSegment segment) {
    if (_activeMutes.add(segment)) {
      // First segment to start muting: remember the volume we must restore.
      _restoreVolume = player.state.volume;
      player.setVolume(0);
    }
  }

  void _releaseMute(FilterSegment segment) {
    if (_activeMutes.remove(segment) && _activeMutes.isEmpty) {
      player.setVolume(_restoreVolume);
    }
  }

  void _releaseAllMutes() {
    if (_activeMutes.isNotEmpty) {
      _activeMutes.clear();
      player.setVolume(_restoreVolume);
    }
  }

  /// Flips [isFading] on, then schedules it back off shortly after.
  void _triggerFade() {
    _fadeTimer?.cancel();
    isFading.value = true;
    _fadeTimer = Timer(const Duration(milliseconds: 260), () {
      if (!isDisposed) isFading.value = false;
    });
  }

  /// Releases all subscriptions, notifiers and the underlying [Player].
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    _fadeTimer?.cancel();
    await _positionSub?.cancel();
    _activeMutes.clear();
    currentSegment.dispose();
    isFading.dispose();
    segmentsNotifier.dispose();
    await player.dispose();
  }
}
