// KnowHow · Supabase Edge Function: create-zoom-meeting
//
// Creates a scheduled Zoom meeting for a tutoring session and returns its join link.
// Zoom credentials live only here, as Edge Function secrets:
//   ZOOM_ACCOUNT_ID, ZOOM_CLIENT_ID, ZOOM_CLIENT_SECRET   (Zoom Server-to-Server OAuth app)
//   ZOOM_HOST_EMAIL (optional)  Zoom user who hosts the meetings; defaults to the app owner.
//
// The caller must be logged in to KnowHow, active, and a mentor (role mentor/both) or an admin.

import { createClient } from 'npm:@supabase/supabase-js@2.118.0';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

let cached: { token: string; expiresAt: number } | null = null;

async function zoomToken(): Promise<string> {
  if (cached && cached.expiresAt > Date.now() + 60_000) return cached.token;
  const accountId = Deno.env.get('ZOOM_ACCOUNT_ID');
  const clientId = Deno.env.get('ZOOM_CLIENT_ID');
  const clientSecret = Deno.env.get('ZOOM_CLIENT_SECRET');
  if (!accountId || !clientId || !clientSecret) {
    throw new Error('Zoom is not set up yet. Ask the admin to add the Zoom secrets in Supabase.');
  }
  const res = await fetch(
    `https://zoom.us/oauth/token?grant_type=account_credentials&account_id=${encodeURIComponent(accountId)}`,
    { method: 'POST', headers: { Authorization: 'Basic ' + btoa(`${clientId}:${clientSecret}`) } },
  );
  if (!res.ok) throw new Error(`Zoom rejected the KnowHow credentials (${res.status}). Check the Zoom secrets.`);
  const data = await res.json();
  cached = { token: data.access_token, expiresAt: Date.now() + Number(data.expires_in) * 1000 };
  return cached.token;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Use POST.' }, 405);

  try {
    // Act as the signed-in user so database rules apply to them.
    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    });
    const { data: userData } = await supabase.auth.getUser();
    if (!userData?.user) return json({ error: 'Please log in again.' }, 401);

    const { data: profile } = await supabase.rpc('my_profile');
    const isMentor = profile && (profile.role === 'mentor' || profile.role === 'both');
    if (!profile || profile.status !== 'active' || !(isMentor || profile.is_admin)) {
      return json({ error: 'Only mentors can create Zoom meetings.' }, 403);
    }

    const body = await req.json().catch(() => ({}));
    const topic = String(body.topic ?? 'KnowHow session').slice(0, 180);
    const agenda = String(body.agenda ?? '').slice(0, 1500);
    const start = new Date(String(body.start_time ?? ''));
    const duration = Math.round(Number(body.duration_min));
    if (Number.isNaN(start.getTime())) return json({ error: 'The session start time is not valid.' }, 400);
    if (!(duration >= 15 && duration <= 300)) return json({ error: 'Session length must be 15 to 300 minutes.' }, 400);

    const token = await zoomToken();
    const host = Deno.env.get('ZOOM_HOST_EMAIL') || 'me';
    const res = await fetch(`https://api.zoom.us/v2/users/${encodeURIComponent(host)}/meetings`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        topic,
        agenda,
        type: 2, // scheduled meeting
        start_time: start.toISOString(),
        duration,
        timezone: 'Asia/Manila',
        settings: {
          join_before_host: true, // mentor and learner can start without the KnowHow host account
          jbh_time: 0,
          waiting_room: false,
          mute_upon_entry: true,
          approval_type: 2,
          auto_recording: 'none',
        },
      }),
    });
    const meeting = await res.json().catch(() => ({}));
    if (!res.ok) return json({ error: meeting.message || `Zoom could not create the meeting (${res.status}).` }, 502);

    return json({ join_url: meeting.join_url, meeting_id: meeting.id, start_time: meeting.start_time });
  } catch (err) {
    return json({ error: err instanceof Error ? err.message : 'Something went wrong.' }, 500);
  }
});
