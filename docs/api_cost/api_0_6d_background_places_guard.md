# API-0.6d — Background Places Call Guards

## Date
2026-05-13

## Executive Summary

API-0.6a/b/c guarded **autocomplete-while-typing** calls. API-0.6d guards **background** Google Places calls that happen on mount, button tap, or save — not triggered by keystrokes, but still capable of freezing the UI or consuming quota unnecessarily.

---

## 1. Background Call Sites (before guards)

| # | File | Function | Trigger | Blocks UI | Timeout | Try/Catch | Local Skip |
|---|------|----------|---------|-----------|---------|-----------|------------|
| 1 | `trip_edit_sheet.dart` | `_detectInitialKind` | On mount | No (sheet already open) | ❌ | ❌ | ✅ via `autocompleteDestinations` |
| 2 | `trip_detail_screen.dart` | `_detectDestinationKind` | On mount | No | ❌ | ✅ | ✅ via `autocompleteDestinations` |
| 3 | `planning_screen.dart` | `_openSuggestionMenu` | Button tap | **Yes** (before dialog) | ❌ | ❌ | ✅ via `autocompleteDestinations` |
| 4 | `document_form_sheet.dart` | `_geocodeHotelAddress` | Save | **Yes** (blocks `_save()`) | ❌ | ❌ | ❌ (arbitrary address) |
| 5 | `document_form_sheet.dart` | `_resolveTransportEndpoint` | Save | **Yes** (blocks `_save()`) | ❌ | ❌ | Partial (IATA-first already local) |
| 6 | `document_form_sheet.dart` | `_geocodeTransportDocument` | Save | **Yes** (blocks `_save()`) | ❌ | ❌ | Partial |

---

## 2. Guards Applied

### 2.1 `_detectInitialKind` (`trip_edit_sheet.dart`)

**Before:**
```dart
final results = await places.autocompleteDestinations(dest);
// ...
final code = await places.getCountryCodeFromPlaceId(pick.placeId);
```

**After:**
```dart
final results = await places.autocompleteDestinations(dest)
    .timeout(const Duration(seconds: 5));
// ...
final code = await places.getCountryCodeFromPlaceId(pick.placeId)
    .timeout(const Duration(seconds: 5));
```

- **Timeout:** 5s on both `autocompleteDestinations` and `getCountryCodeFromPlaceId`
- **Try/catch:** Added around both calls; logs `[api-0.6d] _detectInitialKind timeout/error...`
- **Stale/disposed:** `mounted` check preserved
- **Local skip:** `autocompleteDestinations` already Lunao-first (API-0.6a/b/c); `getCountryCodeFromPlaceId` already resolves synthetic `lunao:*` IDs locally

### 2.2 `_detectDestinationKind` (`trip_detail_screen.dart`)

**Before:**
```dart
try {
  final results = await places.autocompleteDestinations(dest);
} catch (_) {
  // silent
}
```

**After:**
```dart
try {
  final results = await places.autocompleteDestinations(dest)
      .timeout(const Duration(seconds: 5));
} catch (e) {
  developer.log('[api-0.6d] _detectDestinationKind error...', name: 'api_guard');
}
```

- **Timeout:** 5s added
- **Try/catch:** Already present; enhanced with debug log
- **Local skip:** Lunao-first via `autocompleteDestinations`

### 2.3 `_openSuggestionMenu` (`planning_screen.dart`)

**Before:**
```dart
final results = await places.autocompleteDestinations(trip.destination);
```

**After:**
```dart
try {
  final results = await places.autocompleteDestinations(trip.destination)
      .timeout(const Duration(seconds: 5));
} catch (e) {
  developer.log('[api-0.6d] _openSuggestionMenu timeout/error...', name: 'api_guard');
  // En cas d'erreur, on laisse passer (kind reste null → pas de blocage).
}
```

- **Timeout:** 5s added
- **Try/catch:** Added; on error, `kind` stays null → dialog is skipped, user can proceed
- **Stale/disposed:** `context.mounted` check preserved
- **Local skip:** Lunao-first via `autocompleteDestinations`

### 2.4 `_geocodeHotelAddress` (`document_form_sheet.dart`)

**Before:**
```dart
final geo = await ref.read(geocodingServiceProvider)
    .geocode(newAddress, regionHint: regionHint);
```

**After:**
```dart
try {
  final geo = await ref.read(geocodingServiceProvider)
      .geocode(newAddress, regionHint: regionHint)
      .timeout(const Duration(seconds: 5));
} catch (e) {
  developer.log('[api-0.6d] _geocodeHotelAddress timeout/error...', name: 'api_guard');
  meta['geocoding_failed'] = true;
}
```

- **Timeout:** 5s added
- **Try/catch:** Added; on error, sets `geocoding_failed = true` (existing UX badge)
- **Local skip:** ❌ Not applicable — hotel addresses are arbitrary text

### 2.5 `_resolveTransportEndpoint` (`document_form_sheet.dart`)

**Before:**
```dart
final resolved = await cache.resolveCoords(...);
// ...
final geo = await ref.read(geocodingServiceProvider)
    .geocode(query, regionHint: regionHint);
```

**After:**
```dart
try {
  final resolved = await cache.resolveCoords(...)
      .timeout(const Duration(seconds: 5));
  // ...
} catch (e) {
  developer.log('[api-0.6d] resolveCoords timeout/error...', name: 'api_guard');
  // Fall through to geocode fallback.
}
// ...
try {
  final geo = await ref.read(geocodingServiceProvider)
      .geocode(query, regionHint: regionHint)
      .timeout(const Duration(seconds: 5));
} catch (e) {
  developer.log('[api-0.6d] _resolveTransportEndpoint geocode timeout/error...', name: 'api_guard');
  meta[failKey] = true;
}
```

- **Timeout:** 5s on both `resolveCoords` (Place Details) and `geocode`
- **Try/catch:** Added around both calls
- **Local skip:** IATA-first path (lines 708-729) already resolves ~366 airports locally without any Google call

### 2.6 `_geocodeTransportDocument` (`document_form_sheet.dart`)

**Before:**
```dart
final trip = await ref.read(tripByIdProvider(_tripId!).future);
await _resolveTransportEndpoint(... from ...);
await _resolveTransportEndpoint(... to ...);
```

**After:**
```dart
try {
  final trip = await ref.read(tripByIdProvider(_tripId!).future)
      .timeout(const Duration(seconds: 5));
} catch (e) { /* log */ }
try {
  await _resolveTransportEndpoint(... from ...)
      .timeout(const Duration(seconds: 5));
} catch (e) {
  meta['from_geocoding_failed'] = true;
}
try {
  await _resolveTransportEndpoint(... to ...)
      .timeout(const Duration(seconds: 5));
} catch (e) {
  meta['to_geocoding_failed'] = true;
}
```

- **Timeout:** 5s on trip lookup and each endpoint resolution
- **Try/catch:** Added around all three async calls
- **Local skip:** Inherits from `_resolveTransportEndpoint` (IATA-first)

---

## 3. Guard Matrix (after API-0.6d)

| Call Site | Timeout | Try/Catch | Mounted/Context Check | Debug Log | Local Skip |
|-----------|---------|-----------|----------------------|-----------|------------|
| `_detectInitialKind` | ✅ 5s | ✅ | ✅ `mounted` | ✅ | ✅ Lunao |
| `_detectDestinationKind` | ✅ 5s | ✅ | ✅ `mounted` | ✅ | ✅ Lunao |
| `_openSuggestionMenu` | ✅ 5s | ✅ | ✅ `context.mounted` | ✅ | ✅ Lunao |
| `_geocodeHotelAddress` | ✅ 5s | ✅ | N/A (save flow) | ✅ | ❌ |
| `_resolveTransportEndpoint` | ✅ 5s | ✅ | N/A (save flow) | ✅ | ✅ IATA-first |
| `_geocodeTransportDocument` | ✅ 5s | ✅ | N/A (save flow) | ✅ | ✅ IATA-first |

---

## 4. Remaining Risks (documented, not fixed)

### 4.1 No timeout on `http.get` itself
The underlying `http.get` calls in `PlacesService._get` and `GeocodingService.geocode` do not have a socket-level timeout. The 5s `.timeout()` on the Future is a **cooperative** timeout — if the HTTP call hangs at the OS level, Dart will throw `TimeoutException` after 5s and cancel the Future, but the underlying socket may still linger. In practice, this is sufficient for mobile apps.

### 4.2 `trip_map_screen.dart` geocoding batch
`lib/features/map/screens/trip_map_screen.dart` batches geocoding for activities without coordinates on mount. This was **not** in the original inventory and was not modified. It has its own `_geocodingInProgress` flag but no timeout on individual `geocode` calls. Risk: low (batch runs once on map open, user is not blocked elsewhere).

### 4.3 Planning pipeline geocoding
`lib/features/planning/screens/planning_screen.dart` passes `geocoder` to `gatherCandidatesForTrip`, `runCoPilotPlacesFirst`, and `runAutoPlacesFirst`. These are **user-initiated** (button tap) and already have 60s timeouts at the pipeline level. Individual `geocode` calls inside the pipeline are not individually timed out. Risk: acceptable (user tapped a button, spinner is expected).

### 4.4 `findCityCoords` and `findInfo`
`PlacesService.findCityCoords` and `findInfo` are used by POI planning logic. Per constraints, POI planning logic was **not touched**.

---

## 5. Test Status

| Test Suite | Result |
|------------|--------|
| `test/planning/autocomplete_guard_test.dart` | ✅ 15 tests pass |
| `test/planning/places_service_autocomplete_guard_test.dart` | ✅ 28 tests pass |
| `test/core/widgets/city_autocomplete_field_test.dart` | ✅ 9 tests pass |
| **Total** | **52/52 pass** |

No new widget tests were added for the background call sites because:
- The guards are thin wrappers (`.timeout()` + `try/catch`) around existing service methods
- The service methods are already covered by offline unit tests
- Meaningful widget tests for on-mount background calls would require heavy mocking of `StatefulWidget` lifecycle + Riverpod providers + `mounted` state, which is out of scope for a minimal guard patch.

---

## 6. Files Modified

| # | File | Lines Changed |
|---|------|---------------|
| 1 | `lib/features/trips/widgets/trip_edit_sheet.dart` | `_detectInitialKind` + `_detectInitialKind` getCountryCode guard |
| 2 | `lib/features/trips/screens/trip_detail_screen.dart` | `_detectDestinationKind` timeout + log; added `developer` import |
| 3 | `lib/features/planning/screens/planning_screen.dart` | `_openSuggestionMenu` timeout + try/catch |
| 4 | `lib/features/wallet/widgets/document_form_sheet.dart` | `_geocodeHotelAddress`, `_resolveTransportEndpoint`, `_geocodeTransportDocument` guards |
