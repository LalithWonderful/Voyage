# Places / POI Refactor Checklist

Date: 2026-05-14

## P0.2 Resolver `train_station` Lunao-First

- [x] Create offline editorial transport hub seed data for the seven current
  POI pilot cities: London, Amsterdam, Paris, Rome, Barcelona, Lisbon, and
  Marrakech.
- [x] Include only major traveler-useful railway, bus, airport-link, and
  intermodal hubs. This is intentionally not an exhaustive metro/bus stop
  database.
- [x] Add an offline resolver that searches by city plus hub name, alias, IATA
  code where relevant, and returns `null` when unresolved.
- [x] Add offline tests for exact lookup, alias lookup, unknown city, unknown
  hub, priority, type filtering, airport-link codes, and absence of Google IDs.
- [ ] Wire runtime train-station / bus-station endpoint resolution to the
  offline resolver before any Google Places or Geocoding fallback.
- [ ] Ensure unresolved train/bus hubs are surfaced cleanly instead of silently
  calling Google.

## Files Added

- `lib/features/transport/data/transport_hubs_seed.dart`
- `lib/features/transport/services/offline_transport_hub_resolver.dart`
- `test/features/transport/offline_transport_hub_resolver_test.dart`

## Notes

The seed is hand-curated editorial data inspired by stable public transport
concepts such as `railway=station`, `public_transport=station`,
`amenity=bus_station`, and major airport rail/bus transfer hubs. This task made
no live API calls and did not automate calls to Google, Supabase, Overpass, OSM,
or any external HTTP source.

P0.2 is not complete until the runtime flow uses this resolver as the first
lookup path for `train_station` and bus-station resolution.
