import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

// ─── TTS Service ──────────────────────────────────────────────────────────────
class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _speaking = false;

  Future<void> init({String? savedVoiceName}) async {
    // Force Google TTS engine (not Samsung's or other OEM robot voice)
    try {
      await _tts.setEngine('com.google.android.tts');
    } catch (_) {
      // fall back to default engine if Google TTS not installed
    }

    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);

    // Apply saved voice or auto-select the best available
    if (savedVoiceName != null && savedVoiceName.isNotEmpty) {
      await _applyVoiceByName(savedVoiceName);
    } else {
      await _selectBestVoice();
    }

    _tts.setStartHandler(() => _speaking = true);
    _tts.setCompletionHandler(() => _speaking = false);
    _tts.setCancelHandler(() => _speaking = false);
  }

  /// Returns all English voices available on device (from Google TTS engine).
  Future<List<Map<String, String>>> getEnglishVoices() async {
    try {
      final voices = await _tts.getVoices as List?;
      if (voices == null) return [];
      return voices
          .cast<Map>()
          .where((v) => (v['locale'] as String? ?? '').toLowerCase().startsWith('en'))
          .map((v) => {
                'name': (v['name'] as String? ?? ''),
                'locale': (v['locale'] as String? ?? ''),
              })
          .where((v) => v['name']!.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _applyVoiceByName(String name) async {
    try {
      final voices = await _tts.getVoices as List?;
      if (voices == null) return;
      final match = voices.cast<Map>().firstWhere(
            (v) => (v['name'] as String? ?? '') == name,
            orElse: () => {},
          );
      if (match.isNotEmpty) {
        await _tts.setVoice({'name': match['name'], 'locale': match['locale']});
      } else {
        await _selectBestVoice();
      }
    } catch (_) {
      await _selectBestVoice();
    }
  }

  /// Tries to pick the highest-quality en-US voice from the Google engine.
  /// Preference order: network (WaveNet/neural) → local enhanced → any en-US.
  Future<void> _selectBestVoice() async {
    try {
      final voices = await _tts.getVoices as List?;
      if (voices == null || voices.isEmpty) return;

      // Strictly filter to en-US to avoid en-IN (Indian), en-AU, etc.
      final usVoices = voices
          .cast<Map>()
          .where((v) {
            final locale = (v['locale'] as String? ?? '').toLowerCase();
            return locale == 'en-us' || locale == 'en_us';
          })
          .toList();

      // Fallback to any English if no en-US voices found
      final enVoices = usVoices.isNotEmpty ? usVoices : voices
          .cast<Map>()
          .where((v) => (v['locale'] as String? ?? '').toLowerCase().startsWith('en'))
          .toList();

      if (enVoices.isEmpty) return;

      // Prefer network/WaveNet voices (highest quality, require Google TTS)
      Map? best = enVoices.firstWhere(
        (v) => (v['name'] as String? ?? '').contains('network'),
        orElse: () => enVoices.firstWhere(
          (v) => (v['name'] as String? ?? '').contains('enhanced'),
          orElse: () => enVoices.first,
        ),
      );

      await _tts.setVoice({
        'name': best['name'],
        'locale': best['locale'],
      });
    } catch (_) {
      // ignore if voice selection fails — defaults will be used
    }
  }

  Future<void> speak(String text) async {
    if (text.isEmpty) return;
    if (_speaking) await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> stop() async {
    await _tts.stop();
    _speaking = false;
  }

  bool get isSpeaking => _speaking;

  Future<List<dynamic>> getVoices() async => await _tts.getVoices;

  Future<void> setVoice(String name) async {
    await _applyVoiceByName(name);
  }

  void dispose() {
    _tts.stop();
  }
}



// ─── STT Service ──────────────────────────────────────────────────────────────
class SttService {
  final SpeechToText _stt = SpeechToText();
  bool _available = false;
  bool _listening = false;

  Future<bool> init() async {
    _available = await _stt.initialize(
      onError: (e) => _listening = false,
      onStatus: (s) {
        if (s == 'done' || s == 'notListening') _listening = false;
      },
    );
    return _available;
  }

  Future<void> startListening({
    required void Function(String text) onResult,
    String localeId = 'en_US',
  }) async {
    if (!_available || _listening) return;
    _listening = true;
    await _stt.listen(
      onResult: (r) {
        if (r.finalResult && r.recognizedWords.isNotEmpty) {
          onResult(r.recognizedWords);
        }
      },
      localeId: localeId,
      listenFor: const Duration(seconds: 10),
      pauseFor: const Duration(seconds: 3),
    );
  }

  Future<void> stopListening() async {
    await _stt.stop();
    _listening = false;
  }

  bool get isAvailable => _available;
  bool get isListening  => _listening;

  // Wake word detection — call this on every STT result
  bool containsWakeWord(String text, String wakeWord) {
    return text.toLowerCase().contains(wakeWord.toLowerCase());
  }

  // Strip wake word from command
  String stripWakeWord(String text, String wakeWord) {
    return text.toLowerCase().replaceAll(wakeWord.toLowerCase(), '').trim();
  }

  void dispose() {
    _stt.stop();
  }
}
