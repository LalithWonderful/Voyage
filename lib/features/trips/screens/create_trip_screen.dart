import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:voyage/core/theme/app_theme.dart';

class CreateTripScreen extends StatelessWidget {
  const CreateTripScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Nouveau voyage'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => context.go('/trips')),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const TextField(decoration: InputDecoration(labelText: 'Nom du voyage', prefixIcon: Icon(Icons.luggage_outlined))),
            const SizedBox(height: 16),
            const TextField(decoration: InputDecoration(labelText: 'Destination', prefixIcon: Icon(Icons.location_on_outlined))),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: const TextField(decoration: InputDecoration(labelText: 'Départ', prefixIcon: Icon(Icons.flight_takeoff)))),
                const SizedBox(width: 12),
                Expanded(child: const TextField(decoration: InputDecoration(labelText: 'Retour', prefixIcon: Icon(Icons.flight_land)))),
              ],
            ),
            const Spacer(),
            ElevatedButton(
              onPressed: () => context.go('/trips'),
              child: const Text('Créer le voyage'),
            ),
          ],
        ),
      ),
    );
  }
}
