/// POI-1.0 — Tests widget de l'écran debug POI.
///
/// Tous les tests sont offline : `poiRepositoryProvider` est overridé
/// avec un `FakePoiRepository` injecté. Aucun Supabase live, aucun
/// credential requis.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/poi/data/fake_poi_repository.dart';
import 'package:voyage/features/poi/debug/poi_debug_screen.dart';
import 'package:voyage/features/poi/domain/poi.dart';
import 'package:voyage/features/poi/domain/poi_repository.dart';
import 'package:voyage/features/poi/providers/poi_repository_provider.dart';

DateTime _ts(String iso) => DateTime.parse(iso);

Poi _poi({
  required String poiId,
  required String name,
  required String normalizedName,
  required PoiCategory category,
  int? editorialScore,
  bool isMustSee = false,
  String sourcePrimaryId = 'src-editorial',
  String destinationKey = 'lisbon',
  int? touristicImportance,
  int? typicalDurationMinutes,
  int? priceLevel,
  bool? isFree,
  bool? isFamilyFriendly,
  bool? isRainFriendly,
}) {
  return Poi(
    poiId: poiId,
    destinationKey: destinationKey,
    name: name,
    normalizedName: normalizedName,
    category: category,
    sourcePrimaryId: sourcePrimaryId,
    editorialScore: editorialScore,
    isMustSee: isMustSee,
    touristicImportance: touristicImportance,
    typicalDurationMinutes: typicalDurationMinutes,
    priceLevel: priceLevel,
    isFree: isFree,
    isFamilyFriendly: isFamilyFriendly,
    isRainFriendly: isRainFriendly,
    createdAt: _ts('2024-01-15T10:00:00Z'),
    updatedAt: _ts('2024-01-15T10:00:00Z'),
  );
}

Widget _buildScreen({required PoiRepository repo}) => ProviderScope(
      overrides: [
        poiRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        home: const PoiDebugScreen(),
      ),
    );

void main() {
  group('PoiDebugScreen — rendu & états', () {
    testWidgets('affiche le titre et les filtres', (tester) async {
      await tester.pumpWidget(_buildScreen(repo: const FakePoiRepository()));
      await tester.pumpAndSettle();

      expect(find.text('🔍 Debug POI'), findsOneWidget);
      expect(find.text('Destination key'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Recherche'), findsOneWidget);
      expect(find.byType(DropdownButton<PoiCategory?>), findsOneWidget);
      expect(find.text('Must-see'), findsOneWidget);
      expect(find.text('Rechercher'), findsOneWidget);
      expect(find.text('Top 10'), findsOneWidget);
    });

    testWidgets('état empty quand repo vide', (tester) async {
      await tester.pumpWidget(_buildScreen(repo: const FakePoiRepository()));
      await tester.pumpAndSettle();

      // Déclenche la recherche avec la destination par défaut (lisbon).
      await tester.tap(find.text('Rechercher'));
      await tester.pumpAndSettle();

      expect(find.text('📭'), findsOneWidget);
      expect(find.text('Aucun POI trouvé'), findsOneWidget);
    });

    testWidgets('mode Top 10 affiche les meilleurs POIs', (tester) async {
      final repo = FakePoiRepository(
        pois: [
          _poi(
            poiId: 'poi-001',
            name: 'Belém Tower',
            normalizedName: 'belem tower',
            category: PoiCategory.monument,
            editorialScore: 95,
            destinationKey: 'lisbon',
          ),
          _poi(
            poiId: 'poi-002',
            name: 'Jerónimos Monastery',
            normalizedName: 'jeronimos monastery',
            category: PoiCategory.monument,
            editorialScore: 92,
            destinationKey: 'lisbon',
          ),
          _poi(
            poiId: 'poi-003',
            name: 'Alfama',
            normalizedName: 'alfama',
            category: PoiCategory.neighborhood,
            editorialScore: 88,
            destinationKey: 'lisbon',
          ),
        ],
      );
      await tester.pumpWidget(_buildScreen(repo: repo));
      await tester.pumpAndSettle();

      // Passe en mode Top 10
      await tester.tap(find.text('Top 10'));
      await tester.pumpAndSettle();

      // Les 3 POIs doivent être présents (ListView peut ne pas renderer
      // les éléments offscreen ; on scroll pour les trouver).
      expect(find.text('Belém Tower'), findsOneWidget);
      expect(find.text('Jerónimos Monastery'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Alfama'),
        100,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Alfama'), findsOneWidget);
    });

    testWidgets('affiche les POI retournés par le repo', (tester) async {
      final repo = FakePoiRepository(
        pois: [
          _poi(
            poiId: 'poi-001',
            name: 'Gardens by the Bay',
            normalizedName: 'gardens by the bay',
            category: PoiCategory.park,
            editorialScore: 98,
            isMustSee: true,
            touristicImportance: 5,
            typicalDurationMinutes: 180,
          ),
          _poi(
            poiId: 'poi-002',
            name: 'Marina Bay Sands',
            normalizedName: 'marina bay sands',
            category: PoiCategory.mustSee,
            editorialScore: 92,
            isMustSee: true,
            priceLevel: 4,
            isFree: false,
          ),
          _poi(
            poiId: 'poi-003',
            name: 'Hawker Centre Maxwell',
            normalizedName: 'hawker centre maxwell',
            category: PoiCategory.food,
            editorialScore: 85,
            isFree: true,
            isFamilyFriendly: true,
          ),
        ],
      );

      await tester.pumpWidget(_buildScreen(repo: repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rechercher'));
      await tester.pumpAndSettle();

      expect(find.text('Gardens by the Bay'), findsOneWidget);
      expect(find.text('Marina Bay Sands'), findsOneWidget);
      expect(find.text('Hawker Centre Maxwell'), findsOneWidget);

      // MUST-SEE badges
      expect(find.text('MUST-SEE'), findsNWidgets(2));

      // Métriques
      expect(find.textContaining('Score 98/100'), findsOneWidget);
      expect(find.textContaining('Score 92/100'), findsOneWidget);
      expect(find.textContaining('Score 85/100'), findsOneWidget);
      expect(find.textContaining('Imp. 5/5'), findsOneWidget);
      expect(find.textContaining('180 min'), findsOneWidget);
      expect(find.textContaining('Prix 4/4'), findsOneWidget);
      expect(find.textContaining('Gratuit'), findsOneWidget);
      expect(find.textContaining('Famille'), findsOneWidget);

      // Source info
      expect(find.textContaining('source: src-editorial'), findsNWidgets(3));
    });

    testWidgets('filtre mustSeeOnly masque les non-must-see', (tester) async {
      final repo = FakePoiRepository(
        pois: [
          _poi(
            poiId: 'poi-001',
            name: 'Must See POI',
            normalizedName: 'must see poi',
            category: PoiCategory.mustSee,
            isMustSee: true,
          ),
          _poi(
            poiId: 'poi-002',
            name: 'Regular POI',
            normalizedName: 'regular poi',
            category: PoiCategory.park,
            isMustSee: false,
          ),
        ],
      );

      await tester.pumpWidget(_buildScreen(repo: repo));
      await tester.pumpAndSettle();

      // Par défaut : les deux visibles.
      await tester.tap(find.text('Rechercher'));
      await tester.pumpAndSettle();
      expect(find.text('Must See POI'), findsOneWidget);
      expect(find.text('Regular POI'), findsOneWidget);

      // Active must-see only.
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rechercher'));
      await tester.pumpAndSettle();

      expect(find.text('Must See POI'), findsOneWidget);
      expect(find.text('Regular POI'), findsNothing);
    });

    testWidgets('recherche textuelle filtre par nom', (tester) async {
      final repo = FakePoiRepository(
        pois: [
          _poi(
            poiId: 'poi-001',
            name: 'Gardens by the Bay',
            normalizedName: 'gardens by the bay',
            category: PoiCategory.park,
          ),
          _poi(
            poiId: 'poi-002',
            name: 'Sentosa Island',
            normalizedName: 'sentosa island',
            category: PoiCategory.beach,
          ),
        ],
      );

      await tester.pumpWidget(_buildScreen(repo: repo));
      await tester.pumpAndSettle();

      // Recherche "gardens".
      await tester.enterText(find.widgetWithText(TextField, 'Recherche'), 'gardens');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rechercher'));
      await tester.pumpAndSettle();

      expect(find.text('Gardens by the Bay'), findsOneWidget);
      expect(find.text('Sentosa Island'), findsNothing);
    });

    testWidgets('affiche les bons emojis de catégorie', (tester) async {
      final repo = FakePoiRepository(
        pois: [
          _poi(
            poiId: 'poi-001',
            name: 'Park POI',
            normalizedName: 'park poi',
            category: PoiCategory.park,
          ),
          _poi(
            poiId: 'poi-002',
            name: 'Food POI',
            normalizedName: 'food poi',
            category: PoiCategory.food,
          ),
          _poi(
            poiId: 'poi-003',
            name: 'Museum POI',
            normalizedName: 'museum poi',
            category: PoiCategory.museum,
          ),
        ],
      );

      await tester.pumpWidget(_buildScreen(repo: repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rechercher'));
      await tester.pumpAndSettle();

      // Les emojis correspondant aux catégories doivent être présents.
      expect(find.text('🌳'), findsOneWidget); // park
      expect(find.text('🍽️'), findsOneWidget); // food
      expect(find.text('🏛️'), findsOneWidget); // museum
    });

    testWidgets('limite de résultats fonctionne', (tester) async {
      final repo = FakePoiRepository(
        pois: List.generate(
          10,
          (i) => _poi(
            poiId: 'poi-$i',
            name: 'POI $i',
            normalizedName: 'poi $i',
            category: PoiCategory.park,
            editorialScore: 100 - i,
          ),
        ),
      );

      await tester.pumpWidget(_buildScreen(repo: repo));
      await tester.pumpAndSettle();

      // Limite à 3.
      await tester.enterText(find.widgetWithText(TextField, 'Limite'), '3');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rechercher'));
      await tester.pumpAndSettle();

      // Seuls 3 POI affichés.
      expect(find.text('POI 0'), findsOneWidget);
      expect(find.text('POI 1'), findsOneWidget);
      expect(find.text('POI 2'), findsOneWidget);
      expect(find.text('POI 3'), findsNothing);
    });
  });
}
