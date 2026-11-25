# KnowHow

Peer tutoring and mentoring for Mapúa Malayan Colleges Laguna (MMCL) students. Students find mentors who aced a subject, book sessions, meet in a video call right on the site, chat, and rate mentors afterwards.

## What's here

| Path | What it is |
|---|---|
| `index.html` | The whole app in one file (React 18 + htm, Tailwind compiled in). Open it in a browser or deploy it as a static site. |
| `supabase/schema.sql` | Database setup for Supabase: tables, row-level security, admin functions, storage buckets, subject list. |
| `assets/logo.png`, `assets/mark.png` | KnowHow logo and mascot with transparent backgrounds. |
| `manifest.webmanifest`, `sw.js`, `assets/app-icon-*.png` | Makes KnowHow installable as an app (home screen / desktop) and lets it open offline. |
| `supabase/functions/turn-credentials/` | Optional relay server for video calls on strict networks (see below). |

## Current state

- **Accounts use Supabase Auth**: sign up (with email confirmation), log in, log out, forgot password, and "Set a new password" from the reset email. Profiles come from `public.profiles`; admins are users with `is_admin = true`.
- **All app data lives in Supabase**: mentor profiles, sessions, reviews, posts, likes, saved mentors, notifications, credentials, videos, reports and the activity log. Photos, covers and videos go to Storage (`avatars`, `videos`), credentials to the private `credentials` bucket.
- **Fixed roles**: people sign up as a student or a mentor and can't switch. Only an admin can change someone's role (Admin Panel → account type). Students book and message mentors; mentors set up a mentor profile, confirm sessions and reply.
- **Video calls on the site**: confirmed sessions get a **Join call** button. The call has video, audio, screen sharing, chat with emojis and emoji reactions. It uses WebRTC (browser to browser) with Supabase Realtime for signaling, so there is no Zoom account or extra server. Very strict networks (some school or office Wi-Fi) can block the video part; chat still works.
- **Video calls also have** a shared whiteboard (both people draw, live) and recording (saves a video file to the device of whoever records; the other person sees a "recording" badge).
- **Messages**: private student ↔ mentor chat with live delivery, typing dots, "Active now", "Seen" with time, emoji reactions on any message, and an emoji picker.
- **Credentials**: mentors' certificates and grades show as a gallery on their profile with a full viewer (zoom, PDF, download). Verified files are viewable by any logged-in user; pending ones stay private to the mentor and admins.
- **Group sessions** (up to 8 students): mentors can open a group class that students join from their dashboard or the mentor's profile, and any student can add classmates (by Gmail) to a session they're in. Each student pays the mentor's full rate and can leave their own review. The video call becomes a grid for everyone (screen sharer shown large); whiteboard, chat and recording include the whole group.
- **No double-booking**: a mentor (or student) can't have two sessions at the same time; the booking form greys out taken times.
- **Reschedule**: the mentor or the student who booked suggests a new time and the other accepts or declines (mentors move group classes directly).
- **Payments (tracking only)**: mentors add their GCash number on their profile; students see how much to pay, tap "I've paid" with an optional reference, and the mentor confirms. KnowHow never handles money.
- **Backup Zoom link**: mentors save their Zoom link once; it's attached to sessions they confirm.
- **Reminders & calendar**: a banner (and a phone/computer notification if allowed) 15 minutes before a session, plus Add to Google Calendar / .ics with a 15-minute alarm.
- **Comments** on study feed posts, with notifications to the post's author.
- **Admin manages subjects**: Admin Panel → Subjects to add, rename, change category, mark critical, or remove subjects.
- **Dark mode** (account menu; follows the phone/computer setting by default) and **installable app** (account menu → Install the app, or the banner on the dashboard).
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

No setup is needed beyond running the SQL updates (or a fresh `schema.sql`). Realtime must be on in Supabase (it is by default).

Calls connect browser to browser. Some networks (school Wi-Fi, mobile data with carrier NAT) block that; the call then stays on "Connecting…" and shows a tip. To make calls work everywhere, add a relay (TURN) server:

1. Get TURN credentials, for example **Cloudflare Realtime TURN** (free tier) or **Metered.ca**.
2. **Supabase → Edge Functions → Deploy a new function → Via editor**: name it `turn-credentials` and paste `supabase/functions/turn-credentials/index.ts`.
3. **Edge Functions → Secrets**: add `CF_TURN_KEY_ID` + `CF_TURN_API_TOKEN` (Cloudflare), or `METERED_DOMAIN` + `METERED_API_KEY` (Metered), or `TURN_URLS` + `TURN_USERNAME` + `TURN_CREDENTIAL` (any TURN server).

The website picks it up automatically; the keys never reach the browser.

`supabase/functions/create-zoom-meeting/` is from the older Zoom flow and is optional now. Mentors can still paste a backup Zoom link when confirming.

## Email (sign-up and password reset)

Supabase's built-in email is only for testing and allows very few emails per hour, so sign-ups and password resets start failing once classmates join. Connect a free email service once:

1. Sign up at **brevo.com** (free plan). Under **Senders**, add and verify the Gmail you want emails to come from.
2. In Brevo open **SMTP & API → SMTP**. Copy the **SMTP server** (`smtp-relay.brevo.com`), **port** (`587`), **login**, and create an **SMTP key**.
3. In **Supabase → Authentication → Emails → SMTP Settings**, turn on **Custom SMTP** and fill in: sender email (the verified Gmail), sender name `KnowHow`, host, port, username (the Brevo login) and password (the SMTP key). Save.
4. In **Supabase → Authentication → Rate Limits**, raise **emails per hour** (for example to 100).

Resend works the same way if you prefer it.

## Sign-up rules

- Gmail addresses only (`@gmail.com`), plus an MMCL student number.
- Admin is a flag on `profiles.is_admin`, set with SQL. Users can't give it to themselves.
