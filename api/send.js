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

    const rawRoom = body?.room || req.query.room || 'default';
    // Clean room name for topic
    const cleanRoom = rawRoom.replace(/[^a-zA-Z0-9_-]/g, '_') || 'default';
    const topic = `tampal_sync_${cleanRoom}`;

    const now = new Date().toISOString();
    const entry = {
      id: body?.id || `entry-${Date.now()}-${Math.random().toString(36).substring(2, 7)}`,
      device_id: body?.device_id || body?.deviceId || 'web-device',
      content_type: body?.content_type || body?.contentType || 'text',
      content: content,
      timestamp: body?.timestamp || now,
      created_at: body?.created_at || now,
      room: rawRoom,
    };

    // Publish to persistent global cloud broker
    try {
      await fetch(`https://ntfy.sh/${topic}`, {
        method: 'POST',
        headers: {
          'Title': 'Tampal Sync',
          'Priority': '3',
          'Tags': 'clipboard',
        },
        body: JSON.stringify(entry),
      });
    } catch (e) {
      console.error('[API Send] Error broadcasting to cloud broker:', e);
    }

    return res.status(200).json({ status: 'ok', entry });
  } catch (err) {
    return res.status(500).json({ error: err.message || 'Internal Error' });
  }
}
