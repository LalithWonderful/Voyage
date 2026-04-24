import 'package:voyage/core/services/currency_service.dart';

/// Parse un prix en incluant le cas des fourchettes "15-30€" : on prend la
/// MOYENNE, comme estimation la plus réaliste. Réutilise la parser du
/// `CurrencyService` pour les formats simples + devises supportées.
/// Retourne null si introuvable ou si le prix est "Gratuit/Free/Inclus".
({double amount, String currency})? parseAmountForBudget(String? raw) {
  if (raw == null) return null;
  final s = raw.trim();
  if (s.isEmpty) return null;
  if (RegExp(r'^(gratuit|free|offert|inclus)', caseSensitive: false).hasMatch(s)) {
    return null;
  }

  // Détecte une fourchette type "15-30€", "15 – 30€", "15—30 EUR"
  final rangeRe = RegExp(r'(\d+(?:[.,]\d+)?)\s*[-–—]\s*(\d+(?:[.,]\d+)?)');
  final rangeMatch = rangeRe.firstMatch(s);
  if (rangeMatch != null) {
    final min = double.tryParse(rangeMatch.group(1)!.replaceAll(',', '.'));
    final max = double.tryParse(rangeMatch.group(2)!.replaceAll(',', '.'));
    if (min != null && max != null) {
      // On réutilise parsePrice juste pour détecter la devise (sur la chaîne entière)
      final asParsed = CurrencyService.parsePrice(s);
      if (asParsed != null) {
        return (amount: (min + max) / 2, currency: asParsed.currency);
      }
    }
  }

  return CurrencyService.parsePrice(s);
}

/// Agrégat de budget pour un voyage (total + répartition par jour).
class TripBudget {
  /// Montant total du voyage, en devise utilisateur.
  final double total;

  /// Répartition par jour (clé = 'YYYY-MM-DD'), en devise utilisateur.
  final Map<String, double> byDay;

  /// Nombre d'éléments (activités + transports) dont le prix n'a pas pu être parsé
  /// ou convertit (devise exotique sans taux, format illisible...). Utile pour
  /// afficher un indicateur "budget partiellement inconnu" côté UI.
  final int unknownCount;

  const TripBudget({
    required this.total,
    required this.byDay,
    required this.unknownCount,
  });

  static const empty = TripBudget(total: 0, byDay: {}, unknownCount: 0);
}
