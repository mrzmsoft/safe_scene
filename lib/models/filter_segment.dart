/// The action that Safe Scene should take while playback passes through a
/// flagged [FilterSegment].
///
/// * [skip]     - jump straight past the segment (seek to its end).
/// * [mute]     - keep playing picture but silence the audio for the window.
/// * [blackout] - keep audio but hide the explicit video content in the UI.
enum FilterAction {
  skip('skip'),
  mute('mute'),
  blackout('blackout');

  const FilterAction(this.label);

  /// The canonical string used in `.safe` / `.safe.json` files.
  final String label;

  /// Parses a [FilterAction] from its serialized string.
  ///
  /// Throws a [FormatException] for unknown values so corrupt rule files fail
  /// loudly instead of silently weakening the filter.
  static FilterAction fromLabel(String label) {
    for (final action in FilterAction.values) {
      if (action.label == label) return action;
    }
    throw FormatException('Unknown FilterAction: "$label"');
  }
}

/// A single flagged time window inside a media file.
///
/// Mirrors one entry of the `segments` array in the `movie.safe.json`
/// specification documented in `ROADMAP.md`.
class FilterSegment {
  const FilterSegment({
    required this.start,
    required this.end,
    required this.action,
    required this.category,
    required this.source,
    this.id,
    this.confidence,
    this.enabled = true,
  });

  /// Optional machine readable identifier (e.g. `seg_001`).
  final String? id;

  /// Start of the flagged window (inclusive).
  final Duration start;

  /// End of the flagged window (exclusive).
  final Duration end;

  /// What to do while the playback position is inside `[start, end)`.
  final FilterAction action;

  /// Human/ML readable category, e.g. `explicit_nudity`, `profanity`.
  final String category;

  /// Origin of the rule, e.g. `ai_nudenet`, `ai_whisper`, `manual`.
  final String source;

  /// Optional detection confidence in the range `[0.0, 1.0]`.
  final double? confidence;

  /// Whether this rule is currently enforced. Disabled segments stay in the
  /// editor (so they can be fine-tuned / re-activated later) but are ignored
  /// by the player and painted faded on the timelines.
  ///
  /// Backwards-compatible JSON: `enabled` is only serialized when `false`;
  /// readers default to `true` when the key is absent.
  final bool enabled;

  /// Total length of the flagged window.
  Duration get length => end - start;

  /// Whether [position] falls inside this segment: `start <= t < end`.
  bool contains(Duration position) {
    return !position.isNegative && position >= start && position < end;
  }

  /// True when the two half-open windows intersect (`start < other.end` and
  /// `other.start < end`) — the condition the player enforce logic cares about.
  bool overlapsWith(FilterSegment other) {
    return start < other.end && other.start < end;
  }

  /// Returns a copy with any of the fields replaced.
  FilterSegment copyWith({
    String? id,
    Duration? start,
    Duration? end,
    FilterAction? action,
    String? category,
    String? source,
    double? confidence,
    bool? enabled,
  }) {
    return FilterSegment(
      id: id ?? this.id,
      start: start ?? this.start,
      end: end ?? this.end,
      action: action ?? this.action,
      category: category ?? this.category,
      source: source ?? this.source,
      confidence: confidence ?? this.confidence,
      enabled: enabled ?? this.enabled,
    );
  }

  /// Deserializes a [FilterSegment] from the `movie.safe.json` schema.
  factory FilterSegment.fromJson(Map<String, dynamic> json) {
    return FilterSegment(
      id: json['id'] as String?,
      start: Duration(milliseconds: (json['start_ms'] as num).toInt()),
      end: Duration(milliseconds: (json['end_ms'] as num).toInt()),
      action: FilterAction.fromLabel(json['action'] as String),
      category: json['category'] as String? ?? '',
      source: json['source'] as String? ?? '',
      confidence: (json['confidence'] as num?)?.toDouble(),
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  /// Serializes this segment to the `movie.safe.json` schema.
  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'start_ms': start.inMilliseconds,
      'end_ms': end.inMilliseconds,
      'action': action.label,
      'category': category,
      'source': source,
      if (confidence != null) 'confidence': confidence,
      if (!enabled) 'enabled': false,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is FilterSegment &&
        other.start == start &&
        other.end == end &&
        other.action == action;
  }

  @override
  int get hashCode => Object.hash(start, end, action);

  @override
  String toString() {
    final from = _format(start);
    final to = _format(end);
    return 'FilterSegment($action, $from → $to, $category)';
  }
}

String _format(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return '${two(h)}:${two(m)}:${two(s)}';
}
