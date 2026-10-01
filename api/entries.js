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

  const room = req.query.room || 'default';
  let entries = getRoomEntries(room);

  // DELETE /api/entries?id=xyz
  if (req.method === 'DELETE' || req.query.action === 'delete') {
    const id = req.query.id || req.body?.id;
    if (id) {
      entries = entries.filter((e) => e.id !== id);
      globalThis._tampalStore.set(room, entries);
      return res.status(200).json({ status: 'deleted', id });
    }
  }

  // GET /api/entries?q=...
  if (req.method === 'GET') {
    const q = (req.query.q || '').toLowerCase().trim();
    let result = entries;
    if (q) {
      result = result.where ? result : result.filter((e) => e.content && e.content.toLowerCase().includes(q));
    }
    return res.status(200).json(result);
  }

  return res.status(405).json({ error: 'Method Not Allowed' });
}
