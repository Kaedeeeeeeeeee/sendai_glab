-- Session telemetry: one row per app launch / foreground.
-- Authenticated users can INSERT/SELECT only their own rows (RLS).
-- No UPDATE/DELETE policies — the table is append-only per device.

create table public.sessions (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    started_at timestamptz not null default now(),
    os_version text,
    locale text,
    created_at timestamptz not null default now()
);

create index sessions_user_id_started_at_idx
    on public.sessions(user_id, started_at desc);

alter table public.sessions enable row level security;

create policy "users insert own sessions"
    on public.sessions for insert to authenticated
    with check (auth.uid() = user_id);

create policy "users read own sessions"
    on public.sessions for select to authenticated
    using (auth.uid() = user_id);
