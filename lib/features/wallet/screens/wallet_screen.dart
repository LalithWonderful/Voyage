import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';
import 'package:voyage/features/wallet/widgets/document_form_sheet.dart';
import 'package:voyage/features/wallet/widgets/hotel_doc_warnings.dart';
import 'package:voyage/features/wallet/widgets/transport_doc_warnings.dart';

/// Écran Wallet — affiche les documents de l'utilisateur. 2 modes :
///
/// 1. **Wallet global** (sans `filterTripId`) — route `/wallet`. Liste tous
///    les documents tous voyages confondus. Filtres en haut : type, date,
///    voyage (dropdown).
/// 2. **Vue intra-voyage** (avec `filterTripId`) — route `/trips/:id/documents`.
///    Liste uniquement les documents rattachés à ce voyage. Le filtre par
///    voyage est caché (déjà imposé par la route).
///
/// Les filtres sont en `ConsumerStatefulWidget` pour gérer le state local
/// (pas besoin de provider dédié, le scope est l'écran).
class WalletScreen extends ConsumerStatefulWidget {
  /// Si fourni, l'écran ne montre que les docs du voyage. Le filtre voyage
  /// est caché. Au "Ajouter", le tripId est pré-rempli.
  final String? filterTripId;
  const WalletScreen({super.key, this.filterTripId});

  @override
  ConsumerState<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends ConsumerState<WalletScreen> {
  /// Filtre catégorie multi-select (vide = toutes). L'user peut cocher
  /// plusieurs types pour voir Vol+Train ensemble par exemple.
  Set<String> _categoryFilter = {};

  /// Filtre date (cf. doc de _DateFilter).
  _DateFilter _dateFilter = _DateFilter.all;

  /// Filtre voyage (null = tous, '' = sans voyage rattaché, ID = ce voyage).
  /// Utilisé seulement dans le mode global (caché en intra-voyage).
  String? _tripIdFilter;

  bool get _isIntraTrip => widget.filterTripId != null;

  @override
  Widget build(BuildContext context) {
    // Source des docs : provider scopé si vue intra-voyage, sinon global.
    final docsAsync = _isIntraTrip
        ? ref.watch(tripDocumentsProvider(widget.filterTripId!))
        : ref.watch(documentsProvider);
    final tripsAsync = ref.watch(tripsProvider);
    final trips = tripsAsync.valueOrNull ?? const <Trip>[];

    // Titre AppBar : "Documents — <voyage>" en intra-voyage, sinon "Wallet".
    final intraTrip = _isIntraTrip ? trips.where((t) => t.id == widget.filterTripId).firstOrNull : null;
    final title = _isIntraTrip
        ? (intraTrip != null ? 'Documents — ${intraTrip.title}' : 'Documents du voyage')
        : 'Wallet';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.surface,
        elevation: 0,
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1), child: Container(color: AppColors.border, height: 1)),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => openDocumentFormSheet(
          context, ref,
          // En intra-voyage, on pré-rattache le doc au voyage courant.
          initialTripId: widget.filterTripId,
        ),
        backgroundColor: AppColors.primary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: docsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e', style: TextStyle(color: AppColors.error))),
        data: (allDocs) {
          // Application des filtres en local (ordre stable, pas besoin de re-fetch).
          final filtered = _applyFilters(allDocs);
          return RefreshIndicator(
            onRefresh: () async {
              if (_isIntraTrip) {
                ref.invalidate(tripDocumentsProvider(widget.filterTripId!));
                await ref.read(tripDocumentsProvider(widget.filterTripId!).future);
              } else {
                ref.invalidate(documentsProvider);
                await ref.read(documentsProvider.future);
              }
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
              children: [
                _FiltersBar(
                  categoryFilter: _categoryFilter,
                  dateFilter: _dateFilter,
                  tripIdFilter: _tripIdFilter,
                  trips: trips,
                  hideTripFilter: _isIntraTrip,
                  onChangeCategory: (c) => setState(() => _categoryFilter = c),  // Set<String>, vide = toutes
                  onChangeDate: (d) => setState(() => _dateFilter = d),
                  onChangeTripId: (id) => setState(() => _tripIdFilter = id),
                ),
                const SizedBox(height: 16),
                if (allDocs.isEmpty)
                  const _EmptyState()
                else if (filtered.isEmpty)
                  _NoMatchState(onReset: _resetFilters)
                else ...[
                  Text(
                    'MES DOCUMENTS · ${filtered.length}',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5),
                  ),
                  const SizedBox(height: 12),
                  for (final d in filtered)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: DocumentCard(
                        doc: d,
                        onTap: () => openDocumentFormSheet(context, ref, existing: d),
                      ),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  void _resetFilters() {
    setState(() {
      _categoryFilter = {};
      _dateFilter = _DateFilter.all;
      _tripIdFilter = null;
    });
  }

  /// Applique les 3 filtres en cascade. La date utilise la "date principale"
  /// du doc (check_in pour hôtel, pickup_date pour voiture, sinon `date` de
  /// la metadata). Si pas de date interprétable, le doc passe en "all" mais
  /// pas en "à venir/en cours/passé" (pour ne pas masquer ces docs).
  List<TripDocument> _applyFilters(List<TripDocument> docs) {
    final today = DateTime.now();
    final todayDay = DateTime(today.year, today.month, today.day);
    return docs.where((d) {
      // Catégorie : vide = toutes acceptées, sinon on ne garde que les
      // catégories sélectionnées.
      if (_categoryFilter.isNotEmpty && !_categoryFilter.contains(d.category)) return false;
      // Voyage (mode global uniquement, l'intra-voyage est déjà scopé)
      if (!_isIntraTrip && _tripIdFilter != null) {
        if (_tripIdFilter == '__none__') {
          if (d.tripId != null) return false;
        } else if (d.tripId != _tripIdFilter) {
          return false;
        }
      }
      // Date
      if (_dateFilter != _DateFilter.all) {
        final docDate = _extractPrimaryDate(d);
        if (docDate == null) return false;
        final docDay = DateTime(docDate.year, docDate.month, docDate.day);
        switch (_dateFilter) {
          case _DateFilter.upcoming:
            if (!docDay.isAfter(todayDay)) return false;
            break;
          case _DateFilter.ongoing:
            if (docDay != todayDay) return false;
            break;
          case _DateFilter.past:
            if (!docDay.isBefore(todayDay)) return false;
            break;
          case _DateFilter.all:
            break;
        }
      }
      return true;
    }).toList();
  }

  DateTime? _extractPrimaryDate(TripDocument d) {
    final raw = switch (d.category) {
      DocumentCategory.hotel => d.metadata['check_in'] as String?,
      DocumentCategory.carRental => d.metadata['pickup_date'] as String?,
      _ => d.metadata['date'] as String?,
    };
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }
}

/// Granularité du filtre date. Calculé contre la "date principale" du doc.
enum _DateFilter { all, upcoming, ongoing, past }

extension _DateFilterX on _DateFilter {
  String get label => switch (this) {
        _DateFilter.all => 'Toutes dates',
        _DateFilter.upcoming => 'À venir',
        _DateFilter.ongoing => "Aujourd'hui",
        _DateFilter.past => 'Passés',
      };
}

/// Barre de filtres : 1 ligne scrollable horizontal de "filter chips" type
/// Material 3. Tap sur une chip → bottom sheet avec les options.
class _FiltersBar extends StatelessWidget {
  final Set<String> categoryFilter;
  final _DateFilter dateFilter;
  final String? tripIdFilter;
  final List<Trip> trips;
  final bool hideTripFilter;
  final ValueChanged<Set<String>> onChangeCategory;
  final ValueChanged<_DateFilter> onChangeDate;
  final ValueChanged<String?> onChangeTripId;

  const _FiltersBar({
    required this.categoryFilter,
    required this.dateFilter,
    required this.tripIdFilter,
    required this.trips,
    required this.hideTripFilter,
    required this.onChangeCategory,
    required this.onChangeDate,
    required this.onChangeTripId,
  });

  String get _categoryLabel {
    if (categoryFilter.isEmpty) return 'Toutes catégories';
    if (categoryFilter.length == 1) return categoryLabel(categoryFilter.first);
    return '${categoryFilter.length} catégories';
  }

  String _tripLabel() {
    if (tripIdFilter == null) return 'Tous voyages';
    if (tripIdFilter == '__none__') return 'Sans voyage';
    final t = trips.where((t) => t.id == tripIdFilter).firstOrNull;
    return t?.title ?? 'Voyage';
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _FilterChip(
            label: _categoryLabel,
            active: categoryFilter.isNotEmpty,
            onTap: () => _openCategoryPicker(context),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: dateFilter.label,
            active: dateFilter != _DateFilter.all,
            onTap: () => _openDatePicker(context),
          ),
          if (!hideTripFilter) ...[
            const SizedBox(width: 8),
            _FilterChip(
              label: _tripLabel(),
              active: tripIdFilter != null,
              onTap: () => _openTripPicker(context),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openCategoryPicker(BuildContext context) async {
    // Sheet stateful : l'user coche/décoche plusieurs catégories puis valide.
    // `isScrollControlled: true` pour que la sheet puisse dépasser 50% de
    // l'écran (sinon le contenu déborde sur petits écrans → ruban jaune
    // d'overflow Flutter).
    final choice = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CategoryPickerSheet(current: categoryFilter),
    );
    if (choice == null) return;
    onChangeCategory(choice);
  }

  Future<void> _openDatePicker(BuildContext context) async {
    final choice = await showModalBottomSheet<_DateFilter?>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DatePickerSheet(current: dateFilter),
    );
    if (choice == null) return;
    onChangeDate(choice);
  }

  Future<void> _openTripPicker(BuildContext context) async {
    final choice = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TripPickerSheet(current: tripIdFilter, trips: trips),
    );
    if (choice == null) return;
    onChangeTripId(choice == '__all__' ? null : choice);
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? AppColors.primaryLight : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? AppColors.primary : AppColors.border,
            width: active ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                color: active ? AppColors.primary : AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more, size: 16, color: active ? AppColors.primary : AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// Sheet multi-select pour les catégories. State local : l'user coche/décoche
/// plusieurs catégories, et valide via le bouton "Appliquer" en bas — qui
/// retourne le `Set<String>` final au caller. Permet de filtrer Vol+Train
/// ensemble, par exemple.
class _CategoryPickerSheet extends StatefulWidget {
  final Set<String> current;
  const _CategoryPickerSheet({required this.current});

  @override
  State<_CategoryPickerSheet> createState() => _CategoryPickerSheetState();
}

class _CategoryPickerSheetState extends State<_CategoryPickerSheet> {
  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = {...widget.current};
  }

  @override
  Widget build(BuildContext context) {
    const categories = [
      DocumentCategory.hotel,
      DocumentCategory.flight,
      DocumentCategory.train,
      DocumentCategory.carRental,
      DocumentCategory.ticket,
      DocumentCategory.other,
    ];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          // "Toutes" = vider la sélection. Distinct des catégories individuelles
          // (un tap ici clear, pas de coche cumulative).
          ListTile(
            leading: const Text('🗂️', style: TextStyle(fontSize: 20)),
            title: const Text('Toutes catégories'),
            trailing: _selected.isEmpty ? Icon(Icons.check, color: AppColors.primary) : null,
            onTap: () => setState(() => _selected = {}),
          ),
          const Divider(height: 1),
          for (final c in categories)
            CheckboxListTile(
              value: _selected.contains(c),
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _selected.add(c);
                  } else {
                    _selected.remove(c);
                  }
                });
              },
              secondary: Text(categoryEmoji(c), style: const TextStyle(fontSize: 20)),
              title: Text(categoryLabel(c)),
              controlAffinity: ListTileControlAffinity.trailing,
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Annuler'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, _selected),
                    child: Text(_selected.isEmpty ? 'Tout afficher' : 'Appliquer (${_selected.length})'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DatePickerSheet extends StatelessWidget {
  final _DateFilter current;
  const _DatePickerSheet({required this.current});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          for (final f in _DateFilter.values)
            ListTile(
              leading: Icon(switch (f) {
                _DateFilter.all => Icons.calendar_today_outlined,
                _DateFilter.upcoming => Icons.schedule,
                _DateFilter.ongoing => Icons.today,
                _DateFilter.past => Icons.history,
              }, color: AppColors.textSecondary),
              title: Text(f.label),
              trailing: current == f ? Icon(Icons.check, color: AppColors.primary) : null,
              onTap: () => Navigator.pop(context, f),
            ),
        ],
      ),
    );
  }
}

class _TripPickerSheet extends StatelessWidget {
  final String? current;
  final List<Trip> trips;
  const _TripPickerSheet({required this.current, required this.trips});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: ListView(
          shrinkWrap: true,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.public),
              title: const Text('Tous voyages'),
              trailing: current == null ? Icon(Icons.check, color: AppColors.primary) : null,
              onTap: () => Navigator.pop(context, '__all__'),
            ),
            ListTile(
              leading: const Icon(Icons.link_off),
              title: const Text('Sans voyage rattaché'),
              trailing: current == '__none__' ? Icon(Icons.check, color: AppColors.primary) : null,
              onTap: () => Navigator.pop(context, '__none__'),
            ),
            if (trips.isNotEmpty) const Divider(height: 1),
            for (final t in trips)
              ListTile(
                leading: Text(t.coverEmoji, style: const TextStyle(fontSize: 20)),
                title: Text(t.title),
                subtitle: Text(t.destination, style: const TextStyle(fontSize: 12)),
                trailing: current == t.id ? Icon(Icons.check, color: AppColors.primary) : null,
                onTap: () => Navigator.pop(context, t.id),
              ),
          ],
        ),
      ),
    );
  }
}

class _NoMatchState extends StatelessWidget {
  final VoidCallback onReset;
  const _NoMatchState({required this.onReset});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        children: [
          Text('🔎', style: const TextStyle(fontSize: 48)),
          const SizedBox(height: 12),
          Text('Aucun document ne correspond à tes filtres.', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: AppColors.textPrimary)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onReset,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Réinitialiser les filtres'),
          ),
        ],
      ),
    );
  }
}

class DocumentCard extends ConsumerWidget {
  final TripDocument doc;
  final VoidCallback onTap;
  const DocumentCard({super.key, required this.doc, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(10)),
              child: Center(child: Text(categoryEmoji(doc.category), style: const TextStyle(fontSize: 20))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(4)),
                        child: Text(categoryLabel(doc.category), style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.primary)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(doc.name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                  if (doc.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(doc.subtitle, style: TextStyle(fontSize: 11, color: AppColors.textSecondary), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                  if (doc.reservationNumber != null) ...[
                    const SizedBox(height: 2),
                    Text('N° ${doc.reservationNumber}', style: TextStyle(fontSize: 10, color: AppColors.textSecondary, fontStyle: FontStyle.italic)),
                  ],
                  HotelDocWarnings(doc: doc, fontSize: 10),
                  // Trip nécessaire pour valider la date du vol/train contre la
                  // plage du voyage. `valueOrNull` : si le trip est encore en
                  // train de charger ou sans tripId, on rend juste les
                  // warnings doc-only (date manquante, geocoding failed).
                  TransportDocWarnings(
                    doc: doc,
                    trip: doc.tripId != null
                        ? ref.watch(tripByIdProvider(doc.tripId!)).valueOrNull
                        : null,
                    fontSize: 10,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: AppColors.textSecondary, size: 20),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        children: [
          Text('📁', style: TextStyle(fontSize: 56)),
          SizedBox(height: 16),
          Text('Aucun document pour l\'instant', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          SizedBox(height: 6),
          Text('Ajoute tes réservations d\'hôtel, billets de vol, tickets...\nColle un email de confirmation, je fais le reste.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.5)),
        ],
      ),
    );
  }
}
