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
    _playingSub = player.stream.playing.listen((playing) {
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
  StreamSubscription<bool>? _playingSub;
  Timer? _fadeTimer;

  bool _isDisposed = false;
  bool get isDisposed => _isDisposed;

  /// The enforced segments (read only, sorted by start time).
  List<FilterSegment> get segments => List.unmodifiable(_segments);

  /// Stable per-segment identity, regardless of whether an explicit `id` is
  /// present. Used so editing/deleting a rule is never ambiguous even when two
  /// rules share the same `start`/`end`/`action`.
  static String _identityOf(FilterSegment s) {
    return s.id ??
        '${s.start.inMilliseconds}:${s.end.inMilliseconds}:${s.action.label}';
  }

  int _indexOfId(String id) {
    for (var i = 0; i < _segments.length; i++) {
      if (_segments[i].id != null && _segments[i].id == id) return i;
    }
    return -1;
  }

  int _indexOfSegment(FilterSegment segment) {
    final identity = _identityOf(segment);
    for (var i = 0; i < _segments.length; i++) {
      if (_identityOf(_segments[i]) == identity) return i;
    }
    return -1;
  }

  /// Keeps the enforced list ordered by start time (then end, then action).
  void _sortSegments() {
    _segments.sort((a, b) {
      final c = a.start.compareTo(b.start);
      if (c != 0) return c;
      final d = a.end.compareTo(b.end);
      if (d != 0) return d;
      return a.action.index.compareTo(b.action.index);
    });
  }

  String _newId() => 'manual_${DateTime.now().microsecondsSinceEpoch}';

  /// Adds [segment] to the enforced rule set (kept sorted by start time).
  void addSegment(FilterSegment segment) {
    final withId = (segment.id == null || segment.id!.isEmpty)
        ? segment.copyWith(id: _newId())
        : segment;
    _segments.add(withId);
    _sortSegments();
    _notifySegments();
    _refreshState();
  }

  /// Removes the first segment equal to [segment] from the rule set.
  void removeSegment(FilterSegment segment) {
    final index = _indexOfSegment(segment);
    if (index < 0) return;
    final removed = _segments.removeAt(index);
    _activeMutes.remove(removed);
    _skipped.remove(removed);
    _notifySegments();
    _refreshState();
  }

  /// Removes the segment carrying [id].
  void removeSegmentById(String id) {
    final index = _indexOfId(id);
    if (index < 0) return;
    final removed = _segments.removeAt(index);
    _activeMutes.remove(removed);
    _skipped.remove(removed);
    _notifySegments();
    _refreshState();
  }

  /// Replaces [old] with [updated] in the rule set. No-op if [old] is absent.
  void updateSegment(FilterSegment old, FilterSegment updated) {
    final index = _indexOfSegment(old);
    if (index < 0) return;
    _segments[index] = updated;
    _sortSegments();
    _notifySegments();
    _refreshState();
  }

  /// Replaces the segment carrying [oldId] with [updated].
  void updateSegmentById(String oldId, FilterSegment updated) {
    final index = _indexOfId(oldId);
    if (index < 0) return;
    _segments[index] = updated;
    _sortSegments();
    _notifySegments();
    _refreshState();
  }

  /// Sets the enabled flag of the segment carrying [id] (no-op when absent).
  void setSegmentEnabled(String id, bool enabled) {
    final index = _indexOfId(id);
    if (index < 0) return;
    final segment = _segments[index];
    _segments[index] = segment.copyWith(enabled: enabled);
    if (!enabled) {
      // A disabled skip/mute must be allowed to fire again once re-enabled.
      _skipped.remove(segment);
      _activeMutes.remove(segment);
      if (_activeMutes.isEmpty && _restoreVolume != 100.0) {
        player.setVolume(_restoreVolume);
      }
    }
    _notifySegments();
    _refreshState();
  }

  /// Inserts an independent copy of [segment] (new id, kept as `manual`).
  FilterSegment duplicateSegment(FilterSegment segment) {
    final copy = segment.copyWith(
      id: _newId(),
      source: 'manual',
    );
    addSegment(copy);
    return copy;
  }

  /// Clears all segments and replaces them with [segments].
  void replaceSegments(List<FilterSegment> segments) {
    _segments
      ..clear()
      ..addAll(segments);
    _sortSegments();
    _skipped.clear();
    _activeMutes.clear();
    if (_activeMutes.isEmpty) player.setVolume(_restoreVolume);
    _notifySegments();
    _refreshState();
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
      if (!segment.enabled) continue;
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

  /// Re-applies the current playback position against the rules *without*
  /// issuing any re-seeks. Called after every editor mutation so that a rule
  /// that was just disabled — or a mute whose window just moved — takes effect
  /// immediately, instead of waiting for the next position tick.
  void _refreshState() {
    final position = player.state.position;

    // (Re)start any mute segment that now contains the position.
    for (final segment in _segments) {
      if (!segment.enabled) continue;
      if (segment.action == FilterAction.mute && segment.contains(position)) {
        _handleMute(segment);
      }
    }

    // Release mutes that are no longer applicable (disabled, removed or left).
    for (final muted in List<FilterSegment>.of(_activeMutes)) {
      if (!_segments.contains(muted) ||
          !muted.enabled ||
          !muted.contains(position)) {
        _releaseMute(muted);
      }
    }

    // Recompute the active badge exactly like [_onPosition] (first rule, in
    // sorted order, that contains the position).
    FilterSegment? active;
    for (final segment in _segments) {
      if (!segment.enabled) continue;
      if (segment.contains(position)) {
        active ??= segment;
      }
    }
    currentSegment.value = active;
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
    await _playingSub?.cancel();
    _activeMutes.clear();
    currentSegment.dispose();
    isFading.dispose();
    segmentsNotifier.dispose();
    await player.dispose();
  }
}
