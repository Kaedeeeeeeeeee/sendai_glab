# ADR-0011: Supabase auth + session telemetry (Phase 10 POC)

- **Status**: Accepted
- **Date**: 2026-04-24
- **Branch**: `feat/supabase-auth-poc`
- **Phase**: 10

## Context

SDG-Lab is heading for App Store release with a research-data-collection
backend requirement. This POC validates the end-to-end pipeline
`iPad login → Supabase auth.users → public.sessions table INSERT on every
app launch / foreground`, as the first brick of a larger telemetry plan.

Explicit non-goals for this PR (deferred):

- Privacy consent screen + Privacy Policy URL (before App Store submission)
- Offline / queued event retry
- Research IRB paperwork
- Additional telemetry surfaces (quest, drilling, behaviour JSONB)

## Decisions

### 1. Supabase over Railway / Firebase

Supabase wins on three axes for our research use case:

- **Postgres RLS** — research reads are SQL-friendly; Dashboard gives
  researchers direct query access.
- **Native iOS flow for Sign in with Apple** — `signInWithIdToken`
  accepts Apple's identityToken directly, no web OAuth, no Services ID /
  JWT secret to manage.
- **Zero custom backend** — PostgREST auto-generates a REST endpoint
  per table. "More endpoints" = "more tables + RLS policies", not
  "more code".

Railway rejected: general PaaS, would require us to build a backend
service, auth verification, and DB schema migrations from scratch.
Firebase rejected: Firestore's NoSQL aggregation is clumsy for
research analytics.

Region: Tokyo (`ap-northeast-1`) per user requirement.

### 2. Anon key is committed

The project URL + anon key live in
`Resources/Supabase/SupabaseConfig.plist` — committed to the repo.
Rationale: the anon key is architecturally designed to be public;
data protection comes from Postgres Row Level Security on
`public.sessions` (`INSERT` requires `auth.uid() = user_id`). Not
committing forces every contributor / CI agent to manage secrets
manually for no security gain.

Service-role key is NEVER committed, and never lives on the client.
Researchers who need aggregate queries use the Dashboard or a server-
side script, not the iOS client.

### 3. Sign-in completely blocks gameplay

Research data requires an identified session. An anonymous "play
without signing in" mode would produce rows that can't be tied back
to the `auth.users` table, defeating the purpose of the collection.

Implementation: `ContentView` wraps `RootView` in a `fullScreenCover`
bound to `authStore.currentUserId == nil`. The cover has no dismiss
affordance — it closes itself when the store flips to a non-nil user
after Sign in with Apple completes. Debug skip is NOT provided.

### 4. Session-log payload: started_at + os_version + locale

`app_version` and `device_model` were considered but dropped from the
POC per user call — research questions don't need them yet. Schema
(`supabase/migrations/20260424000000_sessions.sql`) keeps those columns
off; adding them later is a forward migration with defaults.

### 5. Protocols live in SDGCore, impls in SDGPlatform

`AuthProviding` and `TelemetryWriting` are in SDGCore so
`AppEnvironment` (SDGCore) can carry `any AuthProviding` /
`any TelemetryWriting` without SDGCore importing supabase-swift.
Production `AuthService` / `TelemetryService` live in SDGPlatform,
which is the only place that sees the Supabase SDK types. Gameplay
and UI layers stay SDK-agnostic — the dependency direction ADR-0001
reserves for the three layers is preserved.

### 6. Auth events in SDGGameplay (not SDGCore)

Follows the existing convention set by DisasterEvents / VehicleEvents
/ QuestEvents / etc.: events live in the module that publishes them.
`AuthStore` (in Gameplay) publishes `UserSignedIn` / `UserSignedOut`;
`SendaiGLabApp` publishes `AppSessionStarted`. App-level code already
imports SDGGameplay, so the App-side scene-phase publisher has access.

### 7. scenePhase === .active as the session trigger

Observed in `SendaiGLabApp.body` via `.onChange(of: scenePhase)`. The
`.active` transition fires for both cold launch
(`.background → .inactive → .active`) and foreground-from-background —
one hook covers both "first session" and "returning session" without
a separate `applicationDidBecomeActive` callback.

Edge case: on cold launch, `.active` fires BEFORE `restoreOnLaunch`
completes, so the first `AppSessionStarted` arrives with
`currentUserId == nil` and is dropped. To recover that first session,
`SessionLogBridge` also subscribes to `UserSignedIn` and logs a row
when the restore (or fresh sign-in) completes. This can produce TWO
rows on a second launch (one from `.active`, one from the restore),
which is acceptable — dedupe-at-query-time is cheap for research use.

## Implementation map

```
SendaiGLabApp (@main, SendaiGLab/)
  │   init: SupabaseConfig.loadOrCrash() → SupabaseClient →
  │         AuthService + TelemetryService → AppEnvironment
  │   .onChange(scenePhase → .active): publish AppSessionStarted
  ▼
ContentView (SendaiGLab/)
  │   @State AuthStore (eventBus, authService from env)
  │   .task { authStore.intent(.restoreOnLaunch) }
  │   .fullScreenCover(isPresented: currentUserId == nil) {
  │       SignInView(store: authStore)
  │   }
  ▼
RootView (SDGUI/)
  │   @Environment(\.authStore) — reads the same store
  │   bootstrap(): start SessionLogBridge(eventBus, authStore, env.telemetry)

Gameplay layer:
  AuthStore (SDGGameplay/Auth/)       — @Observable @MainActor
  SessionLogBridge (SDGGameplay/Auth/) — subscribes AppSessionStarted + UserSignedIn
  AuthEvents (SDGGameplay/Auth/)      — UserSignedIn, UserSignedOut, AppSessionStarted

Platform layer:
  AuthService (SDGPlatform/Auth/)             — wraps SupabaseClient.auth
  TelemetryService (SDGPlatform/Telemetry/)   — wraps SupabaseClient.from("sessions")
  SupabaseConfig (SDGPlatform/Auth/)          — plist loader
  AppleNonce (SDGPlatform/Auth/)              — SecRandomCopyBytes + SHA256

Core layer:
  AuthProviding, TelemetryWriting (SDGCore/Auth/)  — protocols
  NoopAuthProvider, NoopTelemetryWriter             — preview/test defaults
  AppEnvironment                                    — now carries both protocols
```

## Manual Dashboard step

Supabase's CLI `config push` is all-or-nothing for the auth block,
which would clobber cloud defaults we don't want to touch. The Apple
provider is configured in the Dashboard:

1. Go to https://supabase.com/dashboard/project/jrqmoxbzbjxrellvsvwn/auth/providers
2. Enable "Apple"
3. Client IDs: `jp.tohoku-gakuin.fshera.sendai-glab`
4. Leave secret fields empty — native iOS flow only uses JWKS verification
5. Save

Documented again in the setup checklist at the bottom of the PR
description.

## Verification

Unit:

- `AuthStoreTests` (7 tests) — intent handling, publish/no-publish on
  success/failure, UI error reporting
- `SessionLogBridgeTests` (4 tests) — subscription count, session log
  with and without a signed-in user, UserSignedIn catch-up row

Integration (manual, device or simulator):

1. Fresh install → `SignInView` fullScreenCover
2. Tap "Sign in with Apple" → iPadOS native sheet → complete
3. Dashboard → Authentication → Users shows the new user
4. Dashboard → Table Editor → `sessions` shows 1 row (now + 1 from the
   UserSignedIn catch-up for the just-signed-in user)
5. Kill app → reopen → cover DOES NOT appear (session restored) →
   `sessions` gets one new row from `.active`
6. Home key → re-enter → another row from `.active`

## Follow-ups (not in this PR)

- Privacy consent screen + App Store Connect privacy nutrition labels
- Offline queue for session events (currently dropped on network error)
- Configure Apple provider via a scoped CLI mechanism if one emerges
- Additional telemetry tables (quest, drilling, behaviour JSONB)
- Research ethics / IRB paperwork before real subjects touch the app
