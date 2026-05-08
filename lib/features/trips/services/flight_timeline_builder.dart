import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/utils/transport_dates.dart';

/// Un séjour candidat déduit de la chronologie des vols : "le voyageur dort à
/// X du jour A au jour B, jusqu'à ce qu'un vol l'emmène ailleurs".
///
/// Les séjours sont ordonnés chronologiquement et peuvent répéter une même
/// ville (ex: Bangkok visité au début et à la fin d'un circuit).
class FlightStayCandidate {
  final String city;
  final String? country;
  final String? countryCode;
  final double? latitude;
  final double? longitude;

  /// Date d'arrivée dans la ville (= date du vol qui y arrive).
  final DateTime startDate;

  /// Date de départ de la ville (= date du vol suivant qui en part, ou
  /// `trip.endDate` si aucun vol suivant n'en part).
  final DateTime endDate;

  /// Nom du document de vol qui a fait remonter ce séjour (sert à l'UX
  /// "détecté depuis : VN1236 Vietnam Airlines").
  final String sourceDocName;

  /// Source = `flightTimeline` constante pour ce builder. Sert à différencier
  /// dans le diff les segments qui viennent d'ici vs des étapes manuelles.
  final String source;

  const FlightStayCandidate({
    required this.city,
    required this.country,
    required this.countryCode,
    required this.latitude,
    required this.longitude,
    required this.startDate,
    required this.endDate,
    required this.sourceDocName,
    this.source = 'flightTimeline',
  });

  int get days {
    final s = DateTime(startDate.year, startDate.month, startDate.day);
    final e = DateTime(endDate.year, endDate.month, endDate.day);
    final diff = e.difference(s).inDays;
    return diff < 1 ? 1 : diff;
  }
}

/// Construit la timeline chronologique de séjours depuis les documents Vol/Train
/// d'un voyage.
///
/// Règles métier (cf. brief Lalith 2026-05-08) :
/// - Les étapes représentent les LIEUX OÙ LE VOYAGEUR DORT, pas les villes
///   présentes dans les vols.
/// - On utilise UNIQUEMENT le `to_city` de chaque vol comme ville-séjour
///   candidate. Le `from_city` n'est jamais une étape (c'est juste d'où on part).
/// - **Ignorer la ville de départ initiale** quand c'est la home base (1er
///   vol part de chez l'utilisateur).
/// - **Ignorer la ville d'arrivée finale** quand c'est la home base (dernier
///   vol = retour maison).
/// - **Autoriser les villes répétées** comme séjours distincts (Bangkok du
///   21/06→03/07 ET Bangkok du 15/07→06/08 = 2 séjours).
/// - Fin d'un séjour = date du prochain vol qui part de cette ville. S'il
///   n'y a pas de prochain vol partant → fin = `tripEndDate`.
///
/// Détection home base :
/// - via `homeAirportCity` (ex: "Luxembourg" déduit du code IATA `LUX`).
///   Comparaison `from_city`/`to_city` normalisé case+accent insensible.
/// - Optionnellement via `homeCountryCode` (ex: 'lu' pour Luxembourg) si
///   la ville n'est pas connue.
List<FlightStayCandidate> buildTripStayTimelineFromFlightDocuments({
  required List<TripDocument> docs,
  required DateTime tripEndDate,
  String? homeAirportCity,
  String? homeCountryCode,
}) {
  // Filtre les docs Vol/Train + docs avec une date parsable + un to_city.
  final flights = <_Flight>[];
  for (final d in docs) {
    if (d.category != DocumentCategory.flight &&
        d.category != DocumentCategory.train) {
      continue;
    }
    final dateRaw = d.metadata['date'] as String?;
    if (dateRaw == null || dateRaw.isEmpty) continue;
    final date = DateTime.tryParse(dateRaw);
    if (date == null) continue;
    final toCity = (d.metadata['to_city'] as String?)?.trim();
    final fromCity = (d.metadata['from_city'] as String?)?.trim();
    if (toCity == null || toCity.isEmpty) continue;
    if (fromCity == null || fromCity.isEmpty) continue;
    // Date d'arrivée résolue via le helper partagé `transport_dates`
    // (V2.3 refactor 2026-05-08) : préfère `arrival_date` explicite si
    // présent, sinon infère J+1 si `arrival_time < departure_time`.
    // Source de vérité unique partagée avec `pinned_dates.dart` et
    // `document_to_activity.dart`.
    final arrivalDate = arrivalDateFromMetadata(d.metadata) ?? date;
    flights.add(_Flight(
      docName: d.name,
      date: date,
      arrivalDate: arrivalDate,
      fromCity: fromCity,
      toCity: toCity,
      fromCountryCode:
          (d.metadata['from_country_code'] as String?)?.trim().toLowerCase(),
      toCountryCode:
          (d.metadata['to_country_code'] as String?)?.trim().toLowerCase(),
      toLat: (d.metadata['to_latitude'] as num?)?.toDouble(),
      toLng: (d.metadata['to_longitude'] as num?)?.toDouble(),
    ));
  }
  if (flights.isEmpty) return const [];

  flights.sort((a, b) => a.date.compareTo(b.date));

  final homeCityNorm =
      homeAirportCity == null ? null : _normalize(homeAirportCity);

  // IMPORTANT : on ne déclare jamais "retour maison" sur la base du
  // `homeCountryCode` SEUL. Sinon un voyage en France (home FR + dest FR)
  // verrait toutes ses étapes nationales (Lyon, Marseille...) supprimées.
  // La détection se fait uniquement via la ville. Le `homeCountryCode` est
  // gardé en signature pour une éventuelle V2 (croisement avec Place
  // Details ou heuristique multi-vols), mais pas exploité en V1.
  // ignore: unused_local_variable
  final homeCC = homeCountryCode?.trim().toLowerCase();

  // Détection du dernier vol "retour maison" : son `to_city` matche la
  // homeAirportCity. Si pas de homeAirportCity fournie, aucun vol n'est
  // considéré comme retour (tous les `to_city` deviennent séjours).
  final lastFlight = flights.last;
  final lastIsReturn = homeCityNorm != null &&
      _normalize(lastFlight.toCity) == homeCityNorm;

  final stays = <FlightStayCandidate>[];
  for (var i = 0; i < flights.length; i++) {
    final f = flights[i];
    final isLast = i == flights.length - 1;

    // Si c'est le dernier vol ET qu'il rentre à la maison → on ne crée pas
    // de séjour pour ce to_city (le voyageur rentre chez lui, pas une étape).
    if (isLast && lastIsReturn) continue;

    // Sécurité supplémentaire : si `to_city` matche la home city directement
    // (ex: vol intermédiaire bizarre qui passe par Luxembourg), on skip aussi.
    if (homeCityNorm != null && _normalize(f.toCity) == homeCityNorm) continue;

    // Le séjour démarre à l'arrivée locale dans la ville, pas au départ
    // du vol — important pour les vols de nuit (overnight) où l'on arrive
    // le lendemain (ex: Lux→BKK part 21/06 mais arrive 22/06).
    final startDate = f.arrivalDate;

    // Fin du séjour = prochain vol qui part de cette même ville.
    DateTime? endDate;
    final cityNorm = _normalize(f.toCity);
    for (var j = i + 1; j < flights.length; j++) {
      if (_normalize(flights[j].fromCity) == cityNorm) {
        endDate = flights[j].date;
        break;
      }
    }
    endDate ??= tripEndDate;

    // Edge case : le séjour se termine avant ou le même jour qu'il commence
    // (timing incohérent dans les docs). On force endDate >= startDate.
    if (endDate.isBefore(startDate)) endDate = startDate;

    stays.add(FlightStayCandidate(
      city: f.toCity,
      country: _countryNameFromCode(f.toCountryCode),
      countryCode: f.toCountryCode,
      latitude: f.toLat,
      longitude: f.toLng,
      startDate: startDate,
      endDate: endDate,
      sourceDocName: f.docName,
    ));
  }

  return stays;
}

/// Mapping minimaliste code ISO → nom pays pour affichage UX. Couvre les
/// principaux pays de l'audience FR + destinations populaires. Fallback =
/// code uppercased (ex: "VN" si pas mappé).
String? _countryNameFromCode(String? code) {
  if (code == null || code.isEmpty) return null;
  const map = {
    'fr': 'France', 'be': 'Belgique', 'ch': 'Suisse', 'lu': 'Luxembourg',
    'it': 'Italie', 'es': 'Espagne', 'de': 'Allemagne', 'gb': 'Royaume-Uni',
    'nl': 'Pays-Bas', 'at': 'Autriche', 'pt': 'Portugal', 'ie': 'Irlande',
    'gr': 'Grèce', 'hr': 'Croatie', 'cz': 'République tchèque',
    'pl': 'Pologne', 'hu': 'Hongrie', 'tr': 'Turquie',
    'ma': 'Maroc', 'tn': 'Tunisie', 'dz': 'Algérie', 'eg': 'Égypte',
    'sn': 'Sénégal', 'za': 'Afrique du Sud', 'ke': 'Kenya',
    'th': 'Thaïlande', 'vn': 'Vietnam', 'kh': 'Cambodge', 'la': 'Laos',
    'mm': 'Birmanie', 'sg': 'Singapour', 'my': 'Malaisie', 'id': 'Indonésie',
    'ph': 'Philippines', 'jp': 'Japon', 'kr': 'Corée du Sud', 'cn': 'Chine',
    'in': 'Inde', 'ae': 'Émirats arabes unis', 'sa': 'Arabie saoudite',
    'us': 'États-Unis', 'ca': 'Canada', 'mx': 'Mexique',
    'br': 'Brésil', 'ar': 'Argentine', 'cl': 'Chili', 'pe': 'Pérou',
    'au': 'Australie', 'nz': 'Nouvelle-Zélande',
  };
  return map[code.toLowerCase()] ?? code.toUpperCase();
}

String _normalize(String s) {
  return s
      .toLowerCase()
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'[éèêë]'), 'e')
      .replaceAll(RegExp(r'[àâä]'), 'a')
      .replaceAll(RegExp(r'[ïî]'), 'i')
      .replaceAll(RegExp(r'[ôö]'), 'o')
      .replaceAll(RegExp(r'[ûü]'), 'u')
      .replaceAll('ç', 'c');
}

/// Représentation interne d'un vol pour l'algo. Évite de retraverser les
/// metadata Map à chaque comparaison.
class _Flight {
  final String docName;
  /// Date de départ du vol (= valeur du champ metadata `date`).
  final DateTime date;
  /// Date locale d'arrivée. Égale à [date] pour un vol de jour, ou
  /// `date + 1` pour un vol overnight (arrival_time < departure_time).
  final DateTime arrivalDate;
  final String fromCity;
  final String toCity;
  final String? fromCountryCode;
  final String? toCountryCode;
  final double? toLat;
  final double? toLng;
  _Flight({
    required this.docName,
    required this.date,
    required this.arrivalDate,
    required this.fromCity,
    required this.toCity,
    required this.fromCountryCode,
    required this.toCountryCode,
    required this.toLat,
    required this.toLng,
  });
}

