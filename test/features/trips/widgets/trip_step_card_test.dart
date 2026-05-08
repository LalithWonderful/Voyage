/// Widget tests `TripStepCard` — garde-fou contre les régressions de
/// rendu sur les états de mobilité (`free`, `docLinked`, `windowLinked`).
///
/// Contexte : le commit 0c108ea utilisait `Border()` non-uniforme +
/// `borderRadius`, ce qui throw `FlutterError` au paint et blanchissait
/// la carte (régression rapportée Lalith 2026-05-08, fix 3685ab1).
/// Ces tests vérifient que chaque état rend ses éléments clés sans
/// exception (ville, dates, badge durée, badge lock le cas échéant).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/trips/widgets/trip_step_card.dart';

DateTime _d(int y, int m, int d) => DateTime(y, m, d);

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    );

void main() {
  group('TripStepCard — rendu sans exception', () {
    testWidgets('lockState=free affiche la ville, les dates et le badge durée',
        (tester) async {
      await tester.pumpWidget(_wrap(
        TripStepCard(
          city: 'Bangkok',
          country: 'Thaïlande',
          days: 11,
          startDate: _d(2026, 6, 21),
          endDate: _d(2026, 7, 2),
          leading: const Icon(Icons.drag_indicator, size: 16),
        ),
      ));
      expect(
        find.textContaining('Bangkok', findRichText: true),
        findsWidgets,
      );
      expect(
        find.textContaining('Thaïlande', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('11'), findsWidgets); // badge durée
      expect(find.textContaining('Du 21/06/2026'), findsOneWidget);
      // Pas de badge lock pour l'état libre.
      expect(find.text('Document lié'), findsNothing);
      expect(find.textContaining('Liée à'), findsNothing);
      // Aucune exception levée par le framework au paint.
      expect(tester.takeException(), isNull);
    });

    testWidgets('lockState=docLinked rend la card + badge "Document lié"',
        (tester) async {
      await tester.pumpWidget(_wrap(
        TripStepCard(
          city: 'Phú Quốc',
          country: 'Vietnam',
          days: 5,
          startDate: _d(2026, 7, 2),
          endDate: _d(2026, 7, 7),
          leading: const Icon(Icons.lock_outline, size: 16),
          lockState: TripStepLockState.docLinked,
        ),
      ));
      // La card est bien rendue (régression Border non-uniforme évitée).
      expect(
        find.textContaining('Phú Quốc', findRichText: true),
        findsWidgets,
      );
      expect(find.textContaining('Du 02/07/2026'), findsOneWidget);
      // Badge spécifique à l'état.
      expect(find.text('Document lié'), findsOneWidget);
      // Pas de badge fenêtre.
      expect(find.textContaining('Liée à'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lockState=windowLinked rend la card + badge "Liée à {city} · {dates}"',
        (tester) async {
      await tester.pumpWidget(_wrap(
        TripStepCard(
          city: 'Ninh Bình',
          country: 'Vietnam',
          days: 3,
          startDate: _d(2026, 7, 7),
          endDate: _d(2026, 7, 10),
          leading: const Icon(Icons.drag_indicator, size: 16),
          lockState: TripStepLockState.windowLinked,
          windowAnchorCity: 'Hanoï',
          windowStart: _d(2026, 7, 7),
          windowEndExclusive: _d(2026, 7, 11),
        ),
      ));
      expect(
        find.textContaining('Ninh Bình', findRichText: true),
        findsWidgets,
      );
      // Badge contient la ville d'ancrage et les dates compactes.
      expect(find.textContaining('Liée à Hanoï'), findsOneWidget);
      expect(find.textContaining('07/07'), findsWidgets);
      expect(find.textContaining('11/07'), findsOneWidget);
      // Pas de badge document-linked.
      expect(find.text('Document lié'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lockState=windowLinked sans dates → "Liée à {city}" sans tirets',
        (tester) async {
      await tester.pumpWidget(_wrap(
        TripStepCard(
          city: 'Krabi',
          country: 'Thaïlande',
          days: 3,
          startDate: _d(2026, 6, 26),
          endDate: _d(2026, 6, 29),
          lockState: TripStepLockState.windowLinked,
          windowAnchorCity: 'Bangkok',
          // pas de windowStart/End → label "Liée à Bangkok" simple
        ),
      ));
      expect(find.text('Liée à Bangkok'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lockState=windowLinked sans anchorCity → label fallback',
        (tester) async {
      await tester.pumpWidget(_wrap(
        TripStepCard(
          city: 'Random',
          country: null,
          days: 2,
          startDate: _d(2026, 7, 1),
          endDate: _d(2026, 7, 3),
          lockState: TripStepLockState.windowLinked,
        ),
      ));
      expect(find.text('Liée à une étape'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('onTap déclenche le callback', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(_wrap(
        TripStepCard(
          city: 'Bangkok',
          country: null,
          days: 11,
          startDate: _d(2026, 6, 21),
          endDate: _d(2026, 7, 2),
          onTap: () => tapped++,
        ),
      ));
      // Tap au centre de la card (RichText pas tappable directement
      // via find.text), via le widget RichText racine.
      await tester.tap(find.byType(TripStepCard));
      await tester.pump();
      expect(tapped, 1);
    });

    testWidgets('onDelete affiche le bouton supprimer et déclenche le callback',
        (tester) async {
      var deleted = 0;
      await tester.pumpWidget(_wrap(
        TripStepCard(
          city: 'Bangkok',
          country: null,
          days: 11,
          startDate: _d(2026, 6, 21),
          endDate: _d(2026, 7, 2),
          onDelete: () => deleted++,
        ),
      ));
      final deleteIcon = find.byIcon(Icons.delete_outline);
      expect(deleteIcon, findsOneWidget);
      await tester.tap(deleteIcon);
      await tester.pump();
      expect(deleted, 1);
    });

    testWidgets('sourceLabel rend la 3ème ligne avec icône avion',
        (tester) async {
      await tester.pumpWidget(_wrap(
        TripStepCard(
          city: 'Bangkok',
          country: 'Thaïlande',
          days: 11,
          startDate: _d(2026, 6, 21),
          endDate: _d(2026, 7, 2),
          sourceLabel: 'Turkish Airlines',
        ),
      ));
      expect(find.textContaining('Turkish Airlines'), findsOneWidget);
      expect(find.byIcon(Icons.flight), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
