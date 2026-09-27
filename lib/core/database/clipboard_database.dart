import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../constants/app_constants.dart';
import '../models/clipboard_entry.dart';

class ClipboardDatabase {
  static final ClipboardDatabase instance = ClipboardDatabase._init();
  static Database? _database;

  ClipboardDatabase._init();

  /// Initialize database factory based on desktop vs mobile platform
  static void initializePlatform() {
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB(AppConstants.databaseName);
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    initializePlatform();
    
    String dbPath;
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      final docDir = await getApplicationDocumentsDirectory();
      dbPath = join(docDir.path, filePath);
    } else {
      final defaultDatabasesPath = await getDatabasesPath();
      dbPath = join(defaultDatabasesPath, filePath);
    }

    return await openDatabase(
      dbPath,
      version: 1,
      onCreate: _createDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    // Exact schema requested:
    // CREATE TABLE clipboard_entries (
    //   id TEXT PRIMARY KEY,
    //   device_id TEXT NOT NULL,
    //   content_type TEXT NOT NULL,
    //   content TEXT NOT NULL,
    //   created_at TEXT NOT NULL
    // );
    // CREATE INDEX idx_created_at ON clipboard_entries(created_at);
    await db.execute('''
      CREATE TABLE clipboard_entries (
        id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        content_type TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_created_at ON clipboard_entries(created_at)
    ''');
  }

  /// Insert or update an entry. Returns true if inserted as new.
  Future<bool> insertEntry(ClipboardEntry entry, {int maxEntries = AppConstants.defaultRetentionLimit, int maxDays = AppConstants.defaultRetentionDays}) async {
    final db = await database;
    
    // Check if an identical content already exists to avoid exact duplicate spam,
    // or if the ID exists.
    final existingById = await db.query(
      'clipboard_entries',
      where: 'id = ?',
      whereArgs: [entry.id],
      limit: 1,
    );

    if (existingById.isNotEmpty) {
      return false;
    }

    // Insert new entry
    await db.insert(
      'clipboard_entries',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // Clean up according to retention policy
    await enforceRetention(maxEntries: maxEntries, maxDays: maxDays);

    return true;
  }

  /// Get list of clipboard entries in reverse chronological order
  Future<List<ClipboardEntry>> getEntries({int limit = 100, int offset = 0, String? searchQuery}) async {
    final db = await database;
    
    String? whereClause;
    List<dynamic>? whereArgs;

    if (searchQuery != null && searchQuery.trim().isNotEmpty) {
      whereClause = 'content LIKE ?';
      whereArgs = ['%${searchQuery.trim()}%'];
    }

    final maps = await db.query(
      'clipboard_entries',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );

    return maps.map((map) => ClipboardEntry.fromMap(map)).toList();
  }

  /// Get the most recent clipboard entry
  Future<ClipboardEntry?> getLatestEntry() async {
    final db = await database;
    final maps = await db.query(
      'clipboard_entries',
      orderBy: 'created_at DESC',
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return ClipboardEntry.fromMap(maps.first);
  }

  /// Get entries created since a specific timestamp (for sync handshake)
  Future<List<ClipboardEntry>> getEntriesSince(DateTime since) async {
    final db = await database;
    final maps = await db.query(
      'clipboard_entries',
      where: 'created_at > ?',
      whereArgs: [since.toIso8601String()],
      orderBy: 'created_at ASC',
    );

    return maps.map((map) => ClipboardEntry.fromMap(map)).toList();
  }

  /// Delete a single entry by ID
  Future<int> deleteEntry(String id) async {
    final db = await database;
    return await db.delete(
      'clipboard_entries',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Enforce retention limits: max items count and max age in days
  Future<void> enforceRetention({
    int maxEntries = AppConstants.defaultRetentionLimit,
    int maxDays = AppConstants.defaultRetentionDays,
  }) async {
    final db = await database;

    // 1. Delete items older than maxDays
    if (maxDays > 0) {
      final cutoffDate = DateTime.now().toUtc().subtract(Duration(days: maxDays));
      await db.delete(
        'clipboard_entries',
        where: 'created_at < ?',
        whereArgs: [cutoffDate.toIso8601String()],
      );
    }

    // 2. Delete items beyond the maxEntries count
    if (maxEntries > 0) {
      await db.execute('''
        DELETE FROM clipboard_entries
        WHERE id NOT IN (
          SELECT id FROM clipboard_entries
          ORDER BY created_at DESC
          LIMIT ?
        )
      ''', [maxEntries]);
    }
  }

  /// Clear all entries from history
  Future<void> clearAll() async {
    final db = await database;
    await db.delete('clipboard_entries');
  }

  /// Close database connection
  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}
