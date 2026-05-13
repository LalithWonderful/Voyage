# API-0.6e — Autocomplete Empty-State Message

## Date
2026-05-13

## Executive Summary

API-0.6a/b/c/d guarded and localised autocomplete calls. When Places API is unavailable and the user types an unknown destination (e.g. "tokyo"), the widget returns zero suggestions and the dropdown stays empty. Users may think the app is broken.

API-0.6e adds a **non-blocking empty-state message** that appears when a valid query (≥ 4 characters) completes with zero results.

---

## Problem Statement

| Scenario | Before API-0.6e | User Perception |
|----------|-----------------|-----------------|
| Type "tok" | Nothing happens | Expected (too short) |
| Type "tokyo" with no API key | Dropdown stays empty | "App is broken / frozen" |
| Type "lisbo" | "Lisbonne" appears | ✅ Works perfectly |

The empty dropdown for "tokyo" is indistinguishable from a frozen UI.

---

## Solution

### UI Change

When `_suggestions.isEmpty` and the query length is ≥ 4 and loading is finished, a small info box appears below the text field:

> ℹ️ Aucun résultat trouvé. Tu peux continuer avec cette destination.

**Design constraints:**
- Same container style as the suggestion dropdown (surface color, border, radius)
- No scary error wording
- Does not block typing or submission
- Disappears as soon as the user types another character
- Hidden for queries < 4 characters

### Implementation

**File:** `lib/core/widgets/city_autocomplete_field.dart`

**New state variable:**
```dart
bool _showEmptyState = false;
```

**Logic:**
| Event | `_showEmptyState` |
|-------|-------------------|
| User types (onChanged) | `false` |
| Query < 4 chars | `false` |
| Search starts (loading) | `false` |
| Search completes with results | `false` |
| Search completes with 0 results, query ≥ 4 | `true` |
| User selects a suggestion | `false` |
| User clears the field | `false` |

**Build UI:**
```dart
if (_suggestions.isNotEmpty)
  // ... existing suggestion dropdown
else if (_showEmptyState)
  Container(
    // info icon + "Aucun résultat trouvé. Tu peux continuer avec cette destination."
  )
```

---

## Behavior Matrix

| Query | Lunao Match | API Available | Suggestions | Empty State Shown |
|-------|-------------|---------------|-------------|-------------------|
| "tok" | — | — | None | ❌ (too short) |
| "lisbo" | ✅ Lisbon | — | Lisbonne | ❌ |
| "fran" | ✅ France | — | France | ❌ |
| "tokyo" | ❌ | ❌ | None | ✅ |
| "tokyo" | ❌ | ✅ | Google results | ❌ |

---

## Tests

**File:** `test/core/widgets/city_autocomplete_field_test.dart`

| Test | Result |
|------|--------|
| Short query "tok" does not show empty-state message | ✅ |
| Unknown long query "tokyo" with no API key shows empty-state message | ✅ |
| Lunao match "lisbo" shows normal suggestion, NOT empty state | ✅ |
| Free-text submission after empty-state (acceptAnyDestination=true) | ✅ |

All existing tests continue to pass (56/56 total).

---

## Files Modified

| # | File | Change |
|---|------|--------|
| 1 | `lib/core/widgets/city_autocomplete_field.dart` | Added `_showEmptyState`, empty-state UI, lifecycle management |
| 2 | `test/core/widgets/city_autocomplete_field_test.dart` | 4 new widget tests |
