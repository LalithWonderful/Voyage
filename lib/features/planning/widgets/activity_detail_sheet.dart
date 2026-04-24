import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/core/widgets/converted_price.dart';
import 'package:voyage/features/planning/models/activity_suggestion_model.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/planning/services/places_service.dart';
import 'package:voyage/features/planning/widgets/activity_edit_sheet.dart';
import 'package:voyage/features/planning/widgets/alternatives_sheet.dart';

Future<void> openActivityDetailSheet(
  BuildContext context,
  WidgetRef ref, {
  required TripActivity activity,
}) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _ActivityDetailSheet(activity: activity),
  );
}

class _ActivityDetailSheet extends ConsumerWidget {
  final TripActivity activity;
  const _ActivityDetailSheet({required this.activity});

  static const _weekdays = ['Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi', 'Dimanche'];
  static const _months = [
    'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
    'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
  ];

  String _formattedDate() {
    final d = activity.dayDate;
    return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]} ${d.year}';
  }

  Future<void> _unlock(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Déverrouiller cette activité ?'),
        content: const Text(
          'Cette activité est dans le passé. La déverrouiller te permettra de la modifier ou la supprimer. '
          'Elle se reverrouillera automatiquement à la prochaine ouverture de l\'app.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: const Text('Annuler')),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Déverrouiller'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(unlockedPastActivitiesProvider.notifier).update((set) => {...set, activity.id});
    }
  }

  Future<void> _openInMaps(BuildContext context, WidgetRef ref) async {
    // Priorité : place_id (pin exact) > coordonnées (pin sur lat/lng) > texte fuzzy.
    // Le texte fuzzy seul donne une liste de résultats quand le titre est verbeux
    // (ex. "Dîner au restaurant O P'tit Bonheur" → page de résultats au lieu de la fiche).
    final placeId = ref.read(activityPlaceInfoProvider(activity)).valueOrNull?.placeId;
    final isHebergement = activity.tag == 'Hébergement';
    final String uri;
    if (placeId != null && placeId.isNotEmpty) {
      final label = Uri.encodeComponent(activity.detail?.isNotEmpty == true ? activity.detail! : activity.title);
      uri = 'https://www.google.com/maps/search/?api=1&query=$label&query_place_id=$placeId';
    } else if (activity.hasCoordinates) {
      uri = 'https://www.google.com/maps/search/?api=1&query=${activity.latitude},${activity.longitude}';
    } else if (isHebergement && activity.detail != null && activity.detail!.isNotEmpty) {
      // Pour un hébergement, utiliser UNIQUEMENT l'adresse. Le titre contient souvent
      // l'emoji 🏨 + préfixe "Arrivée · " ou "Départ · " qui brouille la recherche Maps
      // et peut faire freezer l'app Google Maps.
      final q = Uri.encodeComponent(activity.detail!);
      uri = 'https://www.google.com/maps/search/?api=1&query=$q';
    } else {
      final q = Uri.encodeComponent('${activity.title} ${activity.detail ?? ''}'.trim());
      uri = 'https://www.google.com/maps/search/?api=1&query=$q';
    }
    final parsed = Uri.parse(uri);
    if (await canLaunchUrl(parsed)) {
      await launchUrl(parsed, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placeInfoAsync = ref.watch(activityPlaceInfoProvider(activity));
    final photosAsync = placeInfoAsync.whenData((info) => info.photos);
    final descriptionAsync = ref.watch(activityDescriptionProvider(activity));
    final locked = isActivityLocked(activity, ref.watch(unlockedPastActivitiesProvider));

    // Rating : priorité au live fetch (Places), fallback sur la valeur persistée en DB.
    // Exception : pour les hébergements, on ignore AUSSI le cache DB — les notes stockées
    // sont issues d'un faux match Places (ex: "Maison LOU" → resto "Loulou"). Forcer null
    // masque la note même si elle avait été persistée avant le fix.
    final isHebergement = activity.tag == 'Hébergement';
    final liveRating = isHebergement ? null : (placeInfoAsync.valueOrNull?.rating ?? activity.rating);
    final liveRatingsCount = isHebergement ? null : (placeInfoAsync.valueOrNull?.ratingsCount ?? activity.ratingsCount);

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.88,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Section photos (hero) + bouton fermer superposé
                  Stack(
                    children: [
                      _PhotosSection(photosAsync: photosAsync),
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
                              child: Icon(Icons.close, color: Colors.white, size: 20),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),

                  // Contenu principal
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(4)),
                              child: Text(activity.tag, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.primary)),
                            ),
                            const Spacer(),
                            if (locked)
                              IconButton(
                                onPressed: () => _unlock(context, ref),
                                icon: const Icon(Icons.lock_outline),
                                tooltip: 'Déverrouiller pour modifier',
                                color: AppColors.textSecondary,
                              )
                            else
                              IconButton(
                                onPressed: () async {
                                  Navigator.of(context).pop();
                                  await openActivityEditSheet(context, ref, activity: activity);
                                },
                                icon: const Icon(Icons.edit_outlined),
                                tooltip: 'Modifier',
                                color: AppColors.primary,
                              ),
                          ],
                        ),
                        if (locked) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF3F4F6),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.lock_outline, size: 16, color: AppColors.textSecondary),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Activité passée verrouillée. Déverrouille-la pour la modifier ou la supprimer.',
                                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.3),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 6),
                        Text(activity.title, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                        if (liveRating != null) ...[
                          const SizedBox(height: 6),
                          _StarsRow(rating: liveRating, count: liveRatingsCount),
                        ],
                        _OpeningStatusRow(activity: activity),
                        const SizedBox(height: 14),

                        // Description (générée par Gemini, cachée en DB)
                        _DescriptionSection(descriptionAsync: descriptionAsync),

                        // Infos clés
                        _InfoTile(icon: Icons.calendar_today, text: _formattedDate()),
                        _InfoTile(icon: Icons.access_time, text: '${activity.startTime}${activity.durationMinutes != null ? ' · ${formatDuration(activity.durationMinutes)}' : ''}'),
                        if (activity.priceEstimate != null && activity.priceEstimate!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.euro_symbol, size: 18, color: AppColors.primary),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ConvertedPriceText(
                                    rawPrice: activity.priceEstimate,
                                    style: TextStyle(fontSize: 14, color: AppColors.textPrimary, height: 1.4),
                                    maxLines: 2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        // Adresse formatée Google Places (quand un lieu précis est matché).
                        // Priorité sur activity.detail qui est souvent une description Gemini
                        // vague ("Centre de bien-être local...") plutôt qu'une vraie adresse.
                        if (!isHebergement && placeInfoAsync.valueOrNull?.address != null &&
                            placeInfoAsync.valueOrNull!.address!.isNotEmpty)
                          _InfoTile(icon: Icons.place_outlined, text: placeInfoAsync.value!.address!),
                        // Description/détail Gemini (sous forme de note d'ambiance)
                        if (activity.detail != null && activity.detail!.isNotEmpty)
                          _InfoTile(icon: Icons.info_outline, text: activity.detail!),

                        const SizedBox(height: 20),

                        // Avis Google
                        _ReviewsSection(activity: activity),

                        // Réserver (placeholder, conditionnel selon catégorie)
                        _BookingSection(activity: activity),

                        // Actions — on ne montre "Voir sur Maps" / "Y aller" que si on a une
                        // cible exploitable (coords, placeId, ou adresse Places). Un `detail`
                        // purement descriptif ("Un bon petit déjeuner") fait planter Maps.
                        Builder(builder: (_) {
                          final placeId = placeInfoAsync.valueOrNull?.placeId;
                          final placesAddress = placeInfoAsync.valueOrNull?.address;
                          final hasMapsTarget = activity.hasCoordinates ||
                              (placeId != null && placeId.isNotEmpty) ||
                              (placesAddress != null && placesAddress.trim().isNotEmpty) ||
                              (isHebergement && activity.detail != null && activity.detail!.trim().isNotEmpty);
                          if (!hasMapsTarget) return const SizedBox.shrink();
                          return Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () => _openInMaps(context, ref),
                                  icon: const Icon(Icons.place, size: 18),
                                  label: const Text('Voir sur Maps'),
                                  style: OutlinedButton.styleFrom(
                                    minimumSize: const Size(0, 48),
                                    foregroundColor: AppColors.primary,
                                    side: BorderSide(color: AppColors.primary),
                                  ),
                                ),
                              ),
                              if (activity.hasCoordinates) ...[
                                const SizedBox(width: 10),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () async {
                                      final lat = activity.latitude!;
                                      final lng = activity.longitude!;
                                      final uri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
                                      if (await canLaunchUrl(uri)) {
                                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                                      }
                                    },
                                    icon: const Icon(Icons.navigation, size: 18),
                                    label: const Text('Y aller'),
                                    style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
                                  ),
                                ),
                              ],
                            ],
                          );
                        }),
                        // Les alternatives sont du "forward-looking" : on les cache dès que
                        // l'activité a commencé (jour passé OU aujourd'hui avec startTime
                        // déjà dépassée). L'édition reste possible via le bouton Modifier
                        // pour corriger/annoter ce qui s'est vraiment passé.
                        if (!isActivityElapsed(activity)) ...[
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: () async {
                              final changed = await openAlternativesSheet(context, ref, current: activity);
                              if (changed && context.mounted) Navigator.of(context).pop();
                            },
                            icon: const Icon(Icons.autorenew, size: 18),
                            label: const Text('Voir des alternatives'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(double.infinity, 48),
                              foregroundColor: AppColors.accent,
                              side: BorderSide(color: AppColors.accent),
                            ),
                          ),
                        ],
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

class _PhotosSection extends StatefulWidget {
  final AsyncValue photosAsync;
  const _PhotosSection({required this.photosAsync});

  @override
  State<_PhotosSection> createState() => _PhotosSectionState();
}

class _PhotosSectionState extends State<_PhotosSection> {
  int _currentPage = 0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 200,
      child: widget.photosAsync.when(
        loading: () => Container(
          color: AppColors.primaryLight,
          child: const Center(child: CircularProgressIndicator()),
        ),
        error: (_, __) => _emptyPlaceholder('Pas de photo disponible'),
        data: (photos) {
          if (photos is! List || photos.isEmpty) {
            return _emptyPlaceholder('Pas de photo trouvée');
          }
          return Stack(
            children: [
              PageView.builder(
                itemCount: photos.length,
                onPageChanged: (i) => setState(() => _currentPage = i),
                itemBuilder: (_, i) {
                  final photo = photos[i];
                  return CachedNetworkImage(
                    imageUrl: photo.url as String,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    placeholder: (_, __) => Container(
                      color: AppColors.primaryLight,
                      child: const Center(child: CircularProgressIndicator()),
                    ),
                    errorWidget: (_, __, ___) => _emptyPlaceholder('Photo indisponible'),
                  );
                },
              ),
              if (photos.length > 1)
                Positioned(
                  bottom: 10,
                  left: 0,
                  right: 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < photos.length; i++)
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: _currentPage == i ? 16 : 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: _currentPage == i ? Colors.white : Colors.white.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _emptyPlaceholder(String label) {
    return Container(
      color: const Color(0xFFF3F4F6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.image_outlined, size: 40, color: AppColors.textSecondary),
          const SizedBox(height: 8),
          Text(label, style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
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
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
        ),
        if (count != null) ...[
          const SizedBox(width: 4),
          Text('($count avis)', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
        ],
      ],
    );
  }
}

class _DescriptionSection extends StatelessWidget {
  final AsyncValue<String> descriptionAsync;
  const _DescriptionSection({required this.descriptionAsync});

  @override
  Widget build(BuildContext context) {
    return descriptionAsync.when(
      loading: () => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          children: [
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Rédaction de la description…',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary, fontStyle: FontStyle.italic),
              ),
            ),
          ],
        ),
      ),
      error: (_, __) => const SizedBox.shrink(),
      data: (description) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.primaryLight.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            description,
            style: TextStyle(fontSize: 13, color: AppColors.textPrimary, height: 1.5),
          ),
        ),
      ),
    );
  }
}

class _OpeningStatusRow extends ConsumerWidget {
  final TripActivity activity;
  const _OpeningStatusRow({required this.activity});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hoursAsync = ref.watch(activityOpeningHoursProvider(activity));
    return hoursAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (hours) {
        if (hours == null || hours.weekdayText.isEmpty) return const SizedBox.shrink();
        final now = DateTime.now();
        final isOpen = hours.isOpenAt(now);
        final todayText = hours.todayText(now);
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isOpen ? const Color(0xFFD1FAE5) : const Color(0xFFFEE2E2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  isOpen ? '● Ouvert' : '● Fermé',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: isOpen ? const Color(0xFF065F46) : const Color(0xFF991B1B),
                  ),
                ),
              ),
              if (todayText != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    todayText,
                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _BookingSection extends StatelessWidget {
  final TripActivity activity;
  const _BookingSection({required this.activity});

  // Catégories pour lesquelles une réservation via partenaire a du sens.
  static const _bookableTags = {'Visite', 'Culture', 'Nightlife', 'Wellness', 'Sport', 'Nature'};

  @override
  Widget build(BuildContext context) {
    if (!_bookableTags.contains(activity.tag)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.accentLight,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Text('🎫', style: TextStyle(fontSize: 22)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Réserver', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text('La réservation via partenaires (GetYourGuide, Viator) arrive bientôt.', style: TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReviewsSection extends ConsumerWidget {
  final TripActivity activity;
  const _ReviewsSection({required this.activity});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reviewsAsync = ref.watch(activityReviewsProvider(activity));
    return reviewsAsync.when(
      loading: () => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          children: [
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Expanded(child: Text('Chargement des avis…', style: TextStyle(fontSize: 12, color: AppColors.textSecondary, fontStyle: FontStyle.italic))),
          ],
        ),
      ),
      error: (_, __) => const SizedBox.shrink(),
      data: (reviews) {
        if (reviews.isEmpty) return const SizedBox.shrink();
        final visible = reviews.take(3).toList();
        return Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('💬', style: TextStyle(fontSize: 16)),
                  const SizedBox(width: 8),
                  Text('Avis Google (${reviews.length})', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                ],
              ),
              const SizedBox(height: 10),
              ...visible.map((r) => _ReviewCard(review: r)),
              if (activity.hasCoordinates)
                TextButton(
                  onPressed: () async {
                    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=${activity.latitude},${activity.longitude}');
                    if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
                  },
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  child: Text('Voir tous les avis sur Google →', style: TextStyle(fontSize: 12, color: AppColors.primary, fontWeight: FontWeight.w600)),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ReviewCard extends StatelessWidget {
  final PlaceReview review;
  const _ReviewCard({required this.review});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  review.authorName,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < 5; i++)
                    Icon(
                      i < review.rating ? Icons.star : Icons.star_border,
                      size: 12,
                      color: const Color(0xFFF59E0B),
                    ),
                ],
              ),
            ],
          ),
          if (review.relativeTime.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(review.relativeTime, style: TextStyle(fontSize: 10, color: AppColors.textSecondary)),
          ],
          if (review.text.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(review.text, style: TextStyle(fontSize: 12, color: AppColors.textPrimary, height: 1.4), maxLines: 4, overflow: TextOverflow.ellipsis),
          ],
        ],
      ),
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
          Expanded(child: Text(text, style: TextStyle(fontSize: 14, color: AppColors.textPrimary, height: 1.4))),
        ],
      ),
    );
  }
}
