import 'dart:math';

/// Override de la ville extraite par cascade `address_components` pour les
/// aéroports majeurs. Cas problématique : un aéroport est physiquement situé
/// dans une banlieue (BKK à Samut Prakan, CDG à Roissy/Val-d'Oise, NRT à
/// Chiba) → Google retourne la subdivision administrative locale au lieu de
/// la "ville touristique". Le voyageur attend "Bangkok" / "Paris" / "Tokyo".
///
/// Approche : table hardcodée des aéroports communs (audience FR : France +
/// DOM-TOM + Europe + destinations populaires monde). Match par haversine
/// < 5 km sur les coords retournées par Place Details / Geocoding. Si match,
/// on override la `city`. Sinon, on garde la cascade. À étendre selon les
/// usages remontés par les beta-testeurs.
///
/// Coordonnées source : Wikipedia / OpenFlights. Précision suffisante pour
/// le matching (5 km est très permissif vs la dispersion typique).

class _AirportInfo {
  final String iata;
  final String city;
  /// Nom propre de l'aéroport (sans la ville). Optionnel — quand présent,
  /// on l'affiche côté UX sous la forme "{city} {name} — {iata}"
  /// (ex: "Paris Charles de Gaulle — CDG"). Sinon fallback "{city} — {iata}".
  /// À enrichir au fil de l'eau pour les aéroports les plus utilisés.
  final String? name;
  final double lat;
  final double lng;
  const _AirportInfo({
    required this.iata,
    required this.city,
    this.name,
    required this.lat,
    required this.lng,
  });
}

const _airports = <_AirportInfo>[
  // === FRANCE métropole ===
  // (name renseigné pour les principaux — fallback "{city} — {iata}" sinon)
  _AirportInfo(iata: 'CDG', city: 'Paris', name: 'Charles de Gaulle', lat: 49.0097, lng: 2.5479),
  _AirportInfo(iata: 'ORY', city: 'Paris', name: 'Orly', lat: 48.7233, lng: 2.3794),
  _AirportInfo(iata: 'BVA', city: 'Paris', name: 'Beauvais', lat: 49.4544, lng: 2.1128),
  _AirportInfo(iata: 'NCE', city: 'Nice', name: "Côte d'Azur", lat: 43.6584, lng: 7.2159),
  _AirportInfo(iata: 'LYS', city: 'Lyon', name: 'Saint-Exupéry', lat: 45.7256, lng: 5.0811),
  _AirportInfo(iata: 'MRS', city: 'Marseille', name: 'Provence', lat: 43.4393, lng: 5.2214),
  _AirportInfo(iata: 'TLS', city: 'Toulouse', name: 'Blagnac', lat: 43.6291, lng: 1.3638),
  _AirportInfo(iata: 'BOD', city: 'Bordeaux', name: 'Mérignac', lat: 44.8283, lng: -0.7156),
  _AirportInfo(iata: 'NTE', city: 'Nantes', name: 'Atlantique', lat: 47.1532, lng: -1.6107),
  _AirportInfo(iata: 'MPL', city: 'Montpellier', lat: 43.5762, lng: 3.9630),
  _AirportInfo(iata: 'SXB', city: 'Strasbourg', lat: 48.5383, lng: 7.6280),
  _AirportInfo(iata: 'LIL', city: 'Lille', lat: 50.5614, lng: 3.0894),
  _AirportInfo(iata: 'BES', city: 'Brest', lat: 48.4475, lng: -4.4185),
  _AirportInfo(iata: 'RNS', city: 'Rennes', lat: 48.0694, lng: -1.7347),
  _AirportInfo(iata: 'AJA', city: 'Ajaccio', lat: 41.9236, lng: 8.8027),
  _AirportInfo(iata: 'BIA', city: 'Bastia', lat: 42.5527, lng: 9.4837),
  _AirportInfo(iata: 'FSC', city: 'Figari', lat: 41.5006, lng: 9.0978),
  _AirportInfo(iata: 'CLY', city: 'Calvi', lat: 42.5306, lng: 8.7931),

  // === FRANCE DOM-TOM ===
  _AirportInfo(iata: 'PTP', city: 'Pointe-à-Pitre', lat: 16.2654, lng: -61.5318),
  _AirportInfo(iata: 'FDF', city: 'Fort-de-France', lat: 14.5910, lng: -61.0032),
  _AirportInfo(iata: 'RUN', city: 'Saint-Denis', lat: -20.8871, lng: 55.5103),
  _AirportInfo(iata: 'DZA', city: 'Mayotte', lat: -12.8047, lng: 45.2811),
  _AirportInfo(iata: 'PPT', city: 'Papeete', lat: -17.5571, lng: -149.6116),
  _AirportInfo(iata: 'NOU', city: 'Nouméa', lat: -22.0146, lng: 166.2129),
  _AirportInfo(iata: 'CAY', city: 'Cayenne', lat: 4.8195, lng: -52.3604),
  _AirportInfo(iata: 'SXM', city: 'Saint-Martin', lat: 18.0410, lng: -63.1109),

  // === EUROPE — Royaume-Uni & Irlande ===
  _AirportInfo(iata: 'LHR', city: 'Londres', name: 'Heathrow', lat: 51.4700, lng: -0.4543),
  _AirportInfo(iata: 'LGW', city: 'Londres', name: 'Gatwick', lat: 51.1537, lng: -0.1821),
  _AirportInfo(iata: 'STN', city: 'Londres', name: 'Stansted', lat: 51.8849, lng: 0.2350),
  _AirportInfo(iata: 'LTN', city: 'Londres', name: 'Luton', lat: 51.8747, lng: -0.3683),
  _AirportInfo(iata: 'LCY', city: 'Londres', name: 'City', lat: 51.5053, lng: 0.0553),
  _AirportInfo(iata: 'MAN', city: 'Manchester', lat: 53.3537, lng: -2.2750),
  _AirportInfo(iata: 'EDI', city: 'Édimbourg', lat: 55.9500, lng: -3.3725),
  _AirportInfo(iata: 'BHX', city: 'Birmingham', lat: 52.4539, lng: -1.7480),
  _AirportInfo(iata: 'GLA', city: 'Glasgow', lat: 55.8642, lng: -4.4332),
  _AirportInfo(iata: 'BRS', city: 'Bristol', lat: 51.3827, lng: -2.7191),
  _AirportInfo(iata: 'DUB', city: 'Dublin', lat: 53.4213, lng: -6.2701),
  _AirportInfo(iata: 'ORK', city: 'Cork', lat: 51.8413, lng: -8.4911),
  _AirportInfo(iata: 'SNN', city: 'Shannon', lat: 52.7019, lng: -8.9248),

  // === EUROPE — Benelux & Allemagne & Suisse & Autriche ===
  _AirportInfo(iata: 'AMS', city: 'Amsterdam', name: 'Schiphol', lat: 52.3105, lng: 4.7683),
  _AirportInfo(iata: 'RTM', city: 'Rotterdam', lat: 51.9569, lng: 4.4372),
  _AirportInfo(iata: 'EIN', city: 'Eindhoven', lat: 51.4500, lng: 5.3747),
  _AirportInfo(iata: 'BRU', city: 'Bruxelles', lat: 50.9014, lng: 4.4844),
  _AirportInfo(iata: 'CRL', city: 'Bruxelles', lat: 50.4592, lng: 4.4538),
  _AirportInfo(iata: 'LUX', city: 'Luxembourg', lat: 49.6233, lng: 6.2044),
  _AirportInfo(iata: 'FRA', city: 'Francfort', name: 'Main', lat: 50.0379, lng: 8.5622),
  _AirportInfo(iata: 'MUC', city: 'Munich', lat: 48.3538, lng: 11.7861),
  _AirportInfo(iata: 'TXL', city: 'Berlin', lat: 52.5597, lng: 13.2877),
  _AirportInfo(iata: 'BER', city: 'Berlin', lat: 52.3667, lng: 13.5033),
  _AirportInfo(iata: 'HAM', city: 'Hambourg', lat: 53.6304, lng: 9.9882),
  _AirportInfo(iata: 'DUS', city: 'Düsseldorf', lat: 51.2895, lng: 6.7668),
  _AirportInfo(iata: 'CGN', city: 'Cologne', lat: 50.8659, lng: 7.1427),
  _AirportInfo(iata: 'STR', city: 'Stuttgart', lat: 48.6900, lng: 9.2219),
  _AirportInfo(iata: 'SCN', city: 'Sarrebruck', lat: 49.2146, lng: 7.1095),
  _AirportInfo(iata: 'NUE', city: 'Nuremberg', lat: 49.4986, lng: 11.0781),
  _AirportInfo(iata: 'ZRH', city: 'Zurich', lat: 47.4647, lng: 8.5492),
  _AirportInfo(iata: 'GVA', city: 'Genève', lat: 46.2381, lng: 6.1090),
  _AirportInfo(iata: 'BSL', city: 'Bâle', lat: 47.5896, lng: 7.5300),
  _AirportInfo(iata: 'BRN', city: 'Berne', lat: 46.9141, lng: 7.4969),
  _AirportInfo(iata: 'VIE', city: 'Vienne', lat: 48.1103, lng: 16.5697),
  _AirportInfo(iata: 'SZG', city: 'Salzbourg', lat: 47.7933, lng: 13.0043),
  _AirportInfo(iata: 'INN', city: 'Innsbruck', lat: 47.2602, lng: 11.3438),

  // === EUROPE — Italie ===
  _AirportInfo(iata: 'FCO', city: 'Rome', name: 'Fiumicino', lat: 41.8003, lng: 12.2389),
  _AirportInfo(iata: 'CIA', city: 'Rome', lat: 41.7994, lng: 12.5949),
  _AirportInfo(iata: 'LIN', city: 'Milan', lat: 45.4451, lng: 9.2767),
  _AirportInfo(iata: 'MXP', city: 'Milan', lat: 45.6306, lng: 8.7281),
  _AirportInfo(iata: 'BGY', city: 'Milan', lat: 45.6739, lng: 9.7042),
  _AirportInfo(iata: 'VCE', city: 'Venise', lat: 45.5052, lng: 12.3519),
  _AirportInfo(iata: 'TSF', city: 'Venise', lat: 45.6484, lng: 12.1944),
  _AirportInfo(iata: 'NAP', city: 'Naples', lat: 40.8860, lng: 14.2908),
  _AirportInfo(iata: 'FLR', city: 'Florence', lat: 43.8100, lng: 11.2051),
  _AirportInfo(iata: 'PSA', city: 'Pise', lat: 43.6839, lng: 10.3927),
  _AirportInfo(iata: 'BLQ', city: 'Bologne', lat: 44.5354, lng: 11.2887),
  _AirportInfo(iata: 'VRN', city: 'Vérone', lat: 45.3957, lng: 10.8885),
  _AirportInfo(iata: 'TRN', city: 'Turin', lat: 45.2008, lng: 7.6496),
  _AirportInfo(iata: 'CTA', city: 'Catane', lat: 37.4668, lng: 15.0664),
  _AirportInfo(iata: 'PMO', city: 'Palerme', lat: 38.1759, lng: 13.0910),
  _AirportInfo(iata: 'CAG', city: 'Cagliari', lat: 39.2515, lng: 9.0542),
  _AirportInfo(iata: 'OLB', city: 'Olbia', lat: 40.8987, lng: 9.5176),
  _AirportInfo(iata: 'BRI', city: 'Bari', lat: 41.1389, lng: 16.7606),

  // === EUROPE — Espagne & Portugal ===
  _AirportInfo(iata: 'BCN', city: 'Barcelone', name: 'El Prat', lat: 41.2974, lng: 2.0833),
  _AirportInfo(iata: 'MAD', city: 'Madrid', name: 'Barajas', lat: 40.4719, lng: -3.5626),
  _AirportInfo(iata: 'PMI', city: 'Palma', lat: 39.5517, lng: 2.7388),
  _AirportInfo(iata: 'AGP', city: 'Malaga', lat: 36.6749, lng: -4.4991),
  _AirportInfo(iata: 'IBZ', city: 'Ibiza', lat: 38.8729, lng: 1.3731),
  _AirportInfo(iata: 'VLC', city: 'Valence', lat: 39.4893, lng: -0.4816),
  _AirportInfo(iata: 'SVQ', city: 'Séville', lat: 37.4180, lng: -5.8931),
  _AirportInfo(iata: 'ALC', city: 'Alicante', lat: 38.2822, lng: -0.5582),
  _AirportInfo(iata: 'BIO', city: 'Bilbao', lat: 43.3011, lng: -2.9106),
  _AirportInfo(iata: 'TFS', city: 'Tenerife', lat: 28.0445, lng: -16.5725),
  _AirportInfo(iata: 'TFN', city: 'Tenerife', lat: 28.4827, lng: -16.3414),
  _AirportInfo(iata: 'LPA', city: 'Las Palmas', lat: 27.9319, lng: -15.3866),
  _AirportInfo(iata: 'ACE', city: 'Lanzarote', lat: 28.9455, lng: -13.6052),
  _AirportInfo(iata: 'FUE', city: 'Fuerteventura', lat: 28.4527, lng: -13.8638),
  _AirportInfo(iata: 'LIS', city: 'Lisbonne', lat: 38.7813, lng: -9.1359),
  _AirportInfo(iata: 'OPO', city: 'Porto', lat: 41.2371, lng: -8.6708),
  _AirportInfo(iata: 'FAO', city: 'Faro', lat: 37.0144, lng: -7.9659),
  _AirportInfo(iata: 'FNC', city: 'Madère', lat: 32.6979, lng: -16.7745),
  _AirportInfo(iata: 'PDL', city: 'Ponta Delgada', lat: 37.7412, lng: -25.6979),

  // === EUROPE — Grèce, Croatie, Balkans ===
  _AirportInfo(iata: 'ATH', city: 'Athènes', lat: 37.9364, lng: 23.9445),
  _AirportInfo(iata: 'SKG', city: 'Thessalonique', lat: 40.5197, lng: 22.9709),
  _AirportInfo(iata: 'HER', city: 'Héraklion', lat: 35.3397, lng: 25.1803),
  _AirportInfo(iata: 'CHQ', city: 'La Canée', lat: 35.5318, lng: 24.1497),
  _AirportInfo(iata: 'JTR', city: 'Santorin', lat: 36.3992, lng: 25.4793),
  _AirportInfo(iata: 'JMK', city: 'Mykonos', lat: 37.4351, lng: 25.3481),
  _AirportInfo(iata: 'RHO', city: 'Rhodes', lat: 36.4054, lng: 28.0862),
  _AirportInfo(iata: 'CFU', city: 'Corfou', lat: 39.6019, lng: 19.9117),
  _AirportInfo(iata: 'ZTH', city: 'Zakynthos', lat: 37.7510, lng: 20.8843),
  _AirportInfo(iata: 'KGS', city: 'Kos', lat: 36.7933, lng: 27.0917),
  _AirportInfo(iata: 'ZAG', city: 'Zagreb', lat: 45.7429, lng: 16.0688),
  _AirportInfo(iata: 'SPU', city: 'Split', lat: 43.5389, lng: 16.2980),
  _AirportInfo(iata: 'DBV', city: 'Dubrovnik', lat: 42.5614, lng: 18.2682),
  _AirportInfo(iata: 'PUY', city: 'Pula', lat: 44.8935, lng: 13.9222),
  _AirportInfo(iata: 'LJU', city: 'Ljubljana', lat: 46.2237, lng: 14.4576),
  _AirportInfo(iata: 'BEG', city: 'Belgrade', lat: 44.8184, lng: 20.3091),
  _AirportInfo(iata: 'SOF', city: 'Sofia', lat: 42.6967, lng: 23.4114),
  _AirportInfo(iata: 'TIA', city: 'Tirana', lat: 41.4147, lng: 19.7206),
  _AirportInfo(iata: 'SKP', city: 'Skopje', lat: 41.9616, lng: 21.6214),
  _AirportInfo(iata: 'TGD', city: 'Podgorica', lat: 42.3594, lng: 19.2519),

  // === EUROPE — Europe centrale & de l'Est ===
  _AirportInfo(iata: 'WAW', city: 'Varsovie', lat: 52.1657, lng: 20.9671),
  _AirportInfo(iata: 'KRK', city: 'Cracovie', lat: 50.0777, lng: 19.7848),
  _AirportInfo(iata: 'GDN', city: 'Gdansk', lat: 54.3776, lng: 18.4662),
  _AirportInfo(iata: 'PRG', city: 'Prague', lat: 50.1008, lng: 14.2632),
  _AirportInfo(iata: 'BUD', city: 'Budapest', lat: 47.4395, lng: 19.2611),
  _AirportInfo(iata: 'OTP', city: 'Bucarest', lat: 44.5722, lng: 26.1022),
  _AirportInfo(iata: 'BTS', city: 'Bratislava', lat: 48.1702, lng: 17.2127),
  _AirportInfo(iata: 'TLL', city: 'Tallinn', lat: 59.4133, lng: 24.8328),
  _AirportInfo(iata: 'RIX', city: 'Riga', lat: 56.9236, lng: 23.9711),
  _AirportInfo(iata: 'VNO', city: 'Vilnius', lat: 54.6341, lng: 25.2858),
  _AirportInfo(iata: 'KBP', city: 'Kiev', lat: 50.3450, lng: 30.8947),
  _AirportInfo(iata: 'SVO', city: 'Moscou', lat: 55.9726, lng: 37.4146),
  _AirportInfo(iata: 'DME', city: 'Moscou', lat: 55.4088, lng: 37.9063),
  _AirportInfo(iata: 'VKO', city: 'Moscou', lat: 55.5915, lng: 37.2615),
  _AirportInfo(iata: 'LED', city: 'Saint-Pétersbourg', lat: 59.8003, lng: 30.2625),

  // === EUROPE — Scandinavie ===
  _AirportInfo(iata: 'CPH', city: 'Copenhague', lat: 55.6181, lng: 12.6561),
  _AirportInfo(iata: 'ARN', city: 'Stockholm', lat: 59.6519, lng: 17.9186),
  _AirportInfo(iata: 'OSL', city: 'Oslo', lat: 60.1939, lng: 11.1004),
  _AirportInfo(iata: 'HEL', city: 'Helsinki', lat: 60.3172, lng: 24.9633),
  _AirportInfo(iata: 'KEF', city: 'Reykjavik', lat: 63.9850, lng: -22.6056),
  _AirportInfo(iata: 'BGO', city: 'Bergen', lat: 60.2934, lng: 5.2181),
  _AirportInfo(iata: 'GOT', city: 'Göteborg', lat: 57.6627, lng: 12.2799),
  _AirportInfo(iata: 'TRD', city: 'Trondheim', lat: 63.4578, lng: 10.9242),

  // === EUROPE — Méditerranée orientale ===
  _AirportInfo(iata: 'IST', city: 'Istanbul', name: 'Havalimanı', lat: 41.2753, lng: 28.7519),
  _AirportInfo(iata: 'SAW', city: 'Istanbul', lat: 40.8986, lng: 29.3092),
  _AirportInfo(iata: 'AYT', city: 'Antalya', lat: 36.8987, lng: 30.8005),
  _AirportInfo(iata: 'BJV', city: 'Bodrum', lat: 37.2506, lng: 27.6643),
  _AirportInfo(iata: 'ESB', city: 'Ankara', lat: 40.1281, lng: 32.9951),
  _AirportInfo(iata: 'ADB', city: 'Izmir', lat: 38.2924, lng: 27.1568),
  _AirportInfo(iata: 'MLA', city: 'La Valette', lat: 35.8575, lng: 14.4775),
  _AirportInfo(iata: 'LCA', city: 'Larnaca', lat: 34.8751, lng: 33.6249),
  _AirportInfo(iata: 'PFO', city: 'Paphos', lat: 34.7180, lng: 32.4857),

  // === MOYEN-ORIENT ===
  _AirportInfo(iata: 'DXB', city: 'Dubaï', name: 'International', lat: 25.2532, lng: 55.3657),
  _AirportInfo(iata: 'DWC', city: 'Dubaï', lat: 24.8964, lng: 55.1614),
  _AirportInfo(iata: 'AUH', city: 'Abu Dhabi', lat: 24.4330, lng: 54.6511),
  _AirportInfo(iata: 'SHJ', city: 'Sharjah', lat: 25.3286, lng: 55.5172),
  _AirportInfo(iata: 'DOH', city: 'Doha', lat: 25.2731, lng: 51.6080),
  _AirportInfo(iata: 'BAH', city: 'Bahreïn', lat: 26.2708, lng: 50.6336),
  _AirportInfo(iata: 'KWI', city: 'Koweït', lat: 29.2266, lng: 47.9689),
  _AirportInfo(iata: 'MCT', city: 'Mascate', lat: 23.5933, lng: 58.2844),
  _AirportInfo(iata: 'RUH', city: 'Riyad', lat: 24.9576, lng: 46.6988),
  _AirportInfo(iata: 'JED', city: 'Djeddah', lat: 21.6796, lng: 39.1565),
  _AirportInfo(iata: 'AMM', city: 'Amman', lat: 31.7226, lng: 35.9933),
  _AirportInfo(iata: 'BEY', city: 'Beyrouth', lat: 33.8208, lng: 35.4884),
  _AirportInfo(iata: 'TLV', city: 'Tel-Aviv', lat: 32.0114, lng: 34.8867),
  _AirportInfo(iata: 'IKA', city: 'Téhéran', lat: 35.4161, lng: 51.1522),

  // === ASIE — Japon ===
  _AirportInfo(iata: 'HND', city: 'Tokyo', name: 'Haneda', lat: 35.5494, lng: 139.7798),
  _AirportInfo(iata: 'NRT', city: 'Tokyo', name: 'Narita', lat: 35.7720, lng: 140.3929),
  _AirportInfo(iata: 'KIX', city: 'Osaka', lat: 34.4347, lng: 135.2440),
  _AirportInfo(iata: 'ITM', city: 'Osaka', lat: 34.7855, lng: 135.4382),
  _AirportInfo(iata: 'NGO', city: 'Nagoya', lat: 34.8584, lng: 136.8054),
  _AirportInfo(iata: 'FUK', city: 'Fukuoka', lat: 33.5859, lng: 130.4505),
  _AirportInfo(iata: 'CTS', city: 'Sapporo', lat: 42.7752, lng: 141.6920),
  _AirportInfo(iata: 'OKA', city: 'Naha', lat: 26.1958, lng: 127.6458),
  _AirportInfo(iata: 'HIJ', city: 'Hiroshima', lat: 34.4361, lng: 132.9197),
  _AirportInfo(iata: 'SDJ', city: 'Sendai', lat: 38.1397, lng: 140.9171),

  // === ASIE — Chine, HK, Taiwan, Corée ===
  _AirportInfo(iata: 'PEK', city: 'Pékin', lat: 40.0801, lng: 116.5846),
  _AirportInfo(iata: 'PKX', city: 'Pékin', lat: 39.5098, lng: 116.4106),
  _AirportInfo(iata: 'PVG', city: 'Shanghai', lat: 31.1443, lng: 121.8083),
  _AirportInfo(iata: 'SHA', city: 'Shanghai', lat: 31.1979, lng: 121.3344),
  _AirportInfo(iata: 'CAN', city: 'Canton', lat: 23.3924, lng: 113.2988),
  _AirportInfo(iata: 'SZX', city: 'Shenzhen', lat: 22.6394, lng: 113.8108),
  _AirportInfo(iata: 'CTU', city: 'Chengdu', lat: 30.5728, lng: 103.9472),
  _AirportInfo(iata: 'XIY', city: 'Xi\'an', lat: 34.4471, lng: 108.7517),
  _AirportInfo(iata: 'CKG', city: 'Chongqing', lat: 29.7194, lng: 106.6417),
  _AirportInfo(iata: 'KMG', city: 'Kunming', lat: 25.1019, lng: 102.9292),
  _AirportInfo(iata: 'HGH', city: 'Hangzhou', lat: 30.2295, lng: 120.4346),
  _AirportInfo(iata: 'HKG', city: 'Hong Kong', lat: 22.3080, lng: 113.9185),
  _AirportInfo(iata: 'MFM', city: 'Macao', lat: 22.1496, lng: 113.5916),
  _AirportInfo(iata: 'TPE', city: 'Taipei', lat: 25.0777, lng: 121.2328),
  _AirportInfo(iata: 'TSA', city: 'Taipei', lat: 25.0697, lng: 121.5519),
  _AirportInfo(iata: 'ICN', city: 'Séoul', lat: 37.4602, lng: 126.4407),
  _AirportInfo(iata: 'GMP', city: 'Séoul', lat: 37.5583, lng: 126.7906),
  _AirportInfo(iata: 'PUS', city: 'Busan', lat: 35.1795, lng: 128.9382),
  _AirportInfo(iata: 'CJU', city: 'Jeju', lat: 33.5113, lng: 126.4930),

  // === ASIE — Sud-Est ===
  _AirportInfo(iata: 'BKK', city: 'Bangkok', name: 'Suvarnabhumi', lat: 13.6900, lng: 100.7501),
  _AirportInfo(iata: 'DMK', city: 'Bangkok', lat: 13.9126, lng: 100.6068),
  _AirportInfo(iata: 'CNX', city: 'Chiang Mai', lat: 18.7669, lng: 98.9626),
  _AirportInfo(iata: 'HKT', city: 'Phuket', lat: 8.1132, lng: 98.3169),
  _AirportInfo(iata: 'KBV', city: 'Krabi', lat: 8.0991, lng: 98.9881),
  _AirportInfo(iata: 'USM', city: 'Koh Samui', lat: 9.5477, lng: 100.0623),
  _AirportInfo(iata: 'SIN', city: 'Singapour', name: 'Changi', lat: 1.3644, lng: 103.9915),
  _AirportInfo(iata: 'KUL', city: 'Kuala Lumpur', lat: 2.7456, lng: 101.7099),
  _AirportInfo(iata: 'PEN', city: 'Penang', lat: 5.2971, lng: 100.2769),
  _AirportInfo(iata: 'LGK', city: 'Langkawi', lat: 6.3299, lng: 99.7287),
  _AirportInfo(iata: 'BKI', city: 'Kota Kinabalu', lat: 5.9372, lng: 116.0512),
  _AirportInfo(iata: 'CGK', city: 'Jakarta', lat: -6.1256, lng: 106.6559),
  _AirportInfo(iata: 'DPS', city: 'Bali', lat: -8.7482, lng: 115.1672),
  _AirportInfo(iata: 'JOG', city: 'Yogyakarta', lat: -7.9006, lng: 110.0571),
  _AirportInfo(iata: 'SUB', city: 'Surabaya', lat: -7.3798, lng: 112.7867),
  _AirportInfo(iata: 'SGN', city: 'Hô Chi Minh-Ville', lat: 10.8188, lng: 106.6519),
  _AirportInfo(iata: 'HAN', city: 'Hanoï', lat: 21.2212, lng: 105.8071),
  _AirportInfo(iata: 'DAD', city: 'Da Nang', lat: 16.0439, lng: 108.1992),
  _AirportInfo(iata: 'CXR', city: 'Nha Trang', lat: 11.9982, lng: 109.2192),
  _AirportInfo(iata: 'HUI', city: 'Hué', lat: 16.4015, lng: 107.7032),
  _AirportInfo(iata: 'PQC', city: 'Phu Quoc', lat: 10.2270, lng: 103.9670),
  _AirportInfo(iata: 'PNH', city: 'Phnom Penh', lat: 11.5466, lng: 104.8441),
  _AirportInfo(iata: 'REP', city: 'Siem Reap', lat: 13.4109, lng: 103.8127),
  _AirportInfo(iata: 'VTE', city: 'Vientiane', lat: 17.9882, lng: 102.5630),
  _AirportInfo(iata: 'LPQ', city: 'Luang Prabang', lat: 19.8973, lng: 102.1614),
  _AirportInfo(iata: 'RGN', city: 'Yangon', lat: 16.9073, lng: 96.1332),
  _AirportInfo(iata: 'MDL', city: 'Mandalay', lat: 21.7019, lng: 95.9778),
  _AirportInfo(iata: 'MNL', city: 'Manille', lat: 14.5086, lng: 121.0194),
  _AirportInfo(iata: 'CEB', city: 'Cebu', lat: 10.3075, lng: 123.9794),
  _AirportInfo(iata: 'PPS', city: 'Puerto Princesa', lat: 9.7421, lng: 118.7587),
  _AirportInfo(iata: 'BWN', city: 'Bandar Seri Begawan', lat: 4.9442, lng: 114.9281),

  // === ASIE — Sud (Inde, Sri Lanka, Maldives, Népal) ===
  _AirportInfo(iata: 'DEL', city: 'Delhi', lat: 28.5562, lng: 77.1000),
  _AirportInfo(iata: 'BOM', city: 'Mumbai', lat: 19.0896, lng: 72.8656),
  _AirportInfo(iata: 'MAA', city: 'Chennai', lat: 12.9941, lng: 80.1709),
  _AirportInfo(iata: 'BLR', city: 'Bangalore', lat: 13.1986, lng: 77.7066),
  _AirportInfo(iata: 'HYD', city: 'Hyderabad', lat: 17.2403, lng: 78.4294),
  _AirportInfo(iata: 'CCU', city: 'Calcutta', lat: 22.6547, lng: 88.4467),
  _AirportInfo(iata: 'GOI', city: 'Goa', lat: 15.3808, lng: 73.8314),
  _AirportInfo(iata: 'COK', city: 'Kochi', lat: 10.1520, lng: 76.4019),
  _AirportInfo(iata: 'TRV', city: 'Trivandrum', lat: 8.4821, lng: 76.9201),
  _AirportInfo(iata: 'CMB', city: 'Colombo', lat: 7.1808, lng: 79.8842),
  _AirportInfo(iata: 'MLE', city: 'Malé', lat: 4.1918, lng: 73.5290),
  _AirportInfo(iata: 'KTM', city: 'Katmandou', lat: 27.6961, lng: 85.3592),
  _AirportInfo(iata: 'PBH', city: 'Paro', lat: 27.4032, lng: 89.4246),
  _AirportInfo(iata: 'DAC', city: 'Dacca', lat: 23.8431, lng: 90.3978),
  _AirportInfo(iata: 'ISB', city: 'Islamabad', lat: 33.5594, lng: 72.8520),
  _AirportInfo(iata: 'KHI', city: 'Karachi', lat: 24.9008, lng: 67.1608),

  // === AMÉRIQUES — USA ===
  _AirportInfo(iata: 'JFK', city: 'New York', name: 'John F. Kennedy', lat: 40.6413, lng: -73.7781),
  _AirportInfo(iata: 'LGA', city: 'New York', lat: 40.7769, lng: -73.8740),
  _AirportInfo(iata: 'EWR', city: 'Newark', name: 'Liberty', lat: 40.6895, lng: -74.1745),
  _AirportInfo(iata: 'LAX', city: 'Los Angeles', name: 'International', lat: 33.9416, lng: -118.4085),
  _AirportInfo(iata: 'SFO', city: 'San Francisco', lat: 37.6213, lng: -122.3790),
  _AirportInfo(iata: 'SAN', city: 'San Diego', lat: 32.7338, lng: -117.1933),
  _AirportInfo(iata: 'LAS', city: 'Las Vegas', lat: 36.0840, lng: -115.1537),
  _AirportInfo(iata: 'ORD', city: 'Chicago', lat: 41.9742, lng: -87.9073),
  _AirportInfo(iata: 'MDW', city: 'Chicago', lat: 41.7868, lng: -87.7522),
  _AirportInfo(iata: 'ATL', city: 'Atlanta', lat: 33.6407, lng: -84.4277),
  _AirportInfo(iata: 'MIA', city: 'Miami', lat: 25.7959, lng: -80.2870),
  _AirportInfo(iata: 'FLL', city: 'Fort Lauderdale', lat: 26.0726, lng: -80.1527),
  _AirportInfo(iata: 'MCO', city: 'Orlando', lat: 28.4312, lng: -81.3081),
  _AirportInfo(iata: 'BOS', city: 'Boston', lat: 42.3656, lng: -71.0096),
  _AirportInfo(iata: 'IAD', city: 'Washington', lat: 38.9531, lng: -77.4565),
  _AirportInfo(iata: 'DCA', city: 'Washington', lat: 38.8512, lng: -77.0402),
  _AirportInfo(iata: 'BWI', city: 'Baltimore', lat: 39.1774, lng: -76.6684),
  _AirportInfo(iata: 'PHL', city: 'Philadelphie', lat: 39.8744, lng: -75.2424),
  _AirportInfo(iata: 'DFW', city: 'Dallas', lat: 32.8998, lng: -97.0403),
  _AirportInfo(iata: 'IAH', city: 'Houston', lat: 29.9844, lng: -95.3414),
  _AirportInfo(iata: 'AUS', city: 'Austin', lat: 30.1945, lng: -97.6699),
  _AirportInfo(iata: 'DEN', city: 'Denver', lat: 39.8561, lng: -104.6737),
  _AirportInfo(iata: 'SEA', city: 'Seattle', lat: 47.4502, lng: -122.3088),
  _AirportInfo(iata: 'PDX', city: 'Portland', lat: 45.5887, lng: -122.5975),
  _AirportInfo(iata: 'PHX', city: 'Phoenix', lat: 33.4343, lng: -112.0080),
  _AirportInfo(iata: 'SLC', city: 'Salt Lake City', lat: 40.7884, lng: -111.9779),
  _AirportInfo(iata: 'MSP', city: 'Minneapolis', lat: 44.8848, lng: -93.2223),
  _AirportInfo(iata: 'DTW', city: 'Detroit', lat: 42.2124, lng: -83.3534),
  _AirportInfo(iata: 'HNL', city: 'Honolulu', lat: 21.3187, lng: -157.9225),

  // === AMÉRIQUES — Canada ===
  _AirportInfo(iata: 'YUL', city: 'Montréal', lat: 45.4706, lng: -73.7408),
  _AirportInfo(iata: 'YYZ', city: 'Toronto', lat: 43.6777, lng: -79.6248),
  _AirportInfo(iata: 'YVR', city: 'Vancouver', lat: 49.1939, lng: -123.1844),
  _AirportInfo(iata: 'YYC', city: 'Calgary', lat: 51.1215, lng: -114.0076),
  _AirportInfo(iata: 'YOW', city: 'Ottawa', lat: 45.3225, lng: -75.6692),
  _AirportInfo(iata: 'YEG', city: 'Edmonton', lat: 53.3097, lng: -113.5800),
  _AirportInfo(iata: 'YHZ', city: 'Halifax', lat: 44.8808, lng: -63.5086),
  _AirportInfo(iata: 'YQB', city: 'Québec', lat: 46.7911, lng: -71.3933),

  // === AMÉRIQUES — Mexique & Amérique centrale & Caraïbes ===
  _AirportInfo(iata: 'MEX', city: 'Mexico', lat: 19.4361, lng: -99.0719),
  _AirportInfo(iata: 'CUN', city: 'Cancún', lat: 21.0365, lng: -86.8770),
  _AirportInfo(iata: 'GDL', city: 'Guadalajara', lat: 20.5218, lng: -103.3111),
  _AirportInfo(iata: 'PVR', city: 'Puerto Vallarta', lat: 20.6801, lng: -105.2540),
  _AirportInfo(iata: 'MTY', city: 'Monterrey', lat: 25.7785, lng: -100.1067),
  _AirportInfo(iata: 'SJD', city: 'Los Cabos', lat: 23.1518, lng: -109.7211),
  _AirportInfo(iata: 'TIJ', city: 'Tijuana', lat: 32.5411, lng: -116.9701),
  _AirportInfo(iata: 'HAV', city: 'La Havane', lat: 22.9892, lng: -82.4091),
  _AirportInfo(iata: 'SDQ', city: 'Saint-Domingue', lat: 18.4297, lng: -69.6689),
  _AirportInfo(iata: 'PUJ', city: 'Punta Cana', lat: 18.5674, lng: -68.3635),
  _AirportInfo(iata: 'NAS', city: 'Nassau', lat: 25.0389, lng: -77.4663),
  _AirportInfo(iata: 'SJO', city: 'San José', lat: 9.9939, lng: -84.2089),
  _AirportInfo(iata: 'PTY', city: 'Panama', lat: 9.0714, lng: -79.3835),
  _AirportInfo(iata: 'GUA', city: 'Guatemala', lat: 14.5833, lng: -90.5275),
  _AirportInfo(iata: 'SAL', city: 'San Salvador', lat: 13.4409, lng: -89.0556),
  _AirportInfo(iata: 'KIN', city: 'Kingston', lat: 17.9357, lng: -76.7875),

  // === AMÉRIQUES — Amérique du Sud ===
  _AirportInfo(iata: 'GRU', city: 'São Paulo', lat: -23.4356, lng: -46.4731),
  _AirportInfo(iata: 'GIG', city: 'Rio de Janeiro', lat: -22.8089, lng: -43.2436),
  _AirportInfo(iata: 'BSB', city: 'Brasilia', lat: -15.8711, lng: -47.9186),
  _AirportInfo(iata: 'SSA', city: 'Salvador de Bahia', lat: -12.9086, lng: -38.3225),
  _AirportInfo(iata: 'FOR', city: 'Fortaleza', lat: -3.7763, lng: -38.5326),
  _AirportInfo(iata: 'REC', city: 'Recife', lat: -8.1264, lng: -34.9236),
  _AirportInfo(iata: 'EZE', city: 'Buenos Aires', lat: -34.8222, lng: -58.5358),
  _AirportInfo(iata: 'AEP', city: 'Buenos Aires', lat: -34.5592, lng: -58.4156),
  _AirportInfo(iata: 'SCL', city: 'Santiago', lat: -33.3930, lng: -70.7858),
  _AirportInfo(iata: 'BOG', city: 'Bogota', lat: 4.7016, lng: -74.1469),
  _AirportInfo(iata: 'CTG', city: 'Carthagène', lat: 10.4424, lng: -75.5130),
  _AirportInfo(iata: 'MDE', city: 'Medellín', lat: 6.1645, lng: -75.4231),
  _AirportInfo(iata: 'LIM', city: 'Lima', lat: -12.0219, lng: -77.1143),
  _AirportInfo(iata: 'CUZ', city: 'Cuzco', lat: -13.5358, lng: -71.9389),
  _AirportInfo(iata: 'UIO', city: 'Quito', lat: -0.1292, lng: -78.3576),
  _AirportInfo(iata: 'GYE', city: 'Guayaquil', lat: -2.1577, lng: -79.8836),
  _AirportInfo(iata: 'LPB', city: 'La Paz', lat: -16.5133, lng: -68.1925),
  _AirportInfo(iata: 'MVD', city: 'Montevideo', lat: -34.8384, lng: -56.0308),
  _AirportInfo(iata: 'CCS', city: 'Caracas', lat: 10.6031, lng: -66.9906),

  // === AFRIQUE — Maghreb ===
  _AirportInfo(iata: 'CMN', city: 'Casablanca', lat: 33.3675, lng: -7.5898),
  _AirportInfo(iata: 'RAK', city: 'Marrakech', lat: 31.6069, lng: -8.0363),
  _AirportInfo(iata: 'AGA', city: 'Agadir', lat: 30.3811, lng: -9.5462),
  _AirportInfo(iata: 'FEZ', city: 'Fès', lat: 33.9273, lng: -4.9779),
  _AirportInfo(iata: 'TNG', city: 'Tanger', lat: 35.7269, lng: -5.9168),
  _AirportInfo(iata: 'RBA', city: 'Rabat', lat: 34.0515, lng: -6.7516),
  _AirportInfo(iata: 'OUD', city: 'Oujda', lat: 34.7872, lng: -1.9239),
  _AirportInfo(iata: 'TUN', city: 'Tunis', lat: 36.8510, lng: 10.2272),
  _AirportInfo(iata: 'DJE', city: 'Djerba', lat: 33.8750, lng: 10.7755),
  _AirportInfo(iata: 'NBE', city: 'Hammamet', lat: 36.0758, lng: 10.4385),
  _AirportInfo(iata: 'ALG', city: 'Alger', lat: 36.6911, lng: 3.2155),
  _AirportInfo(iata: 'ORN', city: 'Oran', lat: 35.6239, lng: -0.6213),
  _AirportInfo(iata: 'CAI', city: 'Le Caire', lat: 30.1219, lng: 31.4056),
  _AirportInfo(iata: 'HRG', city: 'Hurghada', lat: 27.1783, lng: 33.7994),
  _AirportInfo(iata: 'SSH', city: 'Charm el-Cheikh', lat: 27.9773, lng: 34.3950),
  _AirportInfo(iata: 'LXR', city: 'Louxor', lat: 25.6710, lng: 32.7066),
  _AirportInfo(iata: 'ASW', city: 'Assouan', lat: 23.9644, lng: 32.8200),

  // === AFRIQUE — Subsaharienne & océan Indien ===
  _AirportInfo(iata: 'JNB', city: 'Johannesburg', lat: -26.1392, lng: 28.2460),
  _AirportInfo(iata: 'CPT', city: 'Le Cap', lat: -33.9648, lng: 18.6017),
  _AirportInfo(iata: 'DUR', city: 'Durban', lat: -29.6144, lng: 31.1197),
  _AirportInfo(iata: 'NBO', city: 'Nairobi', lat: -1.3192, lng: 36.9278),
  _AirportInfo(iata: 'DAR', city: 'Dar es Salaam', lat: -6.8781, lng: 39.2026),
  _AirportInfo(iata: 'JRO', city: 'Kilimandjaro', lat: -3.4291, lng: 37.0745),
  _AirportInfo(iata: 'ZNZ', city: 'Zanzibar', lat: -6.2222, lng: 39.2249),
  _AirportInfo(iata: 'ADD', city: 'Addis-Abeba', lat: 8.9778, lng: 38.7993),
  _AirportInfo(iata: 'KGL', city: 'Kigali', lat: -1.9686, lng: 30.1395),
  _AirportInfo(iata: 'EBB', city: 'Entebbe', lat: 0.0424, lng: 32.4435),
  _AirportInfo(iata: 'DKR', city: 'Dakar', lat: 14.6708, lng: -17.0734),
  _AirportInfo(iata: 'ABJ', city: 'Abidjan', lat: 5.2614, lng: -3.9263),
  _AirportInfo(iata: 'LOS', city: 'Lagos', lat: 6.5774, lng: 3.3211),
  _AirportInfo(iata: 'ACC', city: 'Accra', lat: 5.6052, lng: -0.1668),
  _AirportInfo(iata: 'DLA', city: 'Douala', lat: 4.0061, lng: 9.7195),
  _AirportInfo(iata: 'NSI', city: 'Yaoundé', lat: 3.7226, lng: 11.5532),
  _AirportInfo(iata: 'LBV', city: 'Libreville', lat: 0.4585, lng: 9.4123),
  _AirportInfo(iata: 'BKO', city: 'Bamako', lat: 12.5335, lng: -7.9499),
  _AirportInfo(iata: 'MRU', city: 'Maurice', lat: -20.4302, lng: 57.6836),
  _AirportInfo(iata: 'SEZ', city: 'Mahé', lat: -4.6743, lng: 55.5218),
  _AirportInfo(iata: 'TNR', city: 'Antananarivo', lat: -18.7969, lng: 47.4788),
  _AirportInfo(iata: 'HRE', city: 'Harare', lat: -17.9319, lng: 31.0928),
  _AirportInfo(iata: 'WDH', city: 'Windhoek', lat: -22.4799, lng: 17.4709),

  // === OCÉANIE ===
  _AirportInfo(iata: 'SYD', city: 'Sydney', lat: -33.9399, lng: 151.1753),
  _AirportInfo(iata: 'MEL', city: 'Melbourne', lat: -37.6690, lng: 144.8410),
  _AirportInfo(iata: 'BNE', city: 'Brisbane', lat: -27.3942, lng: 153.1218),
  _AirportInfo(iata: 'PER', city: 'Perth', lat: -31.9404, lng: 115.9669),
  _AirportInfo(iata: 'ADL', city: 'Adelaide', lat: -34.9461, lng: 138.5306),
  _AirportInfo(iata: 'CNS', city: 'Cairns', lat: -16.8858, lng: 145.7549),
  _AirportInfo(iata: 'OOL', city: 'Gold Coast', lat: -28.1644, lng: 153.5050),
  _AirportInfo(iata: 'HBA', city: 'Hobart', lat: -42.8361, lng: 147.5103),
  _AirportInfo(iata: 'DRW', city: 'Darwin', lat: -12.4147, lng: 130.8767),
  _AirportInfo(iata: 'AKL', city: 'Auckland', lat: -37.0082, lng: 174.7850),
  _AirportInfo(iata: 'WLG', city: 'Wellington', lat: -41.3272, lng: 174.8053),
  _AirportInfo(iata: 'CHC', city: 'Christchurch', lat: -43.4894, lng: 172.5320),
  _AirportInfo(iata: 'ZQN', city: 'Queenstown', lat: -45.0211, lng: 168.7392),
  _AirportInfo(iata: 'NAN', city: 'Nadi', lat: -17.7553, lng: 177.4453),
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

/// Résultat d'une recherche d'aéroport : code IATA + ville + nom propre
/// optionnel. Format d'affichage recommandé : `displayLabel` ci-dessous.
typedef AirportSuggestion = ({String iata, String city, String? name});

/// Format d'affichage humain pour une suggestion. Exemples :
/// - "Paris Charles de Gaulle — CDG" (si name présent)
/// - "Manchester — MAN" (fallback si name absent)
String formatAirportLabel(AirportSuggestion s) {
  if (s.name != null && s.name!.isNotEmpty) {
    return '${s.city} ${s.name} — ${s.iata}';
  }
  return '${s.city} — ${s.iata}';
}

/// Recherche d'aéroports pour autocomplete UI : matche le code IATA exact,
/// puis IATA en préfixe, puis nom de ville OU nom propre de l'aéroport
/// (case+accent-insensible). Retourne au plus [limit] résultats.
///
/// L'ordre privilégie l'usage typique : "CDG" → CDG d'abord ; "Nice" → NCE ;
/// "Charles" → CDG (via le name) ; "Heathrow" → LHR (via le name).
List<AirportSuggestion> searchAirports(String query, {int limit = 8}) {
  final q = _normalizeAirportSearch(query);
  if (q.isEmpty) return const [];

  final iataExact = <_AirportInfo>[];
  final iataPrefix = <_AirportInfo>[];
  final textMatch = <_AirportInfo>[];
  for (final a in _airports) {
    final iata = a.iata.toLowerCase();
    final city = _normalizeAirportSearch(a.city);
    final name = a.name == null ? '' : _normalizeAirportSearch(a.name!);
    if (iata == q) {
      iataExact.add(a);
    } else if (iata.startsWith(q)) {
      iataPrefix.add(a);
    } else if (city.contains(q) || (name.isNotEmpty && name.contains(q))) {
      textMatch.add(a);
    }
  }
  textMatch.sort((a, b) => a.city.compareTo(b.city));
  final all = <_AirportInfo>[...iataExact, ...iataPrefix, ...textMatch];
  return all
      .take(limit)
      .map((a) => (iata: a.iata, city: a.city, name: a.name))
      .toList();
}

/// Lookup direct par code IATA. Retourne null si l'aéroport n'est pas dans
/// la table — l'UI doit alors afficher le code seul (fallback).
AirportSuggestion? lookupAirport(String iata) {
  final code = iata.trim().toUpperCase();
  if (code.length != 3) return null;
  for (final a in _airports) {
    if (a.iata == code) return (iata: a.iata, city: a.city, name: a.name);
  }
  return null;
}

String _normalizeAirportSearch(String s) {
  return s
      .toLowerCase()
      .trim()
      .replaceAll(RegExp(r'[éèêë]'), 'e')
      .replaceAll(RegExp(r'[àâä]'), 'a')
      .replaceAll(RegExp(r'[ïî]'), 'i')
      .replaceAll(RegExp(r'[ôö]'), 'o')
      .replaceAll(RegExp(r'[ûü]'), 'u')
      .replaceAll('ç', 'c');
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
