/// Lot A 2026-05-13 — Résolution offline IATA-first pour les
/// endpoints `from`/`to` des documents Vol.
///
/// Helper pur, sans Flutter, sans I/O, sans appel API. Utilise la base
/// IATA Dart const déjà disponible dans
/// `features/planning/services/airport_city_overrides.dart` (~366
/// aéroports majeurs).
///
/// Objectif produit (Lalith 2026-05-13) : tant que Lunao a une source
/// IATA offline, le SAVE d'un document Vol doit la consulter en
/// priorité avant tout fallback Google (Geocoding ou Place Details).
/// Couvre estimé : ~80% des vols mainstream avec 0 call live.
library;

import 'package:voyage/features/planning/services/airport_city_overrides.dart';

/// Résultat d'un lookup IATA dans la base offline Lunao.
class ResolvedAirport {
  /// Code IATA canonique (3 lettres MAJUSCULES). Toujours = entrée
  /// normalisée, jamais null.
  final String iata;

  /// Ville touristique associée à l'aéroport (ex. "Paris" pour CDG, pas
  /// "Roissy-en-France"). Suit la table éditoriale Lunao.
  final String city;

  /// Nom propre de l'aéroport sans la ville (ex. "Charles de Gaulle").
  /// `null` si la table ne le porte pas — utiliser `formatAirportLabel`
  /// pour un libellé complet.
  final String? name;

  /// Code pays ISO 3166-1 alpha-2 (ex: 'FR', 'TH', 'US'). Lot A2
  /// 2026-05-13 : renseigné pour toutes les entrées éditoriales.
  /// `null` ne devrait pas se produire en pratique mais reste possible
  /// pour rétro-compat si une entrée future est ajoutée sans pays.
  final String? countryCode;

  final double lat;
  final double lng;

  const ResolvedAirport({
    required this.iata,
    required this.city,
    required this.lat,
    required this.lng,
    this.name,
    this.countryCode,
  });
}

/// Résout un code IATA via la base offline. Retourne `null` si :
///  - l'entrée est `null` / vide / pas 3 caractères après trim ;
///  - le code n'est pas dans la table Lunao.
///
/// La résolution normalise la casse (UPPER) et retire les espaces.
/// `countryCode` (ISO 3166-1 alpha-2) est renseigné pour toutes les
/// entrées éditoriales depuis Lot A2 (2026-05-13).
ResolvedAirport? resolveAirportByIata(String? raw) {
  if (raw == null) return null;
  final code = raw.trim().toUpperCase();
  if (code.length != 3) return null;
  final info = lookupAirport(code);
  if (info == null) return null;
  final coords = coordsForAirport(code);
  if (coords == null) return null;
  return ResolvedAirport(
    iata: code,
    city: info.city,
    name: info.name,
    countryCode: info.countryCode,
    lat: coords.lat,
    lng: coords.lng,
  );
}

/// Cohérence entre l'IATA résolu et le texte saisi par l'utilisateur
/// (ou extrait par Gemini) dans le champ `from`/`to`.
///
/// Retourne `true` si au moins UNE des sous-chaînes du résolu apparaît
/// dans `displayedName` (case-insensible) : code IATA, ville, nom
/// propre. Permet de filtrer le cas où l'utilisateur édite le texte
/// après extract sans toucher à l'IATA stockée, qui devient alors
/// obsolète.
///
/// Exemple :
/// - `displayedName = "Aéroport de Bangkok Suvarnabhumi"`,
///   `resolved.iata = "BKK"` → `true` (contient "bkk" via le nom).
/// - `displayedName = "Paris CDG"`, `resolved = BKK Bangkok` → `false`.
bool isAirportConsistentWithName(
  ResolvedAirport resolved,
  String displayedName,
) {
  final lower = displayedName.toLowerCase();
  if (lower.isEmpty) return false;
  if (lower.contains(resolved.iata.toLowerCase())) return true;
  if (lower.contains(resolved.city.toLowerCase())) return true;
  final name = resolved.name;
  if (name != null && name.isNotEmpty && lower.contains(name.toLowerCase())) {
    return true;
  }
  return false;
}
