import 'package:flutter/material.dart';

import '../controllers/safe_player_controller.dart';
import '../models/filter_segment.dart';

/// A side panel that shows an editable list of all flagged segments.
class SceneEditorDrawer extends StatelessWidget {
  const SceneEditorDrawer({
    super.key,
    required this.controller,
    this.markStart,
    this.markEnd,
    required this.onPreview,
    required this.onClose,
    this.onClearMarks,
    this.width = 320,
  });

  final SafePlayerController controller;
  final Duration? markStart;
  final Duration? markEnd;
  final ValueChanged<FilterSegment> onPreview;
  final VoidCallback onClose;
  final VoidCallback? onClearMarks;
  final double width;

  void _editSegment(BuildContext context, FilterSegment old) {
    final categoryCtrl = TextEditingController(text: old.category);
    FilterAction? newAction = old.action;
    String? newCategory = old.category;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          title: const Text('Edit Segment', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: newAction!.label,
                dropdownColor: const Color(0xFF1E293B),
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Action', border: OutlineInputBorder()),
                items: FilterAction.values.map((a) => DropdownMenuItem(value: a.label, child: Text(a.label))).toList(),
                onChanged: (v) => setDialogState(() => newAction = FilterAction.fromLabel(v!)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: categoryCtrl,
                decoration: const InputDecoration(labelText: 'Category', border: OutlineInputBorder()),
                style: const TextStyle(color: Colors.white),
                onChanged: (v) => newCategory = v,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                controller.updateSegment(
                  old,
                  FilterSegment(
                    id: old.id,
                    start: old.start,
                    end: old.end,
                    action: newAction!,
                    category: newCategory ?? old.category,
                    source: old.source,
                    confidence: old.confidence,
                  ),
                );
                Navigator.of(ctx).pop();
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        border: Border(left: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        children: [
          _buildHeader(context),
          _SaveNewCard(
            markStart: markStart,
            markEnd: markEnd,
            onSave: () => _saveNewSegment(context),
            onClear: onClearMarks ?? () {},
          ),
          const Divider(height: 1, color: Colors.white12),
          Expanded(child: _buildSegmentList(context)),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white12))),
      child: Row(
        children: [
          const Icon(Icons.edit, color: Colors.white70, size: 20),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('Scene Editor', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70, size: 20),
            onPressed: onClose,
            tooltip: 'Close editor (E)',
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentList(BuildContext context) {
    return ValueListenableBuilder<List<FilterSegment>>(
      valueListenable: controller.segmentsNotifier,
      builder: (context, segments, _) {
        if (segments.isEmpty) {
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
        return ListView.separated(
          padding: const EdgeInsets.only(top: 8),
          itemCount: segments.length,
          separatorBuilder: (_, _) => const Divider(height: 1, color: Colors.white12),
          itemBuilder: (context, index) {
            final segment = segments[index];
            return _SegmentTile(
              segment: segment,
              onEdit: () => _editSegment(context, segment),
              onDelete: () => controller.removeSegment(segment),
              onPreview: () => onPreview(segment),
            );
          },
        );
      },
    );
  }
void _saveNewSegment(BuildContext context) {
    final start = markStart;
    final end = markEnd;
    if (start == null || end == null || start >= end) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Set both [start] and ]end] marks first.')),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => _NewSegmentDialog(
        start: start,
        end: end,
        onSave: (segment) {
          controller.addSegment(segment);
          Navigator.of(ctx).pop();
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text('Added ${segment.action.label} segment ${_format(segment.start)}–${_format(segment.end)}')),
          );
        },
      ),
    );
  }
}

/// Card that appears at the top prompting to save a new segment from marks.
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
    return Container(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'New Segment',
            style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  markStart != null && markEnd != null
                      ? '${_format(markStart!)} \u2192 ${_format(markEnd!)}'
                      : 'Set [start] and ]end] marks',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              if (markStart != null && markEnd != null) ...[
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, color: Colors.lightBlueAccent, size: 22),
                  tooltip: 'Save segment',
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
        ],
      ),
    );
  }
}

/// One row in the segmented list.
class _SegmentTile extends StatelessWidget {
  const _SegmentTile({
    required this.segment,
    required this.onEdit,
    required this.onDelete,
    required this.onPreview,
  });

  final FilterSegment segment;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onPreview;

  Color get _color => switch (segment.action) {
    FilterAction.skip => const Color(0xFFEF4444),
    FilterAction.mute => const Color(0xFFFBBF24),
    FilterAction.blackout => const Color(0xFF8B5CF6),
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: _color, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  segment.category.isEmpty ? segment.action.label : segment.category,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
                Text('${_format(segment.start)} \u2013 ${_format(segment.end)}',
                    style: const TextStyle(color: Colors.white54, fontSize: 11)),
              ],
            ),
          ),
          IconButton(
              icon: const Icon(Icons.play_arrow, color: Colors.white54, size: 20),
              tooltip: 'Preview (3s lead-in)',
              onPressed: onPreview),
          IconButton(
              icon: const Icon(Icons.edit, color: Colors.white54, size: 18),
              tooltip: 'Edit',
              onPressed: onEdit),
          IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
              tooltip: 'Delete',
              onPressed: onDelete),
        ],
      ),
    );
  }
}
/// Dialog shown when saving a new segment from marks.
class _NewSegmentDialog extends StatefulWidget {
  const _NewSegmentDialog({
    required this.start,
    required this.end,
    required this.onSave,
  });
  final Duration start;
  final Duration end;
  final ValueChanged<FilterSegment> onSave;

  @override
  State<_NewSegmentDialog> createState() => _NewSegmentDialogState();
}

class _NewSegmentDialogState extends State<_NewSegmentDialog> {
  FilterAction _action = FilterAction.skip;
  final _categoryCtrl = TextEditingController();

  @override
  void dispose() {
    _categoryCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0F172A),
      title: const Text('New Flagged Segment', style: TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_format(widget.start)} \u2192 ${_format(widget.end)}',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _action.label,
            dropdownColor: const Color(0xFF1E293B),
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(labelText: 'Action', border: OutlineInputBorder()),
            items: FilterAction.values
                .map((a) => DropdownMenuItem(value: a.label, child: Text(a.label)))
                .toList(),
            onChanged: (v) => setState(() => _action = FilterAction.fromLabel(v!)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _categoryCtrl,
            decoration: const InputDecoration(labelText: 'Category', hintText: 'e.g. explicit_nudity', border: OutlineInputBorder()),
            style: const TextStyle(color: Colors.white),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final segment = FilterSegment(
              id: 'manual_${DateTime.now().millisecondsSinceEpoch}',
              start: widget.start,
              end: widget.end,
              action: _action,
              category: _categoryCtrl.text.trim().isEmpty ? _action.label : _categoryCtrl.text.trim(),
              source: 'manual',
            );
            widget.onSave(segment);
          },
          child: const Text('Add Segment'),
        ),
      ],
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