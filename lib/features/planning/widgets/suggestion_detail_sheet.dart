import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/core/widgets/converted_price.dart';
import 'package:voyage/features/planning/models/activity_suggestion_model.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/planning/services/places_service.dart';

Future<void> openSuggestionDetailSheet(
  BuildContext context,
  WidgetRef ref, {
  required ActivitySuggestion suggestion,
  required String destination,
}) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _SuggestionDetailSheet(
      suggestion: suggestion,
      destination: destination,
    ),
  );
}

class _SuggestionDetailSheet extends ConsumerStatefulWidget {
  final ActivitySuggestion suggestion;
  final String destination;
  const _SuggestionDetailSheet({
    required this.suggestion,
    required this.destination,
  });

  @override
  ConsumerState<_SuggestionDetailSheet> createState() =>
      _SuggestionDetailSheetState();
}

class _SuggestionDetailSheetState
    extends ConsumerState<_SuggestionDetailSheet> {
  late Future<PlaceInfo> _placeInfoFuture;
  late Future<String> _descriptionFuture;

  static const _weekdays = [
    'Lundi',
    'Mardi',
    'Mercredi',
    'Jeudi',
    'Vendredi',
    'Samedi',
    'Dimanche',
  ];
  static const _months = [
    'janvier',
    'février',
    'mars',
    'avril',
    'mai',
    'juin',
    'juillet',
    'août',
    'septembre',
    'octobre',
    'novembre',
    'décembre',
  ];

  @override
  void initState() {
    super.initState();
    final cache = ref.read(placesCacheServiceProvider);
    _placeInfoFuture = cache.findInfo(
      title: widget.suggestion.title,
      destination: widget.destination,
    );

    final ai = ref.read(aiSuggestionsServiceProvider);
    _descriptionFuture = ai.describeActivity(
      title: widget.suggestion.title,
      detail: widget.suggestion.detail,
      destination: widget.destination,
      tag: widget.suggestion.tag,
    );
  }

  String _formattedDate() {
    final d = widget.suggestion.dayDate;
    return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]} ${d.year}';
  }

  Future<void> _openInMaps() async {
    // Priorité au place_id résolu par Places : ouvre directement la fiche
    // au lieu d'une liste de résultats pour un titre verbeux.
    String? placeId;
    try {
      final info = await _placeInfoFuture;
      placeId = info.placeId;
    } catch (_) {}
    final label = Uri.encodeComponent(
      '${widget.suggestion.title} ${widget.destination}',
    );
    final uri = (placeId != null && placeId.isNotEmpty)
        ? Uri.parse(
            'https://www.google.com/maps/search/?api=1&query=$label&query_place_id=$placeId',
          )
        : Uri.parse('https://www.google.com/maps/search/?api=1&query=$label');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.suggestion;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.88,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      _PhotosArea(future: _placeInfoFuture),
                      Positioned(
                        top: 10,
                        left: 10,
                        child: Material(
                          color: Colors.black54,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => Navigator.of(context).pop(),
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(
                                Icons.close,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primaryLight,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            s.tag,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          s.title,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        FutureBuilder<PlaceInfo>(
                          future: _placeInfoFuture,
                          builder: (_, snap) {
                            final rating = snap.data?.rating;
                            if (rating == null) return const SizedBox.shrink();
                            return Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: _StarsRow(
                                rating: rating,
                                count: snap.data?.ratingsCount,
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 14),

                        FutureBuilder<String>(
                          future: _descriptionFuture,
                          builder: (_, snap) {
                            if (snap.connectionState != ConnectionState.done) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                    SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        'Rédaction de la description…',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: AppColors.textSecondary,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }
                            if (snap.hasError ||
                                snap.data == null ||
                                snap.data!.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryLight.withValues(
                                    alpha: 0.4,
                                  ),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  snap.data!,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: AppColors.textPrimary,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),

                        _InfoTile(
                          icon: Icons.calendar_today,
                          text: _formattedDate(),
                        ),
                        _InfoTile(
                          icon: Icons.access_time,
                          text:
                              '${s.startTime}${s.durationMinutes != null ? ' · ${formatDuration(s.durationMinutes)}' : ''}',
                        ),
                        if (s.priceEstimate != null &&
                            s.priceEstimate!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.euro_symbol,
                                  size: 18,
                                  color: AppColors.primary,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ConvertedPriceText(
                                    rawPrice: s.priceEstimate,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: AppColors.textPrimary,
                                      height: 1.4,
                                    ),
                                    maxLines: 2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (s.detail != null && s.detail!.isNotEmpty)
                          _InfoTile(
                            icon: Icons.place_outlined,
                            text: s.detail!,
                          ),

                        const SizedBox(height: 20),
                        OutlinedButton.icon(
                          onPressed: _openInMaps,
                          icon: const Icon(Icons.place, size: 18),
                          label: const Text('Voir sur Google Maps'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 48),
                            foregroundColor: AppColors.primary,
                            side: BorderSide(color: AppColors.primary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhotosArea extends StatelessWidget {
  final Future<PlaceInfo> future;
  const _PhotosArea({required this.future});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 200,
      child: FutureBuilder<PlaceInfo>(
        future: future,
        builder: (_, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Container(
              color: AppColors.primaryLight,
              child: const Center(child: CircularProgressIndicator()),
            );
          }
          final photos = snap.data?.photos ?? const <PlacePhoto>[];
          if (photos.isEmpty) return _empty('Pas de photo trouvée');
          return PageView.builder(
            itemCount: photos.length,
            itemBuilder: (_, i) => CachedNetworkImage(
              imageUrl: photos[i].url,
              fit: BoxFit.cover,
              width: double.infinity,
              placeholder: (_, _) => Container(
                color: AppColors.primaryLight,
                child: const Center(child: CircularProgressIndicator()),
              ),
              errorWidget: (_, _, _) => _empty('Photo indisponible'),
            ),
          );
        },
      ),
    );
  }

  Widget _empty(String label) => Container(
    color: const Color(0xFFF3F4F6),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.image_outlined, size: 40, color: AppColors.textSecondary),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ],
    ),
  );
}

class _StarsRow extends StatelessWidget {
  final double rating;
  final int? count;
  const _StarsRow({required this.rating, this.count});

  @override
  Widget build(BuildContext context) {
    final full = rating.floor();
    final half = (rating - full) >= 0.25 && (rating - full) < 0.75;
    final filledCount = full + (rating - full >= 0.75 ? 1 : 0);
    return Row(
      children: [
        for (var i = 0; i < 5; i++)
          Icon(
            i < filledCount
                ? Icons.star
                : (i == full && half ? Icons.star_half : Icons.star_border),
            size: 16,
            color: const Color(0xFFF59E0B),
          ),
        const SizedBox(width: 6),
        Text(
          rating.toStringAsFixed(1),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 4),
          Text(
            '($count avis)',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
        ],
      ],
    );
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoTile({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.textPrimary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
