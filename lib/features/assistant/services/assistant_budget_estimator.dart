import 'package:voyage/features/planning/data/destination_baseline_costs.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

/// Estimation budgétaire structurée pour un voyage. Produite par Lunao,
/// passée à Gemini comme bloc DATA — Gemini ne doit ni inventer ni modifier
/// les chiffres, juste les expliquer et proposer des ajustements.
class AssistantBudgetEstimate {
  final String destination;
  final int durationDays;
  final int travelers;
  final String? travelerType;
  final List<String> interests;
  final String? homeAirport;

  /// Vol AR par personne, fourchette basse (low-cost) ajusté pour l'origine.
  final int flightLowEur;

  /// Vol AR par personne, fourchette moyenne ajusté pour l'origine.
  final int flightAvgEur;

  /// Coût quotidien sur place par personne (héberg + restos + activités modérées).
  final int dailyBudgetEur;

  /// Total minimum par personne (vol low + quotidien × jours).
  final int totalMinPerPerson;

  /// Total moyen réaliste par personne (vol moyen + quotidien × 1.2 × jours).
  final int totalAvgPerPerson;

  /// Total minimum global (× nb voyageurs).
  final int totalMinAll;

  /// Total moyen global (× nb voyageurs).
  final int totalAvgAll;

  /// Budget cible par personne défini par l'user (null si non renseigné).
  final num? userBudgetEur;
  final bool? userBudgetIncludesFlight;

  /// True si userBudgetEur >= totalMin. Null si pas de budget user.
  final bool? fits;

  /// True si fits mais user < totalAvg (juste de quoi tenir, pas confort).
  final bool? tightFit;

  /// Nom du baseline auquel la destination a été rattachée (`displayName` de
  /// l'entrée). Souvent un pays ("Maroc") quand l'utilisateur a entré une
  /// ville ("Marrakech"). Sert à informer Gemini du scope.
  final String baselineName;

  /// Fiabilité de l'estimation pour cette destination précise :
  /// - `bonne` : la destination matche directement le baselineName (ex:
  ///   user a entré "Maroc" et la baseline est "Maroc")
  /// - `moyenne` : la destination matche via un keyword secondaire (ex:
  ///   user a entré "Marrakech", baseline pays = "Maroc") — l'estimation
  ///   est à l'échelle pays et peut varier selon les villes choisies
  final String reliability;

  /// Étiquette tier de la destination ("Maghreb proche", etc.) — sert au
  /// contexte conversationnel.
  final String tier;

  const AssistantBudgetEstimate({
    required this.destination,
    required this.durationDays,
    required this.travelers,
    required this.travelerType,
    required this.interests,
    required this.homeAirport,
    required this.flightLowEur,
    required this.flightAvgEur,
    required this.dailyBudgetEur,
    required this.totalMinPerPerson,
    required this.totalAvgPerPerson,
    required this.totalMinAll,
    required this.totalAvgAll,
    required this.userBudgetEur,
    required this.userBudgetIncludesFlight,
    required this.fits,
    required this.tightFit,
    required this.baselineName,
    required this.reliability,
    required this.tier,
  });

  /// Sérialisation lisible pour injection dans le prompt Gemini. Format
  /// volontairement explicite pour que Gemini réutilise les chiffres tels
  /// quels.
  String toPromptBlock() {
    final scopeNote = reliability == 'bonne'
        ? 'estimation alignée sur la destination demandée'
        : 'estimation à l\'échelle $baselineName, à affiner selon les villes choisies';

    final buf = StringBuffer();
    buf.writeln('DONNÉES BUDGET (calculées par Lunao — utilise EXACTEMENT ces chiffres)');
    buf.writeln('- Destination demandée : $destination');
    buf.writeln('- Estimation basée sur : $baselineName ($tier)');
    buf.writeln('- Fiabilité : $reliability ($scopeNote)');
    buf.writeln('- Durée : $durationDays jours');
    buf.writeln('- Voyageurs : $travelers');
    if (travelerType != null) {
      buf.writeln('- Profil voyageur : $travelerType');
    }
    if (interests.isNotEmpty) {
      buf.writeln("- Centres d'intérêt : ${interests.join(', ')}");
    }
    if (homeAirport != null && homeAirport!.isNotEmpty) {
      buf.writeln('- Aéroport de départ : $homeAirport');
    }
    buf.writeln('- Vol AR par personne : $flightLowEur–$flightAvgEur €');
    buf.writeln('- Coût quotidien par personne sur place : $dailyBudgetEur €');
    buf.writeln('- Total PAR PERSONNE : $totalMinPerPerson € (économique) à '
        '$totalAvgPerPerson € (confort)');
    buf.writeln('- Total POUR LE GROUPE ($travelers voyageur'
        '${travelers > 1 ? 's' : ''}) : $totalMinAll € à $totalAvgAll €');
    if (userBudgetEur != null) {
      final budget = userBudgetEur!.toInt();
      buf.writeln('- Budget défini par l\'utilisateur : $budget €/personne'
          '${userBudgetIncludesFlight == false ? ' (hors vol)' : ' (vol inclus)'}');
      if (fits == true && tightFit == true) {
        buf.writeln('- Verdict : faisable mais serré (couvre le minimum, '
            'pas de marge confort)');
      } else if (fits == true) {
        buf.writeln('- Verdict : largement faisable');
      } else if (fits == false) {
        buf.writeln('- Verdict : trop juste — il manque environ '
            '${totalMinPerPerson - budget} €/personne pour le minimum');
      }
    }
    buf.writeln('- Inclus dans l\'estimation : vol AR éco, hébergement standard '
        '(3*), restos, activités modérées, transport local de base');
    buf.writeln('- NON inclus : shopping personnel, excursions premium, extras '
        '(souvenirs, sorties soir luxe...), assurance voyage');
    buf.writeln();
    buf.writeln('Consigne pour cette réponse : présente l\'estimation à '
        'l\'utilisateur, mentionne CLAIREMENT le par-personne ET le total '
        'groupe (si plus d\'1 voyageur), précise ce qui est inclus, et signale '
        'la fiabilité si elle est "moyenne". Tu peux proposer une vision '
        '"budget serré", "confort" ou "plaisir" en commentaire. Si le verdict '
        'est "trop juste", suggère d\'augmenter le budget OU de raccourcir '
        'le séjour OU de viser une destination plus proche.');
    return buf.toString();
  }
}

class AssistantBudgetEstimator {
  /// Calcule une estimation pour le voyage donné. Retourne null si la
  /// destination n'est pas dans la baseline (Gemini retombera sur une
  /// réponse conversationnelle plutôt que d'inventer des chiffres).
  AssistantBudgetEstimate? estimate({
    required Trip trip,
    required String? travelerType,
    required List<String> interests,
    required String? homeAirport,
  }) {
    final cost = findBaselineCostFor(trip.destination);
    if (cost == null) return null;

    final factor = _originFactorFor(homeAirport);
    final flightLow = (cost.flightLowEur * factor).round();
    final flightAvg = (cost.flightAvgEur * factor).round();
    final days = trip.durationDays;
    final daily = cost.dailyBudgetEur;
    final travelers = trip.travelers.isEmpty ? 1 : trip.travelers.length;

    final totalMin = flightLow + (daily * days);
    final totalAvg = flightAvg + ((daily * days * 1.2).round());

    bool? fits;
    bool? tightFit;
    if (trip.budgetPerPersonEur != null) {
      final budget = trip.budgetPerPersonEur!;
      // Si l'user dit "budget hors vol", on compare au quotidien seul.
      final reference = (trip.budgetIncludesFlight == false)
          ? (daily * days)
          : totalMin;
      fits = budget >= reference;
      if (fits) {
        final avgRef = (trip.budgetIncludesFlight == false)
            ? ((daily * days * 1.2).round())
            : totalAvg;
        tightFit = budget < avgRef;
      }
    }

    // Fiabilité : "bonne" si la destination matche directement le baseline
    // (ex: user a entré "Maroc", baseline = "Maroc"). "moyenne" si le match
    // passe par un keyword secondaire (ex: user "Marrakech" → baseline "Maroc")
    // car l'estimation est à l'échelle pays/région.
    final destNorm = _normalize(trip.destination);
    final nameNorm = _normalize(cost.displayName);
    final reliability = destNorm.contains(nameNorm) ? 'bonne' : 'moyenne';

    return AssistantBudgetEstimate(
      destination: trip.destination,
      durationDays: days,
      travelers: travelers,
      travelerType: travelerType,
      interests: interests,
      homeAirport: homeAirport,
      flightLowEur: flightLow,
      flightAvgEur: flightAvg,
      dailyBudgetEur: daily,
      totalMinPerPerson: totalMin,
      totalAvgPerPerson: totalAvg,
      totalMinAll: totalMin * travelers,
      totalAvgAll: totalAvg * travelers,
      userBudgetEur: trip.budgetPerPersonEur,
      userBudgetIncludesFlight: trip.budgetIncludesFlight,
      fits: fits,
      tightFit: tightFit,
      baselineName: cost.displayName,
      reliability: reliability,
      tier: cost.tier,
    );
  }

  static String _normalize(String s) {
    return s
        .toLowerCase()
        .replaceAll(RegExp(r'[éèêë]'), 'e')
        .replaceAll(RegExp(r'[àâä]'), 'a')
        .replaceAll(RegExp(r'[ïî]'), 'i')
        .replaceAll(RegExp(r'[ôö]'), 'o')
        .replaceAll(RegExp(r'[ûü]'), 'u')
        .replaceAll('ç', 'c');
  }

  /// Réplique de `_originFactor` du module baseline costs (privé là-bas).
  /// On garde la même table pour la cohérence ; à factoriser plus tard si
  /// on veut éviter la duplication.
  double _originFactorFor(String? iata) {
    if (iata == null || iata.isEmpty) return 1.0;
    final code = iata.toUpperCase();
    switch (code) {
      case 'CDG':
      case 'ORY':
      case 'BVA':
        return 1.0;
      case 'NCE':
      case 'MRS':
      case 'LYS':
      case 'TLS':
      case 'BOD':
      case 'NTE':
        return 1.15;
      case 'GVA':
      case 'BRU':
      case 'LUX':
        return 1.10;
      default:
        return 1.20;
    }
  }
}
