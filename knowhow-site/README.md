# KnowHow

Peer tutoring and mentoring for Mapúa Malayan Colleges Laguna (MMCL) students. Students find mentors who aced a subject, book sessions, meet in a video call right on the site, chat, and rate mentors afterwards.

## What's here

| Path | What it is |
|---|---|
| `index.html` | The whole app in one file (React 18 + htm, Tailwind compiled in). Open it in a browser or deploy it as a static site. |
| `supabase/schema.sql` | Database setup for Supabase: tables, row-level security, admin functions, storage buckets, subject list. |
| `assets/logo.png`, `assets/mark.png` | KnowHow logo and mascot with transparent backgrounds. |

## Current state

- **Accounts use Supabase Auth**: sign up (with email confirmation), log in, log out, forgot password, and "Set a new password" from the reset email. Profiles come from `public.profiles`; admins are users with `is_admin = true`.
- **All app data lives in Supabase**: mentor profiles, sessions, reviews, posts, likes, saved mentors, notifications, credentials, videos, reports and the activity log. Photos, covers and videos go to Storage (`avatars`, `videos`), credentials to the private `credentials` bucket.
- **Fixed roles**: people sign up as a student or a mentor and can't switch. Only an admin can change someone's role (Admin Panel → account type). Students book and message mentors; mentors set up a mentor profile, confirm sessions and reply.
- **Video calls on the site**: confirmed sessions get a **Join call** button. The call has video, audio, screen sharing, chat with emojis and emoji reactions. It uses WebRTC (browser to browser) with Supabase Realtime for signaling, so there is no Zoom account or extra server. Very strict networks (some school or office Wi-Fi) can block the video part; chat still works.
- **Messages**: private student ↔ mentor chat with an emoji picker and live updates (Supabase Realtime on `public.messages`).
- **Database updates** live in `supabase/`. On an existing project run each `update-*.sql` once, in order. `schema.sql` already includes them for a fresh project.
- Supabase project URL and publishable key are set at the top of the auth section in `index.html` (`SB_URL`, `SB_KEY`).

## Deploy (Vercel)

```bash
npm install -g vercel
vercel --prod
```

Or import this repository on vercel.com. It's a static site, so no build settings are needed.

## Supabase setup

1. Create a project in **Southeast Asia (Singapore)**.
2. **SQL Editor** → paste `supabase/schema.sql` → **Run** (on an empty project).
3. Sign up the admin with a Gmail address, then run the "MAKE ADMIN" line at the bottom of the SQL file.
4. **Authentication → URL Configuration**: set the Site URL and a Redirect URL to the deployed link.
5. **Authentication → Emails → SMTP Settings**: connect a mail service (for example Resend or Brevo) so password-reset emails reach students.

Only the Project URL and the anon/publishable key go in the website. Never commit the `service_role` key.

## Video calls

No setup is needed beyond running `update-5.sql` (or a fresh `schema.sql`). Realtime must be on in Supabase (it is by default). Calls use Google's public STUN servers; if many users can't connect video on campus Wi-Fi, add a TURN server to `ICE_SERVERS` in `index.html`.

`supabase/functions/create-zoom-meeting/` is from the older Zoom flow and is optional now. Mentors can still paste a backup Zoom link when confirming.

## Sign-up rules

- Gmail addresses only (`@gmail.com`), plus an MMCL student number.
- Admin is a flag on `profiles.is_admin`, set with SQL. Users can't give it to themselves.
