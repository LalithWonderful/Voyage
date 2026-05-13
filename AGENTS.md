# AGENTS.md

## Repo Context

Lunao is a Flutter/Supabase travel planning app. The repo contains product UI,
planning services, POI tooling, Supabase SQL, and offline tests. Treat live APIs
as expensive or stateful unless a guard explicitly says otherwise.

## No Live By Default

Never run live API calls during ordinary agent work. Do not use credentials,
service-role keys, or `--dart-define=ALLOW_LIVE_*` flags unless the user
explicitly asks for a controlled live run.

Live API families include:

- Google Places
- Google Geocoding
- Google Routes
- Gemini/AI
- Overpass
- Supabase tooling, verification, import/write, and RPC
- Currency API

Any new live call must be protected by the existing `LiveApiGuards` mechanism
or by a documented provider/runtime exception. Tests, scripts, tools, and
diagnostics must fail fast by default before network/client creation.

Runtime exceptions must be intentional and documented. For example, a product
provider may opt into a user-facing runtime capability, while tests should
override that provider or instantiate the service with default closed guards.

## Safe Workflow

- Preserve unrelated WIP. The worktree may already be dirty.
- Stage only task-related files.
- Make one atomic commit per task when asked to commit.
- Do not run global `dart format .`.
- Prefer targeted formatting on touched Dart files only.
- Prefer the smallest relevant offline tests.
- Prefer targeted `flutter analyze <files>` over full analyze when unrelated
  repo diagnostics already exist.
- Do not run commands that require live credentials or live opt-in flags.

## POI Rules

- POI tests must not hide a live Google Places dependency.
- Prefer deterministic fixtures and fake clients.
- Supabase POI imports, verification, reads, writes, and RPC-like tooling must
  be guarded.
- Overpass extraction must be guarded and skipped/blocked by default.
- Keep POI fixture generation reproducible; avoid adding network dependency to
  mapping, validation, or SQL contract tests.

## Definition Of Done

Final summaries should include:

- Changed files
- Tests run
- Analyze result, or why targeted analyze was used
- Confirmation that no live API call was made
- Confirmation that no unrelated WIP was staged
- Remaining risks or intentionally live runtime surfaces
