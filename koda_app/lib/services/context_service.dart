import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Manages Koda's context files (soul, koda, user, skills, memory) and session logs.
class ContextService {
  static const _contextFiles = ['soul.md', 'koda.md', 'user.md', 'skills.md', 'memory.md'];
  static const _assetPrefix = 'assets/context/';

  late Directory _contextDir;
  late Directory _logsDir;
  String? _currentSessionLogPath;
  File? _previousLogFile;

  /// Call once on app start. Copies defaults, extracts memory from last session.
  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    _contextDir = Directory('${appDir.path}/context');
    _logsDir = Directory('${appDir.path}/logs');
    await _contextDir.create(recursive: true);
    await _logsDir.create(recursive: true);
    await _copyDefaults();
  }

  /// Copies bundled asset templates to device storage on first run.
  Future<void> _copyDefaults() async {
    for (final name in _contextFiles) {
      final file = File('${_contextDir.path}/$name');
      if (!await file.exists()) {
        final content = await rootBundle.loadString('$_assetPrefix$name');
        await file.writeAsString(content);
      }
    }
  }

  /// Reads all 5 context files and assembles the full system prompt.
  Future<String> buildSystemPrompt() async {
    final buffer = StringBuffer();
    for (final name in _contextFiles) {
      final file = File('${_contextDir.path}/$name');
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          buffer.writeln('---');
          buffer.writeln(content.trim());
          buffer.writeln();
        }
      }
    }
    return buffer.toString();
  }

  /// Starts a new session log file for the current Brain Mode session.
  Future<void> startSession() async {
    _previousLogFile = await _lastSessionLog();
    
    final now = DateTime.now();
    final name =
        '${now.year}-${_p(now.month)}-${_p(now.day)}-${_p(now.hour)}-${_p(now.minute)}.md';
    _currentSessionLogPath = '${_logsDir.path}/$name';
    await File(_currentSessionLogPath!).writeAsString(
      '# Koda Session Log — $name\n\n',
    );
  }

  /// Appends a timestamped entry to the current session log.
  Future<void> appendSessionLog(String entry) async {
    if (_currentSessionLogPath == null) return;
    final time = _timeStamp();
    await File(_currentSessionLogPath!).writeAsString(
      '[$time] $entry\n',
      mode: FileMode.append,
    );
  }

  /// On startup: reads the most recent session log and uses LLM to extract
  /// high-value memories, appending new ones to memory.md.
  /// Returns the prompt to send to the LLM for extraction.
  Future<String?> buildMemoryExtractionPrompt() async {
    if (_previousLogFile == null) return null;
    final logContent = await _previousLogFile!.readAsString();
    if (logContent.trim().isEmpty || logContent.split('\n').length < 4) return null;

    final memFile = File('${_contextDir.path}/memory.md');
    final existingMemory = await memFile.exists() ? await memFile.readAsString() : '';

    return '''
Read this Koda session log and extract ONLY high-value persistent facts worth remembering long-term.
High-value: user name, preferences, home layout facts, important discoveries, emotional reactions, user face, family, locations, and anything worth keeping
Low-value (skip): navigation steps, routine movements, explore loop steps, generic greetings.

Respond with ONLY a plain list of new facts (one per line, no markdown formatting).
Do NOT repeat facts already in the existing memory.
If there are no new high-value facts, respond with exactly: NONE

EXISTING MEMORY:
$existingMemory

SESSION LOG:
$logContent
''';
  }

  /// Appends extracted memory entries to memory.md.
  Future<void> appendMemory(String extractedText) async {
    if (extractedText.trim() == 'NONE' || extractedText.trim().isEmpty) return;
    final memFile = File('${_contextDir.path}/memory.md');
    final date = _dateStamp();
    await memFile.writeAsString(
      '\n<!-- Extracted $date -->\n$extractedText\n',
      mode: FileMode.append,
    );
  }

  /// Returns the last N interactions from the previous session log to jumpstart conversation context
  Future<String> getRecentHistoryString(int count) async {
    if (_previousLogFile == null) return '';
    try {
      final lines = await _previousLogFile!.readAsLines();
      final history = lines
          .where((l) => l.contains('[user]') || l.contains('[koda]'))
          .toList();
      final recent = history.length <= count ? history : history.sublist(history.length - count);
      
      return recent.map((l) {
        // Log format: "[12:34:56] [user] message"
        final idx = l.indexOf('] [');
        if (idx != -1) {
          var str = l.substring(idx + 2); // "[user] message"
          return str.replaceFirst('[user] ', 'USER: ').replaceFirst('[koda] ', 'KODA: ');
        }
        return l;
      }).join('\n');
    } catch (_) {
      return '';
    }
  }

  // ── Settings editor helpers ───────────────────────────────────────────────

  Future<List<String>> getMemories() async {
    final memFile = File('${_contextDir.path}/memory.md');
    if (!await memFile.exists()) return [];
    final content = await memFile.readAsString();
    
    return content
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('<!--'))
        .toList();
  }

  Future<String> readFile(String name) async {
    final file = File('${_contextDir.path}/$name');
    return await file.exists() ? await file.readAsString() : '';
  }

  Future<void> writeFile(String name, String content) async {
    await File('${_contextDir.path}/$name').writeAsString(content);
  }

  List<String> get contextFileNames => List.unmodifiable(_contextFiles);

  // ── Private helpers ───────────────────────────────────────────────────────

  Future<File?> _lastSessionLog() async {
    final files = await _logsDir
        .list()
        .where((e) => e is File && e.path.endsWith('.md'))
        .map((e) => e as File)
        .toList();
    if (files.isEmpty) return null;
    files.sort((a, b) => b.path.compareTo(a.path));
    return files.first;
  }

  String _p(int n) => n.toString().padLeft(2, '0');
  String _timeStamp() {
    final n = DateTime.now();
    return '${_p(n.hour)}:${_p(n.minute)}:${_p(n.second)}';
  }
  String _dateStamp() {
    final n = DateTime.now();
    return '${n.year}-${_p(n.month)}-${_p(n.day)}';
  }
}
