# Maps And Network Images Runtime Surface Audit

Date: 2026-05-13

Scope: offline audit of Maps SDK, external map URLs, and network image/photo
surfaces. No app code was changed and no live API call was made.

## Summary

These surfaces are mostly valid product/runtime behavior, not hidden batch API
jobs. The main distinction is:

- `GoogleMap` renders automatically when the user opens the map screen and can
  generate Maps SDK network usage.
- Google Maps URLs are user-initiated deeplinks via buttons/taps.
- Network images load automatically when widgets render, usually from Google
  Place Photo URLs or Supabase avatar URLs.

No Apple Maps, Waze, `geo:` scheme, `Image.network`, or non-Google navigation
URL surfaces were found in this pass.

## Surfaces

| File / lines | Surface | Trigger path / user action | External network usage? | Automatic or user-initiated | Cost / billing risk | UX risk if blocked | Recommendation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `lib/features/map/screens/trip_map_screen.dart:6`, `:219` | `google_maps_flutter` `GoogleMap` widget | User opens trip map route. Entry points include `lib/core/router/app_router.dart:120` and buttons/tabs in `lib/features/planning/screens/planning_screen.dart:1107`, `lib/features/trips/screens/trip_detail_screen.dart:923`. | Yes. SDK can fetch map tiles and Google Maps runtime resources. | Automatic after user opens map screen. | Medium. Potential Maps SDK billing/traffic, but bounded by explicit map screen usage. | High. Blocking removes the primary map experience. | Leave as runtime behavior for now. Add widget-test fakes/static placeholder for tests. Consider future `LiveApiFamily.mapsSdk` or runtime config if automated tests ever instantiate this screen. |
| `lib/features/map/screens/trip_map_screen.dart:332`, `:334`, `:336` | Google Maps directions URL | In map activity details, user taps directions from current location. | Yes, external Google Maps app/browser may open and use network/location. | User-initiated. | Low to medium. Deeplink itself is not a server API call from Lunao, but hands off to Google Maps. | Medium. Blocking hurts navigation utility. | Leave as user action. Keep behind button/tap. Add URL launcher mock tests if behavior is tested. |
| `lib/features/map/screens/trip_map_screen.dart:372`, `:373`, `:375` | Google Maps search URL | In map hotel/activity details, user taps open in Maps. | Yes, external Google Maps app/browser. | User-initiated. | Low. | Medium. | Leave as user action. No guard needed unless automated tests launch URLs. |
| `lib/features/planning/widgets/suggestion_detail_sheet.dart:96`, `:107`, `:113`, `:315` | Google Maps search URL with optional `query_place_id` | User opens suggestion detail sheet, taps Maps button. Uses resolved Places `placeId` if available. | Yes, external Google Maps app/browser. | User-initiated. | Low. | Medium. | Leave as user action. Keep `url_launcher` mocked in tests. |
| `lib/features/planning/widgets/activity_detail_sheet.dart:106`, `:120`, `:123`, `:132`, `:137`, `:140`, `:424` | Google Maps search URL for activity | User taps map/open button in activity detail sheet. Chooses place id, coordinates, accommodation address, or fuzzy text fallback. | Yes, external Google Maps app/browser. | User-initiated. | Low. | Medium. | Leave as user action. Add tests/fakes around URL construction if refactored later. |
| `lib/features/planning/widgets/activity_detail_sheet.dart:440`, `:443`, `:447` | Google Maps directions URL | User taps navigation button in activity detail sheet when coordinates exist. | Yes, external Google Maps app/browser. | User-initiated. | Low. | Medium. | Leave as user action. |
| `lib/features/planning/widgets/activity_detail_sheet.dart:895`, `:898`, `:902` | Google Maps search URL from details/reviews section | User taps secondary map text button when coordinates exist. | Yes. | User-initiated. | Low. | Low to medium. | Leave as user action. Could consolidate with `_openInMaps` later, but no live-risk fix needed now. |
| `lib/features/planning/screens/planning_screen.dart:3032`, `:3038`, `:3042` | Google Maps directions URL for logistics | User taps logistics itinerary action for an activity with coordinates. | Yes, external Google Maps app/browser. | User-initiated. | Low. | Medium. | Leave as user action. |
| `lib/features/planning/screens/planning_screen.dart:3727`, `:3784`, `:3787`, `:3912` | Google Maps directions URL for transport pair | User taps transport directions; may include origin from device location or coordinates/text fallback. | Yes, external Google Maps app/browser. May use device location before building URL. | User-initiated. | Low for URL; device location is a separate guarded family to watch. | Medium to high for transport UX. | Leave as user action. Ensure tests mock location and URL launcher. Consider future external-link helper for deterministic URL tests. |
| `lib/features/planning/services/places_service.dart:413`, `:424`, `:463` | Google Place Photo URL construction | A guarded Places `findInfo()` live/cache path returns photo URLs like `/maps/api/place/photo`. | URL construction itself no; later image render yes. | Automatic once Places info is fetched or read from cache. | Medium. Place Photo fetches can be Google-billed when image widgets load. | Low if placeholders shown, medium for visual richness. | Do not block URL construction now. Future: strip/suppress photo URLs when `allowNetworkImages=false` in tests or deterministic modes. |
| `lib/features/planning/providers/planning_provider.dart:299`, `:309`, `:314`, `:342`, `:343` | Cached activity photo URL propagation | Provider reconstructs `PlacePhoto` from `trip_activities.photo_urls` or writes new URLs after Places cache lookup. | Not directly; it feeds image widgets. | Automatic provider work when planning/activity UI asks for place info. | Medium when rendered later. | Low to medium. | Leave cache behavior. Add tests/fakes for `PlacePhoto` data and avoid real image rendering in tests. |
| `lib/features/planning/widgets/suggestion_detail_sheet.dart:345`, `:358`, `:359` | `CachedNetworkImage` for suggestion photos | Suggestion detail sheet renders photo page view after `PlaceInfo` future completes. | Yes. Loads remote Google Place Photo URLs. | Automatic after user opens sheet; not a separate tap per image. | Medium. Google photo fetch traffic/billing possible. | Low to medium; placeholders/errors already exist. | Add cache/placeholder/timeout policy. Future guard or fake image provider for tests. |
| `lib/features/planning/screens/planning_screen.dart:2122`, `:2127`, `:2147`, `:2148` | `CachedNetworkImage` thumbnail on suggestion card | Suggestion cards render in planning screen after `_placeInfoFor(s)` resolves. | Yes if a photo URL exists. | Automatic while planning UI is visible. | Medium; potentially many thumbnails. | Low to medium; fallback icon exists. | Highest image-runtime priority: cap/consolidate thumbnails, ensure cache sizing, and provide test fakes. Consider future `allowNetworkImages` gate for deterministic tests. |
| `lib/features/planning/widgets/alternatives_sheet.dart:250`, `:404`, `:405` | `CachedNetworkImage` thumbnail for alternatives | Alternatives sheet fetches/uses place info and renders first photo. | Yes if photo URL exists. | Automatic after user opens alternatives sheet. | Medium but bounded by sheet usage. | Low; fallback exists. | Leave runtime behavior. Add timeout/cache/fake image tests if this sheet gets widget coverage. |
| `lib/features/planning/widgets/activity_detail_sheet.dart:523`, `:535`, `:540`, `:541` | `CachedNetworkImage` activity photo carousel | Activity detail sheet renders photo carousel from `activityPhotosProvider`. | Yes. Loads remote Google Place Photo URLs or cached photo URLs. | Automatic after user opens activity detail sheet. | Medium. | Medium; this is prominent hero imagery. | Leave runtime behavior. Add placeholder/timeout/cache policy; future `allowNetworkImages` gate for tests or low-data mode. |
| `lib/features/profile/screens/profile_screen.dart:54`, `:230`, `:530` | Supabase avatar public URL + `NetworkImage` | Profile screen renders `avatar_url` from profile; upload flow stores a Supabase Storage public URL. | Yes, image load from Supabase Storage/public CDN. | Automatic when profile screen/avatar widget renders. Upload itself is separate Supabase behavior. | Low to medium Supabase bandwidth/storage egress. | Medium; blocking removes profile avatar. | Leave as product runtime behavior. Add placeholder/error handling and widget tests with fake/empty avatar URL. Future `allowNetworkImages` could suppress remote avatars in tests. |

## Classification Notes

- No `Image.network` usages were found.
- No Apple Maps, Waze, or `geo:` URL surfaces were found.
- `CachedNetworkImage` is already used for most Places photos, which gives
  local caching behavior, but no repo-level network-image guard is wired into
  widgets yet.
- `LiveApiFamily.networkImages` exists in `lib/config/live_api_guards.dart`,
  but this audit does not recommend wiring it immediately into production UI.
  The safer next step is test seams/fakes plus a clear runtime policy.

## Recommendations

1. Leave external map URLs as user-initiated runtime behavior.
2. Keep `GoogleMap` as runtime behavior, but avoid pumping the real map screen
   in ordinary widget tests without a fake/static placeholder.
3. Add URL construction tests only if the map deeplink code is refactored into
   helpers; mock `url_launcher` in widget tests.
4. Treat suggestion-card thumbnails as the highest network-image risk because
   they can load in lists automatically.
5. For network images, prefer cache/placeholder/timeout and fake image loading
   in tests before adding a user-visible guard.
6. Consider a future `allowNetworkImages` gate for deterministic tests,
   screenshots, or low-data/offline modes, but do not block production imagery
   blindly.

## Remaining Risks

- Maps SDK can still generate network usage when the user opens the map screen.
- Google Place Photo URLs can be loaded automatically by visible widgets.
- Supabase avatar URLs can be loaded automatically by the profile UI.
- Runtime image loading is not centrally governed by `LiveApiGuards` today.
