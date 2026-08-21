import '../models/filter_segment.dart' show FilterAction, FilterSegment;

/// The active stage of a scanner run, surfaced to the UI so the dialog can show
/// a meaningful "Audio / Video" label rather than just a bare percentage.
enum ScanPhase {
  preparing('Preparing'),
  audio('Audio'),
  video('Video'),
  finalizing('Finalizing'),
  done('Done');

  const ScanPhase(this.label);

  /// Human readable label for the phase badge.
  final String label;
}

/// A single snapshot of scanner progress, streamed live to the UI.
///
/// [percentage] always lies in `[0.0, 1.0]`. The counter fields are the raw
/// detections reported by the engine so far (frames flagged / profanity hits);
/// [segmentsFound] additionally reflects the merged segment count as soon as
/// the final `RESULT` has been parsed.
class ScanProgress {
  const ScanProgress({
    required this.percentage,
    required this.phase,
    this.visualFlagged = 0,
    this.profanityFlagged = 0,
    this.segmentsFound = 0,
    this.message = '',
  });

  /// Helper for the "nothing happened yet" state.
  const ScanProgress.initial()
      : this(
          percentage: 0.0,
          phase: ScanPhase.preparing,
          message: 'Starting scanner…',
        );

  final double percentage;
  final ScanPhase phase;
  final int visualFlagged;
  final int profanityFlagged;
  final int segmentsFound;
  final String message;

  /// Total raw detections seen so far.
  int get detected => visualFlagged + profanityFlagged;

  /// Whether the run has fully finished (either a RESULT was parsed or the
  /// reported percentage reached 1.0).
  bool get isDone => phase == ScanPhase.done || percentage >= 1.0;

  ScanProgress copyWith({
    double? percentage,
    ScanPhase? phase,
    int? visualFlagged,
    int? profanityFlagged,
    int? segmentsFound,
    String? message,
  }) {
    return ScanProgress(
      percentage: percentage ?? this.percentage,
      phase: phase ?? this.phase,
      visualFlagged: visualFlagged ?? this.visualFlagged,
      profanityFlagged: profanityFlagged ?? this.profanityFlagged,
      segmentsFound: segmentsFound ?? this.segmentsFound,
      message: message ?? this.message,
    );
  }

  @override
  String toString() =>
      'ScanProgress(${phase.label}, ${(percentage * 100).toStringAsFixed(1)}%, '
      'v=$visualFlagged p=$profanityFlagged seg=$segmentsFound)';
}

/// The structured outcome of a completed scan, parsed from the engine's
/// `RESULT:<json>` payload (same schema as `movie.safe.json`).
class ScanResult {
  const ScanResult({
    required this.mediaTitle,
    required this.mediaHash,
    required this.durationMs,
    required this.segments,
    this.raw,
  });

  final String mediaTitle;
  final String mediaHash;
  final int durationMs;
  final List<FilterSegment> segments;
  final Map<String, dynamic>? raw;

  /// Number of visual ("skip") segments in the final result.
  int get visualCount =>
      segments.where((s) => s.action == FilterAction.skip).length;

  /// Number of profanity ("mute") segments in the final result.
  int get profanityCount =>
      segments.where((s) => s.action == FilterAction.mute).length;

  /// Deserializes a `ScanResult` from the `movie.safe.json` schema.
  factory ScanResult.fromJson(Map<String, dynamic> json) {
    final rawSegments = json['segments'] as List<dynamic>? ?? const [];
    final segments = rawSegments
        .map((e) => FilterSegment.fromJson(e as Map<String, dynamic>))
        .toList();
    return ScanResult(
      mediaTitle: json['media_title'] as String? ?? '',
      mediaHash: json['media_hash'] as String? ?? '',
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
      segments: segments,
      raw: json,
    );
  }

  @override
  String toString() =>
      'ScanResult($mediaTitle, ${segments.length} segments)';
}