import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/core/providers/currency_provider.dart';
import 'package:voyage/core/services/currency_service.dart';
import 'package:voyage/core/widgets/offline_banner.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/planning/services/ai_suggestions_service.dart';
import 'package:voyage/features/planning/services/places_first_pipeline.dart';
import 'package:voyage/features/poi/providers/poi_repository_provider.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';
import 'package:voyage/features/trips/widgets/regional_loop_sheet.dart';
import 'package:voyage/features/trips/widgets/trip_edit_sheet.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';
import 'package:voyage/features/wallet/screens/wallet_screen.dart';
import 'package:voyage/features/wallet/utils/trip_documents_grouping.dart';
import 'package:voyage/features/wallet/widgets/document_form_sheet.dart';
import 'package:voyage/features/wallet/widgets/hotel_doc_warnings.dart';

class TripDetailScreen extends ConsumerWidget {
  final String tripId;
  const TripDetailScreen({super.key, required this.tripId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tripAsync = ref.watch(tripByIdProvider(tripId));

    return Scaffold(
      backgroundColor: AppColors.background,
      body: tripAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e', style: TextStyle(color: AppColors.error))),
        data: (trip) {
          if (trip == null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Voyage introuvable', style: TextStyle(fontSize: 16, color: AppColors.textSecondary)),
                  const SizedBox(height: 16),
                  TextButton(onPressed: () => context.go('/trips'), child: const Text('Retour aux voyages')),
                ],
              ),
            );
          }
          return _TripDetail(trip: trip);
        },
      ),
    );
  }
}

/// Pays/régions masculins en français commençant par une consonne (qui prennent
/// "au"). Liste à enrichir au fil du temps si on rate un cas. Pour les masculins
/// commençant par voyelle (Iran, Israël, Iraq...), on garde "en" qui est le
/// fallback.
const Set<String> _frMasculineConsonant = <String>{
  'Maroc', 'Portugal', 'Brésil', 'Japon', 'Canada', 'Pérou', 'Mexique',
  'Vietnam', 'Cambodge', 'Laos', 'Sénégal', 'Kenya', 'Chili', 'Yémen',
  'Liban', 'Honduras', 'Nicaragua', 'Salvador', 'Panama', 'Guatemala',
  'Pakistan', 'Bangladesh', 'Bhoutan', 'Népal', 'Tadjikistan', 'Kazakhstan',
  'Turkménistan', 'Kirghizistan', 'Ouzbékistan', 'Soudan', 'Tchad', 'Mali',
  'Niger', 'Botswana', 'Cameroun', 'Gabon', 'Congo', 'Mozambique',
  'Zimbabwe', 'Lesotho', 'Burkina Faso', 'Bénin', 'Togo', 'Ghana',
  'Suriname', 'Paraguay', 'Uruguay', 'Venezuela', 'Costa Rica',
  'Liechtenstein', 'Luxembourg', 'Royaume-Uni', 'Danemark', 'Vatican',
  'Belize', 'Bélarus', 'Bélize', 'Sri Lanka', 'Tibet', 'Groenland',
  'Kosovo', 'Monténégro', 'Surinam', 'Soudan du Sud',
};

/// Pays/régions au pluriel en français (qui prennent "aux").
const Set<String> _frPlural = <String>{
  'États-Unis', 'Pays-Bas', 'Philippines', 'Émirats arabes unis',
  'Émirats Arabes Unis', 'Bahamas', 'Maldives', 'Seychelles', 'Comores',
  'Antilles néerlandaises', 'Îles Salomon', 'Îles Cook', 'Fidji',
  'Caraïbes', 'Açores', 'Bermudes', 'Tonga', 'Samoa',
};

/// Pays/régions traités comme des villes (article-less, prennent "à"). En
/// majorité des îles ou micro-États dont l'usage français est sans article.
const Set<String> _frArticleLess = <String>{
  'Bali', 'Cuba', 'Madagascar', 'Malte', 'Chypre', 'Hawaï', 'Hawaii',
  'Tahiti', 'Singapour', 'Hong Kong', 'Monaco', 'Andorre', 'Bahreïn',
  'Saint-Marin', 'Vanuatu', 'Djibouti', 'Maurice', 'Oman', 'Qatar',
  'Brunei', 'Macao', 'Taïwan', 'Taiwan', 'Goa',
};

/// Construit la phrase "voyage en/au/aux/à {destination}" en français correct.
/// Heuristique :
/// - kind=city → "à {destination}"
/// - destination dans `_frArticleLess` → "à"
/// - destination dans `_frMasculineConsonant` → "au"
/// - destination dans `_frPlural` → "aux"
/// - sinon → "en" (féminin OU masculin avec voyelle initiale, qui couvre la
///   majorité des cas restants : Italie, Allemagne, Inde, Iran, Israël,
///   Iraq, Égypte, Afghanistan, etc.)
///
/// Édge cases connus à enrichir si rencontrés : pays exotiques avec genre
/// non-trivial. Le fallback "en" reste lisible même quand grammaticalement
/// incorrect (ex: "en Maroc" au lieu de "au Maroc" — non grave, juste pas idéal).
String _frenchJourneyPhrase(String destination, String? kind) {
  final firstPart = destination.split(',').first.trim();
  if (firstPart.isEmpty) return '';
  if (kind == 'city') return 'à $firstPart';
  if (_frArticleLess.contains(firstPart)) return 'à $firstPart';
  if (_frPlural.contains(firstPart)) return 'aux $firstPart';
  if (_frMasculineConsonant.contains(firstPart)) return 'au $firstPart';
  return 'en $firstPart';
}

/// Mots fréquents dans les noms d'hôtels qui ne sont JAMAIS des villes.
/// Utilisés pour filtrer le fallback "dernier mot capitalisé du nom".
const Set<String> _hotelNameStopwords = <String>{
  // Marques / chaînes
  'Hotel', 'Hôtel', 'Best', 'Western', 'Resort', 'Inn', 'Suites', 'Lodge',
  'Royal', 'Grand', 'Boutique', 'Auberge', 'Spa', 'Palace', 'Plaza',
  'Mercure', 'Novotel', 'Ibis', 'Sofitel', 'Mövenpick', 'Marriott', 'Hilton',
  'Sheraton', 'Westin', 'Holiday', 'Express', 'Premier', 'Comfort', 'Quality',
  // Génériques
  'Maison', 'Villa', 'Château', 'Manoir', 'Domaine', 'Ferme', 'Gîte',
  'Apart', 'Apartments', 'Studio', 'Studios', 'Camping',
  // Compléments
  'Centre', 'Center', 'City', 'Centre-Ville', 'Airport', 'Aéroport',
  'Boulevard', 'Plage', 'Beach',
};

/// Extrait la ville d'un hôtel. Heuristique V1 multi-passes :
/// 1. Adresse avec code postal FR : "26 rue X, 88000 Épinal, France" → "Épinal"
/// 2. Adresse multi-segments : ", Bangkok, Thaïlande" → "Bangkok"
/// 3. Fallback nom de l'hôtel : dernier mot capitalisé non-stopword
///    ("Best Western Epinal" → "Epinal", "Royal Mansour Marrakech" → "Marrakech")
/// Retourne null si rien n'est extractible. À terme : ajouter un champ
/// explicite `city` dans `TripDocument.metadata` saisi au formulaire.
String? _extractCityFromHotel(TripDocument hotel) {
  final addr = hotel.metadata['address'] as String?;
  if (addr != null && addr.trim().isNotEmpty) {
    // 1. Code postal 4-5 chiffres puis ville (jusqu'à virgule ou fin)
    final postalMatch = RegExp(r'\b\d{4,5}\s+([^,]+)').firstMatch(addr);
    if (postalMatch != null) {
      final candidate = postalMatch.group(1)?.trim();
      if (candidate != null && candidate.isNotEmpty) return candidate;
    }
    // 2. Avant-dernier segment, en nettoyant les éventuels chiffres résiduels
    final parts = addr
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length >= 2) {
      final cleaned = parts[parts.length - 2]
          .replaceAll(RegExp(r'\b\d+\b'), '')
          .trim();
      if (cleaned.isNotEmpty) return cleaned;
    }
  }
  // 3. Fallback : dernier mot "ville-like" du nom de l'hôtel. Itère depuis la
  //    fin pour matcher "Best Western Epinal" → "Epinal", "Royal Mansour
  //    Marrakech" → "Marrakech". Filtre les stopwords (chaînes hôtelières,
  //    génériques) pour éviter de retourner "Royal" ou "Hotel".
  final words = hotel.name.split(RegExp(r'\s+'));
  for (final w in words.reversed) {
    final clean = w.replaceAll(RegExp(r'[^a-zA-ZÀ-ÿ\-]'), '');
    if (clean.length < 4) continue;
    if (clean[0] != clean[0].toUpperCase()) continue;
    if (_hotelNameStopwords.contains(clean)) continue;
    return clean;
  }
  return null;
}

/// Construit la séquence de villes du parcours à partir des hôtels triés par
/// check-in ASC. Supprime les doublons consécutifs (Nancy → Nancy → Épinal
/// devient Nancy → Épinal). Skip les hôtels sans ville extractible.
List<String> _journeyCities(List<TripDocument> hotels) {
  final cities = <String>[];
  for (final h in hotels) {
    final c = _extractCityFromHotel(h);
    if (c == null || c.isEmpty) continue;
    if (cities.isNotEmpty && cities.last.toLowerCase() == c.toLowerCase()) continue;
    cities.add(c);
  }
  return cities;
}

/// Statut d'avancement d'un voyage. Calculé à partir du Trip + de ses
/// dépendances (activités, étapes, kind de destination). Préparé extensible :
/// V1 = 3 statuts simples ; en V2 on pourra ajouter `inProgress`/`past` quand
/// on les voudra.
enum _TripStatus {
  /// Destination = pays/région ET aucune étape — l'utilisateur doit préciser
  /// au moins une ville pour que l'IA sache où chercher.
  toComplete,
  /// ≥1 étape définie ET 0 activité — l'utilisateur peut générer le planning.
  readyToPlan,
  /// ≥1 activité — le voyage est prêt à consulter / ajuster.
  ready,
}

class _TripDetail extends ConsumerStatefulWidget {
  final Trip trip;
  const _TripDetail({required this.trip});

  @override
  ConsumerState<_TripDetail> createState() => _TripDetailState();
}

class _TripDetailState extends ConsumerState<_TripDetail> {
  /// Type de destination détecté via Places autocomplete au boot. Sert à
  /// distinguer "destination ville" (auto-création possible d'étape par défaut)
  /// vs "destination pays/région" (nécessite des étapes explicites).
  /// `null` au boot = en cours de détection ; `'unknown'` = échec / saisie manuelle
  /// non présente dans Places. On traite `unknown` comme une ville par défaut
  /// (ne bloque rien), mais le statut "À compléter" ne se déclenche que pour
  /// `country`/`region` confirmés.
  String? _destinationKind;

  Trip get trip => widget.trip;

  static const _months = [
    'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
    'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
  ];

  @override
  void initState() {
    super.initState();
    _detectDestinationKind();
  }

  Future<void> _detectDestinationKind() async {
    final dest = trip.destination.trim();
    if (dest.isEmpty) {
      if (mounted) setState(() => _destinationKind = 'unknown');
      return;
    }
    try {
      final places = ref.read(placesServiceProvider);
      final results = await places.autocompleteDestinations(dest).timeout(const Duration(seconds: 5));
      if (!mounted) return;
      if (results.isEmpty) {
        setState(() => _destinationKind = 'unknown');
        return;
      }
      // Prend la 1ère suggestion dont le mainText matche exactement la destination
      // pour éviter les homonymies (cf. trip_edit_sheet._detectInitialKind).
      final exact = results.where((r) => r.mainText.toLowerCase() == dest.toLowerCase());
      final pick = exact.isNotEmpty ? exact.first : results.first;
      setState(() => _destinationKind = pick.kind);
    } catch (e) {
      developer.log('[api-0.6d] _detectDestinationKind error for "$dest": $e', name: 'api_guard');
      if (mounted) setState(() => _destinationKind = 'unknown');
    }
  }

  /// Calcule le statut courant du voyage. `activitiesCount` vient d'un provider
  /// async — quand il est null (pas encore chargé), on ne montre pas de badge
  /// pour ne pas afficher "À compléter" puis "Voyage prêt" juste après le boot.
  _TripStatus? _computeStatus(int? activitiesCount) {
    if (activitiesCount == null) return null;
    if (activitiesCount > 0) return _TripStatus.ready;
    final hasSegments = trip.itinerarySegments.isNotEmpty;
    final destIsLarge = _destinationKind == 'country' || _destinationKind == 'region';
    if (destIsLarge && !hasSegments) return _TripStatus.toComplete;
    return _TripStatus.readyToPlan;
  }

  String _formatRange() {
    if (trip.hasUnspecifiedPeriod) return 'Dates à préciser';
    // Recommandation Lunao : préfixe "Recommandé" pour distinguer du choix
    // utilisateur libre. Cf. `feedback` review commit 3.
    if (trip.hasRecommendedPeriod) {
      return 'Recommandé : ${trip.targetPeriodLabel ?? "période à définir"}';
    }
    // Mois cible choisi librement par l'utilisateur.
    if (!trip.hasExactDates) {
      return 'Plutôt en ${trip.targetPeriodLabel ?? "période à définir"}';
    }
    final s = trip.startDate;
    final e = trip.endDate;
    final sameMonth = s.month == e.month && s.year == e.year;
    if (sameMonth) {
      return '${s.day} – ${e.day} ${_months[e.month - 1]} ${e.year} • ${trip.durationDays} jours';
    }
    return '${s.day} ${_months[s.month - 1]} – ${e.day} ${_months[e.month - 1]} ${e.year} • ${trip.durationDays} jours';
  }

  /// Sous-titre court pour le header : "21 jours · 11–31 mai 2026".
  String _headerSubtitle() {
    if (trip.hasUnspecifiedPeriod) return 'Dates à préciser';
    if (trip.hasRecommendedPeriod) {
      return 'Recommandé : ${trip.targetPeriodLabel ?? "période à définir"}';
    }
    if (!trip.hasExactDates) {
      return 'Plutôt en ${trip.targetPeriodLabel ?? "période à définir"}';
    }
    final s = trip.startDate;
    final e = trip.endDate;
    final sameMonth = s.month == e.month && s.year == e.year;
    final dates = sameMonth
        ? '${s.day}–${e.day} ${_months[e.month - 1]} ${e.year}'
        : '${s.day} ${_months[s.month - 1]} – ${e.day} ${_months[e.month - 1]} ${e.year}';
    return '${trip.durationDays} jour${trip.durationDays > 1 ? "s" : ""} · $dates';
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  /// Mode "clé en main" V1 — chaîne complète :
  /// 1. `regional_loop_sheet` propose les villes via Gemini, l'user coche → segments
  /// 2. Update DB `trips.itinerary_segments`
  /// 3. Loader bloquant `_TurnkeyPlanningLoaderDialog` ouvert
  /// 4. `runAutoPlacesFirst` génère les `ActivitySuggestion`
  /// 5. Insert batch dans `trip_activities`
  /// 6. Invalide les providers, ferme le loader, navigue vers /planning
  ///
  /// **Self-healing** : si étape 4 ou 5 plante après étape 2 réussie, on garde
  /// les segments créés et on affiche un toast explicite. L'user retombe alors
  /// naturellement sur le `_NextStepCard` Cas 2 ("Ton planning n'est pas encore
  /// prêt" + CTA "Générer mon planning") qui le relance via le flow normal.
  Future<void> _runTurnkeyItinerary() async {
    final segments = await openRegionalLoopSheet(
      context, ref,
      mainDestination: trip.destination,
      durationDays: trip.durationDays,
      travelerType: trip.travelerType,
      interests: trip.interests ?? const [],
      destinationKind: _destinationKind,
      tripId: trip.id,
      // Si le pays a été détecté précédemment (persisté en BDD), on l'utilise.
      // Active le flow régions pour les pays large/travel_region.
      countryCode: trip.destinationCountryCode,
    );
    if (segments == null || segments.isEmpty || !mounted) return;
    try {
      await ref.read(supabaseProvider).from('trips').update({
        'itinerary_segments': segments.map((s) => s.toJson()).toList(),
      }).eq('id', trip.id);
      ref.invalidate(tripsProvider);
      ref.invalidate(tripByIdProvider(trip.id));
      if (!mounted) return;
    } catch (e) {
      if (mounted) {
        // Wording humanisé : un user qui voit
        // "Erreur : ClientException: Connection reset by peer, uri=https://..."
        // ne comprend rien. On classifie selon le type d'erreur pour
        // afficher quelque chose d'actionnable.
        final raw = e.toString();
        final isNetwork = raw.contains('SocketException') ||
            raw.contains('Failed host lookup') ||
            raw.contains('TimeoutException') ||
            raw.contains('ClientException') ||
            raw.contains('Connection reset') ||
            raw.contains('Connection refused') ||
            raw.contains('Network is unreachable');
        final msg = isNetwork
            ? 'Pas de connexion internet. Vérifie ta connexion et réessaie.'
            : 'Quelque chose a coincé. Réessaie dans un instant.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: AppColors.error),
        );
      }
      return;
    }
    // Étape 2/2 : génération du planning. Si plante, self-healing (toast +
    // l'user reste sur le détail voyage et voit le Cas 2 "Générer mon planning").
    await _runTurnkeyPlanningGeneration();
  }

  /// Étape 2/2 du flow clé en main : génère le planning auto via
  /// `runAutoPlacesFirst` pendant qu'un loader bloquant tient l'écran.
  /// Insère en batch dans `trip_activities`. Fermeture + navigation au succès,
  /// toast graceful à l'échec (segments conservés, l'user retombe sur Cas 2).
  Future<void> _runTurnkeyPlanningGeneration() async {
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    var dialogClosed = false;
    void closeLoader() {
      if (!dialogClosed) {
        dialogClosed = true;
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
    var cancelled = false;
    void showInfo(String msg) {
      if (cancelled) return;
      if (!mounted) return;
      closeLoader();
      messenger.showSnackBar(
        SnackBar(
          content: Text(msg, maxLines: 4),
          duration: const Duration(seconds: 8),
          backgroundColor: AppColors.accent,
        ),
      );
    }

    // Loader bloquant : barrierDismissible: false + PopScope dans le widget
    // pour empêcher aussi le bouton retour Android pendant la génération.
    // Le bouton « Annuler la génération » (onCancel) est le SEUL moyen de
    // sortir : il lève `cancelled` qui bloque l'INSERT batch et le go().
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TurnkeyPlanningLoaderDialog(
        onCancel: () {
          cancelled = true;
          closeLoader();
        },
      ),
    );

    try {
      // Trip frais (avec les segments fraîchement créés). On lit via le
      // provider pour bénéficier du cache + invalidations.
      final freshTrip = await ref.read(tripByIdProvider(trip.id).future);
      if (cancelled) return;
      if (freshTrip == null) throw Exception('Voyage introuvable');
      final hotels = await ref.read(tripHotelsProvider(trip.id).future);
      if (cancelled) return;
      final existingActivities = await ref.read(tripActivitiesProvider(trip.id).future);
      if (cancelled) return;
      String norm(String s) => s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
      final existingTitlesNormalized = existingActivities.map((a) => norm(a.title)).toSet();

      // Timeout de 60s : `runAutoPlacesFirst` enchaîne plusieurs appels Places
      // Nearby + Geocoding + Gemini. Sans réseau (cas wifi coupé en test ou
      // utilisateur en zone blanche pendant le voyage), ces calls peuvent
      // bloquer indéfiniment (HTTP socket sans timeout par défaut). Le
      // timeout fait throw une `TimeoutException` qui tombe dans le catch
      // → fermeture du loader + toast graceful + retombe sur Cas 2.
      // V8.4 (Lalith 2026-05-10) — flow turnkey passe en
      // `category=activities` pour s'aligner sur la décision produit
      // 0e24288 (restos retirés de l'auto-gen). Le turnkey ne doit
      // pas insérer de repas non plus, sinon on contourne la décision.
      final suggestions = await runAutoPlacesFirst(
        trip: freshTrip,
        hotels: hotels,
        geocoder: ref.read(geocodingServiceProvider),
        nearbyService: ref.read(placesNearbyServiceProvider),
        aiService: ref.read(aiSuggestionsServiceProvider),
        category: SuggestionCategory.activities,
        existingTitlesNormalized: existingTitlesNormalized,
        languageCode: 'fr',
        poiRepository: ref.read(poiRepositoryProvider),
      ).timeout(const Duration(seconds: 60));
      // GUARD CRITIQUE : empêche l'INSERT batch et le go() si l'utilisateur
      // a annulé pendant que runAutoPlacesFirst tournait. Sans ce guard, on
      // créerait des activités fantômes en DB et on naviguerait de force
      // alors que l'utilisateur a explicitement demandé d'annuler.
      if (cancelled) return;

      if (suggestions.isNotEmpty) {
        final rows = suggestions.map((s) => s.toInsertJson(trip.id)).toList();
        await ref.read(supabaseProvider).from('trip_activities').insert(rows);
        if (cancelled) return;
      }
      ref.invalidate(tripActivitiesProvider(trip.id));
      ref.invalidate(tripTransportsProvider(trip.id));

      if (cancelled) return;
      if (!mounted) return;
      closeLoader();
      router.go('/trips/${trip.id}/planning');
    } on LiveApiBlockedException catch (e) {
      final familyLabel = e.family == LiveApiFamily.gemini
          ? 'le service IA (Gemini)'
          : 'les services de géolocalisation (Google Maps)';
      showInfo(
        '✓ Étapes créées. Génération indisponible : $familyLabel est désactivé. '
        'Pour les destinations couvertes (Lisbonne, Paris, Rome, Barcelone), '
        'le mode Auto utilise les POIs Lunao sans appel externe. '
        'Réessaie depuis « Générer mon planning ».',
      );
    } on TimeoutException catch (_) {
      showInfo(
        '✓ Étapes créées. La génération a mis trop de temps à répondre. Vérifie ta connexion et réessaie depuis « Générer mon planning ».',
      );
    } catch (e) {
      showInfo(
        '✓ Étapes créées. La génération du planning a échoué — réessaie depuis « Générer mon planning ».',
      );
      // Pas de navigation : l'user reste sur le détail voyage et voit
      // le _NextStepCard Cas 2 ("Ton planning n'est pas encore prêt").
    }
  }

  /// Ouvre le dialog de réinitialisation : l'user choisit ce qu'il veut
  /// effacer (étapes / planning / documents). Cas d'usage : préparation de
  /// voyage en multi-simulations (tester différents itinéraires sans recréer
  /// le voyage de zéro). Action **neutre** (bleu primary, pas error rouge) —
  /// la suppression complète reste un autre bouton distinct.
  ///
  /// Le détachement des documents (`trip_id := null`) les conserve dans le
  /// wallet global, l'user peut les rattacher à un autre voyage. Les
  /// activités du planning sont supprimées **avec** leurs trajets associés
  /// (FK : trip_transports référencerait des activities inexistantes).
  Future<void> _openResetTripDialog(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<_ResetChoices>(
      context: context,
      builder: (_) => _ResetTripDialog(trip: trip),
    );
    if (result == null || !result.hasAny) return;
    final client = ref.read(supabaseProvider);
    try {
      // Ordre des deletes : trajets avant activités (FK trip_transports →
      // trip_activities), puis le reste. Toujours batch-éable côté Supabase.
      if (result.planning) {
        await client.from('trip_transports').delete().eq('trip_id', trip.id);
        await client.from('trip_activities').delete().eq('trip_id', trip.id);
      }
      if (result.documents) {
        await client.from('trip_documents').update({'trip_id': null}).eq('trip_id', trip.id);
      }
      if (result.segments) {
        await client.from('trips').update({
          'itinerary_segments': const <Map<String, dynamic>>[],
        }).eq('id', trip.id);
      }
      // Invalidations en cascade pour rafraîchir l'UI partout (détail,
      // wallet, planning…).
      ref.invalidate(tripsProvider);
      ref.invalidate(tripByIdProvider(trip.id));
      if (result.planning) {
        ref.invalidate(tripActivitiesProvider(trip.id));
        ref.invalidate(tripTransportsProvider(trip.id));
      }
      if (result.documents) {
        ref.invalidate(tripDocumentsProvider(trip.id));
        ref.invalidate(documentsProvider);
      }
      // Toast récapitulatif : ce qui a été effacé.
      final parts = <String>[];
      if (result.segments) parts.add('étapes');
      if (result.planning) parts.add('planning');
      if (result.documents) parts.add('documents détachés');
      messenger.showSnackBar(SnackBar(
        content: Text('✓ Voyage réinitialisé : ${parts.join(', ')}'),
        duration: const Duration(seconds: 4),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Erreur lors de la réinitialisation : $e'),
        backgroundColor: AppColors.error,
        duration: const Duration(seconds: 8),
      ));
    }
  }

  /// Modal obligatoire de suppression — appelé depuis la section "Actions"
  /// en bas de page. Wording aligné sur la spec V3 (court et direct, l'utilisateur
  /// est déjà dans la zone "Actions" donc on n'a pas besoin de réexpliquer).
  Future<void> _confirmDeleteTrip(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Supprimer ce voyage ?'),
        content: const Text('Cette action est définitive.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await deleteTripCascade(ref.read(supabaseProvider), trip.id);
      ref.invalidate(tripsProvider);
      ref.invalidate(hasTripsProvider);
      ref.invalidate(documentsProvider);
      messenger.showSnackBar(SnackBar(content: Text('« ${trip.title} » supprimé.')));
      router.go('/trips');
    } catch (e, st) {
      // Cascade peut avoir échoué partiellement → on rafraîchit l'UI quand
      // même. AlertDialog plutôt que SnackBar : l'erreur reste affichée et
      // sélectable jusqu'au dismissal manuel (un SnackBar disparait avant
      // lecture quand l'écran rebuild après invalidate).
      debugPrint('[trip-delete] échec suppression voyage ${trip.id} : $e');
      debugPrint('[trip-delete] stack: $st');
      ref.invalidate(tripsProvider);
      ref.invalidate(hasTripsProvider);
      ref.invalidate(documentsProvider);
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('Erreur lors de la suppression'),
          content: SelectableText(_humanizeDeleteError(e)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  /// Wording humanisé du message d'erreur de suppression. L'erreur brute
  /// `ClientException with SocketException: Failed host lookup: ...` est
  /// incompréhensible pour un utilisateur — on classifie selon le type
  /// pour donner une explication actionnable.
  String _humanizeDeleteError(Object e) {
    final raw = e.toString();
    if (raw.contains('SocketException') ||
        raw.contains('Failed host lookup') ||
        raw.contains('TimeoutException') ||
        raw.contains('ClientException') ||
        raw.contains('Connection reset') ||
        raw.contains('Connection refused') ||
        raw.contains('Network is unreachable') ||
        raw.contains('No address associated')) {
      return 'Pas de connexion internet. Vérifie ta connexion et réessaie.';
    }
    return 'Quelque chose a coincé lors de la suppression. Réessaie dans un instant.';
  }

  @override
  Widget build(BuildContext context) {
    final docsAsync = ref.watch(tripDocumentsProvider(trip.id));
    final docs = docsAsync.valueOrNull ?? const <TripDocument>[];
    final hotelsAsync = ref.watch(tripHotelsProvider(trip.id));
    final hotels = hotelsAsync.valueOrNull ?? const <TripDocument>[];
    // Refonte UX 2026-05-13 : on découpe les non-hôtels en transports /
    // réservations & activités / autres pour éviter une longue liste
    // verticale de DocumentCard. Les groupes sont déjà triés chrono par
    // [classifyTripDocuments]. Aucun doc n'est jeté : le groupe `others`
    // est le fallback.
    final grouped = classifyTripDocuments(docs);
    final transports = grouped.transports;
    final tickets = grouped.tickets;
    final otherDocs = grouped.others;

    final budget = ref.watch(tripBudgetProvider(trip.id)).valueOrNull;
    final userCurrency = ref.watch(userCurrencyProvider);
    final budgetLabel = (budget != null && budget.total > 0)
        ? '~${CurrencyService.formatAmount(budget.total, userCurrency)}'
        : null;

    final activitiesAsync = ref.watch(tripActivitiesProvider(trip.id));
    final activitiesCount = activitiesAsync.valueOrNull?.length;
    final status = _computeStatus(activitiesCount);

    return CustomScrollView(
      slivers: [
        const OfflineSliverBanner(),
        SliverAppBar(
          // Header plus haut pour accommoder emoji 64px aligné gauche + titre
          // + sous-titre + badge statut. 240px laisse respirer sans déborder.
          expandedHeight: 240,
          pinned: true,
          backgroundColor: AppColors.primary,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => context.go('/trips'),
          ),
          actions: [
            // Bouton Modifier visible : icône + texte. Plus parlant que la
            // simple icône crayon de l'ancienne version. Supprimer n'est PLUS
            // ici — il vit dans la section "Actions" en bas de la page (zone
            // safe contre les clics accidentels mobile, voir spec V3).
            TextButton.icon(
              onPressed: () => openTripEditSheet(context, ref, trip: trip),
              icon: const Icon(Icons.edit_outlined, color: Colors.white, size: 18),
              label: const Text('Modifier', style: TextStyle(color: Colors.white)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
          ],
          flexibleSpace: FlexibleSpaceBar(
            // Pas de `title:` ici : le grand titre du `background` (Stack)
            // suffit en expanded. En collapsed, on n'affiche pas de titre dans
            // la barre — l'utilisateur sait qu'il est sur le voyage par le
            // contexte de navigation. Si un jour on veut un titre collapsed,
            // il faudrait soit doubler (complexe à gérer sans flicker),
            // soit ne garder que celui de FlexibleSpaceBar et perdre la grande
            // typo en expanded. Pour V1 le grand titre prime.
            // Background expanded : gradient subtil bleu primary → primaryDark
            // (10% d'opacité de différence — plus que ça vire kitsch). Emoji
            // 64px aligné gauche, titre grand dessous, sous-titre durée/dates,
            // badge statut outline. Layout mobile-first, padding généreux pour
            // éviter de toucher les actions du SliverAppBar.
            background: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppColors.primary, AppColors.primaryDark],
                    ),
                  ),
                ),
                // SafeArea + padding pour ne pas chevaucher les actions
                // (AppBar fait ~56px de haut + status bar). On positionne
                // le contenu dans la moitié basse de l'expanded.
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 56,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(trip.coverEmoji, style: const TextStyle(fontSize: 56)),
                      const SizedBox(height: 8),
                      Text(
                        trip.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 26,
                          height: 1.1,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              budgetLabel != null
                                  ? '${_headerSubtitle()} · $budgetLabel'
                                  : _headerSubtitle(),
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (status != null) ...[
                            const SizedBox(width: 10),
                            _TripStatusBadge(status: status),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.all(24),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              // Card "Prochaine étape" : guide l'utilisateur sur la prochaine
              // action selon l'état du voyage. Affichée pour 2 cas seulement :
              // - `toComplete` : destination=country/region + 0 étape
              // - `readyToPlan` : ≥1 étape + 0 activité
              // Le cas "voyage prêt" est volontairement masqué (Lalith 27/04) :
              // il ferait doublon avec la card Planning enrichie en bas qui
              // dit déjà "X jours planifiés" et mène au même écran.
              if (status == _TripStatus.toComplete || status == _TripStatus.readyToPlan)
                _NextStepCard(
                  trip: trip,
                  destinationKind: _destinationKind,
                  nextCase: status == _TripStatus.toComplete
                      ? _NextStepCase.discoverItinerary
                      : _NextStepCase.generatePlan,
                  onPrimary: status == _TripStatus.toComplete
                      ? _runTurnkeyItinerary
                      : () => context.go('/trips/${trip.id}/planning'),
                  onSecondary: status == _TripStatus.toComplete
                      ? () => openTripEditSheet(context, ref, trip: trip)
                      : null,
                ),
              _InfoRow(icon: Icons.location_on, text: trip.destination),
              const SizedBox(height: 12),
              _InfoRow(icon: Icons.calendar_today, text: _formatRange()),
              if (trip.travelers.isNotEmpty) ...[
                const SizedBox(height: 12),
                _InfoRow(
                  icon: Icons.group,
                  text: '${trip.travelers.length} voyageur${trip.travelers.length > 1 ? 's' : ''} · ${trip.travelers.map((t) => '${t.name} (${t.age})').join(', ')}',
                ),
              ],
              const SizedBox(height: 24),

              // Bloc Hébergement(s) — carrousel swipeable (une carte visible à la fois)
              // pour que le bouton Planning reste proche du haut même sur un road trip 15 jours.
              if (hotels.isEmpty)
                _QuickActionTile(
                  emoji: '🏨',
                  label: 'Où dors-tu ?',
                  subtitle: 'Ajoute hôtel, Airbnb ou adresse',
                  onTap: () => openDocumentFormSheet(
                    context, ref,
                    initialTripId: trip.id,
                    initialCategory: DocumentCategory.hotel,
                  ),
                )
              else ...[
                // Parcours léger : "Nancy → Épinal" en gris caption, sans fond.
                // Vue d'ensemble seulement, affiché à partir de 2 villes
                // uniques. Règle "1 info = 1 endroit" : ici uniquement les villes,
                // pas les dates (les dates sont dans le step actif et la card).
                if (_journeyCities(hotels).length >= 2) ...[
                  _JourneyOverview(cities: _journeyCities(hotels)),
                  const SizedBox(height: 10),
                ],
                _HotelsCarousel(hotels: hotels, fmtDate: _fmtDate),
                const SizedBox(height: 10),
                _QuickActionTile(
                  emoji: '🏨',
                  label: 'Ajouter un autre hébergement',
                  subtitle: 'Hôtel, Airbnb ou adresse complémentaire',
                  onTap: () => openDocumentFormSheet(
                    context, ref,
                    initialTripId: trip.id,
                    initialCategory: DocumentCategory.hotel,
                  ),
                ),
              ],

              // Transports — carrousel positionné par défaut sur le prochain
              // transport à venir (vol/train/location). Évite d'empiler un
              // flight, un train et un bus sous "Autres documents".
              if (transports.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('TRANSPORTS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                const SizedBox(height: 10),
                _DocumentsCarousel(
                  documents: transports,
                  group: TripDocumentGroup.transport,
                ),
              ],

              // Réservations & activités (billets : spectacles, parcs, musées,
              // tours, événements). Même logique de carrousel chronologique.
              if (tickets.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('RÉSERVATIONS & ACTIVITÉS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                const SizedBox(height: 10),
                _DocumentsCarousel(
                  documents: tickets,
                  group: TripDocumentGroup.ticket,
                ),
              ],

              // Fallback : documents non classifiés (catégorie `other` ou
              // inconnue). Affichage liste verticale historique pour ne
              // jamais cacher un document.
              if (otherDocs.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('AUTRES DOCUMENTS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                const SizedBox(height: 10),
                for (final d in otherDocs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: DocumentCard(
                      doc: d,
                      onTap: () => openDocumentFormSheet(context, ref, existing: d),
                    ),
                  ),
              ],

              const SizedBox(height: 12),
              _QuickActionTile(
                emoji: '📄',
                label: (transports.isEmpty && tickets.isEmpty && otherDocs.isEmpty)
                    ? 'Ajoute tes réservations'
                    : 'Ajouter une réservation',
                subtitle: 'Vols, billets, confirmations',
                onTap: () => openDocumentFormSheet(context, ref, initialTripId: trip.id),
              ),
              const SizedBox(height: 20),

              // Cards principales avec sous-texte dynamique. Toutes 3 ont la
              // même logique de visibilité : on n'affiche QUE si elles ont
              // quelque chose de concret à offrir, pour ne pas surcharger la
              // page d'accès à des écrans vides.
              // - Planning : ≥1 activité (sinon `_NextStepCard` propose déjà
              //   "Générer mon planning")
              // - Documents : ≥1 doc (sinon les tuiles "Où dors-tu ?" /
              //   "Ajoute tes réservations" en haut suffisent ; /wallet reste
              //   accessible via la bottom nav)
              // - Carte : ≥1 activité (sans planning, la map est forcément vide)
              if (activitiesCount != null && activitiesCount > 0) ...[
                _RichActionCard(
                  icon: Icons.calendar_month,
                  label: 'Planning',
                  subtitle: () {
                    final activities = activitiesAsync.valueOrNull ?? const [];
                    final daysWith = activities
                        .map((a) => DateTime(a.dayDate.year, a.dayDate.month, a.dayDate.day))
                        .toSet()
                        .length;
                    return '$daysWith jour${daysWith > 1 ? "s" : ""} planifié${daysWith > 1 ? "s" : ""}';
                  }(),
                  onTap: () => context.go('/trips/${trip.id}/planning'),
                ),
                const SizedBox(height: 12),
              ],
              if (docs.isNotEmpty) ...[
                _RichActionCard(
                  icon: Icons.wallet,
                  label: 'Documents',
                  subtitle: 'Billets, hôtels, confirmations',
                  // Vue filtrée sur ce voyage uniquement (depuis l'écran détail
                  // voyage l'user est dans la "bulle" de ce voyage). Le Wallet
                  // global reste accessible via la nav principale.
                  onTap: () => context.go('/trips/${trip.id}/documents'),
                ),
                const SizedBox(height: 12),
              ],
              if (activitiesCount != null && activitiesCount > 0)
                _RichActionCard(
                  icon: Icons.map,
                  label: 'Carte',
                  subtitle: 'Voir les lieux de ton voyage',
                  onTap: () => context.go('/trips/${trip.id}/map'),
                ),
              // Section "Actions" en bas — séparée des actions principales
              // pour héberger les actions destructives. Position basse =
              // hors zone de clic accidentel (UX mobile safe selon spec V3).
              const SizedBox(height: 32),
              Text(
                'ACTIONS',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 8),
              // Réinitialiser : action neutre (pas destructive), permet de
              // remettre à zéro un voyage pour tester une nouvelle simulation
              // sans recréer (cas typique : voyageur explore plusieurs
              // organisations possibles avant de fixer son choix).
              InkWell(
                onTap: () => _openResetTripDialog(context, ref),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.restart_alt, color: AppColors.primary, size: 20),
                      const SizedBox(width: 12),
                      Text(
                        'Réinitialiser ce voyage',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              InkWell(
                onTap: () => _confirmDeleteTrip(context, ref),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline, color: AppColors.error, size: 20),
                      const SizedBox(width: 12),
                      Text(
                        'Supprimer ce voyage',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.error,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ]),
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.primary, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text, style: TextStyle(color: AppColors.textSecondary, fontSize: 15)),
        ),
      ],
    );
  }
}

/// Carrousel horizontal des hébergements : une seule carte visible, swipe pour changer.
/// Démarre sur l'hôtel qui couvre ce soir (ou le premier à venir).
class _HotelsCarousel extends StatefulWidget {
  final List<TripDocument> hotels;
  final String Function(DateTime) fmtDate;
  const _HotelsCarousel({required this.hotels, required this.fmtDate});

  @override
  State<_HotelsCarousel> createState() => _HotelsCarouselState();
}

class _HotelsCarouselState extends State<_HotelsCarousel> {
  late final PageController _controller;
  late int _currentPage;

  // 124 — la transition "Arrivée depuis X" est maintenant au-dessus du
  // carrousel (step actif), donc la card revient à sa hauteur initiale.
  // Hauteur fixée pour absorber les warnings UX (dates manquantes, adresse
  // introuvable) sans overflow, même quand les 2 sont présents simultanément.
  static const double _cardHeight = 150;

  int _initialIndex() =>
      findInitialAccommodationIndex(widget.hotels, DateTime.now());

  @override
  void initState() {
    super.initState();
    _currentPage = _initialIndex();
    _controller = PageController(initialPage: _currentPage);
  }

  @override
  void didUpdateWidget(covariant _HotelsCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si un hôtel est ajouté/supprimé et que l'index courant sort des bornes, on recale.
    if (_currentPage >= widget.hotels.length) {
      _currentPage = widget.hotels.length - 1;
      if (_controller.hasClients) {
        _controller.jumpToPage(_currentPage);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Couleur du dot de position : vert si début, rouge si fin, bleu sinon
  /// (étape intermédiaire ou hôtel solo). Spec Lalith 28/04 brief premium.
  Color _positionColor(int index, int total) {
    if (total == 1) return AppColors.primary;
    if (index == 0) return AppColors.success;
    if (index == total - 1) return AppColors.error;
    return AppColors.primary;
  }

  /// Format compact "7–8 mai" si même mois, "30 avril – 2 mai" sinon.
  /// Sans année (déjà dans le header du voyage).
  static const _monthsShort = [
    'janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin',
    'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.',
  ];
  String _formatStay(DateTime ci, DateTime co) {
    if (ci.month == co.month && ci.year == co.year) {
      return '${ci.day}–${co.day} ${_monthsShort[ci.month - 1]}';
    }
    return '${ci.day} ${_monthsShort[ci.month - 1]} – ${co.day} ${_monthsShort[co.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final hotels = widget.hotels;
    final dotColor = _positionColor(_currentPage, hotels.length);
    final current = hotels[_currentPage];
    final currentCity = _extractCityFromHotel(current);
    final previousCity = _currentPage > 0
        ? _extractCityFromHotel(hotels[_currentPage - 1])
        : null;
    // Construction du libellé du step actif : "Épinal · 7–8 mai · 1 nuit"
    final ciStr = current.metadata['check_in'];
    final coStr = current.metadata['check_out'];
    final ci = ciStr is String ? DateTime.tryParse(ciStr) : null;
    final co = coStr is String ? DateTime.tryParse(coStr) : null;
    final stayParts = <String>[];
    if (currentCity != null && currentCity.isNotEmpty) stayParts.add(currentCity);
    if (ci != null && co != null) {
      stayParts.add(_formatStay(ci, co));
      final nights = co.difference(ci).inDays;
      if (nights > 0) stayParts.add('$nights nuit${nights > 1 ? "s" : ""}');
    }
    final stepLabel = stayParts.join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // STEP ACTIF — combine position + ville + dates + nuits sur une ligne,
        // avec la transition "Arrivée depuis X" en sous-ligne discrète.
        // AnimatedSwitcher pour transition douce au swipe (fade 180ms).
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: Padding(
            // Key dépend du currentPage pour déclencher l'animation au swipe
            key: ValueKey('step-$_currentPage-$stepLabel'),
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 9, height: 9,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        stepLabel.isEmpty ? 'Hébergement' : stepLabel,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (previousCity != null) ...[
                  const SizedBox(height: 2),
                  Padding(
                    padding: const EdgeInsets.only(left: 17),
                    child: Text(
                      'Arrivée depuis $previousCity',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        SizedBox(
          height: _cardHeight,
          child: PageView.builder(
            controller: _controller,
            itemCount: hotels.length,
            onPageChanged: (i) => setState(() => _currentPage = i),
            itemBuilder: (_, i) => _HotelCard(
              hotel: hotels[i],
              fmtDate: widget.fmtDate,
            ),
          ),
        ),
        if (hotels.length > 1) ...[
          const SizedBox(height: 8),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(hotels.length, (i) {
                final active = i == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: active ? AppColors.primary : AppColors.border,
                    borderRadius: BorderRadius.circular(3),
                  ),
                );
              }),
            ),
          ),
        ],
      ],
    );
  }
}

class _HotelCard extends ConsumerWidget {
  final TripDocument hotel;
  final String Function(DateTime) fmtDate;
  const _HotelCard({
    required this.hotel,
    required this.fmtDate,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: () => openDocumentFormSheet(context, ref, existing: hotel),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('🏨', style: TextStyle(fontSize: 28)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(hotel.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  if (hotel.metadata['address'] != null) ...[
                    const SizedBox(height: 2),
                    Text(hotel.metadata['address'] as String, style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  ],
                  if (hotel.metadata['check_in'] != null || hotel.metadata['check_out'] != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (hotel.metadata['check_in'] != null) 'Check-in ${fmtDate(DateTime.parse(hotel.metadata['check_in'] as String))}',
                        if (hotel.metadata['check_out'] != null) 'Check-out ${fmtDate(DateTime.parse(hotel.metadata['check_out'] as String))}',
                      ].join(' · '),
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ],
                  if (hotel.reservationNumber != null) ...[
                    const SizedBox(height: 4),
                    Text('N° ${hotel.reservationNumber}', style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontStyle: FontStyle.italic)),
                  ],
                  HotelDocWarnings(doc: hotel, fontSize: 11),
                ],
              ),
            ),
            Icon(Icons.edit, size: 16, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// Carrousel horizontal générique pour les groupes "transports" et
/// "réservations & activités". Réutilise [DocumentCard] (badge catégorie,
/// route, date, n° de réservation, chevron) — un swipe = un document.
///
/// L'index initial est calculé par [findInitialTransportIndex] /
/// [findInitialTicketIndex] : prochain à venir > plus récent passé > 0.
/// L'auto-recalage post-mutation (ajout/suppression) garde l'index dans
/// les bornes même quand la liste change.
class _DocumentsCarousel extends ConsumerStatefulWidget {
  final List<TripDocument> documents;
  final TripDocumentGroup group;
  const _DocumentsCarousel({
    required this.documents,
    required this.group,
  });

  @override
  ConsumerState<_DocumentsCarousel> createState() =>
      _DocumentsCarouselState();
}

class _DocumentsCarouselState extends ConsumerState<_DocumentsCarousel> {
  late final PageController _controller;
  late int _currentPage;

  int _initialIndex() {
    final now = DateTime.now();
    switch (widget.group) {
      case TripDocumentGroup.transport:
        return findInitialTransportIndex(widget.documents, now);
      case TripDocumentGroup.ticket:
        return findInitialTicketIndex(widget.documents, now);
      case TripDocumentGroup.accommodation:
      case TripDocumentGroup.other:
        return 0;
    }
  }

  TripDocumentStatus _statusOf(TripDocument doc) {
    final now = DateTime.now();
    switch (widget.group) {
      case TripDocumentGroup.transport:
        return transportStatus(doc, now);
      case TripDocumentGroup.ticket:
        return ticketStatus(doc, now);
      case TripDocumentGroup.accommodation:
        return accommodationStatus(doc, now);
      case TripDocumentGroup.other:
        return TripDocumentStatus.unknown;
    }
  }

  @override
  void initState() {
    super.initState();
    _currentPage = _initialIndex();
    _controller = PageController(initialPage: _currentPage);
  }

  @override
  void didUpdateWidget(covariant _DocumentsCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_currentPage >= widget.documents.length) {
      _currentPage = (widget.documents.length - 1)
          .clamp(0, widget.documents.length);
      if (_controller.hasClients && widget.documents.isNotEmpty) {
        _controller.jumpToPage(_currentPage);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _statusLabel(TripDocumentStatus s) {
    switch (s) {
      case TripDocumentStatus.current:
        return 'En cours';
      case TripDocumentStatus.upcoming:
        return 'Prochain';
      case TripDocumentStatus.past:
        return 'Passé';
      case TripDocumentStatus.unknown:
        return null;
    }
  }

  Color _statusColor(TripDocumentStatus s) {
    switch (s) {
      case TripDocumentStatus.current:
        return AppColors.success;
      case TripDocumentStatus.upcoming:
        return AppColors.primary;
      case TripDocumentStatus.past:
        return AppColors.textSecondary;
      case TripDocumentStatus.unknown:
        return AppColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final docs = widget.documents;
    if (docs.isEmpty) return const SizedBox.shrink();
    final current = docs[_currentPage.clamp(0, docs.length - 1)];
    final status = _statusOf(current);
    final statusLabel = _statusLabel(status);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (statusLabel != null)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: Padding(
              key: ValueKey('doc-status-$_currentPage-$statusLabel'),
              padding: const EdgeInsets.only(bottom: 8, left: 2),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _statusColor(status),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    statusLabel,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _statusColor(status),
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        // Hauteur fixée pour absorber 2 lignes de subtitle + warnings sans
        // overflow ; alignée sur la DocumentCard standard utilisée ailleurs.
        SizedBox(
          height: 112,
          child: PageView.builder(
            controller: _controller,
            itemCount: docs.length,
            onPageChanged: (i) => setState(() => _currentPage = i),
            itemBuilder: (_, i) => DocumentCard(
              doc: docs[i],
              onTap: () =>
                  openDocumentFormSheet(context, ref, existing: docs[i]),
            ),
          ),
        ),
        if (docs.length > 1) ...[
          const SizedBox(height: 8),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(docs.length, (i) {
                final active = i == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: active ? AppColors.primary : AppColors.border,
                    borderRadius: BorderRadius.circular(3),
                  ),
                );
              }),
            ),
          ),
        ],
      ],
    );
  }
}

/// Parcours du voyage : "Nancy → Épinal" en gris caption, sans fond ni icône.
/// Vue d'ensemble légère (règle d'or : ici les villes uniquement, pas les dates).
class _JourneyOverview extends StatelessWidget {
  final List<String> cities;
  const _JourneyOverview({required this.cities});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        cities.join(' → '),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: AppColors.textSecondary,
          letterSpacing: 0.2,
        ),
        overflow: TextOverflow.ellipsis,
        maxLines: 2,
      ),
    );
  }
}

/// Tuile d'action rapide avec emoji (au lieu d'une icône Material). Utilisée
/// pour les points d'entrée d'écriture rapide ("Où dors-tu ?", "Ajoute tes
/// réservations") qui méritent un style chaleureux et conversationnel —
/// distinct des cards principales de navigation (`_RichActionCard`).
class _QuickActionTile extends StatelessWidget {
  final String emoji;
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  const _QuickActionTile({
    required this.emoji,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 26)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.add, color: AppColors.primary, size: 20),
          ],
        ),
      ),
    );
  }
}

/// Card d'action enrichie : icône + label + sous-texte dynamique + chevron.
/// Remplace l'ancien `_ActionButton` qui n'avait que icône+label. Le sous-texte
/// donne un état immédiat ("8 jours planifiés", "Aucun planning pour l'instant",
/// "Billets, hôtels, confirmations") qui transforme la card de simple bouton
/// de navigation en résumé d'état du voyage.
class _RichActionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  const _RichActionCard({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: AppColors.primaryLight,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: AppColors.primary, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                      height: 1.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.arrow_forward_ios, size: 14, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// Card "Prochaine étape" : guide l'utilisateur sur l'action suivante selon
/// l'état du voyage. 3 cas dynamiques :
/// - `_NextStepCase.discoverItinerary` : destination=country/region + 0 étape
///   → 2 CTAs (clé en main / manuel)
/// - `_NextStepCase.generatePlan` : étapes définies + 0 activité
///   → 1 CTA "Générer mon planning"
/// - `_NextStepCase.viewPlan` : ≥1 activité
///   → 1 CTA "Voir le planning"
enum _NextStepCase { discoverItinerary, generatePlan, viewPlan }

class _NextStepCard extends StatelessWidget {
  final Trip trip;
  final _NextStepCase nextCase;
  /// Type de destination (`city` / `country` / `region` / `place` / `unknown`).
  /// Sert à choisir la bonne préposition française dans le titre du cas
  /// `discoverItinerary` ("au Maroc" / "en Thaïlande" / "à Bali" / "à Bangkok").
  final String? destinationKind;
  /// Callback du CTA principal (mode auto / générer / voir selon le cas).
  final VoidCallback onPrimary;
  /// Callback du CTA secondaire — utilisé uniquement dans le cas
  /// `discoverItinerary` (ajout manuel des étapes). Null pour les autres cas.
  final VoidCallback? onSecondary;

  const _NextStepCard({
    required this.trip,
    required this.nextCase,
    required this.onPrimary,
    this.destinationKind,
    this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    // Phrase grammaticalement correcte selon le pays/région : "au Maroc",
    // "en Thaïlande", "aux États-Unis", "à Bali", etc.
    final journey = _frenchJourneyPhrase(trip.destination, destinationKind);

    final (String title, String? body, String primaryLabel, String? primaryEmoji) =
        switch (nextCase) {
      _NextStepCase.discoverItinerary => (
        journey.isEmpty
            ? 'Et si on créait ton voyage ? ✨'
            : 'Et si on créait ton voyage $journey ? ✨',
        null,
        'Générer mon itinéraire',
        '✨',
      ),
      _NextStepCase.generatePlan => (
        'Ton voyage est prêt à être planifié ✨',
        null,
        'Générer mon planning',
        '✨',
      ),
      _NextStepCase.viewPlan => (
        'Ton voyage est prêt',
        'Consulte ou ajuste ton planning.',
        'Voir le planning',
        null,
      ),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      // Padding réduit (-10%) + ombre retirée pour un look plus léger. La
      // bordure subtile reste pour démarquer la card du fond sans alourdir.
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          if (body != null) ...[
            const SizedBox(height: 6),
            Text(
              body,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 12),
          // CTA principal : bouton plein bleu, plus visible. L'emoji est
          // optionnel selon le cas (✨ pour l'IA, rien pour le simple "Voir").
          ElevatedButton(
            onPressed: onPrimary,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (primaryEmoji != null) ...[
                  Text(primaryEmoji, style: const TextStyle(fontSize: 16)),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    primaryLabel,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          // CTA secondaire = OutlinedButton de même taille/radius que le principal.
          // Pattern Airbnb/Apple : 2 boutons cohérents > bouton + lien texte.
          // Pas de séparateur "OU" ni sous-texte → le titre + 2 boutons suffisent.
          if (onSecondary != null) ...[
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: onSecondary,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                side: BorderSide(color: AppColors.border),
                foregroundColor: AppColors.textPrimary,
                backgroundColor: AppColors.surface,
              ),
              child: const Text(
                'Créer moi-même',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Badge statut "outline" (bordure + texte couleur, fond transparent) — style
/// Material 3 / iOS moderne. Volontairement discret pour ne pas concurrencer
/// les CTAs pleins. 3 statuts V1 : "À compléter" (ambre), "Prêt à planifier"
/// (bleu primary), "Voyage prêt" (vert success). Extensible pour V2 (en cours,
/// passé) sans changer l'API.
class _TripStatusBadge extends StatelessWidget {
  final _TripStatus status;
  const _TripStatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      _TripStatus.toComplete => ('À compléter', AppColors.accent),
      _TripStatus.readyToPlan => ('Prêt à planifier', AppColors.primaryLight),
      _TripStatus.ready => ('Voyage prêt', AppColors.success),
    };
    // Sur le header bleu, le contraste demande un texte blanc + bordure
    // claire — on garde le même esprit "outline" mais adapté fond foncé.
    // Sur fond clair (utilisation future hors header), on tomberait sur le
    // mode classique : bordure et texte couleur, fond transparent.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Loader bloquant pour la phase 2/2 du flow "clé en main" (génération auto
/// du planning Places-first). `barrierDismissible: false` côté caller +
/// `PopScope` ici → l'user ne peut ni taper outside ni utiliser le bouton
/// retour pendant les 5–15 secondes du process. Reste à l'écran jusqu'à la
/// fermeture programmée par le caller (succès → navigation /planning, ou
/// erreur → toast graceful + reste sur le détail voyage).
///
/// Step indicator visible : la phase 1/2 (choix des villes) est marquée
/// terminée (✓), la phase 2/2 (construction du planning) est en cours
/// (spinner). Texte rassurant pour normaliser le délai.
class _TurnkeyPlanningLoaderDialog extends StatelessWidget {
  final VoidCallback? onCancel;
  const _TurnkeyPlanningLoaderDialog({this.onCancel});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Je prépare ton voyage',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              _StepRow(
                emoji: '✨',
                label: '1/2 — Choix des villes',
                done: true,
              ),
              const SizedBox(height: 10),
              _StepRow(
                emoji: '🗺',
                label: '2/2 — Construction de ton planning sur place…',
                done: false,
              ),
              const SizedBox(height: 18),
              Text(
                'Ça peut prendre 30 secondes, c\'est normal.',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
              if (onCancel != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.primary,
                    ),
                    onPressed: onCancel,
                    child: const Text('Annuler la génération'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Choix utilisateur dans `_ResetTripDialog` : 3 catégories indépendantes que
/// l'user peut effacer en une fois ou séparément.
class _ResetChoices {
  final bool segments;
  final bool planning;
  final bool documents;
  const _ResetChoices({
    this.segments = false,
    this.planning = false,
    this.documents = false,
  });
  bool get hasAny => segments || planning || documents;
}

/// Dialog "Réinitialiser ce voyage" — l'user choisit via 3 checkboxes ce
/// qu'il veut effacer. Affiche aussi le compte (X étapes, Y activités,
/// Z documents) pour qu'il sache ce qu'il efface. Action **neutre** (pas
/// destructive) : tout reste local au voyage, on conserve la coquille
/// (titre, dates, destination, profil, intérêts).
class _ResetTripDialog extends ConsumerStatefulWidget {
  final Trip trip;
  const _ResetTripDialog({required this.trip});

  @override
  ConsumerState<_ResetTripDialog> createState() => _ResetTripDialogState();
}

class _ResetTripDialogState extends ConsumerState<_ResetTripDialog> {
  bool _segments = false;
  bool _planning = false;
  bool _documents = false;

  @override
  Widget build(BuildContext context) {
    final activitiesAsync = ref.watch(tripActivitiesProvider(widget.trip.id));
    final docsAsync = ref.watch(tripDocumentsProvider(widget.trip.id));
    final segmentsCount = widget.trip.itinerarySegments.length;
    final activitiesCount = activitiesAsync.valueOrNull?.length ?? 0;
    final documentsCount = docsAsync.valueOrNull?.length ?? 0;
    final hasAny = _segments || _planning || _documents;

    return AlertDialog(
      title: const Text('Réinitialiser ce voyage ?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Choisis ce que tu veux effacer. Le voyage est conservé (titre, dates, destination).',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 12),
          // Cascade descendante uniquement : cocher Étapes coche aussi
          // Planning (un planning sans étapes ancres devient incohérent).
          // Mais cocher Planning seul est OK (cas typique : re-générer le
          // planning sans changer les étapes, par ex. après avoir testé un
          // mode auto puis voulu le mode co-pilote).
          _ResetCheckboxTile(
            label: 'Étapes',
            sub: segmentsCount > 0
                ? '$segmentsCount ville${segmentsCount > 1 ? "s" : ""} (le planning sera aussi effacé)'
                : 'aucune',
            value: _segments,
            enabled: segmentsCount > 0,
            onChanged: (v) => setState(() {
              _segments = v;
              if (v) _planning = true; // cascade descendante seulement
            }),
          ),
          _ResetCheckboxTile(
            label: 'Planning',
            sub: activitiesCount > 0
                ? '$activitiesCount activité${activitiesCount > 1 ? "s" : ""} + trajets'
                : 'aucun',
            value: _planning,
            enabled: activitiesCount > 0,
            onChanged: (v) => setState(() => _planning = v),
          ),
          _ResetCheckboxTile(
            label: 'Documents',
            sub: documentsCount > 0
                ? '$documentsCount document${documentsCount > 1 ? "s" : ""} — détachés (conservés dans ton wallet)'
                : 'aucun',
            value: _documents,
            enabled: documentsCount > 0,
            onChanged: (v) => setState(() => _documents = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        TextButton(
          onPressed: hasAny
              ? () => Navigator.pop(
                    context,
                    _ResetChoices(
                      segments: _segments,
                      planning: _planning,
                      documents: _documents,
                    ),
                  )
              : null,
          style: TextButton.styleFrom(foregroundColor: AppColors.primary),
          child: const Text('Réinitialiser'),
        ),
      ],
    );
  }
}

class _ResetCheckboxTile extends StatelessWidget {
  final String label;
  final String sub;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  const _ResetCheckboxTile({
    required this.label,
    required this.sub,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Checkbox(
              value: value,
              onChanged: enabled ? (v) => onChanged(v ?? false) : null,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: enabled ? AppColors.textPrimary : AppColors.textSecondary,
                    ),
                  ),
                  Text(
                    sub,
                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final String emoji;
  final String label;
  final bool done;
  const _StepRow({required this.emoji, required this.label, required this.done});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(emoji, style: const TextStyle(fontSize: 18)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: done ? AppColors.textSecondary : AppColors.textPrimary,
              fontWeight: done ? FontWeight.w400 : FontWeight.w600,
              decoration: done ? TextDecoration.lineThrough : null,
              decorationColor: AppColors.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 10),
        if (done)
          Icon(Icons.check_circle, size: 18, color: AppColors.success)
        else
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
      ],
    );
  }
}
