import 'package:flutter/material.dart';

import 'core/llm_engine.dart';
import 'core/llm_settings.dart';
import 'ui/chat_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await LlmSettings.load();
  runApp(YerelAsistanApp(engine: LlmEngine(settings)));
}

class YerelAsistanApp extends StatelessWidget {
  const YerelAsistanApp({super.key, required this.engine});
  final LlmEngine engine;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yerel Asistan',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: ChatScreen(engine: engine),
    );
  }
}
