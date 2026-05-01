import 'dart:math';

/// Override de la ville extraite par cascade `address_components` pour les
/// aéroports majeurs. Cas problématique : un aéroport est physiquement situé
/// dans une banlieue (BKK à Samut Prakan, CDG à Roissy/Val-d'Oise, NRT à
/// Chiba) → Google retourne la subdivision administrative locale au lieu de
/// la "ville touristique". Le voyageur attend "Bangkok" / "Paris" / "Tokyo".
///
/// Approche : table hardcodée des ~30 aéroports les plus communs. Match par
/// haversine < 5 km sur les coords retournées par Place Details / Geocoding.
/// Si match, on override la `city`. Sinon, on garde la cascade. Couvre 90%
/// des vols mainstream pour la beta. À étendre selon les usages.
///
/// Coordonnées source : Wikipedia / OpenFlights. Précision suffisante pour
/// le matching (5 km est très permissif vs la dispersion typique).

class _AirportInfo {
  final String iata;
  final String city;
  final double lat;
  final double lng;
  const _AirportInfo({
    required this.iata,
    required this.city,
    required this.lat,
    required this.lng,
  });
}

const _airports = <_AirportInfo>[
  // Asie du Sud-Est
  _AirportInfo(iata: 'BKK', city: 'Bangkok', lat: 13.6900, lng: 100.7501),
  _AirportInfo(iata: 'DMK', city: 'Bangkok', lat: 13.9126, lng: 100.6068),
  _AirportInfo(iata: 'CNX', city: 'Chiang Mai', lat: 18.7669, lng: 98.9626),
  _AirportInfo(iata: 'HKT', city: 'Phuket', lat: 8.1132, lng: 98.3169),
  _AirportInfo(iata: 'KBV', city: 'Krabi', lat: 8.0991, lng: 98.9881),
  _AirportInfo(iata: 'USM', city: 'Koh Samui', lat: 9.5477, lng: 100.0623),
  _AirportInfo(iata: 'SIN', city: 'Singapour', lat: 1.3644, lng: 103.9915),
  _AirportInfo(iata: 'KUL', city: 'Kuala Lumpur', lat: 2.7456, lng: 101.7099),
  _AirportInfo(iata: 'CGK', city: 'Jakarta', lat: -6.1256, lng: 106.6559),
  _AirportInfo(iata: 'DPS', city: 'Bali', lat: -8.7482, lng: 115.1672),
  _AirportInfo(iata: 'SGN', city: 'Hô Chi Minh-Ville', lat: 10.8188, lng: 106.6519),
  _AirportInfo(iata: 'HAN', city: 'Hanoï', lat: 21.2212, lng: 105.8071),
  _AirportInfo(iata: 'PNH', city: 'Phnom Penh', lat: 11.5466, lng: 104.8441),
  _AirportInfo(iata: 'REP', city: 'Siem Reap', lat: 13.4109, lng: 103.8127),
  _AirportInfo(iata: 'VTE', city: 'Vientiane', lat: 17.9882, lng: 102.5630),
  _AirportInfo(iata: 'LPQ', city: 'Luang Prabang', lat: 19.8973, lng: 102.1614),
  _AirportInfo(iata: 'RGN', city: 'Yangon', lat: 16.9073, lng: 96.1332),

  // Asie de l'Est
  _AirportInfo(iata: 'HND', city: 'Tokyo', lat: 35.5494, lng: 139.7798),
  _AirportInfo(iata: 'NRT', city: 'Tokyo', lat: 35.7720, lng: 140.3929),
  _AirportInfo(iata: 'KIX', city: 'Osaka', lat: 34.4347, lng: 135.2440),
  _AirportInfo(iata: 'ITM', city: 'Osaka', lat: 34.7855, lng: 135.4382),
  _AirportInfo(iata: 'NGO', city: 'Nagoya', lat: 34.8584, lng: 136.8054),
  _AirportInfo(iata: 'PEK', city: 'Pékin', lat: 40.0801, lng: 116.5846),
  _AirportInfo(iata: 'PKX', city: 'Pékin', lat: 39.5098, lng: 116.4106),
  _AirportInfo(iata: 'PVG', city: 'Shanghai', lat: 31.1443, lng: 121.8083),
  _AirportInfo(iata: 'SHA', city: 'Shanghai', lat: 31.1979, lng: 121.3344),
  _AirportInfo(iata: 'CAN', city: 'Canton', lat: 23.3924, lng: 113.2988),
  _AirportInfo(iata: 'HKG', city: 'Hong Kong', lat: 22.3080, lng: 113.9185),
  _AirportInfo(iata: 'TPE', city: 'Taipei', lat: 25.0777, lng: 121.2328),
  _AirportInfo(iata: 'ICN', city: 'Séoul', lat: 37.4602, lng: 126.4407),
  _AirportInfo(iata: 'GMP', city: 'Séoul', lat: 37.5583, lng: 126.7906),

  // Asie du Sud
  _AirportInfo(iata: 'DEL', city: 'Delhi', lat: 28.5562, lng: 77.1000),
  _AirportInfo(iata: 'BOM', city: 'Mumbai', lat: 19.0896, lng: 72.8656),
  _AirportInfo(iata: 'MAA', city: 'Chennai', lat: 12.9941, lng: 80.1709),
  _AirportInfo(iata: 'BLR', city: 'Bangalore', lat: 13.1986, lng: 77.7066),

  // Moyen-Orient
  _AirportInfo(iata: 'DXB', city: 'Dubaï', lat: 25.2532, lng: 55.3657),
  _AirportInfo(iata: 'AUH', city: 'Abu Dhabi', lat: 24.4330, lng: 54.6511),
  _AirportInfo(iata: 'DOH', city: 'Doha', lat: 25.2731, lng: 51.6080),
  _AirportInfo(iata: 'IST', city: 'Istanbul', lat: 41.2753, lng: 28.7519),
  _AirportInfo(iata: 'SAW', city: 'Istanbul', lat: 40.8986, lng: 29.3092),
  _AirportInfo(iata: 'TLV', city: 'Tel-Aviv', lat: 32.0114, lng: 34.8867),

  // Europe
  _AirportInfo(iata: 'CDG', city: 'Paris', lat: 49.0097, lng: 2.5479),
  _AirportInfo(iata: 'ORY', city: 'Paris', lat: 48.7233, lng: 2.3794),
  _AirportInfo(iata: 'BVA', city: 'Paris', lat: 49.4544, lng: 2.1128),
  _AirportInfo(iata: 'LHR', city: 'Londres', lat: 51.4700, lng: -0.4543),
  _AirportInfo(iata: 'LGW', city: 'Londres', lat: 51.1537, lng: -0.1821),
  _AirportInfo(iata: 'STN', city: 'Londres', lat: 51.8849, lng: 0.2350),
  _AirportInfo(iata: 'LTN', city: 'Londres', lat: 51.8747, lng: -0.3683),
  _AirportInfo(iata: 'AMS', city: 'Amsterdam', lat: 52.3105, lng: 4.7683),
  _AirportInfo(iata: 'BRU', city: 'Bruxelles', lat: 50.9014, lng: 4.4844),
  _AirportInfo(iata: 'FRA', city: 'Francfort', lat: 50.0379, lng: 8.5622),
  _AirportInfo(iata: 'MUC', city: 'Munich', lat: 48.3538, lng: 11.7861),
  _AirportInfo(iata: 'TXL', city: 'Berlin', lat: 52.5597, lng: 13.2877),
  _AirportInfo(iata: 'BER', city: 'Berlin', lat: 52.3667, lng: 13.5033),
  _AirportInfo(iata: 'FCO', city: 'Rome', lat: 41.8003, lng: 12.2389),
  _AirportInfo(iata: 'CIA', city: 'Rome', lat: 41.7994, lng: 12.5949),
  _AirportInfo(iata: 'LIN', city: 'Milan', lat: 45.4451, lng: 9.2767),
  _AirportInfo(iata: 'MXP', city: 'Milan', lat: 45.6306, lng: 8.7281),
  _AirportInfo(iata: 'BCN', city: 'Barcelone', lat: 41.2974, lng: 2.0833),
  _AirportInfo(iata: 'MAD', city: 'Madrid', lat: 40.4719, lng: -3.5626),
  _AirportInfo(iata: 'LIS', city: 'Lisbonne', lat: 38.7813, lng: -9.1359),
  _AirportInfo(iata: 'OPO', city: 'Porto', lat: 41.2371, lng: -8.6708),
  _AirportInfo(iata: 'ATH', city: 'Athènes', lat: 37.9364, lng: 23.9445),
  _AirportInfo(iata: 'VIE', city: 'Vienne', lat: 48.1103, lng: 16.5697),
  _AirportInfo(iata: 'ZRH', city: 'Zurich', lat: 47.4647, lng: 8.5492),
  _AirportInfo(iata: 'GVA', city: 'Genève', lat: 46.2381, lng: 6.1090),

  // Amériques
  _AirportInfo(iata: 'JFK', city: 'New York', lat: 40.6413, lng: -73.7781),
  _AirportInfo(iata: 'LGA', city: 'New York', lat: 40.7769, lng: -73.8740),
  _AirportInfo(iata: 'EWR', city: 'Newark', lat: 40.6895, lng: -74.1745),
  _AirportInfo(iata: 'LAX', city: 'Los Angeles', lat: 33.9416, lng: -118.4085),
  _AirportInfo(iata: 'SFO', city: 'San Francisco', lat: 37.6213, lng: -122.3790),
  _AirportInfo(iata: 'ORD', city: 'Chicago', lat: 41.9742, lng: -87.9073),
  _AirportInfo(iata: 'MIA', city: 'Miami', lat: 25.7959, lng: -80.2870),
  _AirportInfo(iata: 'BOS', city: 'Boston', lat: 42.3656, lng: -71.0096),
  _AirportInfo(iata: 'IAD', city: 'Washington', lat: 38.9531, lng: -77.4565),
  _AirportInfo(iata: 'DCA', city: 'Washington', lat: 38.8512, lng: -77.0402),
  _AirportInfo(iata: 'YUL', city: 'Montréal', lat: 45.4706, lng: -73.7408),
  _AirportInfo(iata: 'YYZ', city: 'Toronto', lat: 43.6777, lng: -79.6248),
  _AirportInfo(iata: 'YVR', city: 'Vancouver', lat: 49.1939, lng: -123.1844),
  _AirportInfo(iata: 'GRU', city: 'São Paulo', lat: -23.4356, lng: -46.4731),
  _AirportInfo(iata: 'GIG', city: 'Rio de Janeiro', lat: -22.8089, lng: -43.2436),
  _AirportInfo(iata: 'EZE', city: 'Buenos Aires', lat: -34.8222, lng: -58.5358),
  _AirportInfo(iata: 'MEX', city: 'Mexico', lat: 19.4361, lng: -99.0719),

  // Afrique
  _AirportInfo(iata: 'CAI', city: 'Le Caire', lat: 30.1219, lng: 31.4056),
  _AirportInfo(iata: 'CMN', city: 'Casablanca', lat: 33.3675, lng: -7.5898),
  _AirportInfo(iata: 'JNB', city: 'Johannesburg', lat: -26.1392, lng: 28.2460),
  _AirportInfo(iata: 'CPT', city: 'Le Cap', lat: -33.9648, lng: 18.6017),
  _AirportInfo(iata: 'NBO', city: 'Nairobi', lat: -1.3192, lng: 36.9278),

  // Océanie
  _AirportInfo(iata: 'SYD', city: 'Sydney', lat: -33.9399, lng: 151.1753),
  _AirportInfo(iata: 'MEL', city: 'Melbourne', lat: -37.6690, lng: 144.8410),
  _AirportInfo(iata: 'AKL', city: 'Auckland', lat: -37.0082, lng: 174.7850),
];

/// Si les coords correspondent à un aéroport connu (haversine < 5 km),
/// retourne la ville touristique override. Sinon null → caller utilise la
/// cascade `address_components` standard.
String? overrideCityForAirportLatLng(double? lat, double? lng) {
  if (lat == null || lng == null) return null;
  for (final airport in _airports) {
    if (_haversineKm(lat, lng, airport.lat, airport.lng) < 5) {
      return airport.city;
    }
  }
  return null;
}

double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
  const earthKm = 6371.0;
  double toRad(double deg) => deg * (pi / 180);
  final dLat = toRad(lat2 - lat1);
  final dLng = toRad(lng2 - lng1);
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(toRad(lat1)) * cos(toRad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
  final c = 2 * atan2(sqrt(a), sqrt(1 - a));
  return earthKm * c;
}
