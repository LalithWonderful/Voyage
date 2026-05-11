/// Phase 3 / Tâche 3.2 — Structure de journal pour les rejets
/// `destination_scope_reject` du sélecteur déterministe.
///
/// **Class minimale, immutable**, sans logique. Mirror du pattern
/// `SameComplexRejection` (Tâche 2.4). Sert uniquement de
/// payload de log appendé à une liste optionnelle passée par
/// `selectVisitsDeterministic` (paramètre optionnel,
/// `null` en production).
///
/// ## Quand est-elle créée ?
///
/// Uniquement quand `useDestinationScope == true` ET qu'un
/// candidat est rejeté par `ScopeValidator` (validator retourne
/// `isInScope == false`).
///
/// ## Reasons possibles
///
/// La string `reason` reprend la valeur de
/// `ScopeRejectionReason.name` (`out_of_country`,
/// `blocked_country`, `blocked_neighbor_region`,
/// `unknown_country`). Préfixée par `destination_scope_` côté
/// log pipeline pour distinction visuelle :
/// `destination_scope_blocked_neighbor_region`, etc.
library;

import 'package:voyage/services/scope_validator.dart';

/// Événement de rejet d'un candidat par `ScopeValidator`.
class DestinationScopeRejection {
  /// Titre du candidat rejeté (`NearbyCandidate.name`).
  final String candidateTitle;

  /// Adresse du candidat si disponible (utile pour debug : voir
  /// quelle adresse a déclenché le rejet).
  final String? candidateAddress;

  /// Raison enum issue du validator (`ScopeRejectionReason`).
  /// Jamais null pour un rejet (validator garantit que `reason`
  /// est non-null quand `isInScope == false`).
  final ScopeRejectionReason reason;

  /// Confiance du verdict validator.
  final ScopeConfidence confidence;

  /// Indice (string court) ayant déclenché le rejet — code pays
  /// (`"MY"`) ou hint adresse (`"johor bahru"`). `null` si le
  /// validator n'a pas remonté d'evidence (rare en cas de rejet).
  final String? matchedEvidence;

  const DestinationScopeRejection({
    required this.candidateTitle,
    required this.reason,
    required this.confidence,
    this.candidateAddress,
    this.matchedEvidence,
  });

  /// String reason canonique loguée dans la breakdown pipeline.
  /// Format : `destination_scope_<reason_snake_case>`.
  String get pipelineReason =>
      'destination_scope_${reason.name.replaceAllMapped(
        RegExp(r'([A-Z])'),
        (m) => '_${m[1]!.toLowerCase()}',
      )}';

  @override
  String toString() => 'DestinationScopeRejection('
      'title=$candidateTitle, '
      'reason=${reason.name}, '
      'confidence=${confidence.name}, '
      'evidence=$matchedEvidence)';
}
