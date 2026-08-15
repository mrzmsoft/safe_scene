import 'package:flutter/material.dart';

import '../models/filter_segment.dart';

/// A custom timeline seek bar that replaces the standard Material [Slider].
///
/// Paints a thin progress track with coloured vertical bands for every
/// flagged segment (red for `skip`, yellow for `mute`). Hovering over a band
/// shows a tooltip with the segment's timestamp range and category name.
class SafeSeekBarWidget extends StatefulWidget {
  const SafeSeekBarWidget({
    super.key,
    required this.position,
    required this.duration,
    required this.segments,
    required this.onSeek,
    this.trackHeight = 4,
    this.height = 44,
  });

  /// Current playback position.
  final Duration position;

  /// Total media length (used to scale the bands).
  final Duration duration;

  /// Flagged segments rendered as coloured bands.
  final List<FilterSegment> segments;

  /// Invoked with the target [Duration] when the user scrubs the bar.
  final ValueChanged<Duration> onSeek;

  /// Thickness of the progress track in logical pixels.
  final double trackHeight;

  /// Total height of the widget (leaves room for the hover tooltip above the
  /// track).
  final double height;

  @override
  State<SafeSeekBarWidget> createState() => _SafeSeekBarWidgetState();
}

class _SafeSeekBarWidgetState extends State<SafeSeekBarWidget> {
  double? _hoverFraction;
  bool get _hasDuration => widget.duration > Duration.zero;
  static const double _tooltipWidth = 220;

  void _seekAt(double dx, double width) {
    if (!_hasDuration) return;
    final fraction = (dx / width).clamp(0.0, 1.0);
    final target = Duration(
      milliseconds: (fraction * widget.duration.inMilliseconds).round(),
    );
    widget.onSeek(target);
  }

  FilterSegment? _segmentAt(double fraction) {
    if (!_hasDuration) return null;
    final ms = (fraction * widget.duration.inMilliseconds).round();
    final pos = Duration(milliseconds: ms);
    for (final segment in widget.segments) {
      if (segment.contains(pos)) return segment;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final trackY = widget.height - widget.trackHeight - 6;
          final progress = _hasDuration
              ? (widget.position.inMilliseconds /
                      widget.duration.inMilliseconds)
                  .clamp(0.0, 1.0)
              : 0.0;
          final hoverFraction = _hoverFraction;
          final hoverSegment =
              hoverFraction == null ? null : _segmentAt(hoverFraction);

          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              if (hoverSegment != null && hoverFraction != null)
                Positioned(
                  top: 0,
                  left:
                      (hoverFraction * width - _tooltipWidth / 2)
                          .clamp(0.0, width - _tooltipWidth),
                  child: _SegmentTooltip(segment: hoverSegment),
                ),
              Positioned(
                left: 0,
                right: 0,
                top: trackY - widget.trackHeight / 2 - 14,
                bottom: 0,
                child: _buildTrack(width, progress),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTrack(double width, double progress) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => _seekAt(details.localPosition.dx, width),
      onHorizontalDragStart: (details) =>
          _seekAt(details.localPosition.dx, width),
      onHorizontalDragUpdate: (details) =>
          _seekAt(details.localPosition.dx, width),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onHover: (event) => setState(() {
          _hoverFraction = (event.localPosition.dx / width).clamp(0.0, 1.0);
        }),
        onExit: (_) => setState(() => _hoverFraction = null),
        child: CustomPaint(
          size: Size.infinite,
          painter: _SeekBarPainter(
            progress: progress,
            segments: widget.segments,
            durationMs: widget.duration.inMilliseconds.toDouble(),
            trackY: widget.trackHeight,
            trackHeight: widget.trackHeight,
          ),
        ),
      ),
    );
  }
}
/// The [CustomPainter] that renders the track, progress fill and segment bands.
class _SeekBarPainter extends CustomPainter {
  const _SeekBarPainter({
    required this.progress,
    required this.segments,
    required this.durationMs,
    required this.trackY,
    required this.trackHeight,
  });

  final double progress;
  final List<FilterSegment> segments;
  final double durationMs;
  final double trackY;
  final double trackHeight;

  @override
  void paint(Canvas canvas, Size size) {
    if (durationMs <= 0) return;
    final centerY = size.height - trackY / 2 - 6;

    // Background track.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, centerY - trackHeight / 2, size.width, trackHeight),
        Radius.circular(trackHeight / 2),
      ),
      Paint()..color = Colors.white24,
    );

    // Progress fill.
    final filledWidth = size.width * progress.clamp(0.0, 1.0);
    if (filledWidth > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, centerY - trackHeight / 2, filledWidth, trackHeight),
          Radius.circular(trackHeight / 2),
        ),
        Paint()..color = const Color(0xFF0EA5E9),
      );
    }

    // Segment bands.
    for (final segment in segments) {
      final start = segment.start.inMilliseconds.toDouble();
      final end = segment.end.inMilliseconds.toDouble();
      if (end < 0 || start > durationMs) continue;
      final begin = (start / durationMs * size.width).clamp(0.0, size.width);
      final finish = (end / durationMs * size.width).clamp(0.0, size.width);
      if (finish < begin) continue;

      final color = switch (segment.action) {
        FilterAction.skip => const Color(0xFFEF4444),
        FilterAction.mute => const Color(0xFFFBBF24),
        FilterAction.blackout => const Color(0xFF8B5CF6),
      };

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            begin,
            centerY - trackHeight / 2 - 6,
            (finish - begin).clamp(2.0, size.width),
            trackHeight + 12,
          ),
          const Radius.circular(4),
        ),
        Paint()..color = color.withValues(alpha: 0.28),
      );

      final linePaint = Paint()..color = color..strokeWidth = 2;
      canvas.drawLine(
        Offset(begin, centerY - trackHeight / 2 - 6),
        Offset(begin, centerY + trackHeight / 2 + 6),
        linePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SeekBarPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.segments != segments ||
        oldDelegate.durationMs != durationMs ||
        oldDelegate.trackY != trackY ||
        oldDelegate.trackHeight != trackHeight;
  }
}
/// Small floating bubble shown while hovering over a flagged segment band.
class _SegmentTooltip extends StatelessWidget {
  const _SegmentTooltip({required this.segment});

  final FilterSegment segment;

  @override
  Widget build(BuildContext context) {
    final color = switch (segment.action) {
      FilterAction.skip => const Color(0xFFEF4444),
      FilterAction.mute => const Color(0xFFFBBF24),
      FilterAction.blackout => const Color(0xFF8B5CF6),
    };
    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xEE1E293B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  segment.category.isEmpty ? segment.action.label : segment.category,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${_format(segment.start)} – ${_format(segment.end)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _format(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) return '$h:${two(m)}:${two(s)}';
  return '${two(m)}:${two(s)}';
}