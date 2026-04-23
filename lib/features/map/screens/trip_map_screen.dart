import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';

class TripMapScreen extends ConsumerStatefulWidget {
  final String tripId;
  const TripMapScreen({super.key, required this.tripId});

  @override
  ConsumerState<TripMapScreen> createState() => _TripMapScreenState();
}

class _TripMapScreenState extends ConsumerState<TripMapScreen> {
  GoogleMapController? _controller;
  bool _geocodingInProgress = false;
  final Completer<GoogleMapController> _ctrlCompleter = Completer();

  static const _dayColors = [
    BitmapDescriptor.hueRed,
    BitmapDescriptor.hueBlue,
    BitmapDescriptor.hueGreen,
    BitmapDescriptor.hueViolet,
    BitmapDescriptor.hueOrange,
    BitmapDescriptor.hueMagenta,
    BitmapDescriptor.hueAzure,
    BitmapDescriptor.hueYellow,
    BitmapDescriptor.hueCyan,
    BitmapDescriptor.hueRose,
  ];

  // Couleurs pour les polylines (versions Color de _dayColors)
  static const _polylineColors = [
    Color(0xFFEF4444), // red
    Color(0xFF3B82F6), // blue
    Color(0xFF10B981), // green
    Color(0xFF8B5CF6), // violet
    Color(0xFFF97316), // orange
    Color(0xFFEC4899), // magenta
    Color(0xFF06B6D4), // azure
    Color(0xFFEAB308), // yellow
    Color(0xFF14B8A6), // cyan
    Color(0xFFF43F5E), // rose
  ];

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _geocodeMissing(List<TripActivity> activities, String destination) async {
    if (_geocodingInProgress) return;
    final toGeocode = activities.where((a) => !a.hasCoordinates).toList();
    if (toGeocode.isEmpty) return;

    setState(() => _geocodingInProgress = true);
    final service = ref.read(geocodingServiceProvider);
    final client = ref.read(supabaseProvider);

    for (final act in toGeocode) {
      final query = [act.title, act.detail, destination].where((s) => s != null && s.isNotEmpty).join(', ');
      final result = await service.geocode(query);
      if (result == null) continue;
      try {
        await client.from('trip_activities').update({
          'latitude': result.latitude,
          'longitude': result.longitude,
        }).eq('id', act.id);
        developer.log('Géocodée : ${act.title} → ${result.latitude},${result.longitude}', name: 'map');
      } catch (e) {
        developer.log('Erreur update coords : $e', name: 'map');
      }
    }
    if (mounted) {
      setState(() => _geocodingInProgress = false);
      ref.invalidate(tripActivitiesProvider(widget.tripId));
    }
  }

  void _fitBounds(List<LatLng> points) {
    if (_controller == null || points.isEmpty) return;
    if (points.length == 1) {
      _controller!.animateCamera(CameraUpdate.newLatLngZoom(points.first, 13));
      return;
    }
    double minLat = points.first.latitude, maxLat = points.first.latitude;
    double minLng = points.first.longitude, maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    _controller!.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(minLat, minLng),
        northeast: LatLng(maxLat, maxLng),
      ),
      60,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tripAsync = ref.watch(tripByIdProvider(widget.tripId));
    final activitiesAsync = ref.watch(tripActivitiesProvider(widget.tripId));
    final hotelAsync = ref.watch(tripHotelProvider(widget.tripId));

    final trip = tripAsync.valueOrNull;
    final activities = activitiesAsync.valueOrNull ?? const <TripActivity>[];
    final hotel = hotelAsync.valueOrNull;

    // Lance le geocodage en arrière-plan
    if (trip != null && activities.any((a) => !a.hasCoordinates) && !_geocodingInProgress) {
      Future.microtask(() => _geocodeMissing(activities, trip.destination));
    }

    // Groupe les jours dans l'ordre pour assigner une couleur par jour
    final sortedDays = activities.map((a) => DateTime(a.dayDate.year, a.dayDate.month, a.dayDate.day))
        .toSet().toList()..sort();
    final dayIndexByDate = {for (var i = 0; i < sortedDays.length; i++) sortedDays[i]: i};

    final markers = <Marker>{};
    final polylines = <Polyline>{};
    final points = <LatLng>[];

    // Activités groupées par jour pour créer les polylines dans l'ordre chronologique
    final byDay = <DateTime, List<TripActivity>>{};
    for (final a in activities) {
      if (!a.hasCoordinates) continue;
      final dayKey = DateTime(a.dayDate.year, a.dayDate.month, a.dayDate.day);
      byDay.putIfAbsent(dayKey, () => []).add(a);
    }
    // Trie chaque jour par heure
    for (final list in byDay.values) {
      list.sort((a, b) => a.startTime.compareTo(b.startTime));
    }

    // Construit markers + polylines
    for (final day in byDay.keys) {
      final dayIdx = dayIndexByDate[day] ?? 0;
      final hue = _dayColors[dayIdx % _dayColors.length];
      final lineColor = _polylineColors[dayIdx % _polylineColors.length];
      final dayActs = byDay[day]!;

      // Markers
      for (final a in dayActs) {
        final pos = LatLng(a.latitude!, a.longitude!);
        points.add(pos);
        markers.add(Marker(
          markerId: MarkerId('act_${a.id}'),
          position: pos,
          icon: BitmapDescriptor.defaultMarkerWithHue(hue),
          infoWindow: InfoWindow(
            title: a.title,
            snippet: 'Jour ${dayIdx + 1} · ${a.startTime}',
          ),
          onTap: () => _showActivityDetails(a, dayIdx + 1),
        ));
      }

      // Polyline : ligne reliant les activités de la journée dans l'ordre
      if (dayActs.length >= 2) {
        polylines.add(Polyline(
          polylineId: PolylineId('day_$dayIdx'),
          points: dayActs.map((a) => LatLng(a.latitude!, a.longitude!)).toList(),
          color: lineColor,
          width: 3,
          patterns: [PatternItem.dash(20), PatternItem.gap(8)],
        ));
      }
    }

    // Pin hôtel (noir pour le distinguer)
    if (hotel != null) {
      final lat = (hotel.metadata['latitude'] as num?)?.toDouble();
      final lng = (hotel.metadata['longitude'] as num?)?.toDouble();
      if (lat != null && lng != null) {
        final pos = LatLng(lat, lng);
        points.add(pos);
        markers.add(Marker(
          markerId: MarkerId('hotel_${hotel.id}'),
          position: pos,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(title: '🏨 ${hotel.name}', snippet: hotel.metadata['address'] as String?),
          onTap: () => _showHotelDetails(hotel),
        ));
      }
    }

    // Ajuste la caméra quand on a des points
    if (points.isNotEmpty && _controller != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitBounds(points));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(trip?.title ?? 'Carte'),
        backgroundColor: AppColors.surface,
        elevation: 1,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/trips/${widget.tripId}'),
        ),
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: const CameraPosition(target: LatLng(48.8566, 2.3522), zoom: 2),
            markers: markers,
            polylines: polylines,
            myLocationButtonEnabled: true,
            zoomControlsEnabled: false,
            onMapCreated: (ctrl) {
              _controller = ctrl;
              if (!_ctrlCompleter.isCompleted) _ctrlCompleter.complete(ctrl);
              if (points.isNotEmpty) {
                WidgetsBinding.instance.addPostFrameCallback((_) => _fitBounds(points));
              }
            },
          ),
          if (_geocodingInProgress)
            Positioned(
              top: 12, left: 12, right: 12,
              child: Material(
                elevation: 3,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(10)),
                  child: Row(children: const [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 10),
                    Expanded(child: Text('Localisation des activités…', style: TextStyle(fontSize: 12))),
                  ]),
                ),
              ),
            ),
          if (activities.isEmpty)
            const Center(
              child: Card(
                margin: EdgeInsets.all(24),
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Ajoute des activités au planning pour les voir sur la carte.', textAlign: TextAlign.center),
                ),
              ),
            )
          else if (activities.every((a) => !a.hasCoordinates) && !_geocodingInProgress)
            const Center(
              child: Card(
                margin: EdgeInsets.all(24),
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Aucune activité n\'a de coordonnées. Vérifie que ta clé Google Maps est configurée.', textAlign: TextAlign.center),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showActivityDetails(TripActivity activity, int dayNumber) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(4)),
                child: Text('Jour $dayNumber · ${activity.startTime}', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.primary)),
              ),
            ]),
            const SizedBox(height: 10),
            Text(activity.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            if (activity.detail != null && activity.detail!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(activity.detail!, style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _openInMaps(activity.latitude!, activity.longitude!, activity.title),
                    icon: const Icon(Icons.place, size: 18),
                    label: const Text('Voir sur Maps'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      foregroundColor: AppColors.primary,
                      side: BorderSide(color: AppColors.primary),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _openDirectionsFromMyLocation(activity.latitude!, activity.longitude!),
                    icon: const Icon(Icons.navigation, size: 18),
                    label: const Text('Y aller'),
                    style: ElevatedButton.styleFrom(minimumSize: const Size(0, 44)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Future<void> _openDirectionsFromMyLocation(double lat, double lng) async {
    // Sans origine explicite, Google Maps utilise la position courante de l'utilisateur
    final uri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showHotelDetails(TripDocument hotel) {
    final lat = (hotel.metadata['latitude'] as num?)?.toDouble();
    final lng = (hotel.metadata['longitude'] as num?)?.toDouble();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('🏨 ${hotel.name}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            if (hotel.metadata['address'] != null) ...[
              const SizedBox(height: 6),
              Text(hotel.metadata['address'] as String, style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            ],
            const SizedBox(height: 16),
            if (lat != null && lng != null)
              ElevatedButton.icon(
                onPressed: () => _openInMaps(lat, lng, hotel.name),
                icon: const Icon(Icons.navigation),
                label: const Text('Ouvrir dans Google Maps'),
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Future<void> _openInMaps(double lat, double lng, String label) async {
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
