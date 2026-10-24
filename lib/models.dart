enum MessageType {
  text,
  image,
  sticker,
  audio,
  video,
  document,
  system,
}

class ChatMessage {
  final String id;
  final DateTime timestamp;
  final String? sender;
  final String content;
  final bool isSystem;
  final MessageType type;
  final String? attachmentFileName;
  final String? replyToSender;
  final String? replyToContent;

  ChatMessage({
    required this.id,
    required this.timestamp,
    this.sender,
    required this.content,
    this.isSystem = false,
    this.type = MessageType.text,
    this.attachmentFileName,
    this.replyToSender,
    this.replyToContent,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'sender': sender,
        'content': content,
        'isSystem': isSystem,
        'type': type.name,
        'attachmentFileName': attachmentFileName,
        'replyToSender': replyToSender,
        'replyToContent': replyToContent,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'],
        timestamp: DateTime.parse(json['timestamp']),
        sender: json['sender'],
        content: json['content'] ?? '',
        isSystem: json['isSystem'] ?? false,
        type: MessageType.values.byName(json['type']),
        attachmentFileName: json['attachmentFileName'],
        replyToSender: json['replyToSender'],
        replyToContent: json['replyToContent'],
      );
}

class ChatMeta {
  String id;
  String title;
  DateTime importedAt;
  bool hasMedia;
  int messageCount;
  String? avatarPath;
  String? mySenderName;

  ChatMeta({
    required this.id,
    required this.title,
    required this.importedAt,
    required this.hasMedia,
    required this.messageCount,
    this.avatarPath,
    this.mySenderName,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'importedAt': importedAt.toIso8601String(),
        'hasMedia': hasMedia,
        'messageCount': messageCount,
        'avatarPath': avatarPath,
        'mySenderName': mySenderName,
      };

  factory ChatMeta.fromJson(Map<String, dynamic> json) => ChatMeta(
        id: json['id'],
        title: json['title'],
        importedAt: DateTime.parse(json['importedAt']),
        hasMedia: json['hasMedia'] ?? false,
        messageCount: json['messageCount'] ?? 0,
        avatarPath: json['avatarPath'],
        mySenderName: json['mySenderName'],
      );
}