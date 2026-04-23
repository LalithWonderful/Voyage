import 'package:flutter/material.dart';
import 'package:voyage/core/theme/app_theme.dart';

class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Carte')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.map, size: 64, color: AppColors.primary),
            SizedBox(height: 16),
            Text('Carte Google Maps à intégrer', style: TextStyle(fontSize: 18, color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}
