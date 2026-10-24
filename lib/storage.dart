import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'models.dart';
import 'parser.dart';

class ArchiveStorage {
  static Future<Directory> getBaseDir() async {
    final appDir = await getApplicationSupportDirectory();
    final archiveDir = Directory(p.join(appDir.path, 'WhatsAppArchive'));
    if (!await archiveDir.exists()) {
      await archiveDir.create(recursive: true);
    }
    return archiveDir;
  }

  static Future<List<ChatMeta>> loadAllChats() async {
    final base = await getBaseDir();
    final List<ChatMeta> result = [];

    if (!await base.exists()) return result;

    final entities = await base.list().toList();
    final dirs = entities.whereType<Directory>();

    for (final dir in dirs) {
      final metaFile = File(p.join(dir.path, 'meta.json'));
      if (await metaFile.exists()) {
        try {
          final content = await metaFile.readAsString();
          final json = jsonDecode(content);
          result.add(ChatMeta.fromJson(json));
        } catch (_) {}
      }
    }

    result.sort((a, b) => b.importedAt.compareTo(a.importedAt));
    return result;
  }

  static Future<void> deleteChat(String chatId) async {
    final base = await getBaseDir();
    final chatDir = Directory(p.join(base.path, chatId));
    if (await chatDir.exists()) {
      await chatDir.delete(recursive: true);
    }
  }

  static Future<void> saveMeta(ChatMeta meta) async {
    final base = await getBaseDir();
    final file = File(p.join(base.path, meta.id, 'meta.json'));
    await file.writeAsString(jsonEncode(meta.toJson()));
  }

  static Future<List<ChatMessage>> loadMessages(String chatId) async {
    final base = await getBaseDir();
    final msgFile = File(p.join(base.path, chatId, 'messages.json'));
    if (!await msgFile.exists()) return [];

    try {
      final rawJson = await msgFile.readAsString();
      final List list = jsonDecode(rawJson);
      return list.map((e) => ChatMessage.fromJson(e)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<ChatMeta> importChatArchive(String filePath) async {
    final base = await getBaseDir();
    final chatId = 'chat_${DateTime.now().millisecondsSinceEpoch}';
    final chatDir = Directory(p.join(base.path, chatId));
    final mediaDir = Directory(p.join(chatDir.path, 'media'));
    await mediaDir.create(recursive: true);

    String rawText = '';
    bool hasMedia = false;
    String detectedTitle = p.basenameWithoutExtension(filePath)
        .replaceAll('WhatsApp Chat - ', '')
        .replaceAll('WhatsApp Chat with ', '')
        .trim();

    final ext = p.extension(filePath).toLowerCase();

    if (ext == '.zip') {
      hasMedia = true;
      final bytes = await File(filePath).readAsBytes();
      final archive = await compute((b) => ZipDecoder().decodeBytes(b), bytes);

      for (final file in archive) {
        if (!file.isFile) continue;

        // Strip any leading directories to flatten files directly into media/ or root
        final baseName = p.basename(file.name);
        if (baseName.isEmpty || baseName.startsWith('._') || baseName == '.DS_Store') {
          continue; // Skip macOS metadata junk files inside zips
        }

        if (baseName.toLowerCase().endsWith('.txt')) {
          final outPath = p.join(chatDir.path, baseName);
          final contentBytes = file.content as List<int>;
          await File(outPath).writeAsBytes(contentBytes);
          rawText = utf8.decode(contentBytes, allowMalformed: true);
        } else {
          final outPath = p.join(mediaDir.path, baseName);
          await File(outPath).writeAsBytes(file.content as List<int>);
        }
      }
    } else {
      final bytes = await File(filePath).readAsBytes();
      rawText = utf8.decode(bytes, allowMalformed: true);
    }

    // Run the updated WhatsApp parser in a separate isolate
    final messages = await compute((txt) => WhatsAppParser.parse(txt), rawText);

    // Persist parsed messages
    final msgFile = File(p.join(chatDir.path, 'messages.json'));
    await msgFile.writeAsString(jsonEncode(messages.map((m) => m.toJson()).toList()));

    final meta = ChatMeta(
      id: chatId,
      title: detectedTitle.isEmpty ? 'WhatsApp Chat' : detectedTitle,
      importedAt: DateTime.now(),
      hasMedia: hasMedia,
      messageCount: messages.length,
    );

    await saveMeta(meta);
    return meta;
  }
}