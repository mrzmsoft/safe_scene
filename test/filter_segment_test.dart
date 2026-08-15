import 'package:flutter_test/flutter_test.dart';

import 'package:safe_scene/models/filter_segment.dart';

void main() {
  group('FilterAction', () {
    test('exposes the canonical labels used in .safe.json', () {
      expect(FilterAction.skip.label, 'skip');
      expect(FilterAction.mute.label, 'mute');
      expect(FilterAction.blackout.label, 'blackout');
    });

    test('parses known labels', () {
      expect(FilterAction.fromLabel('skip'), FilterAction.skip);
      expect(FilterAction.fromLabel('mute'), FilterAction.mute);
      expect(FilterAction.fromLabel('blackout'), FilterAction.blackout);
    });

    test('throws on unknown labels', () {
      expect(
        () => FilterAction.fromLabel('explode'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('FilterSegment', () {
    const segment = FilterSegment(
      id: 'seg_001',
      start: Duration(seconds: 10),
      end: Duration(seconds: 20),
      action: FilterAction.mute,
      category: 'profanity',
      source: 'ai_whisper',
      confidence: 0.97,
    );

    test('contains uses half-open [start, end) bounds', () {
      expect(segment.contains(Duration(seconds: 9)), isFalse);
      expect(segment.contains(Duration(seconds: 10)), isTrue);
      expect(segment.contains(Duration(seconds: 15)), isTrue);
      expect(segment.contains(Duration(seconds: 20)), isFalse);
      expect(segment.contains(Duration.zero), isFalse);
    });

    test('computes length', () {
      expect(segment.length, const Duration(seconds: 10));
    });

    test('round-trips through toJson/fromJson', () {
      final json = segment.toJson();
      expect(json['start_ms'], 10000);
      expect(json['end_ms'], 20000);
      expect(json['action'], 'mute');

      final restored = FilterSegment.fromJson(json);
      expect(restored.id, segment.id);
      expect(restored.start, segment.start);
      expect(restored.end, segment.end);
      expect(restored.action, segment.action);
      expect(restored.category, segment.category);
      expect(restored.source, segment.source);
      expect(restored.confidence, segment.confidence);
    });

    test('equality is based on start/end/action', () {
      const same = FilterSegment(
        start: Duration(seconds: 10),
        end: Duration(seconds: 20),
        action: FilterAction.mute,
        category: 'profanity',
        source: 'ai_whisper',
      );
      const different = FilterSegment(
        start: Duration(seconds: 11),
        end: Duration(seconds: 20),
        action: FilterAction.mute,
        category: 'profanity',
        source: 'ai_whisper',
      );
      expect(same, segment);
      expect(different, isNot(segment));
    });

    test('enabled defaults to true and is kept out of JSON when true', () {
      const s = FilterSegment(
        id: 'seg_e',
        start: Duration(seconds: 1),
        end: Duration(seconds: 2),
        action: FilterAction.skip,
        category: 'x',
        source: 'manual',
      );
      expect(s.enabled, isTrue);
      expect(s.toJson().containsKey('enabled'), isFalse);
    });

    test('disabled state round-trips through JSON', () {
      const s = FilterSegment(
        id: 'seg_off',
        start: Duration(seconds: 1),
        end: Duration(seconds: 2),
        action: FilterAction.skip,
        category: 'x',
        source: 'manual',
        enabled: false,
      );
      expect(s.toJson()['enabled'], isFalse);
      final restored = FilterSegment.fromJson(s.toJson());
      expect(restored.enabled, isFalse);
      // Absent key still restores to enabled.
      final json = s.toJson()..remove('enabled');
      expect(FilterSegment.fromJson(json).enabled, isTrue);
    });

    test('copyWith replaces only the requested fields', () {
      final updated = segment.copyWith(
        end: const Duration(seconds: 25),
        category: 'updated',
        enabled: false,
      );
      expect(updated.id, segment.id);
      expect(updated.start, segment.start);
      expect(updated.end, const Duration(seconds: 25));
      expect(updated.action, segment.action);
      expect(updated.category, 'updated');
      expect(updated.source, segment.source);
      expect(updated.confidence, segment.confidence);
      expect(updated.enabled, isFalse);
    });

    test('overlapsWith detects intersection only', () {
      const a = FilterSegment(
        start: Duration(seconds: 10),
        end: Duration(seconds: 20),
        action: FilterAction.mute,
        category: 'p',
        source: 'manual',
      );
      // Touching at the boundary is not an overlap (half-open windows).
      const touching = FilterSegment(
        start: Duration(seconds: 20),
        end: Duration(seconds: 30),
        action: FilterAction.mute,
        category: 'p',
        source: 'manual',
      );
      const inside = FilterSegment(
        start: Duration(seconds: 12),
        end: Duration(seconds: 15),
        action: FilterAction.skip,
        category: 'n',
        source: 'manual',
      );
      const separate = FilterSegment(
        start: Duration(seconds: 30),
        end: Duration(seconds: 40),
        action: FilterAction.mute,
        category: 'p',
        source: 'manual',
      );
      expect(a.overlapsWith(touching), isFalse);
      expect(a.overlapsWith(inside), isTrue);
      expect(a.overlapsWith(separate), isFalse);
    });
  });
}
