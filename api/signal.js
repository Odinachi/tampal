/**
 * Tampal WebRTC Signaling API
 * 
 * A minimal ephemeral signaling relay for WebRTC SDP and ICE candidate exchange.
 * Sessions auto-expire after 5 minutes. No clipboard data ever passes through here —
 * only the WebRTC handshake metadata (SDP offer/answer and ICE candidates).
 * 
 * Routes:
 *   POST /api/signal?room=XXXX&type=offer       — store offer SDP
 *   POST /api/signal?room=XXXX&type=answer      — store answer SDP
 *   POST /api/signal?room=XXXX&type=ice&side=a  — append ICE candidate from caller
 *   POST /api/signal?room=XXXX&type=ice&side=b  — append ICE candidate from answerer
 *   GET  /api/signal?room=XXXX&type=offer       — fetch offer SDP
 *   GET  /api/signal?room=XXXX&type=answer      — fetch answer SDP
 *   GET  /api/signal?room=XXXX&type=ice&side=a  — fetch ICE candidates from caller
 *   GET  /api/signal?room=XXXX&type=ice&side=b  — fetch ICE candidates from answerer
 */

// In-memory store. Vercel serverless instances are ephemeral,
// but for LAN pairing this is reliable enough — both browsers pair within seconds.
const rooms = new Map();
const ROOM_TTL_MS = 5 * 60 * 1000; // 5 minutes

function getRoom(code) {
  const room = rooms.get(code);
  if (!room) return null;
  if (Date.now() - room.createdAt > ROOM_TTL_MS) {
    rooms.delete(code);
    return null;
  }
  return room;
}

function ensureRoom(code) {
  let room = getRoom(code);
  if (!room) {
    room = { createdAt: Date.now(), offer: null, answer: null, iceA: [], iceB: [] };
    rooms.set(code, room);
  }
  return room;
}

function setCors(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
}

export default async function handler(req, res) {
  setCors(res);

  if (req.method === 'OPTIONS') return res.status(200).end();

  const { room: code, type, side } = req.query;

  if (!code || !/^\d{4}$/.test(code)) {
    return res.status(400).json({ error: 'Invalid room code. Must be 4 digits.' });
  }

  if (!['offer', 'answer', 'ice'].includes(type)) {
    return res.status(400).json({ error: 'Invalid type. Must be offer, answer, or ice.' });
  }

  // ── POST: store signal data ──────────────────────────────────────────────
  if (req.method === 'POST') {
    const body = req.body ?? {};
    const room = ensureRoom(code);

    if (type === 'offer') {
      room.offer = body.sdp ?? null;
      return res.status(200).json({ ok: true });
    }

    if (type === 'answer') {
      room.answer = body.sdp ?? null;
      return res.status(200).json({ ok: true });
    }

    if (type === 'ice') {
      const candidate = body.candidate ?? null;
      if (!candidate) return res.status(400).json({ error: 'Missing candidate.' });
      if (side === 'a') room.iceA.push(candidate);
      else if (side === 'b') room.iceB.push(candidate);
      else return res.status(400).json({ error: 'side must be a or b' });
      return res.status(200).json({ ok: true });
    }
  }

  // ── GET: retrieve signal data ─────────────────────────────────────────────
  if (req.method === 'GET') {
    const room = getRoom(code);

    if (type === 'offer') {
      return res.status(200).json({ sdp: room?.offer ?? null });
    }

    if (type === 'answer') {
      return res.status(200).json({ sdp: room?.answer ?? null });
    }

    if (type === 'ice') {
      const candidates = side === 'a' ? (room?.iceA ?? []) : (room?.iceB ?? []);
      return res.status(200).json({ candidates });
    }
  }

  return res.status(405).json({ error: 'Method not allowed.' });
}
