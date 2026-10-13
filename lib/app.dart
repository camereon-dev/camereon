import 'package:flutter/material.dart';

import 'features/home/home_screen.dart';

class CamereonApp extends StatelessWidget {
  const CamereonApp({super.key});

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF235C43);

    return MaterialApp(
      title: 'camereon',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: green,
          primary: green,
          surface: const Color(0xFFF7F9F5),
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F9F5),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
