import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:safe_scene/screens/home_page.dart';

void main() {
  testWidgets('HomePage renders the open-video landing screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));

    expect(find.text('Safe Scene'), findsOneWidget);
    expect(find.text('Open Video File'), findsOneWidget);
    expect(find.byIcon(Icons.shield), findsOneWidget);
  });
}
