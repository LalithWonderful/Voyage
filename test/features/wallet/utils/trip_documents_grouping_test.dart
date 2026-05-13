/// Tests unitaires `trip_documents_grouping.dart`.
///
/// Couvre :
/// - [classifyTripDocuments] : ventilation par groupe, jamais de doc perdu.
/// - [sortTransportDocuments] / [sortAccommodationDocuments] /
///   [sortTicketDocuments] : tri chronologique stable, `null` en fin.
/// - [findInitialAccommodationIndex] : couvrant > à venir > plus récent
///   passé > 0.
/// - [findInitialTransportIndex] / [findInitialTicketIndex] : à venir >
///   passé > 0.
/// - [accommodationStatus] / [transportStatus] / [ticketStatus] :
///   current / upcoming / past / unknown.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/utils/trip_documents_grouping.dart';

TripDocument _doc({
  required String id,
  required String category,
  Map<String, dynamic> metadata = const {},
}) {
  return TripDocument(
    id: id,
    userId: 'u1',
    tripId: 't1',
    category: category,
    name: 'doc-$id',
    metadata: metadata,
    createdAt: DateTime(2026, 1, 1),
  );
}

void main() {
  group('classifyTripDocuments', () {
    test('ventile chaque catégorie vers le bon groupe', () {
      final docs = [
        _doc(id: 'h1', category: DocumentCategory.hotel),
        _doc(id: 'f1', category: DocumentCategory.flight),
        _doc(id: 'tr1', category: DocumentCategory.train),
        _doc(id: 'cr1', category: DocumentCategory.carRental),
        _doc(id: 'tk1', category: DocumentCategory.ticket),
        _doc(id: 'o1', category: DocumentCategory.other),
      ];
      final grouped = classifyTripDocuments(docs);
      expect(grouped.accommodations.map((d) => d.id), ['h1']);
      expect(
        grouped.transports.map((d) => d.id).toSet(),
        {'f1', 'tr1', 'cr1'},
      );
      expect(grouped.tickets.map((d) => d.id), ['tk1']);
      expect(grouped.others.map((d) => d.id), ['o1']);
    });

    test('catégorie inconnue → fallback `other`', () {
      final docs = [_doc(id: 'x1', category: 'wat')];
      final grouped = classifyTripDocuments(docs);
      expect(grouped.others.map((d) => d.id), ['x1']);
      expect(grouped.accommodations, isEmpty);
      expect(grouped.transports, isEmpty);
      expect(grouped.tickets, isEmpty);
    });

    test('liste vide → 4 listes vides', () {
      final grouped = classifyTripDocuments(const []);
      expect(grouped.isEmpty, isTrue);
    });

    test('aucun doc perdu : somme des groupes = entrée', () {
      final docs = [
        for (var i = 0; i < 5; i++)
          _doc(id: 'h$i', category: DocumentCategory.hotel),
        for (var i = 0; i < 3; i++)
          _doc(id: 'f$i', category: DocumentCategory.flight),
        _doc(id: 'tk1', category: DocumentCategory.ticket),
        _doc(id: 'o1', category: DocumentCategory.other),
        _doc(id: 'x1', category: 'unknown_future_cat'),
      ];
      final grouped = classifyTripDocuments(docs);
      final total = grouped.accommodations.length +
          grouped.transports.length +
          grouped.tickets.length +
          grouped.others.length;
      expect(total, docs.length);
    });
  });

  group('sortTransportDocuments', () {
    test('tri par date+heure croissant', () {
      final a = _doc(
        id: 'a',
        category: DocumentCategory.flight,
        metadata: {'date': '2026-06-22', 'departure_time': '10:00'},
      );
      final b = _doc(
        id: 'b',
        category: DocumentCategory.flight,
        metadata: {'date': '2026-06-21', 'departure_time': '23:00'},
      );
      final c = _doc(
        id: 'c',
        category: DocumentCategory.flight,
        metadata: {'date': '2026-06-22', 'departure_time': '08:00'},
      );
      final sorted = sortTransportDocuments([a, b, c]);
      expect(sorted.map((d) => d.id), ['b', 'c', 'a']);
    });

    test('docs sans date finissent à la fin, ordre d\'insertion préservé', () {
      final a = _doc(
        id: 'a',
        category: DocumentCategory.flight,
        metadata: {'date': '2026-06-22'},
      );
      final nodate1 = _doc(id: 'nd1', category: DocumentCategory.flight);
      final nodate2 = _doc(id: 'nd2', category: DocumentCategory.flight);
      final b = _doc(
        id: 'b',
        category: DocumentCategory.flight,
        metadata: {'date': '2026-06-20'},
      );
      final sorted = sortTransportDocuments([a, nodate1, b, nodate2]);
      expect(sorted.map((d) => d.id), ['b', 'a', 'nd1', 'nd2']);
    });

    test('car_rental utilise pickup_date', () {
      final cr = _doc(
        id: 'cr',
        category: DocumentCategory.carRental,
        metadata: {'pickup_date': '2026-06-15'},
      );
      final fl = _doc(
        id: 'fl',
        category: DocumentCategory.flight,
        metadata: {'date': '2026-06-20'},
      );
      expect(sortTransportDocuments([fl, cr]).map((d) => d.id), ['cr', 'fl']);
    });
  });

  group('findInitialAccommodationIndex', () {
    test('hôtel couvrant aujourd\'hui gagne sur tout', () {
      final h1 = _doc(
        id: 'h1',
        category: DocumentCategory.hotel,
        metadata: {'check_in': '2026-06-10', 'check_out': '2026-06-15'},
      );
      final h2 = _doc(
        id: 'h2',
        category: DocumentCategory.hotel,
        metadata: {'check_in': '2026-06-20', 'check_out': '2026-06-25'},
      );
      final h3 = _doc(
        id: 'h3',
        category: DocumentCategory.hotel,
        metadata: {'check_in': '2026-07-01', 'check_out': '2026-07-05'},
      );
      final sorted = sortAccommodationDocuments([h1, h2, h3]);
      final idx = findInitialAccommodationIndex(
        sorted,
        DateTime(2026, 6, 22),
      );
      expect(sorted[idx].id, 'h2');
    });

    test('aucun en cours → prochain à venir', () {
      final h1 = _doc(
        id: 'h1',
        category: DocumentCategory.hotel,
        metadata: {'check_in': '2026-06-10', 'check_out': '2026-06-15'},
      );
      final h2 = _doc(
        id: 'h2',
        category: DocumentCategory.hotel,
        metadata: {'check_in': '2026-07-01', 'check_out': '2026-07-05'},
      );
      final sorted = sortAccommodationDocuments([h1, h2]);
      final idx = findInitialAccommodationIndex(
        sorted,
        DateTime(2026, 6, 20),
      );
      expect(sorted[idx].id, 'h2');
    });

    test('tous passés → plus récent passé (pas le premier)', () {
      final old = _doc(
        id: 'old',
        category: DocumentCategory.hotel,
        metadata: {'check_in': '2026-01-10', 'check_out': '2026-01-15'},
      );
      final recent = _doc(
        id: 'recent',
        category: DocumentCategory.hotel,
        metadata: {'check_in': '2026-05-10', 'check_out': '2026-05-15'},
      );
      final sorted = sortAccommodationDocuments([old, recent]);
      final idx = findInitialAccommodationIndex(
        sorted,
        DateTime(2026, 6, 1),
      );
      expect(sorted[idx].id, 'recent');
    });

    test('check_in == today → couvre (current, pas upcoming)', () {
      final h = _doc(
        id: 'h',
        category: DocumentCategory.hotel,
        metadata: {'check_in': '2026-06-20', 'check_out': '2026-06-25'},
      );
      expect(
        findInitialAccommodationIndex([h], DateTime(2026, 6, 20, 14, 0)),
        0,
      );
      expect(accommodationStatus(h, DateTime(2026, 6, 20, 14, 0)),
          TripDocumentStatus.current);
    });

    test('liste vide → 0', () {
      expect(findInitialAccommodationIndex(const [], DateTime(2026, 6, 1)),
          0);
    });
  });

  group('findInitialTransportIndex', () {
    test('prochain transport à venir', () {
      final t1 = _doc(
        id: 't1',
        category: DocumentCategory.flight,
        metadata: {'date': '2026-06-10', 'departure_time': '10:00'},
      );
      final t2 = _doc(
        id: 't2',
        category: DocumentCategory.flight,
        metadata: {'date': '2026-06-25', 'departure_time': '14:00'},
      );
      final t3 = _doc(
        id: 't3',
        category: DocumentCategory.flight,
        metadata: {'date': '2026-07-10', 'departure_time': '09:00'},
      );
      final sorted = sortTransportDocuments([t1, t2, t3]);
      final idx = findInitialTransportIndex(
        sorted,
        DateTime(2026, 6, 22, 12, 0),
      );
      expect(sorted[idx].id, 't2');
    });

    test('tous passés → plus récent passé', () {
      final t1 = _doc(
        id: 't1',
        category: DocumentCategory.flight,
        metadata: {'date': '2026-01-10'},
      );
      final t2 = _doc(
        id: 't2',
        category: DocumentCategory.flight,
        metadata: {'date': '2026-05-10'},
      );
      final sorted = sortTransportDocuments([t1, t2]);
      final idx = findInitialTransportIndex(
        sorted,
        DateTime(2026, 6, 1),
      );
      expect(sorted[idx].id, 't2');
    });

    test('départ == now → considéré upcoming (>= now)', () {
      final t = _doc(
        id: 't',
        category: DocumentCategory.flight,
        metadata: {'date': '2026-06-22', 'departure_time': '14:00'},
      );
      expect(
        findInitialTransportIndex([t], DateTime(2026, 6, 22, 14, 0)),
        0,
      );
      expect(transportStatus(t, DateTime(2026, 6, 22, 14, 0)),
          TripDocumentStatus.upcoming);
    });

    test('liste vide → 0', () {
      expect(findInitialTransportIndex(const [], DateTime(2026, 6, 1)), 0);
    });
  });

  group('findInitialTicketIndex', () {
    test('prochaine réservation à venir', () {
      final tk1 = _doc(
        id: 'tk1',
        category: DocumentCategory.ticket,
        metadata: {'date': '2026-06-10', 'time': '20:00'},
      );
      final tk2 = _doc(
        id: 'tk2',
        category: DocumentCategory.ticket,
        metadata: {'date': '2026-06-25', 'time': '19:30'},
      );
      final sorted = sortTicketDocuments([tk1, tk2]);
      final idx = findInitialTicketIndex(
        sorted,
        DateTime(2026, 6, 22),
      );
      expect(sorted[idx].id, 'tk2');
    });

    test('toutes passées → plus récente passée', () {
      final tk1 = _doc(
        id: 'tk1',
        category: DocumentCategory.ticket,
        metadata: {'date': '2026-01-10'},
      );
      final tk2 = _doc(
        id: 'tk2',
        category: DocumentCategory.ticket,
        metadata: {'date': '2026-05-10'},
      );
      final sorted = sortTicketDocuments([tk1, tk2]);
      final idx = findInitialTicketIndex(
        sorted,
        DateTime(2026, 6, 1),
      );
      expect(sorted[idx].id, 'tk2');
    });
  });

  group('status helpers', () {
    test('accommodationStatus : current vs upcoming vs past', () {
      final h = _doc(
        id: 'h',
        category: DocumentCategory.hotel,
        metadata: {'check_in': '2026-06-10', 'check_out': '2026-06-15'},
      );
      expect(accommodationStatus(h, DateTime(2026, 6, 12)),
          TripDocumentStatus.current);
      expect(accommodationStatus(h, DateTime(2026, 6, 1)),
          TripDocumentStatus.upcoming);
      expect(accommodationStatus(h, DateTime(2026, 7, 1)),
          TripDocumentStatus.past);
    });

    test('transportStatus : upcoming vs past', () {
      final t = _doc(
        id: 't',
        category: DocumentCategory.flight,
        metadata: {
          'date': '2026-06-22',
          'departure_time': '14:00',
          'arrival_time': '15:55',
        },
      );
      expect(transportStatus(t, DateTime(2026, 6, 22, 13, 0)),
          TripDocumentStatus.upcoming);
      expect(transportStatus(t, DateTime(2026, 6, 23)),
          TripDocumentStatus.past);
    });

    test('status `unknown` quand aucune date exploitable', () {
      final orphan = _doc(id: 'x', category: DocumentCategory.flight);
      expect(transportStatus(orphan, DateTime(2026, 6, 1)),
          TripDocumentStatus.unknown);
    });
  });
}
