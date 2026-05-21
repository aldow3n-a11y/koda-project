import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter_gemma/flutter_gemma.dart';
import '../models/models.dart';

class LlmService {
  static const _apiUrl = 'https://api.anthropic.com/v1/messages';
  static const _anthropicVersion = '2023-06-01';

  String _apiKey = '';
  String _model  = 'gemini-robotics-er-1.6-preview';
  String _customApiUrl = '';
  int _maxTokens = 300;
  int _thinkingBudget = 0; // 0 = default/off, >0 = enabled

  void configure({required String apiKey, String? model, int? maxTokens, String? customApiUrl, int? thinkingBudget}) {
    _apiKey    = apiKey;
    _model     = model ?? _model;
    _maxTokens = maxTokens ?? _maxTokens;
    _customApiUrl = customApiUrl ?? _customApiUrl;
    _thinkingBudget = thinkingBudget ?? _thinkingBudget;
  }

  // ── Main chat call ────────────────────────────────────────────────────────
  /// Sends a message to the LLM with a fully assembled system prompt from ContextService.
  Future<KodaResponse?> chat({
    required String userMessage,
    required String systemPrompt,
    List<List<int>>? images,
    String? visionContext,
  }) async {
    // Allow gemma4-native to bypass the API key check (runs locally)
    if (_apiKey.isEmpty && _customApiUrl.isEmpty && _model != 'gemma4-native') return null;

    final userContent = visionContext != null
        ? '$userMessage\n\nCamera context: $visionContext'
        : userMessage;

    try {
      final text = await _call(
        systemPrompt: systemPrompt,
        userContent: userContent,
        images: images,
        maxTokens: _maxTokens,
      );
      if (text == null) return null;
      
      // Robust JSON extraction: Find first { and last }
      final startIndex = text.indexOf('{');
      final endIndex = text.lastIndexOf('}');
      
      if (startIndex != -1 && endIndex != -1 && endIndex >= startIndex) {
        final clean = text.substring(startIndex, endIndex + 1);
        return KodaResponse.fromJson(jsonDecode(clean));
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  // ── Raw plain-text call (used for memory extraction from session logs) ────
  Future<String?> callRaw(String prompt, {int maxTokens = 400, List<List<int>>? images}) async {
    if (_apiKey.isEmpty && _customApiUrl.isEmpty) return null;
    return _call(systemPrompt: '', userContent: prompt, maxTokens: maxTokens, images: images);
  }

  // ── Shared HTTP logic ─────────────────────────────────────────────────────
  Future<String?> _call({
    required String systemPrompt,
    required String userContent,
    List<List<int>>? images,
    required int maxTokens,
  }) async {
    try {
      http.Response res;

      // 0. Native Local Inference (Gemma 4)
      if (_model == 'gemma4-native') {
        try {
          final fullPrompt = '$systemPrompt\n\n$userContent';
          final model = await FlutterGemma.getActiveModel();
          final session = await model.createSession();
          
          if (images != null && images.isNotEmpty) {
            // Local Gemma currently only supports one image in this wrapper
            await session.addQueryChunk(Message.withImage(
              text: fullPrompt,
              imageBytes: Uint8List.fromList(images.first),
              isUser: true,
            ));
          } else {
            await session.addQueryChunk(Message.text(text: fullPrompt, isUser: true));
          }

          final response = await session.getResponse();
          await session.close();
          if (response.isNotEmpty) {
            // Verify valid JSON before returning
            final startIndex = response.indexOf('{');
            final endIndex = response.lastIndexOf('}');
            if (startIndex != -1 && endIndex != -1 && endIndex >= startIndex) {
              jsonDecode(response.substring(startIndex, endIndex + 1));
              return response;
            }
          }
        } catch (e) {
          print('Local inference failed. Falling back to Cloud LLM... Error: $e');
          // Fall back to gemini if API key available, otherwise give up
          if (_apiKey.isEmpty && _customApiUrl.isEmpty) return null;
          // Continue below using a real cloud model for fallback
        }
      }

      // For cloud fallback when gemma4-native fails, use gemini if key is set
      final cloudModel = _model == 'gemma4-native' ? 'gemini-robotics-er-1.6-preview' : _model;
      final isGoogleModel = cloudModel.startsWith('gemini') || cloudModel.startsWith('gemma');
      final isRoboticsER = cloudModel.contains('robotics-er');
      
      // 1. Custom / Cloud API (Standardized OpenAI-like)
      if (_customApiUrl.isNotEmpty && !_customApiUrl.contains('generativelanguage.googleapis.com')) {
        final headers = {
          'Content-Type': 'application/json',
          if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
        };

        final messages = <Map<String, dynamic>>[];
        if (systemPrompt.isNotEmpty) {
          messages.add({'role': 'system', 'content': systemPrompt});
        }

        final List<Map<String, dynamic>> userParts = [{'type': 'text', 'text': userContent}];
        if (images != null) {
          for (final img in images) {
            userParts.add({
              'type': 'image_url',
              'image_url': {
                'url': 'data:image/jpeg;base64,${base64Encode(img)}'
              }
            });
          }
        }
        messages.add({'role': 'user', 'content': userParts});

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
      // 2. Google native (Gemini or Gemma)
      else if (isGoogleModel) {
        final parts = <Map<String, dynamic>>[];
        if (images != null) {
          for (final img in images) {
            parts.add({
              'inlineData': {
                'mimeType': 'image/jpeg',
                'data': base64Encode(img),
              }
            });
          }
        }
        parts.add({'text': userContent});

        final body = <String, dynamic>{
          'contents': [{'parts': parts}],
          'generationConfig': {
            'maxOutputTokens': maxTokens,
            if (_thinkingBudget > 0 && (cloudModel.contains('thinking') || isRoboticsER)) 
              'thinkingConfig': {'thinkingBudget': _thinkingBudget},
          },
          if (isRoboticsER) 'tools': [{'codeExecution': {}}],
        };
        if (systemPrompt.isNotEmpty) {
          body['systemInstruction'] = {'parts': [{'text': systemPrompt}]};
        }

        final endpoint = _customApiUrl.isNotEmpty ? _customApiUrl : 
            'https://generativelanguage.googleapis.com/v1beta/models/$cloudModel:generateContent?key=$_apiKey';

        res = await http.post(
          Uri.parse(endpoint),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        ).timeout(const Duration(seconds: 30));
      } 
      // 3. Anthropic native
      else {
        final List<Map<String, dynamic>> contentParts = [];
        if (images != null) {
          for (final img in images) {
            contentParts.add({
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': 'image/jpeg',
                'data': base64Encode(img),
              }
            });
          }
        }
        contentParts.add({'type': 'text', 'text': userContent});

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
              {'role': 'user', 'content': contentParts},
            ],
          }),
        ).timeout(const Duration(seconds: 30));
      }

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (_customApiUrl.isNotEmpty && !_customApiUrl.contains('generativelanguage.googleapis.com')) {
          return data['choices'][0]['message']['content'] as String;
        } else if (isGoogleModel) {
          final candidates = data['candidates'] as List?;
          if (candidates == null || candidates.isEmpty) {
            final feedback = data['promptFeedback'];
            print('Gemini Error: No candidates. Feedback: $feedback');
            return null;
          }
          
          final candidate = candidates[0];
          final content = candidate['content'];
          if (content == null) {
             print('Gemini Error: No content in candidate. Reason: ${candidate['finishReason']}');
             return null;
          }

          final parts = content['parts'] as List?;
          if (parts == null || parts.isEmpty) {
            print('Gemini Error: No parts in candidate.');
            return null;
          }

          // In case of code execution, there might be multiple parts (call + result + final text)
          // We want to find the final text part or the one that contains our JSON
          String combinedText = '';
          for (final part in parts) {
            if (part.containsKey('text')) {
              combinedText += part['text'];
            }
          }
          return combinedText;
        } else {
          return data['content'][0]['text'] as String;
        }
      } else {
        print('LLM API Error: ${res.statusCode} - ${res.body}');
      }
    } catch (e) {
      print('LLM Service Exception: $e');
    }
    return null;
  }
}
