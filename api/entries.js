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

  const rawRoom = req.query.room || 'default';
  const cleanRoom = rawRoom.replace(/[^a-zA-Z0-9_-]/g, '_') || 'default';
  const topic = `tampal_sync_${cleanRoom}`;

  // GET /api/entries?room=...&q=...
  if (req.method === 'GET') {
    const q = (req.query.q || '').toLowerCase().trim();
    const entriesMap = new Map();

    try {
      const response = await fetch(`https://ntfy.sh/${topic}/json?poll=1&since=24h`);
      if (response.ok) {
        const text = await response.text();
        const lines = text.split('\n').filter(Boolean);

        for (const line of lines) {
          try {
            const data = JSON.parse(line);
            if (data.event === 'message' && data.message) {
              const parsedEntry = JSON.parse(data.message);
              if (parsedEntry && parsedEntry.id && parsedEntry.content) {
                // Keep the most recent version of this entry ID
                entriesMap.set(parsedEntry.id, parsedEntry);
              }
            }
          } catch (_) {
            // Ignore non-json lines
          }
        }
      }
    } catch (e) {
      console.error('[API Entries] Error fetching from cloud broker:', e);
    }

    let result = Array.from(entriesMap.values());

    // Sort newest first
    result.sort((a, b) => {
      const timeA = new Date(a.timestamp || a.created_at || 0).getTime();
      const timeB = new Date(b.timestamp || b.created_at || 0).getTime();
      return timeB - timeA;
    });

    // Apply search filter if present
    if (q) {
      result = result.filter((e) => e.content && e.content.toLowerCase().includes(q));
    }

    return res.status(200).json(result);
  }

  return res.status(405).json({ error: 'Method Not Allowed' });
}
