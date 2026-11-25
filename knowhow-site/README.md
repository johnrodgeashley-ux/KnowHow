# KnowHow

Peer tutoring and mentoring for Mapúa Malayan Colleges Laguna (MMCL) students. Students find mentors who aced a subject, book sessions with a Zoom link, and rate them afterwards.

## What's here

| Path | What it is |
|---|---|
| `index.html` | The whole app in one file (React 18 + htm, Tailwind compiled in). Open it in a browser or deploy it as a static site. |
| `supabase/schema.sql` | Database setup for Supabase: tables, row-level security, admin functions, storage buckets, subject list. |
| `assets/logo.png`, `assets/mark.png` | KnowHow logo and mascot with transparent backgrounds. |

## Current state

- **Accounts use Supabase Auth**: sign up (with email confirmation), log in, log out, forgot password, and "Set a new password" from the reset email. Profiles come from `public.profiles`; admins are users with `is_admin = true`.
- **All app data lives in Supabase**: mentor profiles, sessions, reviews, posts, likes, saved mentors, notifications, credentials, videos, reports and the activity log. Photos, covers and videos go to Storage (`avatars`, `videos`), credentials to the private `credentials` bucket.
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

## Automatic Zoom meetings

`supabase/functions/create-zoom-meeting/index.ts` is a Supabase Edge Function. When a mentor taps **Create Zoom meeting automatically**, it creates a scheduled Zoom meeting at the session time and confirms the session with the join link. Zoom credentials stay in Supabase secrets, never in the website.

1. **Zoom:** marketplace.zoom.us → Develop → Build App → **Server-to-Server OAuth**. Add the scope to create meetings (`meeting:write:meeting:admin`, or `meeting:write:admin` on older apps), then **Activate**. Copy the Account ID, Client ID and Client Secret.
2. **Supabase → Edge Functions → Secrets:** add `ZOOM_ACCOUNT_ID`, `ZOOM_CLIENT_ID`, `ZOOM_CLIENT_SECRET` (optional `ZOOM_HOST_EMAIL`).
3. **Supabase → Edge Functions → Deploy a new function → Via editor:** name it `create-zoom-meeting`, paste `index.ts`, deploy.

Mentors can still paste their own Zoom link instead.

## Sign-up rules

- Gmail addresses only (`@gmail.com`), plus an MMCL student number.
- Admin is a flag on `profiles.is_admin`, set with SQL. Users can't give it to themselves.
