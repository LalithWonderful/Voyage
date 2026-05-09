/// Helpers de dates pour les documents de transport (vol, train, ferry…).
///
/// Règle produit (Lalith 2026-05-08) : pour un transport, la date qui rend
/// la ville de destination disponible est la date d'**arrivée**, pas la
/// date de **départ**. Pour Lux→BKK qui décolle le 21/06 et atterrit le
/// 22/06, Bangkok n'est pas disponible le 21/06.
///
/// Schéma metadata (rétrocompat) :
/// - `date` (string ISO YYYY-MM-DD) : date de DÉPART (legacy = "date du
///   document").
/// - `departure_time` (string HH:MM) : heure de départ.
/// - `arrival_date` (string ISO, optionnel) : date d'arrivée explicite.
/// - `arrival_time` (string HH:MM) : heure d'arrivée.
///
/// Pour les anciens documents sans `arrival_date`, on infère via la règle
/// MVP : si `arrival_time < departure_time`, l'arrivée est le lendemain
/// du départ. Sinon même jour. Cette règle couvre les vols overnight les
/// plus courants ; elle n'est pas exacte pour les vols >24h (rare).
library;

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  if (v is String) return DateTime.tryParse(v);
  return null;
}

/// Calcule la date d'arrivée d'un transport.
///
/// Si `explicitArrivalDate` est fournie, la retourne (priorité absolue).
/// Sinon si `arrivalTime < departureTime` (format HH:MM), retourne
/// `departureDate + 1 day`. Sinon retourne `departureDate`.
///
/// Retourne `null` si `departureDate` est null et qu'il n'y a pas
/// d'`explicitArrivalDate` (impossible de déduire quoi que ce soit).
DateTime? inferArrivalDate({
  required DateTime? departureDate,
  String? departureTime,
  String? arrivalTime,
  DateTime? explicitArrivalDate,
}) {
  if (explicitArrivalDate != null) return explicitArrivalDate;
  if (departureDate == null) return null;
  if (departureTime != null &&
      arrivalTime != null &&
      _isTimeBefore(arrivalTime, departureTime)) {
    return departureDate.add(const Duration(days: 1));
  }
  return departureDate;
}

/// Lit la date d'arrivée d'un transport depuis sa metadata. Préfère
/// `arrival_date` explicite, sinon infère via [inferArrivalDate] depuis
/// `date` + `departure_time` + `arrival_time`.
///
/// Sert au backward-compat : les anciens documents (sans `arrival_date`)
/// sont traités correctement à la lecture sans backfill.
DateTime? arrivalDateFromMetadata(Map<String, dynamic> metadata) {
  return inferArrivalDate(
    departureDate: _parseDate(metadata['date']),
    departureTime: metadata['departure_time'] as String?,
    arrivalTime: metadata['arrival_time'] as String?,
    explicitArrivalDate: _parseDate(metadata['arrival_date']),
  );
}

/// Auto-fill `arrival_date` dans une metadata transport quand l'extraction
/// (Gemini, OCR, manuelle) a oublié ce champ mais a fourni `date` +
/// `departure_time` + `arrival_time`. Pure : ne mute pas l'entrée,
/// retourne une copie enrichie. Si `arrival_date` est déjà présent, la
/// valeur est respectée (l'explicite gagne — règle V2.3).
///
/// Utilisé au save d'un doc Vol/Train (`document_form_sheet`) : garantit
/// que `pinned_dates` et le timeline ne tombent pas en fallback ambigu.
///
/// Cas d'usage typique (Lalith 2026-05-09) : Gemini extrait
/// ```
/// { date: '2026-07-03', departure_time: '14:35', arrival_time: '15:55' }
/// ```
/// sans `arrival_date`. Cette fonction inflate la metadata avec
/// `arrival_date: '2026-07-03'` (vol same-day, 15:55 > 14:35).
Map<String, dynamic> autoFillArrivalDate(Map<String, dynamic> metadata) {
  final hasExplicit = (metadata['arrival_date'] as String?)?.isNotEmpty
      ?? false;
  if (hasExplicit) return metadata;
  final inferred = inferArrivalDate(
    departureDate: _parseDate(metadata['date']),
    departureTime: metadata['departure_time'] as String?,
    arrivalTime: metadata['arrival_time'] as String?,
  );
  if (inferred == null) return metadata;
  return {
    ...metadata,
    'arrival_date':
        '${inferred.year.toString().padLeft(4, '0')}-'
        '${inferred.month.toString().padLeft(2, '0')}-'
        '${inferred.day.toString().padLeft(2, '0')}',
  };
}

/// Retourne `true` si `a` < `b` au format HH:MM. Pour formats invalides,
/// retourne `false` (on ne déclenche pas la règle J+1 sur des données
/// douteuses, plutôt rester sur le même jour).
bool _isTimeBefore(String a, String b) {
  final ap = a.split(':');
  final bp = b.split(':');
  if (ap.length < 2 || bp.length < 2) return false;
  final ah = int.tryParse(ap[0]);
  final am = int.tryParse(ap[1]);
  final bh = int.tryParse(bp[0]);
  final bm = int.tryParse(bp[1]);
  if (ah == null || am == null || bh == null || bm == null) return false;
  return ah * 60 + am < bh * 60 + bm;
}
