import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:voyage/config/live_api_guards.dart';

/// Service de conversion de devises via frankfurter.app (ECB, gratuit, sans clé).
/// Cache les taux ~6h en mémoire pour limiter les appels.
class CurrencyService {
  final Map<String, _RateEntry> _cache = {};
  final LiveApiGuards _guards;
  final http.Client? _httpClient;
  static const _ttl = Duration(hours: 6);

  CurrencyService({LiveApiGuards? guards, http.Client? httpClient})
    : _guards = guards ?? LiveApiGuards.fromEnvironment(),
      _httpClient = httpClient;

  /// Récupère le taux FROM → TO. Retourne null en cas d'échec.
  Future<double?> getRate(String from, String to) async {
    final fromU = from.toUpperCase();
    final toU = to.toUpperCase();
    if (fromU == toU) return 1.0;
    final key = '$fromU->$toU';
    final cached = _cache[key];
    if (cached != null && DateTime.now().difference(cached.fetchedAt) < _ttl) {
      return cached.rate;
    }
    _guards.assertAllowed(
      LiveApiFamily.currencyApi,
      operation: 'CurrencyService.getRate exchange rates',
    );
    try {
      final uri = Uri.parse(
        'https://api.frankfurter.app/latest?from=$fromU&to=$toU',
      );
      final resp = await (_httpClient?.get(uri) ?? http.get(uri)).timeout(
        const Duration(seconds: 8),
      );
      if (resp.statusCode != 200) {
        developer.log('Frankfurter HTTP ${resp.statusCode}', name: 'currency');
        return null;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final rates = data['rates'] as Map<String, dynamic>?;
      final rate = (rates?[toU] as num?)?.toDouble();
      if (rate != null) {
        _cache[key] = _RateEntry(rate, DateTime.now());
      }
      return rate;
    } catch (e) {
      developer.log('Erreur currency : $e', name: 'currency');
      return null;
    }
  }

  /// Parse un prix formaté type "~800 THB", "15€", "~20$", "1 250 JPY", "Gratuit".
  /// Retourne (amount, currencyCode) ou null si introuvable.
  static ({double amount, String currency})? parsePrice(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return null;
    // Ignore "Gratuit", "Free", etc.
    if (RegExp(
      r'^(gratuit|free|offert|inclus)',
      caseSensitive: false,
    ).hasMatch(s)) {
      return null;
    }

    // Détection du code/symbole de devise (ordre important : symbol d'abord)
    final currencyPatterns = <RegExp, String>{
      RegExp(r'€'): 'EUR',
      RegExp(r'£'): 'GBP',
      RegExp(r'\$'): 'USD',
      RegExp(r'¥'): 'JPY',
      RegExp(r'₹'): 'INR',
      RegExp(r'₩'): 'KRW',
      RegExp(r'฿'): 'THB',
      RegExp(r'\bEUR\b', caseSensitive: false): 'EUR',
      RegExp(r'\bUSD\b', caseSensitive: false): 'USD',
      RegExp(r'\bGBP\b', caseSensitive: false): 'GBP',
      RegExp(r'\bJPY\b', caseSensitive: false): 'JPY',
      RegExp(r'\bCNY\b', caseSensitive: false): 'CNY',
      RegExp(r'\bTHB\b', caseSensitive: false): 'THB',
      RegExp(r'\bKRW\b', caseSensitive: false): 'KRW',
      RegExp(r'\bINR\b', caseSensitive: false): 'INR',
      RegExp(r'\bCHF\b', caseSensitive: false): 'CHF',
      RegExp(r'\bAUD\b', caseSensitive: false): 'AUD',
      RegExp(r'\bCAD\b', caseSensitive: false): 'CAD',
      RegExp(r'\bMAD\b', caseSensitive: false): 'MAD',
      RegExp(r'\bVND\b', caseSensitive: false): 'VND',
    };
    String? currency;
    for (final entry in currencyPatterns.entries) {
      if (entry.key.hasMatch(s)) {
        currency = entry.value;
        break;
      }
    }
    if (currency == null) return null;

    // Extrait le nombre (prend la première séquence de chiffres avec virgule/point/espace)
    final numMatch = RegExp(r'([\d\s]+(?:[.,]\d+)?)').firstMatch(s);
    if (numMatch == null) return null;
    final cleaned = numMatch
        .group(1)!
        .replaceAll(RegExp(r'\s'), '')
        .replaceAll(',', '.');
    final amount = double.tryParse(cleaned);
    if (amount == null) return null;
    return (amount: amount, currency: currency);
  }

  /// Formate un montant avec sa devise (symbole si courant, sinon code).
  static String formatAmount(double amount, String currency) {
    final symbol = _currencySymbol(currency);
    final rounded = amount >= 100 ? amount.round() : amount;
    final str = rounded is int || rounded == rounded.roundToDouble()
        ? rounded.toStringAsFixed(0)
        : rounded.toStringAsFixed(1);
    return symbol != null ? '$str$symbol' : '$str $currency';
  }

  static String? _currencySymbol(String currency) {
    switch (currency.toUpperCase()) {
      case 'EUR':
        return '€';
      case 'USD':
        return r'$';
      case 'GBP':
        return '£';
      case 'JPY':
        return '¥';
      case 'CNY':
        return '¥';
      case 'INR':
        return '₹';
      case 'KRW':
        return '₩';
      case 'THB':
        return '฿';
      default:
        return null;
    }
  }
}

class _RateEntry {
  final double rate;
  final DateTime fetchedAt;
  _RateEntry(this.rate, this.fetchedAt);
}

/// Liste des devises supportées dans le sélecteur de profil.
const supportedCurrencies = <({String code, String label})>[
  (code: 'EUR', label: 'Euro (€)'),
  (code: 'USD', label: 'Dollar US (\$)'),
  (code: 'GBP', label: 'Livre sterling (£)'),
  (code: 'CHF', label: 'Franc suisse (CHF)'),
  (code: 'CAD', label: 'Dollar canadien (CAD)'),
  (code: 'AUD', label: 'Dollar australien (AUD)'),
  (code: 'JPY', label: 'Yen japonais (¥)'),
  (code: 'CNY', label: 'Yuan chinois (¥)'),
  (code: 'KRW', label: 'Won sud-coréen (₩)'),
  (code: 'INR', label: 'Roupie indienne (₹)'),
  (code: 'THB', label: 'Baht thaï (฿)'),
  (code: 'VND', label: 'Dong vietnamien (VND)'),
  (code: 'MAD', label: 'Dirham marocain (MAD)'),
];
