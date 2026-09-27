import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/clipsync_providers.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late TextEditingController _nameController;
  late TextEditingController _portController;
  late TextEditingController _webPortController;
  late int _retentionLimit;
  late int _retentionDays;
  late bool _autoSync;
  late bool _webEnabled;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsServiceProvider);
    _nameController = TextEditingController(text: settings.deviceName);
    _portController = TextEditingController(text: settings.serverPort.toString());
    _webPortController = TextEditingController(text: settings.webPort.toString());
    _retentionLimit = settings.retentionLimit;
    _retentionDays = settings.retentionDays;
    _autoSync = settings.autoSync;
    _webEnabled = settings.webEnabled;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _portController.dispose();
    _webPortController.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() async {
    final settings = ref.read(settingsServiceProvider);
    final db = ref.read(clipboardDatabaseProvider);
    final webServer = ref.read(webServerProvider);

    await settings.setDeviceName(_nameController.text.trim());
    final port = int.tryParse(_portController.text.trim());
    if (port != null && port > 1024 && port < 65535) {
      await settings.setServerPort(port);
    }
    final webPort = int.tryParse(_webPortController.text.trim());
    if (webPort != null && webPort > 1024 && webPort < 65535) {
      await settings.setWebPort(webPort);
    }
    await settings.setRetentionLimit(_retentionLimit);
    await settings.setRetentionDays(_retentionDays);
    await settings.setAutoSync(_autoSync);
    await settings.setWebEnabled(_webEnabled);

    // Update WebServer if toggled
    if (_webEnabled && !webServer.isRunning) {
      await webServer.start(port: webPort);
    } else if (!_webEnabled && webServer.isRunning) {
      await webServer.stop();
    }

    // Enforce retention right away
    await db.enforceRetention(maxEntries: _retentionLimit, maxDays: _retentionDays);
    ref.read(clipboardHistoryProvider.notifier).loadEntries();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppTheme.successColor,
          content: Text('Settings saved successfully'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsServiceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(
            onPressed: _saveSettings,
            child: const Text('Save', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.accentColor)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Device identity section
          _buildSectionHeader('Device Identity'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Device Friendly Name',
                      hintText: 'e.g. Work MacBook, Galaxy S24',
                      prefixIcon: Icon(Icons.badge_rounded, color: Color(0xFF94A3B8)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Device ID', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
                      Flexible(
                        child: Text(
                          settings.deviceId,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFFCBD5E1)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Retention limits section
          _buildSectionHeader('History Retention Policy'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Automatically prune older entries to preserve storage and performance.',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  const Text('Maximum Entries to Keep:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [50, 100, 250, 500].map((limit) {
                      final selected = _retentionLimit == limit;
                      return ChoiceChip(
                        label: Text('$limit items'),
                        selected: selected,
                        selectedColor: AppTheme.primaryColor,
                        onSelected: (val) {
                          if (val) setState(() => _retentionLimit = limit);
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  const Text('Keep Entries For Up To:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      {'days': 3, 'label': '3 Days'},
                      {'days': 7, 'label': '7 Days (Default)'},
                      {'days': 14, 'label': '14 Days'},
                      {'days': 30, 'label': '30 Days'},
                      {'days': 0, 'label': 'Forever'},
                    ].map((item) {
                      final days = item['days'] as int;
                      final label = item['label'] as String;
                      final selected = _retentionDays == days;
                      return ChoiceChip(
                        label: Text(label),
                        selected: selected,
                        selectedColor: AppTheme.primaryColor,
                        onSelected: (val) {
                          if (val) setState(() => _retentionDays = days);
                        },
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Network & Sync section
          _buildSectionHeader('Network & Sync Settings'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Automatic Background Sync', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                      'Automatically push and receive clipboard changes when paired.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                    ),
                    value: _autoSync,
                    activeThumbColor: AppTheme.accentColor,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (val) => setState(() => _autoSync = val),
                  ),
                  const Divider(color: Color(0xFF334155)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'TCP Listening Port',
                      hintText: '42880',
                      prefixIcon: Icon(Icons.router_rounded, color: Color(0xFF94A3B8)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Web dashboard section
          _buildSectionHeader('Local Web Portal'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Enable Web Dashboard', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                      'Allows viewing and pushing clipboard items from any web browser on local Wi-Fi.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                    ),
                    value: _webEnabled,
                    activeThumbColor: AppTheme.accentColor,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (val) => setState(() => _webEnabled = val),
                  ),
                  if (_webEnabled) ...[
                    const Divider(color: Color(0xFF334155)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _webPortController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Web Server HTTP Port',
                        hintText: '42881',
                        prefixIcon: Icon(Icons.language_rounded, color: Color(0xFF94A3B8)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Database maintenance
          _buildSectionHeader('Storage Maintenance'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.cleaning_services_rounded, color: AppTheme.primaryLight),
                  title: const Text('Apply Retention Policy Now'),
                  subtitle: const Text('Prune entries exceeding limits', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final db = ref.read(clipboardDatabaseProvider);
                    await db.enforceRetention(maxEntries: _retentionLimit, maxDays: _retentionDays);
                    ref.read(clipboardHistoryProvider.notifier).loadEntries();
                    if (!mounted) return;
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Database pruned according to retention rules.')),
                    );
                  },
                ),
                const Divider(height: 1, color: Color(0xFF334155)),
                ListTile(
                  leading: const Icon(Icons.delete_forever_rounded, color: AppTheme.errorColor),
                  title: const Text('Clear All Clipboard History', style: TextStyle(color: AppTheme.errorColor)),
                  subtitle: const Text('Permanently remove all local entries', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: AppTheme.darkCard,
                        title: const Text('Clear All Entries?'),
                        content: const Text('This will delete all saved clipboard entries from this device.'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel'),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorColor),
                            onPressed: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              Navigator.pop(ctx);
                              await ref.read(clipboardHistoryProvider.notifier).clearHistory();
                              if (!mounted) return;
                              messenger.showSnackBar(
                                const SnackBar(content: Text('All clipboard history cleared.')),
                              );
                            },
                            child: const Text('Delete All'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.8,
          color: Color(0xFF64748B),
        ),
      ),
    );
  }
}
