import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';
import 'package:voyage/features/trips/widgets/trip_edit_sheet.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';
import 'package:voyage/features/wallet/screens/wallet_screen.dart';
import 'package:voyage/features/wallet/widgets/document_form_sheet.dart';

class TripDetailScreen extends ConsumerWidget {
  final String tripId;
  const TripDetailScreen({super.key, required this.tripId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tripAsync = ref.watch(tripByIdProvider(tripId));

    return Scaffold(
      backgroundColor: AppColors.background,
      body: tripAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e', style: TextStyle(color: AppColors.error))),
        data: (trip) {
          if (trip == null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Voyage introuvable', style: TextStyle(fontSize: 16, color: AppColors.textSecondary)),
                  const SizedBox(height: 16),
                  TextButton(onPressed: () => context.go('/trips'), child: const Text('Retour aux voyages')),
                ],
              ),
            );
          }
          return _TripDetail(trip: trip);
        },
      ),
    );
  }
}

class _TripDetail extends ConsumerWidget {
  final Trip trip;
  const _TripDetail({required this.trip});

  static const _months = [
    'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
    'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
  ];

  String _formatRange() {
    final s = trip.startDate;
    final e = trip.endDate;
    final sameMonth = s.month == e.month && s.year == e.year;
    if (sameMonth) {
      return '${s.day} – ${e.day} ${_months[e.month - 1]} ${e.year} • ${trip.durationDays} jours';
    }
    return '${s.day} ${_months[s.month - 1]} – ${e.day} ${_months[e.month - 1]} ${e.year} • ${trip.durationDays} jours';
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final docsAsync = ref.watch(tripDocumentsProvider(trip.id));
    final docs = docsAsync.valueOrNull ?? const <TripDocument>[];
    final hotelsAsync = ref.watch(tripHotelsProvider(trip.id));
    final hotels = hotelsAsync.valueOrNull ?? const <TripDocument>[];
    final others = docs.where((d) => d.category != DocumentCategory.hotel).toList();

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          expandedHeight: 220,
          pinned: true,
          backgroundColor: AppColors.primary,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => context.go('/trips'),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.edit_outlined, color: Colors.white),
              tooltip: 'Modifier',
              onPressed: () => openTripEditSheet(context, ref, trip: trip),
            ),
          ],
          flexibleSpace: FlexibleSpaceBar(
            title: Text(trip.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            background: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.primary, AppColors.primaryDark],
                ),
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 48),
                  child: Text(trip.coverEmoji, style: const TextStyle(fontSize: 72)),
                ),
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.all(24),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _InfoRow(icon: Icons.location_on, text: trip.destination),
              const SizedBox(height: 12),
              _InfoRow(icon: Icons.calendar_today, text: _formatRange()),
              if (trip.travelers.isNotEmpty) ...[
                const SizedBox(height: 12),
                _InfoRow(
                  icon: Icons.group,
                  text: '${trip.travelers.length} voyageur${trip.travelers.length > 1 ? 's' : ''} · ${trip.travelers.map((t) => '${t.name} (${t.age})').join(', ')}',
                ),
              ],
              const SizedBox(height: 24),

              // Bloc Hébergement(s) — carrousel swipeable (une carte visible à la fois)
              // pour que le bouton Planning reste proche du haut même sur un road trip 15 jours.
              if (hotels.isEmpty)
                OutlinedButton.icon(
                  onPressed: () => openDocumentFormSheet(
                    context, ref,
                    initialTripId: trip.id,
                    initialCategory: DocumentCategory.hotel,
                  ),
                  icon: const Icon(Icons.hotel_outlined),
                  label: const Text('Ajouter un hébergement'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 52),
                    foregroundColor: AppColors.primary,
                    side: BorderSide(color: AppColors.primary),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                )
              else ...[
                _HotelsCarousel(hotels: hotels, fmtDate: _fmtDate),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => openDocumentFormSheet(
                    context, ref,
                    initialTripId: trip.id,
                    initialCategory: DocumentCategory.hotel,
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Ajouter un autre hébergement'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 44),
                    foregroundColor: AppColors.primary,
                    side: BorderSide(color: AppColors.border),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],

              // Autres documents du voyage
              if (others.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('AUTRES DOCUMENTS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                const SizedBox(height: 10),
                for (final d in others)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: DocumentCard(
                      doc: d,
                      onTap: () => openDocumentFormSheet(context, ref, existing: d),
                    ),
                  ),
              ],

              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: () => openDocumentFormSheet(context, ref, initialTripId: trip.id),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Ajouter un document'),
                style: TextButton.styleFrom(foregroundColor: AppColors.primary),
              ),
              const SizedBox(height: 16),

              _ActionButton(icon: Icons.calendar_month, label: 'Planning', onTap: () => context.go('/trips/${trip.id}/planning')),
              const SizedBox(height: 12),
              _ActionButton(icon: Icons.wallet, label: 'Documents', onTap: () => context.go('/wallet')),
              const SizedBox(height: 12),
              _ActionButton(icon: Icons.map, label: 'Carte', onTap: () => context.go('/trips/${trip.id}/map')),
            ]),
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.primary, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text, style: TextStyle(color: AppColors.textSecondary, fontSize: 15)),
        ),
      ],
    );
  }
}

/// Carrousel horizontal des hébergements : une seule carte visible, swipe pour changer.
/// Démarre sur l'hôtel qui couvre ce soir (ou le premier à venir).
class _HotelsCarousel extends StatefulWidget {
  final List<TripDocument> hotels;
  final String Function(DateTime) fmtDate;
  const _HotelsCarousel({required this.hotels, required this.fmtDate});

  @override
  State<_HotelsCarousel> createState() => _HotelsCarouselState();
}

class _HotelsCarouselState extends State<_HotelsCarousel> {
  late final PageController _controller;
  late int _currentPage;

  static const double _cardHeight = 124;

  int _initialIndex() {
    final today = DateTime.now();
    final d = DateTime(today.year, today.month, today.day);
    // 1. Hôtel couvrant aujourd'hui
    for (var i = 0; i < widget.hotels.length; i++) {
      final h = widget.hotels[i];
      final ci = h.metadata['check_in'] is String ? DateTime.tryParse(h.metadata['check_in'] as String) : null;
      final co = h.metadata['check_out'] is String ? DateTime.tryParse(h.metadata['check_out'] as String) : null;
      if (ci == null || co == null) continue;
      final start = DateTime(ci.year, ci.month, ci.day);
      final end = DateTime(co.year, co.month, co.day);
      if (!d.isBefore(start) && !d.isAfter(end)) return i;
    }
    // 2. Premier hôtel à venir (check_in ≥ aujourd'hui)
    for (var i = 0; i < widget.hotels.length; i++) {
      final h = widget.hotels[i];
      final ci = h.metadata['check_in'] is String ? DateTime.tryParse(h.metadata['check_in'] as String) : null;
      if (ci == null) continue;
      final start = DateTime(ci.year, ci.month, ci.day);
      if (!start.isBefore(d)) return i;
    }
    // 3. Fallback : premier
    return 0;
  }

  @override
  void initState() {
    super.initState();
    _currentPage = _initialIndex();
    _controller = PageController(initialPage: _currentPage);
  }

  @override
  void didUpdateWidget(covariant _HotelsCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si un hôtel est ajouté/supprimé et que l'index courant sort des bornes, on recale.
    if (_currentPage >= widget.hotels.length) {
      _currentPage = widget.hotels.length - 1;
      if (_controller.hasClients) {
        _controller.jumpToPage(_currentPage);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hotels = widget.hotels;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hotels.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'HÉBERGEMENT ${_currentPage + 1}/${hotels.length}',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5),
                ),
                Text(
                  'Glisser ›',
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
        SizedBox(
          height: _cardHeight,
          child: PageView.builder(
            controller: _controller,
            itemCount: hotels.length,
            onPageChanged: (i) => setState(() => _currentPage = i),
            itemBuilder: (_, i) => _HotelCard(hotel: hotels[i], fmtDate: widget.fmtDate),
          ),
        ),
        if (hotels.length > 1) ...[
          const SizedBox(height: 8),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(hotels.length, (i) {
                final active = i == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: active ? AppColors.primary : AppColors.border,
                    borderRadius: BorderRadius.circular(3),
                  ),
                );
              }),
            ),
          ),
        ],
      ],
    );
  }
}

class _HotelCard extends ConsumerWidget {
  final TripDocument hotel;
  final String Function(DateTime) fmtDate;
  const _HotelCard({required this.hotel, required this.fmtDate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: () => openDocumentFormSheet(context, ref, existing: hotel),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('🏨', style: TextStyle(fontSize: 28)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(hotel.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  if (hotel.metadata['address'] != null) ...[
                    const SizedBox(height: 2),
                    Text(hotel.metadata['address'] as String, style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  ],
                  if (hotel.metadata['check_in'] != null || hotel.metadata['check_out'] != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (hotel.metadata['check_in'] != null) 'Check-in ${fmtDate(DateTime.parse(hotel.metadata['check_in'] as String))}',
                        if (hotel.metadata['check_out'] != null) 'Check-out ${fmtDate(DateTime.parse(hotel.metadata['check_out'] as String))}',
                      ].join(' · '),
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ],
                  if (hotel.reservationNumber != null) ...[
                    const SizedBox(height: 4),
                    Text('N° ${hotel.reservationNumber}', style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontStyle: FontStyle.italic)),
                  ],
                ],
              ),
            ),
            Icon(Icons.edit, size: 16, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppColors.primary),
            const SizedBox(width: 16),
            Text(label, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const Spacer(),
            Icon(Icons.arrow_forward_ios, size: 16, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}
