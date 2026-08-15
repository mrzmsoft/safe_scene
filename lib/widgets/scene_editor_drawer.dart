import 'package:flutter/material.dart';

import '../controllers/safe_player_controller.dart';
import '../models/filter_segment.dart';

/// A side panel for reviewing, searching and precisely controlling every
/// flagged [FilterSegment].
///
/// Goes beyond the base scene list:
///  * per-action filter chips + text search + sorting
///  * a clickable mini timeline map scaled to the whole movie
///  * per-rule enable/disable switch (rules can be paused, not just deleted)
///  * precise time editing — preset steps (100 ms / 500 ms / 1 s / 5 s),
///    typeable HH:MM:SS.mmm fields and "set to playhead" sync
///  * jump-to-boundary previews, duplicate, split-at-playhead, clear-all
///  * overlap validation so rules never clash accidentally
class SceneEditorDrawer extends StatefulWidget {
  const SceneEditorDrawer({
    super.key,
    required this.controller,
    this.markStart,
    this.markEnd,
    required this.onPreview,
    required this.onClose,
    this.onClearMarks,
    this.onSeek,
    this.duration = Duration.zero,
    this.width = 380,
  });

  /// The filter-aware playback controller owning the rule set.
  final SafePlayerController controller;

  /// Marked `[start]` for a new segment (set from the player with `[`).
  final Duration? markStart;

  /// Marked `]end]` for a new segment (set from the player with `]`).
  final Duration? markEnd;

  /// Seeks to the segment start (3 s lead-in) and plays it.
  final ValueChanged<FilterSegment> onPreview;

  /// Closes the editor panel.
  final VoidCallback onClose;

  /// Clears the in-progress `[start]`-`]end]` marks.
  final VoidCallback? onClearMarks;

  /// Precise seek used by boundary jumps and mini-map taps.
  final ValueChanged<Duration>? onSeek;

  /// Total media length (drives the mini timeline map).
  final Duration duration;

  /// Panel width in logical pixels.
  final double width;

  @override
  State<SceneEditorDrawer> createState() => _SceneEditorDrawerState();
}

enum _SegmentSort { timeAsc, timeDesc, longest }

class _SceneEditorDrawerState extends State<SceneEditorDrawer> {
  FilterAction? _actionFilter; // null == all actions
  bool _searchOpen = false;
  String _query = '';
  _SegmentSort _sort = _SegmentSort.timeAsc;

  Duration get _duration => widget.duration;

  void _seek(Duration target) {
    if (widget.onSeek != null) {
      widget.onSeek!(target);
    } else {
      widget.controller.seek(target);
    }
  }

  List<FilterSegment> _filterAndSort(List<FilterSegment> all) {
    final q = _query.trim().toLowerCase();
    final out = all.where((s) {
      if (_actionFilter != null && s.action != _actionFilter) return false;
      if (q.isEmpty) return true;
      return s.category.toLowerCase().contains(q) ||
          s.source.toLowerCase().contains(q) ||
          (s.id?.toLowerCase().contains(q) ?? false);
    }).toList();
    switch (_sort) {
      case _SegmentSort.timeAsc:
        out.sort((a, b) {
          final c = a.start.compareTo(b.start);
          return c != 0 ? c : a.end.compareTo(b.end);
        });
      case _SegmentSort.timeDesc:
        out.sort((a, b) {
          final c = b.start.compareTo(a.start);
          return c != 0 ? c : b.end.compareTo(a.end);
        });
      case _SegmentSort.longest:
        out.sort((a, b) => b.length.compareTo(a.length));
    }
    return out;
  }

  void _deleteSegment(FilterSegment segment) {
    widget.controller.removeSegment(segment);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          'Deleted ${_actionName(segment.action)} '
          '${_formatMs(segment.start)}–${_formatMs(segment.end)}',
        ),
      ),
    );
  }

  void _duplicate(FilterSegment segment) {
    widget.controller.duplicateSegment(segment);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Segment duplicated')),
    );
  }

  void _toggleEnabled(FilterSegment segment) {
    if (segment.id == null) return;
    widget.controller.setSegmentEnabled(segment.id!, !segment.enabled);
  }

  void _clearAll() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text(
          'Clear all segments?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'This removes every rule from the current list. It cannot be undone.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              widget.controller.replaceSegments(const []);
              Navigator.of(ctx).pop();
            },
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
  }

  void _editSegment(FilterSegment segment) {
    showDialog<void>(
      context: context,
      builder: (_) => _SegmentEditDialog(
        controller: widget.controller,
        segment: segment,
        duration: _duration,
        onSeek: _seek,
      ),
    );
  }

  void _saveNewSegment(BuildContext context) {
    final start = widget.markStart;
    final end = widget.markEnd;
    if (start == null || end == null || start >= end) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Set both [start] and ]end] marks first.')),
      );
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => _NewSegmentDialog(
        controller: widget.controller,
        start: start,
        end: end,
        duration: _duration,
        onSeek: _seek,
        onSave: (segment) {
          widget.controller.addSegment(segment);
          Navigator.of(ctx).pop();
        },
      ),
    );
  }

@override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<FilterSegment>>(
      valueListenable: widget.controller.segmentsNotifier,
      builder: (context, segments, _) {
        return Container(
          width: widget.width,
          decoration: const BoxDecoration(
            color: Color(0xFF0F172A),
            border: Border(left: BorderSide(color: Colors.white12)),
          ),
          child: Column(
            children: [
              _buildHeader(context, segments),
              _buildStatsRow(segments),
              _buildFilterRow(),
              _SaveNewCard(
                markStart: widget.markStart,
                markEnd: widget.markEnd,
                onSave: () => _saveNewSegment(context),
                onClear: widget.onClearMarks ?? () {},
              ),
              if (_searchOpen) _buildSearchField(),
              if (_duration > Duration.zero)
                _SegmentMap(
                  segments: segments,
                  duration: _duration,
                  onSeek: _seek,
                ),
              const Divider(height: 1, color: Colors.white12),
              Expanded(child: _buildList(segments)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, List<FilterSegment> segments) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          const Icon(Icons.edit_note, color: Colors.white70, size: 20),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Scene Editor',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              _searchOpen ? Icons.search_off : Icons.search,
              color: Colors.white70,
              size: 20,
            ),
            tooltip: _searchOpen ? 'Hide search' : 'Search segments',
            onPressed: () => setState(() => _searchOpen = !_searchOpen),
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep, color: Colors.white70, size: 20),
            tooltip: 'Clear all segments',
            onPressed: segments.isEmpty ? null : _clearAll,
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70, size: 20),
            tooltip: 'Close editor (E)',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow(List<FilterSegment> segments) {
    final skip = segments.where((s) => s.action == FilterAction.skip).length;
    final mute = segments.where((s) => s.action == FilterAction.mute).length;
    final blackout =
        segments.where((s) => s.action == FilterAction.blackout).length;
    final off = segments.where((s) => !s.enabled).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          _LegendChip(
            color: const Color(0xFFEF4444),
            icon: Icons.fast_forward,
            label: '$skip skip',
          ),
          _LegendChip(
            color: const Color(0xFFFBBF24),
            icon: Icons.volume_off,
            label: '$mute mute',
          ),
          _LegendChip(
            color: const Color(0xFF8B5CF6),
            icon: Icons.visibility_off,
            label: '$blackout blackout',
          ),
          if (off > 0)
            _LegendChip(
              color: const Color(0xFF9CA3AF),
              icon: Icons.pause_circle_outline,
              label: '$off off',
            ),
        ],
      ),
    );
  }
    Widget _buildFilterRow() {
    final entries = <FilterAction?, String>{
      null: 'All',
      FilterAction.skip: 'Skip',
      FilterAction.mute: 'Mute',
      FilterAction.blackout: 'Blackout',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: entries.entries.map((e) {
                  final selected = _actionFilter == e.key;
                  final color = switch (e.key) {
                    FilterAction.skip => const Color(0xFFEF4444),
                    FilterAction.mute => const Color(0xFFFBBF24),
                    FilterAction.blackout => const Color(0xFF8B5CF6),
                    null => Colors.white70,
                  };
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(e.value, style: const TextStyle(fontSize: 12)),
                      labelStyle: TextStyle(
                        color: selected ? Colors.black : color,
                        fontWeight: FontWeight.w600,
                      ),
                      selected: selected,
                      selectedColor: color.withValues(alpha: 0.9),
                      backgroundColor: const Color(0xFF1E293B),
                      side: BorderSide(color: color.withValues(alpha: 0.4)),
                      onSelected: (_) => setState(() => _actionFilter = e.key),
                      visualDensity: VisualDensity.compact,
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          PopupMenuButton<_SegmentSort>(
            icon: const Icon(Icons.sort, color: Colors.white70, size: 20),
            tooltip: 'Sort segments',
            color: const Color(0xFF1E293B),
            initialValue: _sort,
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                value: _SegmentSort.timeAsc,
                child: Text('Time · first to last', style: TextStyle(color: Colors.white)),
              ),
              PopupMenuItem(
                value: _SegmentSort.timeDesc,
                child: Text('Time · last to first', style: TextStyle(color: Colors.white)),
              ),
              PopupMenuItem(
                value: _SegmentSort.longest,
                child: Text('Longest first', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: TextField(
        autofocus: true,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          hintText: 'Filter by category, source or id…',
          hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
          prefixIcon: const Icon(Icons.filter_list, color: Colors.white54, size: 18),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, color: Colors.white54, size: 16),
                  onPressed: () => setState(() => _query = ''),
                ),
          isDense: true,
          filled: true,
          fillColor: const Color(0xFF1E293B),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
        ),
        onChanged: (v) => setState(() => _query = v),
      ),
    );
  }

  Widget _buildList(List<FilterSegment> all) {
    final segments = _filterAndSort(all);
    if (all.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No flagged segments.\nUse [ and ] to mark, then save above.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ),
      );
    }
    if (segments.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No segments match the current filter.',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: segments.length,
      separatorBuilder: (_, _) => const Divider(height: 1, color: Colors.white12),
      itemBuilder: (context, index) {
        final segment = segments[index];
        return _SegmentTile(
          segment: segment,
          onEdit: () => _editSegment(segment),
          onDelete: () => _deleteSegment(segment),
          onDuplicate: () => _duplicate(segment),
          onPreview: () => widget.onPreview(segment),
          onToggleEnabled: () => _toggleEnabled(segment),
          onJumpToStart: () => _seek(segment.start),
        );
      },
    );
  }
}
/// One row in the filtered segment list.
class _SegmentTile extends StatelessWidget {
  const _SegmentTile({
    required this.segment,
    required this.onEdit,
    required this.onDelete,
    required this.onDuplicate,
    required this.onPreview,
    required this.onToggleEnabled,
    required this.onJumpToStart,
  });

  final FilterSegment segment;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onDuplicate;
  final VoidCallback onPreview;
  final VoidCallback onToggleEnabled;
  final VoidCallback onJumpToStart;

  Color get _color => switch (segment.action) {
        FilterAction.skip => const Color(0xFFEF4444),
        FilterAction.mute => const Color(0xFFFBBF24),
        FilterAction.blackout => const Color(0xFF8B5CF6),
      };

  @override
  Widget build(BuildContext context) {
    final dimmed = !segment.enabled;
    final confidence = segment.confidence;
    return Opacity(
      opacity: dimmed ? 0.55 : 1.0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: dimmed ? Colors.white24 : _color, width: 3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _ActionChip(action: segment.action, enabled: segment.enabled),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    segment.category.isEmpty
                        ? _actionName(segment.action)
                        : segment.category,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Switch(
                  value: segment.enabled,
                  onChanged: (_) => onToggleEnabled(),
                  activeTrackColor: _color,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${_formatMs(segment.start)} → ${_formatMs(segment.end)} · ${_formatLength(segment.length)}',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                _MetaChip(text: segment.source),
                if (confidence != null)
                  _MetaChip(
                    text: '${(confidence * 100).toStringAsFixed(0)}% conf',
                  ),
                if (dimmed) const _MetaChip(text: 'disabled'),
                const Spacer(),
                _TileButton(
                  icon: Icons.my_location,
                  tooltip: 'Jump to start',
                  onPressed: onJumpToStart,
                ),
                _TileButton(
                  icon: Icons.play_arrow,
                  tooltip: 'Preview (3s lead-in)',
                  onPressed: onPreview,
                ),
                _TileButton(
                  icon: Icons.content_copy,
                  tooltip: 'Duplicate',
                  onPressed: onDuplicate,
                ),
                _TileButton(icon: Icons.edit, tooltip: 'Edit', onPressed: onEdit),
                _TileButton(
                  icon: Icons.delete_outline,
                  tooltip: 'Delete',
                  onPressed: onDelete,
                  destructive: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
/// Tiny colored pill used in the header legend.
class _LegendChip extends StatelessWidget {
  const _LegendChip({
    required this.color,
    required this.icon,
    required this.label,
  });

  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact colored badge naming the action (skip / mute / blackout).
class _ActionChip extends StatelessWidget {
  const _ActionChip({required this.action, required this.enabled});

  final FilterAction action;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = switch (action) {
      FilterAction.skip => const Color(0xFFEF4444),
      FilterAction.mute => const Color(0xFFFBBF24),
      FilterAction.blackout => const Color(0xFF8B5CF6),
    };
    final icon = switch (action) {
      FilterAction.skip => Icons.fast_forward,
      FilterAction.mute => Icons.volume_off,
      FilterAction.blackout => Icons.visibility_off,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: enabled ? 0.25 : 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: enabled ? 0.7 : 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            _actionName(action),
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small muted text chip (source, confidence, …).
class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white38, fontSize: 10),
      ),
    );
  }
}

/// Compact icon action button used inside each tile.
class _TileButton extends StatelessWidget {
  const _TileButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.destructive = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? Colors.redAccent : Colors.white54;
    return IconButton(
      icon: Icon(icon, size: 16, color: color),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 26, height: 26),
      onPressed: onPressed,
    );
  }
}
/// A clickable strip painting every band scaled to the whole movie duration.
class _SegmentMap extends StatelessWidget {
  const _SegmentMap({
    required this.segments,
    required this.duration,
    required this.onSeek,
  });

  final List<FilterSegment> segments;
  final Duration duration;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: SizedBox(
        height: 26,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return GestureDetector(
              onTapDown: (details) {
                final durationMs = duration.inMilliseconds;
                if (durationMs <= 0) return;
                final dx = details.localPosition.dx.clamp(0.0, width);
                onSeek(
                  Duration(milliseconds: (dx / width * durationMs).round()),
                );
              },
              child: CustomPaint(
                size: Size(width, 26),
                painter: _SegmentMapPainter(
                  segments: segments,
                  durationMs: duration.inMilliseconds,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SegmentMapPainter extends CustomPainter {
  const _SegmentMapPainter({required this.segments, required this.durationMs});

  final List<FilterSegment> segments;
  final int durationMs;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, centerY - 2, size.width, 4),
        const Radius.circular(2),
      ),
      Paint()..color = const Color(0xFF334155),
    );
    for (final s in segments) {
      if (durationMs <= 0) continue;
      final begin = (s.start.inMilliseconds / durationMs * size.width)
          .clamp(0.0, size.width);
      final finish = (s.end.inMilliseconds / durationMs * size.width)
          .clamp(0.0, size.width);
      if (finish <= begin) continue;
      final color = switch (s.action) {
        FilterAction.skip => const Color(0xFFEF4444),
        FilterAction.mute => const Color(0xFFFBBF24),
        FilterAction.blackout => const Color(0xFF8B5CF6),
      };
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            begin,
            centerY - 6,
            (finish - begin).clamp(1.5, size.width),
            12,
          ),
          const Radius.circular(3),
        ),
        Paint()..color = color.withValues(alpha: s.enabled ? 0.55 : 0.15),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SegmentMapPainter old) =>
      old.segments != segments || old.durationMs != durationMs;
}
/// One labelled time field with step nudge buttons and "set to playhead".
class _TimeRow extends StatelessWidget {
  const _TimeRow({
    required this.label,
    required this.controller,
    required this.step,
    required this.invalid,
    required this.onNudge,
    required this.onSetToPlayhead,
    required this.onEdited,
  });

  final String label;
  final TextEditingController controller;
  final Duration step;
  final bool invalid;
  final void Function(int deltaMs) onNudge;
  final VoidCallback onSetToPlayhead;
  final ValueChanged<String> onEdited;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
            decoration: InputDecoration(
              isDense: true,
              errorText: invalid ? 'Invalid time' : null,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Colors.white24),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Colors.white24),
              ),
            ),
            onChanged: onEdited,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.gps_fixed, size: 16, color: Colors.lightBlueAccent),
          tooltip: 'Set $label to playhead',
          onPressed: onSetToPlayhead,
        ),
        IconButton(
          icon: const Icon(Icons.remove_circle_outline, size: 18, color: Colors.white54),
          tooltip: '$label −${_stepLabel(step)}',
          onPressed: () => onNudge(-step.inMilliseconds),
        ),
        IconButton(
          icon: const Icon(Icons.add_circle_outline, size: 18, color: Colors.white54),
          tooltip: '$label +${_stepLabel(step)}',
          onPressed: () => onNudge(step.inMilliseconds),
        ),
      ],
    );
  }
}
/// Shared precise-time editing: step selector + start/end rows. Owns the text
/// controllers, parses typed times, clamps to [0, duration] and enforces a
/// minimum gap so a segment never collapses or inverts.
class _TimeEditSection extends StatefulWidget {
  const _TimeEditSection({
    required this.start,
    required this.end,
    required this.duration,
    required this.playhead,
    required this.onChanged,
    required this.onValidity,
  });

  final Duration start;
  final Duration end;
  final Duration duration;
  final Duration playhead;
  final void Function(Duration start, Duration end) onChanged;
  final ValueChanged<bool> onValidity;

  @override
  State<_TimeEditSection> createState() => _TimeEditSectionState();
}

class _TimeEditSectionState extends State<_TimeEditSection> {
  static const _steps = <Duration>[
    Duration(milliseconds: 100),
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 5),
  ];

  /// Minimum window length enforced so a segment never collapses or inverts.
  static const _minGap = Duration(milliseconds: 300);

  late Duration _start = widget.start;
  late Duration _end = widget.end;
  Duration _step = const Duration(milliseconds: 500);
  late final TextEditingController _startCtrl =
      TextEditingController(text: _formatMs(widget.start));
  late final TextEditingController _endCtrl =
      TextEditingController(text: _formatMs(widget.end));
  bool _startInvalid = false;
  bool _endInvalid = false;

  @override
  void initState() {
    super.initState();
    _emit();
  }

  @override
  void dispose() {
    _startCtrl.dispose();
    _endCtrl.dispose();
    super.dispose();
  }

  Duration _clamp(Duration v) {
    var next = v;
    if (next.isNegative) next = Duration.zero;
    if (widget.duration > Duration.zero && next > widget.duration) {
      next = widget.duration;
    }
    return next;
  }

  void _emit() {
    widget.onChanged(_start, _end);
    widget.onValidity(_startInvalid || _endInvalid);
  }

  void _applyStart(Duration v) {
    var next = _clamp(v);
    if (_end - next < _minGap) next = _end - _minGap;
    setState(() {
      _start = next;
      _startCtrl.text = _formatMs(_start);
      _startInvalid = false;
    });
    _emit();
  }

  void _applyEnd(Duration v) {
    var next = _clamp(v);
    if (next - _start < _minGap) next = _start + _minGap;
    setState(() {
      _end = next;
      _endCtrl.text = _formatMs(_end);
      _endInvalid = false;
    });
    _emit();
  }

  void _nudgeStart(int ms) => _applyStart(_start + Duration(milliseconds: ms));
  void _nudgeEnd(int ms) => _applyEnd(_end + Duration(milliseconds: ms));

  void _onStartEdited(String raw) {
    final parsed = _parseTimeInput(raw);
    setState(() => _startInvalid = parsed == null);
    if (parsed != null) {
      var next = _clamp(parsed);
      if (_end - next < _minGap) next = _end - _minGap;
      _start = next;
    }
    _emit();
  }

  void _onEndEdited(String raw) {
    final parsed = _parseTimeInput(raw);
    setState(() => _endInvalid = parsed == null);
    if (parsed != null) {
      var next = _clamp(parsed);
      if (next - _start < _minGap) next = _start + _minGap;
      _end = next;
    }
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Fine-tune step',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 4),
        SegmentedButton<Duration>(
          segments: _steps
              .map(
                (s) => ButtonSegment(
                  value: s,
                  label: Text(_stepLabel(s), style: const TextStyle(fontSize: 11)),
                ),
              )
              .toList(),
          selected: {_step},
          onSelectionChanged: (sel) => setState(() => _step = sel.first),
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
        ),
        const SizedBox(height: 12),
        _TimeRow(
          label: 'Start',
          controller: _startCtrl,
          step: _step,
          invalid: _startInvalid,
          onNudge: _nudgeStart,
          onSetToPlayhead: () => _applyStart(widget.playhead),
          onEdited: _onStartEdited,
        ),
        const SizedBox(height: 8),
        _TimeRow(
          label: 'End',
          controller: _endCtrl,
          step: _step,
          invalid: _endInvalid,
          onNudge: _nudgeEnd,
          onSetToPlayhead: () => _applyEnd(widget.playhead),
          onEdited: _onEndEdited,
        ),
      ],
    );
  }
}
/// Full editor for a single segment: action, category, enabled state, precise
/// times, overlap validation, jump-to-boundary previews and split-at-playhead.
class _SegmentEditDialog extends StatefulWidget {
  const _SegmentEditDialog({
    required this.controller,
    required this.segment,
    required this.duration,
    required this.onSeek,
  });

  final SafePlayerController controller;
  final FilterSegment segment;
  final Duration duration;
  final ValueChanged<Duration> onSeek;

  @override
  State<_SegmentEditDialog> createState() => _SegmentEditDialogState();
}

class _SegmentEditDialogState extends State<_SegmentEditDialog> {
  late FilterAction _action = widget.segment.action;
  late bool _enabled = widget.segment.enabled;
  late final TextEditingController _categoryCtrl =
      TextEditingController(text: widget.segment.category);
  late Duration _start = widget.segment.start;
  late Duration _end = widget.segment.end;
  bool _timeInvalid = false;
  String? _overlapHint;
  Duration get _duration => widget.duration;
  Duration get _playhead => widget.controller.player.state.position;

  @override
  void dispose() {
    _categoryCtrl.dispose();
    super.dispose();
  }

  void _onTimes(Duration start, Duration end) {
    setState(() {
      _start = start;
      _end = end;
    });
    _recheckOverlaps();
  }

  void _recheckOverlaps() {
    String? hint;
    for (final s in widget.controller.segments) {
      if (s.id != null && s.id == widget.segment.id) continue;
      if (!s.enabled) continue;
      if (s.start < _end && _start < s.end) {
        hint = 'Overlaps “${s.category.isEmpty ? _actionName(s.action) : s.category}” '
            '(${_formatMs(s.start)}–${_formatMs(s.end)}).';
        break;
      }
    }
    if (hint != _overlapHint) setState(() => _overlapHint = hint);
  }

  void _splitAtPlayhead() {
    final pos = _playhead;
    if (!(pos > _start && pos < _end)) return;
    final first = widget.segment.copyWith(end: pos);
    final second = widget.segment.copyWith(
      id: _newSegmentId(),
      start: pos,
      source: 'manual',
    );
    widget.controller
      ..updateSegment(widget.segment, first)
      ..addSegment(second);
    Navigator.of(context).pop();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Segment split at playhead')),
    );
  }

  void _save() {
    if (_timeInvalid || _overlapHint != null) return;
    final category = _categoryCtrl.text.trim();
    widget.controller.updateSegment(
      widget.segment,
      widget.segment.copyWith(
        start: _start,
        end: _end,
        action: _action,
        category: category.isEmpty ? widget.segment.category : category,
        enabled: _enabled,
      ),
    );
    Navigator.of(context).pop();
  }
  @override
  Widget build(BuildContext context) {
    final canSave = !_timeInvalid && _overlapHint == null;
    final confidence = widget.segment.confidence;
    return AlertDialog(
      backgroundColor: const Color(0xFF0F172A),
      title: const Text('Edit Segment', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<FilterAction>(
                segments: const [
                  ButtonSegment(
                    value: FilterAction.skip,
                    icon: Icon(Icons.fast_forward, size: 16),
                    label: Text('Skip'),
                  ),
                  ButtonSegment(
                    value: FilterAction.mute,
                    icon: Icon(Icons.volume_off, size: 16),
                    label: Text('Mute'),
                  ),
                  ButtonSegment(
                    value: FilterAction.blackout,
                    icon: Icon(Icons.visibility_off, size: 16),
                    label: Text('Blackout'),
                  ),
                ],
                selected: {_action},
                onSelectionChanged: (sel) => setState(() => _action = sel.first),
                showSelectedIcon: false,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _categoryCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Category',
                  labelStyle: TextStyle(color: Colors.white54),
                  hintText: 'e.g. explicit_nudity',
                  hintStyle: TextStyle(color: Colors.white38),
                  border: OutlineInputBorder(),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Enabled',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                subtitle: const Text(
                  'Disabled rules are kept but ignored by the player.',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                value: _enabled,
                activeTrackColor: switch (_action) {
                  FilterAction.skip => const Color(0xFFEF4444),
                  FilterAction.mute => const Color(0xFFFBBF24),
                  FilterAction.blackout => const Color(0xFF8B5CF6),
                },
                onChanged: (v) => setState(() => _enabled = v),
              ),
              const Divider(height: 24, color: Colors.white12),
              _TimeEditSection(
                start: _start,
                end: _end,
                duration: _duration,
                playhead: _playhead,
                onChanged: _onTimes,
                onValidity: (v) => setState(() => _timeInvalid = v),
              ),
              if (_overlapHint != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _overlapHint!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: () => widget.onSeek(_start),
                    child: const Text('Seek start'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => widget.onSeek(_end),
                    child: const Text('Seek end'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed:
                        (_playhead > _start && _playhead < _end) ? _splitAtPlayhead : null,
                    child: const Text('Split at playhead'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (confidence != null)
                    _MetaChip(
                      text: '${(confidence * 100).toStringAsFixed(0)}% conf',
                    ),
                  _MetaChip(text: widget.segment.source),
                  if (widget.segment.id != null)
                    _MetaChip(text: widget.segment.id!),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canSave ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
/// Dialog for creating a new segment from the `[start]`-`]end]` marks, with
/// the same precise time controls and overlap validation as the editor.
class _NewSegmentDialog extends StatefulWidget {
  const _NewSegmentDialog({
    required this.controller,
    required this.start,
    required this.end,
    required this.duration,
    required this.onSeek,
    required this.onSave,
  });

  final SafePlayerController controller;
  final Duration start;
  final Duration end;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<FilterSegment> onSave;

  @override
  State<_NewSegmentDialog> createState() => _NewSegmentDialogState();
}

class _NewSegmentDialogState extends State<_NewSegmentDialog> {
  FilterAction _action = FilterAction.skip;
  bool _enabled = true;
  late final TextEditingController _categoryCtrl = TextEditingController();
  late Duration _start = widget.start;
  late Duration _end = widget.end;
  bool _timeInvalid = false;
  String? _overlapHint;

  Duration get _duration => widget.duration;
  Duration get _playhead => widget.controller.player.state.position;

  @override
  void dispose() {
    _categoryCtrl.dispose();
    super.dispose();
  }

  void _onTimes(Duration start, Duration end) {
    setState(() {
      _start = start;
      _end = end;
    });
    _recheckOverlaps();
  }

  void _recheckOverlaps() {
    String? hint;
    for (final s in widget.controller.segments) {
      if (!s.enabled) continue;
      if (s.start < _end && _start < s.end) {
        hint = 'Overlaps “${s.category.isEmpty ? _actionName(s.action) : s.category}” '
            '(${_formatMs(s.start)}–${_formatMs(s.end)}).';
        break;
      }
    }
    if (hint != _overlapHint) setState(() => _overlapHint = hint);
  }

  void _save() {
    if (_timeInvalid || _overlapHint != null) return;
    final category = _categoryCtrl.text.trim();
    widget.onSave(
      FilterSegment(
        id: _newSegmentId(),
        start: _start,
        end: _end,
        action: _action,
        category: category.isEmpty ? _actionName(_action) : category,
        source: 'manual',
        enabled: _enabled,
      ),
    );
  }
  @override
  Widget build(BuildContext context) {
    final canSave = !_timeInvalid && _overlapHint == null;
    return AlertDialog(
      backgroundColor: const Color(0xFF0F172A),
      title: const Text(
        'New Flagged Segment',
        style: TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_formatMs(widget.start)} → ${_formatMs(widget.end)}',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              SegmentedButton<FilterAction>(
                segments: const [
                  ButtonSegment(
                    value: FilterAction.skip,
                    icon: Icon(Icons.fast_forward, size: 16),
                    label: Text('Skip'),
                  ),
                  ButtonSegment(
                    value: FilterAction.mute,
                    icon: Icon(Icons.volume_off, size: 16),
                    label: Text('Mute'),
                  ),
                  ButtonSegment(
                    value: FilterAction.blackout,
                    icon: Icon(Icons.visibility_off, size: 16),
                    label: Text('Blackout'),
                  ),
                ],
                selected: {_action},
                onSelectionChanged: (sel) => setState(() => _action = sel.first),
                showSelectedIcon: false,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _categoryCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Category',
                  labelStyle: TextStyle(color: Colors.white54),
                  hintText: 'e.g. explicit_nudity',
                  hintStyle: TextStyle(color: Colors.white38),
                  border: OutlineInputBorder(),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Enabled',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                value: _enabled,
                activeTrackColor: switch (_action) {
                  FilterAction.skip => const Color(0xFFEF4444),
                  FilterAction.mute => const Color(0xFFFBBF24),
                  FilterAction.blackout => const Color(0xFF8B5CF6),
                },
                onChanged: (v) => setState(() => _enabled = v),
              ),
              const Divider(height: 24, color: Colors.white12),
              _TimeEditSection(
                start: _start,
                end: _end,
                duration: _duration,
                playhead: _playhead,
                onChanged: _onTimes,
                onValidity: (v) => setState(() => _timeInvalid = v),
              ),
              if (_overlapHint != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _overlapHint!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canSave ? _save : null,
          child: const Text('Add Segment'),
        ),
      ],
    );
  }
}
/// Prompt card showing the in-progress `[start]`-`]end]` marks with save/clear.
class _SaveNewCard extends StatelessWidget {
  const _SaveNewCard({
    required this.markStart,
    required this.markEnd,
    required this.onSave,
    required this.onClear,
  });

  final Duration? markStart;
  final Duration? markEnd;
  final VoidCallback onSave;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final both = markStart != null && markEnd != null;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.add_box_outlined, color: Colors.white54, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              both
                  ? 'New: ${_formatMs(markStart!)} → ${_formatMs(markEnd!)}'
                  : 'Mark [start] and ]end], then add',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          if (both) ...[
            IconButton(
              icon: const Icon(Icons.add_circle, color: Colors.lightBlueAccent, size: 22),
              tooltip: 'Add segment from marks',
              onPressed: onSave,
            ),
            IconButton(
              icon: const Icon(Icons.clear, color: Colors.white38, size: 18),
              tooltip: 'Clear marks',
              onPressed: onClear,
            ),
          ],
        ],
      ),
    );
  }
}

String _newSegmentId() => 'manual_${DateTime.now().microsecondsSinceEpoch}';

String _actionName(FilterAction a) => switch (a) {
      FilterAction.skip => 'Skip',
      FilterAction.mute => 'Mute',
      FilterAction.blackout => 'Blackout',
    };

/// Formats `h:mm:ss.mmm` (always shows hours and milliseconds for precision).
String _formatMs(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  String three(int n) => n.toString().padLeft(3, '0');
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  final ms = d.inMilliseconds.remainder(1000);
  return '$h:${two(m)}:${two(s)}.${three(ms)}';
}

/// Compact human length, e.g. `1.5s`, `1m 05s`.
String _formatLength(Duration d) {
  final total = d.inMilliseconds / 1000.0;
  if (total < 60) return '${total.toStringAsFixed(1)}s';
  final m = (total ~/ 60).toInt();
  final s = (total % 60).round();
  return '${m}m ${s.toStringAsFixed(0)}s';
}

/// Human label for a nudge step duration.
String _stepLabel(Duration step) {
  if (step.inMilliseconds < 1000) return '${step.inMilliseconds}ms';
  return '${step.inSeconds}s';
}

/// Tolerant time parser supporting `s`, `ss.mmm`, `mm:ss`, `h:mm:ss.mmm`,
/// `ms` suffixes and negatives. Returns null when the input is not a time.
Duration? _parseTimeInput(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  var sign = 1;
  if (s.startsWith('-')) {
    sign = -1;
    s = s.substring(1);
  }
  final parts = s.split(':');
  try {
    double millis;
    if (parts.length == 1) {
      final p = parts[0].toLowerCase();
      if (p.isEmpty) return null;
      millis = p.endsWith('ms')
          ? double.parse(p.substring(0, p.length - 2))
          : double.parse(p) * 1000.0;
    } else {
      final vals = parts.map(double.parse).toList();
      if (vals.any((v) => v < 0)) return null;
      var secs = vals.last;
      for (var i = vals.length - 2; i >= 0; i--) {
        secs = vals[i] * 60 + secs;
      }
      millis = secs * 1000.0;
    }
    if (millis.isNaN || millis.isInfinite) return null;
    return Duration(milliseconds: (sign * millis).round());
  } catch (_) {
    return null;
  }
}
