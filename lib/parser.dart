import 'models.dart';

class WhatsAppParser {
  // Regex that captures timestamp, optional sender, and content
  static final RegExp _msgRegex = RegExp(
    r'^\[?(\d{1,2}[\/\.]\d{1,2}[\/\.]\d{2,4},\s+\d{1,2}:\d{2}(?::\d{2})?(?:\s*[APap][Mm])?)\]?(?:\s+-\s+|\s+)(?:([^:]+):\s)?(.*)$',
  );

  static List<ChatMessage> parse(String rawText) {
    // 1. Scrub invisible Unicode marks and normalize spaces
    final cleaned = rawText
        .replaceAll(RegExp(r'[\u200E\u200F\u202A-\u202E\uFEFF]'), '')
        .replaceAll(RegExp(r'[\u202F\u00A0]'), ' ');

    final lines = cleaned.split(RegExp(r'\r?\n'));
    final List<ChatMessage> messages = [];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty) continue;

      final match = _msgRegex.firstMatch(line.trim());
      if (match != null) {
        final timeStr = match.group(1)!;
        final sender = match.group(2);
        final rawContent = match.group(3) ?? '';
        final dt = _parseDateTime(timeStr);

        final attachment = _extractAttachment(rawContent);
        final isSys = sender == null ||
            rawContent.contains('Messages and calls are end-to-end encrypted') ||
            rawContent.contains('image omitted') ||
            rawContent.contains('video omitted');

        final type = _determineType(attachment, rawContent, isSys);

        String displayText = rawContent
            .replaceAll(RegExp(r'<attached:\s*[^>]+>', caseSensitive: false), '')
            .replaceAll(RegExp(r'\(file attached\)', caseSensitive: false), '')
            .trim();

        messages.add(ChatMessage(
          id: 'msg_${messages.length}_$i',
          timestamp: dt,
          sender: sender?.trim(),
          content: displayText,
          isSystem: isSys,
          type: type,
          attachmentFileName: attachment,
        ));
      } else if (messages.isNotEmpty) {
        // Multi-line continuation: append to the current message
        final last = messages.last;
        messages[messages.length - 1] = ChatMessage(
          id: last.id,
          timestamp: last.timestamp,
          sender: last.sender,
          content: '${last.content}\n${line.trim()}',
          isSystem: last.isSystem,
          type: last.type,
          attachmentFileName: last.attachmentFileName,
        );
      }
    }

    // 2. Post-process messages to extract Quoted Replies accurately from full text
    return messages.map((m) {
      if (m.isSystem || m.content.isEmpty) return m;

      String? replySender;
      String? replyText;
      String cleanContent = m.content;

      // Pattern 1: iOS blockquote style (> sender: quote \n message OR > quote \n message)
      final blockquoteRegex = RegExp(r'^>\s*(?:([^:\n]+):\s*)?([^\n]+)(?:\n+([\s\S]*))?');
      final match = blockquoteRegex.firstMatch(m.content);

      if (match != null) {
        replySender = match.group(1)?.trim();
        replyText = match.group(2)?.trim();
        cleanContent = match.group(3)?.trim() ?? '';
      } else {
        // Pattern 2: Curly or straight quotes style (“quoted text” \n message)
        final curlyQuoteRegex = RegExp(r'^[“"]([^”"\n]+)[”"](?:\n+([\s\S]*))?');
        final curlyMatch = curlyQuoteRegex.firstMatch(m.content);
        if (curlyMatch != null) {
          replyText = curlyMatch.group(1)?.trim();
          cleanContent = curlyMatch.group(2)?.trim() ?? '';
        }
      }

      if (replyText != null && replyText.isNotEmpty) {
        return ChatMessage(
          id: m.id,
          timestamp: m.timestamp,
          sender: m.sender,
          content: cleanContent,
          isSystem: m.isSystem,
          type: m.type,
          attachmentFileName: m.attachmentFileName,
          replyToSender: replySender ?? 'You',
          replyToContent: replyText,
        );
      }

      return m;
    }).toList();
  }

  static String? _extractAttachment(String text) {
    final iosMatch = RegExp(r'<attached:\s*([^>]+)>', caseSensitive: false).firstMatch(text);
    if (iosMatch != null) return iosMatch.group(1)?.trim();

    final androidMatch = RegExp(r'^(.*?)\s*\(file attached\)', caseSensitive: false).firstMatch(text);
    if (androidMatch != null) return androidMatch.group(1)?.trim();

    return null;
  }

  static MessageType _determineType(String? filename, String content, bool isSystem) {
    if (isSystem) return MessageType.system;
    if (filename == null) return MessageType.text;

    final ext = filename.split('.').last.toLowerCase().trim();
    if (['jpg', 'jpeg', 'png', 'heic'].contains(ext)) return MessageType.image;
    if (ext == 'webp') return MessageType.sticker;
    if (['mp3', 'opus', 'm4a', 'ogg', 'wav', 'flac'].contains(ext)) return MessageType.audio;
    if (['mp4', 'mov', 'avi', 'mkv'].contains(ext)) return MessageType.video;
    return MessageType.document;
  }

  static DateTime _parseDateTime(String raw) {
    try {
      final sanitized = raw.replaceAll('.', '/').replaceAll(',', '').trim();
      final parts = sanitized.split(' ');
      final dateParts = parts[0].split('/').map(int.parse).toList();

      int year = dateParts[2];
      if (year < 100) year += 2000;
      int month = dateParts[1];
      int day = dateParts[0];

      if (month > 12 && day <= 12) {
        final t = month;
        month = day;
        day = t;
      }

      int hour = 0;
      int minute = 0;
      int second = 0;
      if (parts.length > 1) {
        final timeParts = parts[1].split(':').map(int.parse).toList();
        hour = timeParts[0];
        minute = timeParts[1];
        if (timeParts.length > 2) second = timeParts[2];

        if (parts.length > 2) {
          final ampm = parts[2].toLowerCase();
          if (ampm.contains('pm') && hour < 12) hour += 12;
          if (ampm.contains('am') && hour == 12) hour = 0;
        }
      }
      return DateTime(year, month, day, hour, minute, second);
    } catch (_) {
      return DateTime.now();
    }
  }
}