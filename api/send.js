// In-memory global store for serverless instances (shared per container)
globalThis._tampalStore = globalThis._tampalStore || new Map();

function getRoomEntries(room = 'default') {
  if (!globalThis._tampalStore.has(room)) {
    globalThis._tampalStore.set(room, []);
  }
  return globalThis._tampalStore.get(room);
}

function setCors(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
}

export default async function handler(req, res) {
  setCors(res);

  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }

  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method Not Allowed' });
  }

  try {
    let body = req.body;
    if (typeof body === 'string') {
      try {
        body = JSON.parse(body);
      } catch (_) {}
    }

    const content = (body?.content || '').trim();
    if (!content) {
      return res.status(400).json({ error: 'Content cannot be empty' });
    }

    const room = body?.room || req.query.room || 'default';
    const entries = getRoomEntries(room);

    const now = new Date().toISOString();
    const entry = {
      id: body?.id || `web-${Date.now()}-${Math.random().toString(36).substring(2, 7)}`,
      device_id: body?.device_id || body?.deviceId || 'web-browser',
      content_type: body?.content_type || body?.contentType || 'text',
      content: content,
      timestamp: body?.timestamp || now,
      created_at: body?.created_at || now,
    };

    // Prepend new entry
    entries.unshift(entry);

    // Keep max 100 entries per room
    if (entries.length > 100) {
      entries.length = 100;
    }
    globalThis._tampalStore.set(room, entries);

    return res.status(200).json({ status: 'ok', entry });
  } catch (err) {
    return res.status(500).json({ error: err.message || 'Internal Error' });
  }
}
