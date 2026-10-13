# HANDCRIC — real app foundation

This replaces the old single-file mockup with a Vite + React app using real URL routes and a Supabase-backed 1v1 multiplayer foundation.

## Pages have real URLs

- `/` — Home
- `/play` — local practice mode
- `/rooms` — create/join online rooms
- `/room/ABC123` — a shareable room URL
- `/tournaments` — tournament hub (coming next; no fake tournaments)
- `/leaderboard` — verified-rankings empty state until results exist
- `/profile` — edit username and guest profile

`vercel.json` includes the SPA rewrite required so direct links such as `/room/ABC123` load after deployment.

## Run locally

1. Install Node.js LTS.
2. In this folder run `npm install`.
3. Copy `.env.example` to `.env` and fill in your Supabase project URL and publishable/anon key.
4. In Supabase, enable **Anonymous Sign-Ins** under Authentication providers.
5. Paste and run `supabase/schema.sql` in the Supabase SQL Editor.
6. Run `npm run dev`.

Without Supabase credentials, the UI works in preview mode, but it explicitly reports that shared multiplayer is not connected. No fake rooms or leaderboard entries are generated.

## Deployment to Vercel

Import this project/repository into Vercel, add `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` as project environment variables, then deploy. The Vercel rewrite keeps React Router URLs working on refresh.

## Honest feature status

- Real routes: implemented.
- Local 1–10 practice mode: implemented.
- Guest sessions, database profiles, room creation/joining, room presence updates, username invitations and server-side 1v1 turn resolution: implemented in the app and SQL setup, and require a configured Supabase project to work online.
- 2v2 and 1v1v1: room setup is visible, but live gameplay is deliberately blocked until their team/turn rules are implemented.
- Tournaments and verified competitive leaderboard: not implemented yet; no fake entries shown.

## Security notes

The client uses only the Supabase publishable/anon key. Never put a service-role key in `.env` or browser code. Match choices are written through a security-definer RPC and are not directly readable from the browser. Review the SQL/RLS policies for your project's needs before production use.
