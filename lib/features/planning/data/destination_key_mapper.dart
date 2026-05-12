/// Mapping minimal Trip.destination → POI destination_key.
/// Seules les destinations avec POI coverage sont listées.
class DestinationKeyMapper {
  static const _mappings = <String, String>{
    'lisbon': 'lisbon',
    'lisbonne': 'lisbon',
    'lisboa': 'lisbon',
  };

  /// Retourne le destinationKey POI, ou null si la destination
  /// n'est pas couverte par la base POI.
  static String? map(String destination) {
    final normalized = destination.trim().toLowerCase();
    return _mappings[normalized];
  }
}
