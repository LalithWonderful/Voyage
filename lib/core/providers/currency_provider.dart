import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/core/services/currency_service.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';

// Product runtime is allowed to fetch live exchange rates for user-facing price
// conversion. Tests and scripts should override this provider or instantiate
// CurrencyService without this explicit opt-in.
final currencyServiceProvider = Provider<CurrencyService>(
  (ref) => CurrencyService(guards: const LiveApiGuards(allowCurrencyApi: true)),
);

/// Devise préférée de l'utilisateur (fallback EUR).
final userCurrencyProvider = Provider<String>((ref) {
  final profile = ref.watch(userProfileProvider).valueOrNull;
  return (profile?['currency'] as String?) ?? 'EUR';
});

/// Retourne un prix converti formaté : "~800 ฿ (~20€)" ou juste "~20€" si déjà en devise utilisateur.
/// Si pas de taux ou prix non parsable, retourne le prix brut.
final convertedPriceProvider = FutureProvider.family<String, String?>((
  ref,
  rawPrice,
) async {
  if (rawPrice == null || rawPrice.trim().isEmpty) return '';
  final parsed = CurrencyService.parsePrice(rawPrice);
  if (parsed == null) return rawPrice;

  final userCurrency = ref.watch(userCurrencyProvider);
  if (parsed.currency == userCurrency) return rawPrice;

  final service = ref.watch(currencyServiceProvider);
  final rate = await service.getRate(parsed.currency, userCurrency);
  if (rate == null) return rawPrice;

  final converted = parsed.amount * rate;
  final convertedStr = CurrencyService.formatAmount(converted, userCurrency);
  return '$rawPrice ($convertedStr)';
});
