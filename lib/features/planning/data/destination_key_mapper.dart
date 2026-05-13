/// Mapping minimal Trip.destination → POI destination_key.
/// Seules les destinations avec POI coverage sont listées.
class DestinationKeyMapper {
  static const _mappings = <String, String>{
    // Lisbon
    'lisbon': 'lisbon',
    'lisbonne': 'lisbon',
    'lisboa': 'lisbon',
    // Paris
    'paris': 'paris',
    'paris france': 'paris',
    // Rome
    'rome': 'rome',
    'roma': 'rome',
    'rome italy': 'rome',
    'rome italie': 'rome',
    'roma italia': 'rome',
    // Barcelona
    'barcelona': 'barcelona',
    'barcelone': 'barcelona',
    'barca': 'barcelona',
    'barcelona spain': 'barcelona',
    'barcelona espagne': 'barcelona',
  };

  /// Retourne le destinationKey POI, ou null si la destination
  /// n'est pas couverte par la base POI.
  static String? map(String destination) {
    final normalized = destination.trim().toLowerCase();
    return _mappings[normalized];
  }
}
