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

  // Tampal operates as a local Wi-Fi clipboard synchronization system.
  // For web clients, point your browser to your local Tampal Desktop hub (e.g. http://<desktop-ip>:42881)
  return res.status(200).json({
    status: 'local_network_required',
    message: 'Tampal sync operates over local Wi-Fi network. Connect your web client to your local Desktop Hub (http://<your-desktop-ip>:42881).'
  });
}
