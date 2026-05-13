import 'dart:developer' as developer;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/core/widgets/converted_price.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/planning/models/activity_suggestion_model.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/planning/services/places_service.dart';
import 'package:voyage/features/planning/services/poi_alternatives_provider.dart';
import 'package:voyage/features/poi/providers/poi_repository_provider.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';
import 'package:voyage/config/live_api_guards.dart';

Future<bool> openAlternativesSheet(
  BuildContext context,
  WidgetRef ref, {
  required TripActivity current,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _AlternativesSheet(current: current),
  );
  return result ?? false;
}

class _AlternativesSheet extends ConsumerStatefulWidget {
  final TripActivity current;
  const _AlternativesSheet({required this.current});

  @override
  ConsumerState<_AlternativesSheet> createState() => _AlternativesSheetState();
}

class _AlternativesSheetState extends ConsumerState<_AlternativesSheet> {
  bool _loading = true;
  String? _error;
  List<ActivitySuggestion> _alternatives = const [];
  Trip? _trip;
  final Map<String, Future<PlaceInfo>> _placeCache = {};
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final trip = await ref.read(
        tripByIdProvider(widget.current.tripId).future,
      );
      if (trip == null) throw Exception('Voyage introuvable.');
      final profile = await ref.read(userProfileProvider.future);
      final interests = await ref.read(userInterestsProvider.future);
      final allActivities = await ref.read(
        tripActivitiesProvider(widget.current.tripId).future,
      );

      // 1. POI-first — aucun appel réseau
      final poiRepo = ref.read(poiRepositoryProvider);
      final poiProvider = PoiAlternativesProvider(poiRepo);
      var alts = await poiProvider.suggestAlternatives(
        current: widget.current,
        trip: trip,
        allActivities: allActivities,
      );

      // 2. Fallback Gemini si aucune alternative POI
      if (alts.isEmpty) {
        try {
          final service = ref.read(aiSuggestionsServiceProvider);
          alts = await service.suggestAlternatives(
            current: widget.current,
            trip: trip,
            travelerType: trip.travelerType ?? profile?['traveler_type'] as String?,
            interests: (trip.interests != null && trip.interests!.isNotEmpty)
                ? trip.interests!
                : interests,
            allActivities: allActivities,
          );
          developer.log(
            '[alternatives] source=gemini_fallback '
            'reason=no_poi_alternatives current="${widget.current.title}"',
            name: 'planning',
          );
        } on LiveApiBlockedException catch (e) {
          developer.log(
            '[alternatives] gemini_blocked reason=${e.operation}',
            name: 'planning',
          );
          // Non bloquant : on laisse la liste vide
        } catch (e) {
          developer.log(
            '[alternatives] gemini_blocked reason=$e',
            name: 'planning',
          );
          // Non bloquant : on laisse la liste vide
        }
      }

      if (!mounted) return;
      setState(() {
        _alternatives = alts;
        _trip = trip;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<PlaceInfo> _placeInfoFor(ActivitySuggestion alt) {
    return _placeCache.putIfAbsent(alt.title, () {
      final cache = ref.read(placesCacheServiceProvider);
      return cache.findInfo(
        title: alt.title,
        destination: _trip?.destination ?? '',
      );
    });
  }

  Future<void> _apply(ActivitySuggestion alt) async {
    setState(() => _applying = true);
    try {
      final client = ref.read(supabaseProvider);
      await client
          .from('trip_activities')
          .update({
            'title': alt.title,
            'detail': alt.detail,
            'tag': alt.tag,
            'duration_minutes': alt.durationMinutes,
            'price_estimate': alt.priceEstimate,
            // reset des champs calculés : on laisse Gemini les régénérer plus tard
            'description': null,
            'latitude': null,
            'longitude': null,
          })
          .eq('id', widget.current.id);
      ref.invalidate(tripActivitiesProvider(widget.current.tripId));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erreur : $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
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
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '🔄 Alternatives IA',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Remplace "${widget.current.title}" par une autre option.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
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
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('✨', style: TextStyle(fontSize: 40)),
            SizedBox(height: 12),
            CircularProgressIndicator(strokeWidth: 2.5),
            SizedBox(height: 8),
            Text(
              'Je cherche des alternatives…',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          'Erreur : $_error',
          style: TextStyle(color: AppColors.error),
        ),
      );
    }
    if (_alternatives.isEmpty) {
      return const Center(child: Text('Aucune alternative trouvée.'));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: _alternatives.length,
      itemBuilder: (_, i) {
        final a = _alternatives[i];
        return FutureBuilder<PlaceInfo>(
          future: _placeInfoFor(a),
          builder: (_, snap) {
            final info = snap.data;
            final loading = snap.connectionState != ConnectionState.done;
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Thumbnail
                      _Thumbnail(
                        photoUrl: info?.photos.isNotEmpty == true
                            ? info!.photos.first.url
                            : null,
                        loading: loading,
                      ),
                      // Infos
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                a.title,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              if (a.detail != null && a.detail!.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  a.detail!,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textSecondary,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                              if (info?.rating != null) ...[
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.star,
                                      size: 14,
                                      color: Color(0xFFF59E0B),
                                    ),
                                    const SizedBox(width: 2),
                                    Text(
                                      info!.rating!.toStringAsFixed(1),
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.textPrimary,
                                      ),
                                    ),
                                    if (info.ratingsCount != null) ...[
                                      const SizedBox(width: 4),
                                      Text(
                                        '(${info.ratingsCount} avis)',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: AppColors.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  _pill(
                                    a.tag,
                                    AppColors.primary,
                                    AppColors.primaryLight,
                                  ),
                                  if (a.durationMinutes != null)
                                    _pill(
                                      '⏱ ${formatDuration(a.durationMinutes)}',
                                      AppColors.textSecondary,
                                      const Color(0xFFF3F4F6),
                                    ),
                                  if (info?.priceLevelLabel != null)
                                    _pill(
                                      info!.priceLevelLabel!,
                                      AppColors.textSecondary,
                                      const Color(0xFFF3F4F6),
                                    )
                                  else if (a.priceEstimate != null &&
                                      a.priceEstimate!.isNotEmpty)
                                    ConvertedPricePill(
                                      rawPrice: a.priceEstimate,
                                      color: AppColors.textSecondary,
                                      bg: const Color(0xFFF3F4F6),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _applying ? null : () => _apply(a),
                        child: _applying
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Remplacer par celle-ci'),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _pill(String label, Color color, Color bg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: color),
    ),
  );
}

class _Thumbnail extends StatelessWidget {
  final String? photoUrl;
  final bool loading;
  const _Thumbnail({this.photoUrl, this.loading = false});

  @override
  Widget build(BuildContext context) {
    const size = 90.0;
    if (photoUrl != null) {
      return SizedBox(
        width: size,
        height: size,
        child: CachedNetworkImage(
          imageUrl: photoUrl!,
          fit: BoxFit.cover,
          placeholder: (_, _) => Container(color: AppColors.primaryLight),
          errorWidget: (_, _, _) => _fallback(),
        ),
      );
    }
    if (loading) {
      return Container(
        width: size,
        height: size,
        color: AppColors.primaryLight,
        child: const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return _fallback();
  }

  Widget _fallback() => Container(
    width: 90,
    height: 90,
    color: const Color(0xFFF3F4F6),
    child: Icon(Icons.image_outlined, size: 28, color: AppColors.textSecondary),
  );
}
