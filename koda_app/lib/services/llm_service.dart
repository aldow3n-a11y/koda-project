import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/models.dart';

class LlmService {
  static const _apiUrl = 'https://api.anthropic.com/v1/messages';
  static const _anthropicVersion = '2023-06-01';

  String _apiKey = '';
  String _model  = 'gemini-2.0-flash';
  String _customApiUrl = '';
  int _maxTokens = 300;

  void configure({required String apiKey, String? model, int? maxTokens, String? customApiUrl}) {
    _apiKey    = apiKey;
    _model     = model ?? _model;
    _maxTokens = maxTokens ?? _maxTokens;
    _customApiUrl = customApiUrl ?? _customApiUrl;
  }

  // ── Main chat call ────────────────────────────────────────────────────────
  /// Sends a message to the LLM with a fully assembled system prompt from ContextService.
  Future<KodaResponse?> chat({
    required String userMessage,
    required String systemPrompt,
    List<int>? imageBytes,
    String? visionContext,
  }) async {
    if (_apiKey.isEmpty && _customApiUrl.isEmpty) return null;

    final userContent = visionContext != null
        ? '$userMessage\n\nCamera context: $visionContext'
        : userMessage;

    try {
      final text = await _call(
        systemPrompt: systemPrompt,
        userContent: userContent,
        imageBytes: imageBytes,
        maxTokens: _maxTokens,
      );
      if (text == null) return null;
      final clean = text.replaceAll('```json', '').replaceAll('```', '').trim();
      return KodaResponse.fromJson(jsonDecode(clean));
    } catch (e) {
      return null;
    }
  }

  // ── Raw plain-text call (used for memory extraction from session logs) ────
  Future<String?> callRaw(String prompt, {int maxTokens = 400}) async {
    if (_apiKey.isEmpty && _customApiUrl.isEmpty) return null;
    return _call(systemPrompt: '', userContent: prompt, maxTokens: maxTokens);
  }

  // ── Shared HTTP logic ─────────────────────────────────────────────────────
  Future<String?> _call({
    required String systemPrompt,
    required String userContent,
    List<int>? imageBytes,
    required int maxTokens,
  }) async {
    try {
      http.Response res;
      
      // 1. Custom / Cloud API (Standardized OpenAI-like)
      if (_customApiUrl.isNotEmpty) {
        final headers = {
          'Content-Type': 'application/json',
          if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
        };

        final messages = <Map<String, dynamic>>[];
        if (systemPrompt.isNotEmpty) {
          messages.add({'role': 'system', 'content': systemPrompt});
        }

        if (imageBytes != null) {
          // Standard OpenAI vision format
          messages.add({
            'role': 'user',
            'content': [
              {'type': 'text', 'text': userContent},
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:image/jpeg;base64,${base64Encode(imageBytes)}'
                }
              },
            ]
          });
        } else {
          messages.add({'role': 'user', 'content': userContent});
        }

        res = await http.post(
          Uri.parse(_customApiUrl),
          headers: headers,
          body: jsonEncode({
            'model': _model,
            'messages': messages,
            'max_tokens': maxTokens,
          }),
        ).timeout(const Duration(seconds: 45));

      } 
      // 2. Gemini native
      else if (_model.startsWith('gemini')) {
        final parts = <Map<String, dynamic>>[];
        if (imageBytes != null) {
          parts.add({
            'inline_data': {
              'mime_type': 'image/jpeg',
              'data': base64Encode(imageBytes),
            }
          });
        }
        parts.add({'text': userContent});

        final body = <String, dynamic>{
          'contents': [{'parts': parts}],
          'generationConfig': {'maxOutputTokens': maxTokens},
        };
        if (systemPrompt.isNotEmpty) {
          body['systemInstruction'] = {'parts': [{'text': systemPrompt}]};
        }

        res = await http.post(
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent?key=$_apiKey'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        ).timeout(const Duration(seconds: 30));
      } 
      // 3. Anthropic native
      else {
        res = await http.post(
          Uri.parse(_apiUrl),
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': _apiKey,
            'anthropic-version': _anthropicVersion,
          },
          body: jsonEncode({
            'model': _model,
            'max_tokens': maxTokens,
            if (systemPrompt.isNotEmpty) 'system': systemPrompt,
            'messages': [
              {'role': 'user', 'content': userContent},
            ],
          }),
        ).timeout(const Duration(seconds: 30));
      }

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (_customApiUrl.isNotEmpty) {
          // Both OpenAI and Ollama (standard chat) use this path
          return data['choices'][0]['message']['content'] as String;
        } else if (_model.startsWith('gemini')) {
          return data['candidates'][0]['content']['parts'][0]['text'] as String;
        } else {
          return data['content'][0]['text'] as String;
        }
      }
    } catch (_) {}
    return null;
  }
}
