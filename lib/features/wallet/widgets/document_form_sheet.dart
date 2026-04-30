import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/core/widgets/transport_autocomplete_field.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';
import 'package:voyage/features/wallet/widgets/overlap_nights_sheet.dart';

Future<void> openDocumentFormSheet(
  BuildContext context,
  WidgetRef ref, {
  TripDocument? existing,
  String? initialTripId,
  String? initialCategory,
}) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _DocumentFormSheet(
      existing: existing,
      initialTripId: initialTripId,
      initialCategory: initialCategory,
    ),
  );
}

class _DocumentFormSheet extends ConsumerStatefulWidget {
  final TripDocument? existing;
  final String? initialTripId;
  final String? initialCategory;
  const _DocumentFormSheet({this.existing, this.initialTripId, this.initialCategory});

  @override
  ConsumerState<_DocumentFormSheet> createState() => _DocumentFormSheetState();
}

class _DocumentFormSheetState extends ConsumerState<_DocumentFormSheet> {
  late String _category;
  String? _tripId;
  bool _extracting = false;
  bool _saving = false;

  final _nameCtrl = TextEditingController();
  // Champs dynamiques stockés par clé
  final Map<String, TextEditingController> _textCtrls = {};
  final Map<String, DateTime?> _dates = {};
  // PlaceId Google + session token associés aux champs `from`/`to` (Vol/Train)
  // quand l'user pick une suggestion via TransportAutocompleteField. Le token
  // est ré-utilisé au save pour le Place Details (continuité tarif session).
  // Réinitialisé si l'user édite le champ après un pick (le champ devient
  // "saisie libre" et retombe en fallback Geocoding texte au save).
  final Map<String, String> _placeIds = {};
  final Map<String, String> _sessionTokens = {};

  @override
  void initState() {
    super.initState();
    _category = widget.existing?.category ?? widget.initialCategory ?? DocumentCategory.hotel;
    _tripId = widget.existing?.tripId ?? widget.initialTripId;
    _nameCtrl.text = widget.existing?.name ?? '';
    _hydrateFromMetadata(widget.existing?.metadata ?? const {});
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final c in _textCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  // Schéma : liste des champs par catégorie : (clé, label, type, flex)
  // type : text | multiline | date | time
  List<_FieldSpec> get _fields {
    switch (_category) {
      case DocumentCategory.hotel:
        return const [
          _FieldSpec('address', 'Adresse', _FieldType.multiline),
          _FieldSpec('check_in', 'Check-in', _FieldType.date),
          _FieldSpec('check_out', 'Check-out', _FieldType.date),
          _FieldSpec('reservation_number', 'N° de réservation', _FieldType.text),
        ];
      case DocumentCategory.flight:
        return const [
          _FieldSpec('airline', 'Compagnie', _FieldType.text),
          _FieldSpec('flight_number', 'N° de vol', _FieldType.text),
          _FieldSpec('from', 'Aéroport de départ', _FieldType.text),
          _FieldSpec('to', 'Aéroport d\'arrivée', _FieldType.text),
          _FieldSpec('date', 'Date', _FieldType.date),
          _FieldSpec('departure_time', 'Heure de départ', _FieldType.time),
          _FieldSpec('arrival_time', 'Heure d\'arrivée', _FieldType.time),
          _FieldSpec('seat', 'Siège', _FieldType.text),
          _FieldSpec('reservation_number', 'N° de réservation', _FieldType.text),
        ];
      case DocumentCategory.train:
        return const [
          _FieldSpec('company', 'Compagnie', _FieldType.text),
          _FieldSpec('train_number', 'N° de train', _FieldType.text),
          _FieldSpec('from', 'Gare de départ', _FieldType.text),
          _FieldSpec('to', 'Gare d\'arrivée', _FieldType.text),
          _FieldSpec('date', 'Date', _FieldType.date),
          _FieldSpec('departure_time', 'Heure de départ', _FieldType.time),
          _FieldSpec('arrival_time', 'Heure d\'arrivée', _FieldType.time),
          _FieldSpec('car', 'Voiture', _FieldType.text),
          _FieldSpec('seat', 'Place', _FieldType.text),
          _FieldSpec('class', 'Classe', _FieldType.text),
          _FieldSpec('reservation_number', 'N° de réservation', _FieldType.text),
        ];
      case DocumentCategory.carRental:
        return const [
          _FieldSpec('company', 'Agence', _FieldType.text),
          _FieldSpec('vehicle', 'Véhicule', _FieldType.text),
          _FieldSpec('pickup_location', 'Prise en charge', _FieldType.text),
          _FieldSpec('pickup_date', 'Date', _FieldType.date),
          _FieldSpec('pickup_time', 'Heure', _FieldType.time),
          _FieldSpec('return_location', 'Retour', _FieldType.text),
          _FieldSpec('return_date', 'Date retour', _FieldType.date),
          _FieldSpec('return_time', 'Heure retour', _FieldType.time),
          _FieldSpec('reservation_number', 'N° de réservation', _FieldType.text),
        ];
      case DocumentCategory.ticket:
        return const [
          _FieldSpec('venue', 'Lieu', _FieldType.text),
          _FieldSpec('address', 'Adresse', _FieldType.multiline),
          _FieldSpec('date', 'Date', _FieldType.date),
          _FieldSpec('time', 'Heure', _FieldType.time),
          _FieldSpec('seat', 'Place / rang', _FieldType.text),
          _FieldSpec('reservation_number', 'N° de billet', _FieldType.text),
        ];
      default:
        return const [
          _FieldSpec('description', 'Description', _FieldType.multiline),
          _FieldSpec('date', 'Date', _FieldType.date),
        ];
    }
  }

  TextEditingController _ctrl(String key) => _textCtrls.putIfAbsent(key, () => TextEditingController());

  void _hydrateFromMetadata(Map<String, dynamic> m) {
    _dates.clear();
    _placeIds.clear();
    _sessionTokens.clear();
    for (final spec in _fields) {
      final v = m[spec.key];
      if (spec.type == _FieldType.date) {
        if (v is String && v.isNotEmpty) {
          _dates[spec.key] = DateTime.tryParse(v);
        }
      } else if (v != null) {
        _ctrl(spec.key).text = v.toString();
      }
    }
    // Restaure les placeIds existants pour les endpoints Vol/Train. Permet
    // l'idempotence au save : si l'user n'a pas changé le champ, on garde
    // le placeId et on saute Place Details via le cache.
    final fromPid = m['from_place_id'] as String?;
    final toPid = m['to_place_id'] as String?;
    if (fromPid != null && fromPid.isNotEmpty) _placeIds['from'] = fromPid;
    if (toPid != null && toPid.isNotEmpty) _placeIds['to'] = toPid;
  }

  Future<void> _pickDate(String key) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dates[key] ?? now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 5),
      locale: const Locale('fr'),
    );
    if (picked != null) setState(() => _dates[key] = picked);
  }

  Future<void> _pickTime(String key) async {
    final existing = _ctrl(key).text;
    TimeOfDay initial = TimeOfDay.now();
    if (existing.contains(':')) {
      final parts = existing.split(':');
      final h = int.tryParse(parts[0]) ?? initial.hour;
      final m = int.tryParse(parts[1]) ?? initial.minute;
      initial = TimeOfDay(hour: h, minute: m);
    }
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null) {
      _ctrl(key).text = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
      setState(() {});
    }
  }

  Future<void> _pickImageAndExtract(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, imageQuality: 85, maxWidth: 2200);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final mimeType = picked.mimeType ?? (picked.path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg');

    setState(() => _extracting = true);
    try {
      final service = ref.read(aiSuggestionsServiceProvider);
      final extracted = await service.extractDocumentFromImage(
        bytes,
        mimeType: mimeType,
        hintCategory: widget.existing != null ? _category : null,
      );
      if (!mounted) return;
      _applyExtracted(extracted);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Extraction impossible : $e'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  Future<void> _chooseImageSource() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Galerie (screenshots, photos)'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source != null) await _pickImageAndExtract(source);
  }

  Future<void> _applyExtracted(Map<String, dynamic> extracted) async {
    final newCategory = (extracted['category'] as String?) ?? _category;
    final name = (extracted['name'] as String?) ?? '';
    final metadata = (extracted['metadata'] as Map?)?.cast<String, dynamic>() ?? const {};

    // Auto-détection du voyage : cherche un voyage actif (non terminé)
    // dont les dates couvrent la date principale extraite du document.
    String? autoTripId;
    if (_tripId == null) {
      final docDate = _extractPrimaryDate(newCategory, metadata);
      if (docDate != null) {
        try {
          final trips = await ref.read(tripsProvider.future);
          final today = DateTime.now();
          final todayStart = DateTime(today.year, today.month, today.day);
          final docDay = DateTime(docDate.year, docDate.month, docDate.day);
          final matches = trips.where((t) {
            final startDay = DateTime(t.startDate.year, t.startDate.month, t.startDate.day);
            final endDay = DateTime(t.endDate.year, t.endDate.month, t.endDate.day);
            final isActive = !endDay.isBefore(todayStart);
            final inRange = !docDay.isBefore(startDay) && !docDay.isAfter(endDay);
            return isActive && inRange;
          }).toList();
          developer.log(
            'Auto-rattachement voyage : docDate=$docDate, voyages actifs matchés=${matches.length}, '
            'voyages total=${trips.length}',
            name: 'wallet',
          );
          if (matches.length == 1) {
            autoTripId = matches.first.id;
          } else if (matches.isEmpty) {
            developer.log(
              'Aucun voyage ne couvre cette date. Voyages : '
              '${trips.map((t) => '${t.title} (${t.startDate.toIso8601String().split('T').first}→${t.endDate.toIso8601String().split('T').first})').join(', ')}',
              name: 'wallet',
            );
          }
        } catch (e) {
          developer.log('Erreur auto-rattachement : $e', name: 'wallet');
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _category = newCategory;
      _nameCtrl.text = name;
      for (final c in _textCtrls.values) {
        c.clear();
      }
      _dates.clear();
      _hydrateFromMetadata(metadata);
      if (autoTripId != null) _tripId = autoTripId;
    });

    final msg = autoTripId != null
        ? '✨ Détecté : ${categoryLabel(newCategory)} — voyage rattaché automatiquement.'
        : '✨ Détecté : ${categoryLabel(newCategory)} — vérifie avant d\'enregistrer.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

    // Pour les docs Vol/Train extraits par Gemini : résolution silencieuse en
    // arrière-plan des placeIds Google pour `from`/`to`. Sans ça, le save
    // tomberait en fallback Geocoding texte (chemin 3) qui n'alimente pas
    // `place_lookup_cache` → un user qui chercherait le même aéroport plus
    // tard manuellement repaierait Place Details. Ici on harmonise les deux
    // modes : Gemini extraction = même bénéfice cache que pick manuel.
    if (newCategory == DocumentCategory.flight || newCategory == DocumentCategory.train) {
      // Fire-and-forget : pas d'await pour ne pas bloquer l'UX. Si l'user
      // édite/save avant que le lookup résolve, le save retombe en chemin 3.
      // ignore: unawaited_futures
      _autoResolveTransportPlaceIds();
    }
  }

  /// Pour chaque endpoint (`from`/`to`) qui a un texte mais pas de placeId,
  /// fait un autocomplete Places avec la 1ère suggestion. Si l'user n'a pas
  /// modifié le champ entre-temps, on persiste le placeId trouvé pour que le
  /// save bénéficie du cache. Silencieux : aucun feedback UI, aucun blocage.
  Future<void> _autoResolveTransportPlaceIds() async {
    final type = _category == DocumentCategory.flight ? 'airport' : 'train_station';
    final placesService = ref.read(placesServiceProvider);
    for (final fieldKey in const ['from', 'to']) {
      final value = _ctrl(fieldKey).text.trim();
      if (value.isEmpty) continue;
      if (_placeIds.containsKey(fieldKey)) continue; // déjà résolu
      // Session token unique pour ce lookup silencieux. Sera ré-utilisé au
      // save pour le Place Details (continuité tarif session).
      final token = _newSessionToken();
      try {
        final results = await placesService.autocompleteTransport(
          value,
          type: type,
          sessionToken: token,
        );
        if (!mounted) return;
        if (results.isEmpty) continue;
        // Si l'user a édité entre-temps, on n'écrase pas sa saisie.
        if (_ctrl(fieldKey).text.trim() != value) continue;
        final picked = results.first;
        _placeIds[fieldKey] = picked.placeId;
        _sessionTokens[fieldKey] = token;
        // On peut aligner le name sur la 1ère suggestion (ex: "BKK" → "Aéroport
        // de Bangkok-Suvarnabhumi") pour cohérence avec le mode pick manuel.
        // setState pour rafraîchir l'affichage du TextField.
        setState(() {
          _ctrl(fieldKey).text = picked.mainText;
        });
      } catch (e) {
        developer.log('[gemini-extract] auto-resolve $fieldKey failed: $e', name: 'wallet');
      }
    }
  }

  /// UUID v4-like pour les session tokens Google Places. Mêmes contraintes
  /// que le widget : juste un identifiant unique côté client, opaque côté
  /// Google. Dupliqué ici (vs le widget) car cette résolution silencieuse
  /// court-circuite le widget.
  String _newSessionToken() {
    final rng = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Retourne la date "principale" d'un document selon sa catégorie.
  DateTime? _extractPrimaryDate(String category, Map<String, dynamic> metadata) {
    String? dateStr;
    switch (category) {
      case DocumentCategory.hotel:
        dateStr = metadata['check_in'] as String?;
        break;
      case DocumentCategory.carRental:
        dateStr = metadata['pickup_date'] as String?;
        break;
      default:
        dateStr = metadata['date'] as String?;
    }
    if (dateStr == null || dateStr.isEmpty) return null;
    return DateTime.tryParse(dateStr);
  }

  Future<void> _openPasteDialog() async {
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: const Text('Coller l\'email de confirmation'),
          content: SizedBox(
            width: double.maxFinite,
            child: TextField(
              controller: ctrl,
              maxLines: 10,
              minLines: 6,
              decoration: const InputDecoration(
                hintText: 'Colle ici le mail (Booking, Airbnb, SNCF, compagnie aérienne, billetterie...)',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Extraire'),
            ),
          ],
        );
      },
    );
    if (text == null || text.isEmpty) return;

    setState(() => _extracting = true);
    try {
      final service = ref.read(aiSuggestionsServiceProvider);
      final extracted = await service.extractDocumentFromText(text, hintCategory: widget.existing != null ? _category : null);
      if (!mounted) return;
      _applyExtracted(extracted);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Extraction impossible : $e'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  Map<String, dynamic> _buildMetadata() {
    // IMPORTANT : on part de l'existant pour préserver les clés qui ne sont pas
    // représentées par un champ du formulaire (ex: `sleep_nights` posé par la sheet
    // de chevauchement d'hébergements). Sans ça, éditer n'importe quel champ effacerait
    // toutes les clés "hors formulaire".
    final m = Map<String, dynamic>.from(widget.existing?.metadata ?? const {});
    for (final spec in _fields) {
      if (spec.type == _FieldType.date) {
        final d = _dates[spec.key];
        if (d != null) {
          m[spec.key] = d.toIso8601String().split('T').first;
        } else {
          m.remove(spec.key);
        }
      } else {
        final v = _ctrl(spec.key).text.trim();
        if (v.isNotEmpty) {
          m[spec.key] = v;
        } else {
          m.remove(spec.key);
        }
      }
    }
    return m;
  }

  /// Tente de géocoder l'adresse d'un hôtel et met à jour `meta` en place
  /// (`latitude`, `longitude`, `geocoding_failed`). Comportement :
  /// - Adresse vide → reset coords + flag (l'user a effacé l'adresse).
  /// - Adresse inchangée + coords déjà présents → no-op (économie d'appel API).
  /// - Adresse nouvelle/changée → appel `GeocodingService.geocode` avec le
  ///   code pays du voyage en hint pour fiabiliser sur les adresses partielles.
  /// - Succès : pose lat/lng, retire le flag d'échec.
  /// - Échec (réseau / pas de résultat) : pose `geocoding_failed=true` et
  ///   retire les coords précédentes (l'adresse a changé donc les anciennes
  ///   coords ne sont plus valides).
  /// Résout un endpoint de transport (`from` ou `to`) en coords + nom canonique
  /// et écrit le résultat dans `meta`. Trois chemins possibles :
  ///
  /// 1. **PlaceId disponible** (l'user a pick une suggestion autocomplete) →
  ///    lookup `place_lookup_cache` partagé. Hit = 0 appel API. Miss = 1
  ///    Place Details (Basic, $0.005) puis upsert dans le cache.
  /// 2. **Pas de placeId mais champ inchangé** (édition sans toucher) → no-op,
  ///    on garde les coords existantes.
  /// 3. **Pas de placeId, champ saisi librement** (extraction Gemini, doc legacy
  ///    importé sans pick) → fallback Geocoding texte avec préfixe + regionHint.
  ///
  /// `kind` = 'airport' ou 'train_station' (alimente le cache pour ré-utilisation
  /// future + permet de différencier les types).
  Future<void> _resolveTransportEndpoint({
    required Map<String, dynamic> meta,
    required String fieldKey,
    required String kind,
    required String prefix,
    required String? regionHint,
  }) async {
    final latKey = '${fieldKey}_latitude';
    final lngKey = '${fieldKey}_longitude';
    final failKey = '${fieldKey}_geocoding_failed';
    final placeIdKey = '${fieldKey}_place_id';

    final newVal = (meta[fieldKey] as String?)?.trim() ?? '';
    if (newVal.isEmpty) {
      // Champ vidé → on nettoie tout (coords, flag, placeId).
      meta.remove(latKey);
      meta.remove(lngKey);
      meta.remove(failKey);
      meta.remove(placeIdKey);
      return;
    }

    // Chemin 1 : placeId fraîchement posé par autocomplete OU déjà en metadata
    // (édition sans changement). Sécurise les coords par le cache partagé.
    final pickedPlaceId = _placeIds[fieldKey];
    final existingPlaceId = pickedPlaceId ?? (widget.existing?.metadata[placeIdKey] as String?);
    if (existingPlaceId != null && existingPlaceId.isNotEmpty) {
      final oldVal = ((widget.existing?.metadata[fieldKey]) as String?)?.trim() ?? '';
      final hadCoords = widget.existing?.metadata[latKey] != null &&
          widget.existing?.metadata[lngKey] != null;
      // Si le user a édité (pas de pick frais) ET le name n'a pas changé ET
      // les coords sont là, on saute le cache aussi (économie max).
      if (pickedPlaceId == null && newVal == oldVal && hadCoords) {
        meta[placeIdKey] = existingPlaceId;
        meta[latKey] = widget.existing!.metadata[latKey];
        meta[lngKey] = widget.existing!.metadata[lngKey];
        meta.remove(failKey);
        return;
      }
      final cache = ref.read(placeLookupCacheServiceProvider);
      final resolved = await cache.resolveCoords(
        placeId: existingPlaceId,
        kind: kind,
        sessionToken: _sessionTokens[fieldKey],
      );
      if (resolved != null) {
        meta[placeIdKey] = existingPlaceId;
        meta[latKey] = resolved.lat;
        meta[lngKey] = resolved.lng;
        // Si Place Details renvoie un nom différent (ex: "BKK" → "Aéroport
        // de Bangkok-Suvarnabhumi"), on écrase le name pour cohérence avec
        // ce que l'user a vu dans le dropdown — c'est déjà le cas si pick
        // frais, on garantit aussi pour le hit cache pur.
        if (resolved.name.isNotEmpty) meta[fieldKey] = resolved.name;
        meta.remove(failKey);
        return;
      }
      // Place Details a foiré (rare) → on tombe en fallback Geocoding texte.
    }

    // Chemin 3 : pas de placeId, fallback Geocoding texte. Idempotent : pas
    // de re-call si rien n'a changé.
    final oldVal = ((widget.existing?.metadata[fieldKey]) as String?)?.trim() ?? '';
    final hadCoords = widget.existing?.metadata[latKey] != null &&
        widget.existing?.metadata[lngKey] != null;
    if (newVal == oldVal && hadCoords) {
      return;
    }
    // Skip le préfixe si l'utilisateur a déjà tapé un mot équivalent (FR/EN/ES).
    const equivalents = ['airport', 'aéroport', 'aeroport', 'gare', 'station', 'estación', 'estacion', 'bahnhof'];
    final lower = newVal.toLowerCase();
    final alreadyTyped = equivalents.any(lower.contains);
    final query = alreadyTyped ? newVal : '$prefix$newVal';
    final geo = await ref
        .read(geocodingServiceProvider)
        .geocode(query, regionHint: regionHint);
    if (geo != null) {
      meta[latKey] = geo.latitude;
      meta[lngKey] = geo.longitude;
      meta.remove(failKey);
      meta.remove(placeIdKey);
    } else {
      meta[failKey] = true;
      meta.remove(latKey);
      meta.remove(lngKey);
      meta.remove(placeIdKey);
    }
  }

  /// Résout les deux endpoints (`from` et `to`) d'un doc Vol ou Train.
  Future<void> _geocodeTransportDocument(Map<String, dynamic> meta) async {
    String? regionHint;
    if (_tripId != null) {
      final trip = await ref.read(tripByIdProvider(_tripId!).future);
      regionHint = trip?.destinationCountryCode;
    }
    final isFlight = _category == DocumentCategory.flight;
    final kind = isFlight ? 'airport' : 'train_station';
    final prefix = isFlight ? 'airport ' : 'train station ';
    await _resolveTransportEndpoint(
      meta: meta,
      fieldKey: 'from',
      kind: kind,
      prefix: prefix,
      regionHint: regionHint,
    );
    await _resolveTransportEndpoint(
      meta: meta,
      fieldKey: 'to',
      kind: kind,
      prefix: prefix,
      regionHint: regionHint,
    );
  }

  Future<void> _geocodeHotelAddress(Map<String, dynamic> meta) async {
    final newAddress = (meta['address'] as String?)?.trim() ?? '';
    if (newAddress.isEmpty) {
      meta.remove('latitude');
      meta.remove('longitude');
      meta.remove('geocoding_failed');
      return;
    }
    final oldAddress =
        ((widget.existing?.metadata['address']) as String?)?.trim() ?? '';
    final hadCoords = widget.existing?.metadata['latitude'] != null &&
        widget.existing?.metadata['longitude'] != null;
    if (newAddress == oldAddress && hadCoords) {
      return;
    }
    String? regionHint;
    if (_tripId != null) {
      final trip = await ref.read(tripByIdProvider(_tripId!).future);
      regionHint = trip?.destinationCountryCode;
    }
    final geo = await ref
        .read(geocodingServiceProvider)
        .geocode(newAddress, regionHint: regionHint);
    if (geo != null) {
      meta['latitude'] = geo.latitude;
      meta['longitude'] = geo.longitude;
      meta.remove('geocoding_failed');
    } else {
      meta['geocoding_failed'] = true;
      meta.remove('latitude');
      meta.remove('longitude');
    }
  }

  Future<void> _save() async {
    // Force le commit IME : sans ça, si l'utilisateur tape "Enregistrer" alors
    // que l'adresse a encore le focus (saisie en cours, autocomplete pending,
    // clavier flottant Samsung, etc.), les derniers caractères peuvent ne pas
    // être dans le controller.text au moment de la lecture.
    FocusManager.instance.primaryFocus?.unfocus();
    // Délai plus long (100ms) pour laisser le temps aux IMEs pénibles (Samsung flottant,
    // autocomplete Android) de commiter la composition avant qu'on lise les controllers.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Le nom est requis.')),
      );
      return;
    }

    // Validations cohérence dates pour les hôtels rattachés à un voyage :
    // 1) Check-in/check-out doivent être DANS la plage du voyage (la convention
    //    Voyage est `endDate` = dernier jour inclus, donc check-out le jour de
    //    fin = OK ; check-out > endDate = erreur).
    // 2) Pas de chevauchement avec un autre hôtel du même voyage. Continuité
    //    autorisée (checkout d'un hôtel = checkin du suivant). Si chevauchement
    //    légitime (transit court, 2 hôtels même nuit), on assouplira.
    // Skip si pas de tripId ou dates manquantes.
    if (_category == DocumentCategory.hotel && _tripId != null) {
      final builtMetaPreview = _buildMetadata();
      final newCiStr = builtMetaPreview['check_in'] as String?;
      final newCoStr = builtMetaPreview['check_out'] as String?;
      final newCi = newCiStr != null ? DateTime.tryParse(newCiStr) : null;
      final newCo = newCoStr != null ? DateTime.tryParse(newCoStr) : null;

      // 1) Cohérence avec les dates du voyage
      if (newCi != null || newCo != null) {
        final trip = await ref.read(tripByIdProvider(_tripId!).future);
        if (!mounted) return;
        if (trip != null) {
          final tripStart = DateTime(trip.startDate.year, trip.startDate.month, trip.startDate.day);
          final tripEnd = DateTime(trip.endDate.year, trip.endDate.month, trip.endDate.day);
          String fmt(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
          if (newCi != null && newCi.isBefore(tripStart)) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('⚠️ Check-in (${fmt(newCi)}) avant le début du voyage (${fmt(tripStart)}).'),
                backgroundColor: AppColors.error,
              ),
            );
            return;
          }
          if (newCo != null && newCo.isAfter(tripEnd)) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('⚠️ Check-out (${fmt(newCo)}) après la fin du voyage (${fmt(tripEnd)}).'),
                backgroundColor: AppColors.error,
              ),
            );
            return;
          }
        }
      }

      // 2) Overlap avec les autres hôtels du voyage
      if (newCi != null && newCo != null) {
        final hotels = await ref.read(tripHotelsProvider(_tripId!).future);
        if (!mounted) return;
        for (final h in hotels) {
          if (widget.existing != null && h.id == widget.existing!.id) continue;
          final otherCi = DateTime.tryParse(h.metadata['check_in'] as String? ?? '');
          final otherCo = DateTime.tryParse(h.metadata['check_out'] as String? ?? '');
          if (otherCi == null || otherCo == null) continue;
          // Overlap = intersection non vide en ouverture stricte sur les
          // bornes : [newCi, newCo) ∩ [otherCi, otherCo) ≠ ∅. Avec cette
          // règle, checkout=checkin est autorisé (suite logique).
          final overlaps = newCi.isBefore(otherCo) && otherCi.isBefore(newCo);
          if (overlaps) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('⚠️ Chevauchement avec « ${h.name} »'),
                backgroundColor: AppColors.error,
              ),
            );
            return;
          }
        }
      }
    }

    setState(() => _saving = true);
    try {
      final client = ref.read(supabaseProvider);
      final userId = client.auth.currentUser!.id;
      final builtMeta = _buildMetadata();
      // Géocodage des adresses d'hébergement pour permettre l'affichage des
      // trajets hôtel ↔ activité dans la timeline. Idempotent : on ne ré-appelle
      // l'API que si l'adresse a changé OU qu'on n'a pas encore de coords.
      // Échec = flag `geocoding_failed`, le caller affiche un badge UX (pas bloquant).
      if (_category == DocumentCategory.hotel) {
        await _geocodeHotelAddress(builtMeta);
        if (!mounted) return;
      }
      // Géocodage des aéroports/gares pour les docs Vol et Train. Permet de
      // générer 2 activités virtuelles géolocalisées (départ + arrivée) dans
      // la timeline (cf. virtualActivitiesFromDocument). Échec sur un endpoint
      // = flag `from_geocoding_failed` / `to_geocoding_failed`, le warning UX
      // s'affiche dans la card du wallet.
      if (_category == DocumentCategory.flight || _category == DocumentCategory.train) {
        await _geocodeTransportDocument(builtMeta);
        if (!mounted) return;
      }
      final payload = {
        'user_id': userId,
        'trip_id': _tripId,
        'category': _category,
        'name': name,
        'metadata': builtMeta,
      };
      String? savedId;
      if (widget.existing != null) {
        // .select() au lieu de .update() seul : si rows=0, on peut détecter
        // un problème de policy RLS et alerter l'utilisateur au lieu d'un échec
        // silencieux (cas vécu sur trip_documents en avril 2026).
        final updateRes = await client
            .from('trip_documents')
            .update(payload)
            .eq('id', widget.existing!.id)
            .select();
        if ((updateRes as List).isEmpty) {
          throw Exception('Aucune ligne mise à jour. Vérifie les policies RLS UPDATE sur trip_documents (auth.uid() = user_id).');
        }
        savedId = widget.existing!.id;
      } else {
        final inserted = await client.from('trip_documents').insert(payload).select();
        if ((inserted as List).isEmpty) {
          throw Exception('Aucun document inséré (vérifie les policies RLS).');
        }
        savedId = (inserted.first as Map)['id'] as String?;
      }
      ref.invalidate(documentsProvider);
      if (_tripId != null) {
        ref.invalidate(tripDocumentsProvider(_tripId!));
        ref.invalidate(tripHotelProvider(_tripId!));
      }

      // Si c'est un hôtel attaché à un voyage et qu'il chevauche un autre hébergement,
      // on demande à l'utilisateur de préciser où il dort chaque nuit de chevauchement.
      // On ne pose la question QUE pour les nuits non encore résolues (pas déjà confirmées
      // dans `metadata.sleep_nights` d'un des hôtels impliqués) — évite de re-demander
      // à chaque édition minime du doc (adresse, numéro de résa...).
      if (_category == DocumentCategory.hotel && _tripId != null && savedId != null) {
        final hotels = await ref.read(tripHotelsProvider(_tripId!).future);
        if (!mounted) return;
        final savedHotel = hotels.where((h) => h.id == savedId).firstOrNull;
        if (savedHotel != null) {
          final overlap = overlappingNights(savedHotel, hotels);
          // Une nuit est "résolue" si UN des hôtels qui la couvrent l'a dans sleep_nights.
          final unresolved = overlap.where((night) {
            final iso = isoDay(night);
            final candidates = hotelsSleepingOnNight(hotels, night);
            return !candidates.any((h) => confirmedSleepNights(h).contains(iso));
          }).toList();
          if (unresolved.isNotEmpty) {
            await openOverlapNightsSheet(
              context, ref,
              tripId: _tripId!,
              overlapNights: unresolved,
              allHotels: hotels,
            );
          }
        }
      }

      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    if (widget.existing == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce document ?'),
        content: Text(widget.existing!.name),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(supabaseProvider).from('trip_documents').delete().eq('id', widget.existing!.id);
      ref.invalidate(documentsProvider);
      if (widget.existing!.tripId != null) {
        ref.invalidate(tripDocumentsProvider(widget.existing!.tripId!));
        ref.invalidate(tripHotelProvider(widget.existing!.tripId!));
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final tripsAsync = ref.watch(tripsProvider);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.9,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.existing == null ? 'Ajouter un document' : 'Modifier le document', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                        const SizedBox(height: 2),
                        Text('Saisie manuelle ou extraction depuis un email.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  if (widget.existing != null)
                    IconButton(
                      onPressed: _delete,
                      icon: Icon(Icons.delete_outline, color: AppColors.error),
                      tooltip: 'Supprimer',
                    ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    color: AppColors.textSecondary,
                    tooltip: 'Fermer',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  Text(
                    'Pré-remplir automatiquement avec Gemini',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.3),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _extracting ? null : _openPasteDialog,
                          icon: const Icon(Icons.content_paste, size: 16),
                          label: const Text('Texte'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 44),
                            foregroundColor: AppColors.accent,
                            side: BorderSide(color: AppColors.accent),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _extracting ? null : _chooseImageSource,
                          icon: const Icon(Icons.image_outlined, size: 16),
                          label: const Text('Image'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 44),
                            foregroundColor: AppColors.accent,
                            side: BorderSide(color: AppColors.accent),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_extracting) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 8),
                        Text('Extraction en cours...', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Sélecteur de catégorie
                    Text('TYPE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 92,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final c in DocumentCategory.all)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: _CategoryChip(
                                category: c,
                                selected: _category == c,
                                onTap: () => setState(() => _category = c),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Rattachement à un voyage
                    Text('RATTACHÉ À UN VOYAGE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 8),
                    tripsAsync.when(
                      loading: () => const SizedBox(height: 40, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
                      error: (_, __) => Text('Erreur de chargement des voyages', style: TextStyle(fontSize: 12, color: AppColors.error)),
                      data: (trips) => DropdownButtonFormField<String?>(
                        value: _tripId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          hintText: 'Aucun (document général)',
                        ),
                        items: [
                          const DropdownMenuItem<String?>(value: null, child: Text('Aucun (document général)')),
                          for (final t in trips)
                            DropdownMenuItem<String?>(value: t.id, child: Text('${t.coverEmoji} ${t.title}', overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: (v) => setState(() => _tripId = v),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Nom
                    Text('NOM *', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _nameCtrl,
                      decoration: InputDecoration(hintText: _hintForCategory(_category)),
                    ),
                    const SizedBox(height: 16),

                    // Champs dynamiques
                    for (final spec in _fields) ...[
                      Text(spec.label.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                      const SizedBox(height: 6),
                      _buildField(spec),
                      const SizedBox(height: 14),
                    ],
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: BoxDecoration(color: AppColors.surface, border: Border(top: BorderSide(color: AppColors.border))),
              child: SafeArea(
                top: false,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('Enregistrer'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildField(_FieldSpec spec) {
    // Cas spéciaux : champs `from`/`to` des docs Vol/Train → autocomplete
    // Google Places filtré sur les aéroports/gares. Évite les saisies libres
    // ("bkkooo") et fournit directement un placeId pour résolution coords
    // précise via le cache partagé.
    if ((spec.key == 'from' || spec.key == 'to') &&
        (_category == DocumentCategory.flight || _category == DocumentCategory.train)) {
      final type = _category == DocumentCategory.flight
          ? TransportPlaceType.airport
          : TransportPlaceType.trainStation;
      return TransportAutocompleteField(
        key: ValueKey('${spec.key}_$_category'),
        type: type,
        initialValue: _ctrl(spec.key).text,
        labelText: null, // le label est rendu au-dessus par le parent (cohérence)
        hintText: type == TransportPlaceType.airport
            ? 'Ex : Bangkok, BKK, Charles de Gaulle…'
            : 'Ex : Lyon Part-Dieu, Bangkok Hua Lamphong…',
        onChanged: (value) {
          _ctrl(spec.key).text = value;
          // Si l'user édite après un pick, le placeId stocké n'est plus
          // valide — on le clear pour retomber en fallback Geocoding au save.
          if (_placeIds.containsKey(spec.key)) {
            _placeIds.remove(spec.key);
            _sessionTokens.remove(spec.key);
          }
        },
        onSelected: (name, placeId, sessionToken) {
          _ctrl(spec.key).text = name;
          _placeIds[spec.key] = placeId;
          _sessionTokens[spec.key] = sessionToken;
        },
      );
    }
    switch (spec.type) {
      case _FieldType.date:
        final d = _dates[spec.key];
        return GestureDetector(
          onTap: () => _pickDate(spec.key),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: d != null ? AppColors.primary : AppColors.border, width: d != null ? 1.5 : 1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.calendar_today, size: 16, color: AppColors.textSecondary),
                const SizedBox(width: 8),
                Text(d != null ? _fmtDate(d) : 'JJ/MM/AAAA', style: TextStyle(fontSize: 13, color: d != null ? AppColors.textPrimary : AppColors.textSecondary)),
              ],
            ),
          ),
        );
      case _FieldType.time:
        return TextField(
          controller: _ctrl(spec.key),
          readOnly: true,
          onTap: () => _pickTime(spec.key),
          decoration: const InputDecoration(hintText: 'HH:MM', suffixIcon: Icon(Icons.access_time, size: 18)),
        );
      case _FieldType.multiline:
        return TextField(
          controller: _ctrl(spec.key),
          minLines: 1,
          maxLines: 3,
        );
      case _FieldType.text:
        return TextField(
          controller: _ctrl(spec.key),
        );
    }
  }

  String _hintForCategory(String c) {
    switch (c) {
      case DocumentCategory.hotel: return 'Ex : Hôtel Memmo Alfama';
      case DocumentCategory.flight: return 'Ex : Vol Paris → Lisbonne';
      case DocumentCategory.train: return 'Ex : TGV Paris → Marseille';
      case DocumentCategory.carRental: return 'Ex : Location Hertz Lisbonne';
      case DocumentCategory.ticket: return 'Ex : Concert Radiohead';
      default: return 'Nom du document';
    }
  }
}

class _CategoryChip extends StatelessWidget {
  final String category;
  final bool selected;
  final VoidCallback onTap;
  const _CategoryChip({required this.category, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 80,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.primaryLight : AppColors.surface,
          border: Border.all(color: selected ? AppColors.primary : AppColors.border, width: selected ? 1.5 : 1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(categoryEmoji(category), style: const TextStyle(fontSize: 24)),
            const SizedBox(height: 4),
            Text(
              categoryLabel(category),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: selected ? AppColors.primary : AppColors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

enum _FieldType { text, multiline, date, time }

class _FieldSpec {
  final String key;
  final String label;
  final _FieldType type;
  const _FieldSpec(this.key, this.label, this.type);
}
