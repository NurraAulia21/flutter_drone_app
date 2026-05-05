import 'package:flutter/material.dart';
import 'constants/app_colors.dart';
import 'screens/select_drone_screen.dart';
import 'screens/drone_screen.dart';
import 'models/drone.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Drone App - TacticalObserver',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primary),
        scaffoldBackgroundColor: AppColors.background,
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const SelectDroneScreen(),
      },
      onGenerateRoute: (settings) {
        if (settings.name == '/drone') {
          final drone = settings.arguments as DroneOption;
          return MaterialPageRoute(
            builder: (context) => DroneScreen(drone: drone),
          );
        }
        return null;
      },
    );
  }
}
