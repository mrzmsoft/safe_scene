import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'screens/home_page.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Must run before any Player / VideoController is created.
  MediaKit.ensureInitialized();

  // Required for the desktop fullscreen toggle (F key) to control the window.
  await windowManager.ensureInitialized();

  runApp(const SafeSceneApp());
}

class SafeSceneApp extends StatelessWidget {
  const SafeSceneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Safe Scene',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const HomePage(),
    );
  }
}
