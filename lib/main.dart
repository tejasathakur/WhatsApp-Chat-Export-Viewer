import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'models.dart';
import 'storage.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WhatsAppViewerApp());
}

Color getSenderColor(String senderName) {
  const colors = [
    Color(0xFF53BDEB), // Cyan / Light Blue
    Color(0xFF00A884), // WhatsApp Green
    Color(0xFFFF9F0A), // Orange
    Color(0xFFFF453A), // Red
    Color(0xFFBF5AF2), // Purple
    Color(0xFFFF375F), // Pink
    Color(0xFF30D158), // Bright Green
    Color(0xFF64D2FF), // Sky Blue
    Color(0xFFFFD60A), // Yellow
    Color(0xFF8E8E93), // Slate Gray
  ];

  int hash = 0;
  for (int code in senderName.codeUnits) {
    hash = (hash * 31 + code) & 0xFFFFFFF;
  }
  return colors[hash % colors.length];
}

class WhatsAppViewerApp extends StatelessWidget {
  const WhatsAppViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WhatsApp Archive Viewer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF242424),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF1C1C1C)),
      ),
      home: const MainDesktopScreen(),
    );
  }
}

class MainDesktopScreen extends StatefulWidget {
  const MainDesktopScreen({super.key});

  @override
  State<MainDesktopScreen> createState() => _MainDesktopScreenState();
}

class _MainDesktopScreenState extends State<MainDesktopScreen> {
  List<ChatMeta> _chats = [];
  ChatMeta? _selectedChat;
  List<ChatMessage> _messages = [];
  bool _isLoading = false;

  // Search & Navigation
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  List<int> _searchResultIndices = [];
  int _currentSearchIndex = 0;
  String _chatListSearchQuery = '';

  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();

  // Floating Sticky Date Tag
  String _floatingDateText = '';

  // Drawer
  bool _showMediaDrawer = false;

  @override
  void initState() {
    super.initState();
    _loadChatList();
    _itemPositionsListener.itemPositions.addListener(_updateFloatingDate);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _itemPositionsListener.itemPositions.removeListener(_updateFloatingDate);
    super.dispose();
  }

  void _updateFloatingDate() {
    if (_messages.isEmpty) return;

    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;

    final topItem = positions.reduce((min, pos) =>
        pos.itemLeadingEdge < min.itemLeadingEdge ? pos : min);
    final topIndex = topItem.index.clamp(0, _messages.length - 1);

    final dt = _messages[topIndex].timestamp;
    final now = DateTime.now();

    String newText;
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      newText = 'Today';
    } else {
      newText = DateFormat('dd MMMM yyyy').format(dt);
    }

    if (newText != _floatingDateText) {
      setState(() {
        _floatingDateText = newText;
      });
    }
  }

  void _onSearchChanged(String query) {
    final clean = query.trim().toLowerCase();
    setState(() {
      _searchQuery = clean;
      _searchResultIndices.clear();
      _currentSearchIndex = 0;

      if (clean.isNotEmpty) {
        for (int i = 0; i < _messages.length; i++) {
          final m = _messages[i];
          if (!m.isSystem && m.content.toLowerCase().contains(clean)) {
            _searchResultIndices.add(i);
          }
        }

        if (_searchResultIndices.isNotEmpty) {
          _currentSearchIndex = _searchResultIndices.length - 1;
          _jumpToSearchOccurrence(_searchResultIndices[_currentSearchIndex]);
        }
      }
    });
  }

  void _navigateSearch(int direction) {
    if (_searchResultIndices.isEmpty) return;

    setState(() {
      _currentSearchIndex =
          (_currentSearchIndex + direction) % _searchResultIndices.length;
      if (_currentSearchIndex < 0) {
        _currentSearchIndex = _searchResultIndices.length - 1;
      }
    });

    _jumpToSearchOccurrence(_searchResultIndices[_currentSearchIndex]);
  }

  void _jumpToSearchOccurrence(int messageIndex) {
    if (_itemScrollController.isAttached) {
      _itemScrollController.scrollTo(
        index: messageIndex,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOutCubic,
        alignment: 0.3,
      );
    }
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _searchResultIndices.clear();
      _currentSearchIndex = 0;
    });
  }

  Future<void> _loadChatList() async {
    final list = await ArchiveStorage.loadAllChats();
    setState(() {
      _chats = list;
      if (list.isNotEmpty && _selectedChat == null) {
        _selectChat(list.first);
      }
    });
  }

  Future<void> _selectChat(ChatMeta meta) async {
    _clearSearch();
    setState(() {
      _selectedChat = meta;
      _isLoading = true;
      _showMediaDrawer = false;
      _floatingDateText = '';
    });

    final msgs = await ArchiveStorage.loadMessages(meta.id);

    // Prompt user to pick their own sender name if not designated yet
    if (meta.mySenderName == null) {
      final senders = msgs
          .map((m) => m.sender)
          .where((s) => s != null && s.isNotEmpty)
          .toSet()
          .toList();
      if (senders.isNotEmpty && mounted) {
        _promptSetSelf(senders.cast<String>());
      }
    }

    setState(() {
      _messages = msgs;
      _isLoading = false;
    });

    // Automatically jump to the newest message when switching chats
    if (msgs.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_itemScrollController.isAttached) {
          _itemScrollController.jumpTo(index: msgs.length - 1);
        }
      });
    }
  }

  Future<void> _handleFileImport(String path) async {
    setState(() => _isLoading = true);
    final meta = await ArchiveStorage.importChatArchive(path);
    await _loadChatList();
    _selectChat(meta);
  }

  void _promptSetSelf(List<String> senders) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1C),
        title: const Text('Which participant is "You"?',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: senders
              .map((s) => ListTile(
                    title: Text(s, style: const TextStyle(color: Colors.white)),
                    onTap: () {
                      _selectedChat!.mySenderName = s;
                      ArchiveStorage.saveMeta(_selectedChat!);
                      setState(() {});
                      Navigator.pop(ctx);
                    },
                  ))
              .toList(),
        ),
      ),
    );
  }

  void _confirmDeleteChat(ChatMeta chat) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1C),
        title: const Text('Delete Chat Archive',
            style: TextStyle(color: Colors.white)),
        content: Text(
          'Are you sure you want to delete "${chat.title}" and all its extracted media from your disk?',
          style: const TextStyle(color: Color(0xFF8696A0)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.pop(ctx);
              await ArchiveStorage.deleteChat(chat.id);

              setState(() {
                _chats.removeWhere((c) => c.id == chat.id);
                if (_selectedChat?.id == chat.id) {
                  _selectedChat = _chats.isNotEmpty ? _chats.first : null;
                  _messages = [];
                }
              });

              if (_selectedChat != null) {
                _selectChat(_selectedChat!);
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragDone: (detail) {
        if (detail.files.isNotEmpty) {
          _handleFileImport(detail.files.first.path);
        }
      },
      child: Scaffold(
        body: Row(
          children: [
            // Left Chats List Panel (Width 360)
            SizedBox(
              width: 360,
              child: _buildLeftSidebar(),
            ),
            const VerticalDivider(
                width: 1, thickness: 1, color: Color(0xFF222D34)),

            // Right Active Chat Panel
            Expanded(
              child: _selectedChat == null
                  ? const Center(
                      child: Text('Import or select a chat to begin',
                          style: TextStyle(color: Color(0xFF8696A0))),
                    )
                  : _buildChatArea(),
            ),

            // Optional Right Drawer for Media, Links & Docs
            if (_showMediaDrawer && _selectedChat != null) ...[
              const VerticalDivider(
                  width: 1, thickness: 1, color: Color(0xFF222D34)),
              SizedBox(
                width: 340,
                child: MediaDrawer(
                  chatId: _selectedChat!.id,
                  messages: _messages,
                  onClose: () => setState(() => _showMediaDrawer = false),
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }

Widget _buildLeftSidebar() {
    final filteredChats = _chats.where((c) {
      if (_chatListSearchQuery.isNotEmpty &&
          !c.title.toLowerCase().contains(_chatListSearchQuery)) {
        return false;
      }
      return true;
    }).toList();

    return Material(
      color: const Color(0xFF1C1C1C), // Matching dark sidebar tone
      child: Column(
        children: [
          // 1. Top Header: (...) Chats (+)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // (...) Options Button
                Container(
                  width: 38,
                  height: 38,
                  decoration: const BoxDecoration(
                    color: Color(0xFF333333),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.more_horiz, color: Colors.white, size: 20),
                    tooltip: 'Options',
                    onPressed: () {},
                  ),
                ),
                const Text(
                  'Chats',
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                // (+) Import / Add Chat Button
                Container(
                  width: 38,
                  height: 38,
                  decoration: const BoxDecoration(
                    color: Color(0xFF00A884), // WhatsApp vibrant green
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.add, color: Colors.black, size: 22),
                    tooltip: 'Import Chat (.zip or .txt)',
                    onPressed: () async {
                      try {
                        final res = await FilePicker.platform.pickFiles(type: FileType.any);
                        if (res != null && res.files.single.path != null) {
                          final path = res.files.single.path!;
                          final ext = p.extension(path).toLowerCase();
                          if (ext == '.zip' || ext == '.txt') {
                            _handleFileImport(path);
                          } else {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Please select a valid WhatsApp .zip or .txt file.'),
                                ),
                              );
                            }
                          }
                        }
                      } catch (e) {
                        debugPrint('Error picking file: $e');
                      }
                    },
                  ),
                ),
              ],
            ),
          ),

          // 2. Rounded Pill Search Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Container(
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2C),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(left: 14, right: 8),
                    child: Icon(Icons.search, size: 18, color: Color(0xFF8696A0)),
                  ),
                  Expanded(
                    child: TextField(
                      style: const TextStyle(fontSize: 13.5, color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: 'Search',
                        hintStyle: TextStyle(color: Color(0xFF8696A0), fontSize: 13.5),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 8),
                      ),
                      onChanged: (v) => setState(() => _chatListSearchQuery = v.trim().toLowerCase()),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 8),

          // 3. Chat Item Cards
          Expanded(
            child: filteredChats.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        'Drop WhatsApp exported .zip or .txt files here\nor click the + icon above',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Color(0xFF8696A0), fontSize: 13),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: filteredChats.length,
                    itemBuilder: (ctx, i) {
                      final chat = filteredChats[i];
                      final isSelected = chat.id == _selectedChat?.id;

                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        child: GestureDetector(
                          onSecondaryTapDown: (details) {
                            // Right-click context menu for Edit/Delete actions
                            showMenu(
                              context: context,
                              position: RelativeRect.fromLTRB(
                                details.globalPosition.dx,
                                details.globalPosition.dy,
                                details.globalPosition.dx,
                                details.globalPosition.dy,
                              ),
                              items: [
                                PopupMenuItem(
                                  onTap: () => Future.delayed(
                                    Duration.zero,
                                    () => _editChatMetadata(chat),
                                  ),
                                  child: const Row(
                                    children: [
                                      Icon(Icons.edit, size: 18, color: Colors.white70),
                                      SizedBox(width: 8),
                                      Text('Edit details'),
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  onTap: () => Future.delayed(
                                    Duration.zero,
                                    () => _confirmDeleteChat(chat),
                                  ),
                                  child: const Row(
                                    children: [
                                      Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                                      SizedBox(width: 8),
                                      Text('Delete chat', style: TextStyle(color: Colors.redAccent)),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          },
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _selectChat(chat),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: isSelected ? const Color(0xFF2C2C2C) : Colors.transparent,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    radius: 24,
                                    backgroundColor: const Color(0xFF383838),
                                    backgroundImage: chat.avatarPath != null
                                        ? FileImage(File(chat.avatarPath!))
                                        : null,
                                    child: chat.avatarPath == null
                                        ? const Icon(Icons.person, color: Colors.white70, size: 26)
                                        : null,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Expanded(
                                              child: Text(
                                                chat.title,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 14.5,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            Text(
                                              DateFormat('HH:mm').format(chat.importedAt),
                                              style: const TextStyle(
                                                color: Color(0xFF8696A0),
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 3),
                                        Row(
                                          children: [
                                            const Icon(Icons.done_all, size: 15, color: Color(0xFF8696A0)),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: Text(
                                                '${chat.messageCount} messages',
                                                style: const TextStyle(
                                                  color: Color(0xFF8696A0),
                                                  fontSize: 13,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
  Widget _buildChatArea() {
    final allSenders = _messages
        .map((m) => m.sender)
        .where((s) => s != null && s.isNotEmpty)
        .toSet();
    final isGroupChat = allSenders.length > 2;

    return Container(
      decoration: const BoxDecoration(
        color: Color.fromARGB(255, 5, 5, 5),
        image: DecorationImage(
          image: AssetImage('assets/chatwp.jpg'),
          fit: BoxFit.cover,
          opacity: 0.7,
        ),
      ),
      child: Column(
        children: [
          // Top AppBar / Header
          Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            color: const Color(0xFF1C1C1C),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: const Color(0xFF6B7B87),
                  backgroundImage: _selectedChat!.avatarPath != null
                      ? FileImage(File(_selectedChat!.avatarPath!))
                      : null,
                  child: _selectedChat!.avatarPath == null
                      ? Icon(isGroupChat ? Icons.groups : Icons.person,
                          color: Colors.white)
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_selectedChat!.title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                      Text('${_messages.length} messages',
                          style: const TextStyle(
                              color: Color(0xFF8696A0), fontSize: 12)),
                    ],
                  ),
                ),
                // Enhanced Search Toolbar with Match Counter & Up/Down Arrows
                Container(
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF242424),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.search,
                            size: 18, color: Color(0xFF8696A0)),
                      ),
                      SizedBox(
                        width: 160,
                        child: TextField(
                          controller: _searchController,
                          style: const TextStyle(
                              fontSize: 13, color: Colors.white),
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: 'Search in chat...',
                            hintStyle: TextStyle(
                                color: Color(0xFF8696A0), fontSize: 13),
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(vertical: 8),
                          ),
                          onChanged: _onSearchChanged,
                        ),
                      ),
                      if (_searchQuery.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            _searchResultIndices.isEmpty
                                ? '0/0'
                                : '${_currentSearchIndex + 1}/${_searchResultIndices.length}',
                            style: const TextStyle(
                              color: Color(0xFF8696A0),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 24, minHeight: 24),
                          icon: const Icon(Icons.keyboard_arrow_up,
                              size: 20, color: Color(0xFFAEBAC1)),
                          tooltip: 'Previous occurrence',
                          onPressed: _searchResultIndices.isEmpty
                              ? null
                              : () => _navigateSearch(-1),
                        ),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 24, minHeight: 24),
                          icon: const Icon(Icons.keyboard_arrow_down,
                              size: 20, color: Color(0xFFAEBAC1)),
                          tooltip: 'Next occurrence',
                          onPressed: _searchResultIndices.isEmpty
                              ? null
                              : () => _navigateSearch(1),
                        ),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 24, minHeight: 24),
                          icon: const Icon(Icons.close,
                              size: 16, color: Color(0xFF8696A0)),
                          tooltip: 'Clear search',
                          onPressed: _clearSearch,
                        ),
                        const SizedBox(width: 4),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.calendar_month,
                      color: Color(0xFFAEBAC1)),
                  tooltip: 'Jump to Date',
                  onPressed: _jumpToDate,
                ),
                IconButton(
                  icon: const Icon(Icons.perm_media_outlined,
                      color: Color(0xFFAEBAC1)),
                  tooltip: 'Media, Links and Docs',
                  onPressed: () =>
                      setState(() => _showMediaDrawer = !_showMediaDrawer),
                ),
              ],
            ),
          ),

          // Message List Area with Sticky Floating Date Tag
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF00A884)))
                : Stack(
                    alignment: Alignment.topCenter,
                    children: [
                      ScrollablePositionedList.builder(
                        itemScrollController: _itemScrollController,
                        itemPositionsListener: _itemPositionsListener,
                        itemCount: _messages.length,
                        initialScrollIndex:
                            _messages.isNotEmpty ? _messages.length - 1 : 0,
                        itemBuilder: (ctx, idx) {
                          final msg = _messages[idx];
                          final isMe = msg.sender != null &&
                              msg.sender == _selectedChat!.mySenderName;
                          final showDateHeader = _shouldShowDateHeader(idx);

                          bool showSenderName = false;
                          if (isGroupChat && !isMe && msg.sender != null) {
                            if (idx == 0 || showDateHeader) {
                              showSenderName = true;
                            } else {
                              final prevMsg = _messages[idx - 1];
                              if (prevMsg.isSystem ||
                                  prevMsg.sender != msg.sender) {
                                showSenderName = true;
                              }
                            }
                          }

                          return Column(
                            children: [
                              if (showDateHeader) _buildDatePill(msg.timestamp),
                              MessageBubble(
                                key: ValueKey(msg.id),
                                message: msg,
                                isMe: isMe,
                                chatId: _selectedChat!.id,
                                searchHighlight: _searchQuery,
                                showSenderName: showSenderName,
                                senderColor: msg.sender != null
                                    ? getSenderColor(msg.sender!)
                                    : Colors.white70,
                              ),
                            ],
                          );
                        },
                      ),

                      // Sticky / Floating Date Tag pinned beneath the header
                      if (_floatingDateText.isNotEmpty)
                        Positioned(
                          top: 10,
                          child: IgnorePointer(
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 200),
                              opacity: 0.95,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 6),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1C1C1C),
                                  borderRadius: BorderRadius.circular(8),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black45,
                                      blurRadius: 6,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Text(
                                  _floatingDateText,
                                  style: const TextStyle(
                                    color: Color(0xFF8696A0),
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  bool _shouldShowDateHeader(int index) {
    if (index == 0) return true;
    final prev = _messages[index - 1].timestamp;
    final curr = _messages[index].timestamp;
    return prev.year != curr.year ||
        prev.month != curr.month ||
        prev.day != curr.day;
  }

  Widget _buildDatePill(DateTime dt) {
    final now = DateTime.now();
    String text;
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      text = 'Today';
    } else {
      text = DateFormat('dd MMMM yyyy').format(dt);
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
          color: const Color(0xFF1C1C1C),
          borderRadius: BorderRadius.circular(8)),
      child: Text(text,
          style: const TextStyle(
              color: Color(0xFF8696A0),
              fontSize: 11,
              fontWeight: FontWeight.bold)),
    );
  }

  void _jumpToDate() async {
    if (_messages.isEmpty) return;
    final picked = await showDatePicker(
      context: context,
      initialDate: _messages.last.timestamp,
      firstDate: _messages.first.timestamp,
      lastDate: DateTime.now(),
      builder: (context, child) => Theme(data: ThemeData.dark(), child: child!),
    );

    if (picked != null) {
      final index = _messages.indexWhere((m) =>
          m.timestamp.year == picked.year &&
          m.timestamp.month == picked.month &&
          m.timestamp.day == picked.day);
      if (index != -1) {
        _itemScrollController.jumpTo(index: index);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No messages found on that date')));
      }
    }
  }

  void _editChatMetadata(ChatMeta chat) {
    final nameCtrl = TextEditingController(text: chat.title);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1C),
        title: const Text('Edit Chat Details',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                  labelText: 'Chat Name',
                  labelStyle: TextStyle(color: Colors.white70)),
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.image),
              label: const Text('Change Display Picture'),
              onPressed: () async {
                final pic =
                    await FilePicker.platform.pickFiles(type: FileType.image);
                if (pic != null && pic.files.single.path != null) {
                  chat.avatarPath = pic.files.single.path;
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              chat.title = nameCtrl.text.trim();
              ArchiveStorage.saveMeta(chat);
              setState(() {});
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          )
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Message Bubble Component (Square Images, Clickable Links, Quoted Replies)
// -----------------------------------------------------------------------------

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;
  final String chatId;
  final String searchHighlight;
  final bool showSenderName;
  final Color senderColor;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.chatId,
    required this.searchHighlight,
    required this.showSenderName,
    required this.senderColor,
  });

  @override
  Widget build(BuildContext context) {
    if (message.isSystem) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF182229),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            message.content,
            style: const TextStyle(color: Color(0xFF8696A0), fontSize: 12),
          ),
        ),
      );
    }

    if (message.type == MessageType.sticker &&
        message.attachmentFileName != null) {
      return _buildStickerBubble(context);
    }

    final bubbleColor = isMe
        ? const Color(0xFF234E39) // Sent: R 0.139, G 0.307, B 0.224
        : const Color(0xFF292B2B); // Received: R 0.160, G 0.167, B 0.167
    final timeStr = DateFormat('h:mm a').format(message.timestamp);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.55,
        ),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(15),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Sender name (in groups)
            if (showSenderName && message.sender != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 3, left: 4),
                child: Text(
                  message.sender!,
                  style: TextStyle(
                    color: senderColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                  ),
                ),
              ),

            // Quoted Reply Banner
            if (message.replyToContent != null &&
                message.replyToContent!.isNotEmpty)
              _buildReplyBanner(),

            if (message.attachmentFileName != null) _buildMedia(context),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  _buildTextContent(),
                  const SizedBox(width: 8),
                  Text(
                    timeStr,
                    style:
                        const TextStyle(color: Color(0xFF8696A0), fontSize: 11),
                  ),
                  if (isMe) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.done_all,
                        size: 14, color: Color(0xFF53BDEB)),
                  ]
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Quoted Reply Banner
  Widget _buildReplyBanner() {
    final accentColor = message.replyToSender == 'You'
        ? const Color(0xFFFFD279)
        : (message.replyToSender != null
            ? getSenderColor(message.replyToSender!)
            : const Color(0xFF00A884));

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.2),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 4,
              color: accentColor,
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      message.replyToSender ?? 'You',
                      style: TextStyle(
                        color: accentColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      message.replyToContent!,
                      style: const TextStyle(
                        color: Color(0xFFD1D7DB),
                        fontSize: 12.5,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Pure Sticker: Fixed 140x140 square with transparent background & inline time chip
  Widget _buildStickerBubble(BuildContext context) {
    final timeStr = DateFormat('h:mm a').format(message.timestamp);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (showSenderName && message.sender != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 2, left: 4),
                child: Text(
                  message.sender!,
                  style: TextStyle(
                    color: senderColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
            FutureBuilder<Directory>(
              future: ArchiveStorage.getBaseDir(),
              builder: (ctx, snap) {
                if (!snap.hasData) return const SizedBox.shrink();

                final baseDir = snap.data!;
                final chatDir = Directory(p.join(baseDir.path, chatId));
                final mediaDir = Directory(p.join(chatDir.path, 'media'));
                final rawAttachment = message.attachmentFileName!.trim();

                File file = File(p.join(mediaDir.path, rawAttachment));
                if (!file.existsSync()) {
                  file = File(p.join(chatDir.path, rawAttachment));
                }

                if (!file.existsSync()) {
                  return Container(
                    width: 140,
                    height: 140,
                    color: Colors.white10,
                    child: const Center(
                      child: Icon(Icons.broken_image, color: Colors.white24),
                    ),
                  );
                }

                return Stack(
                  children: [
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => _openImageFullscreen(context, file),
                        child: SizedBox(
                          width: 140,
                          height: 140,
                          child: Image.file(
                            file,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 2,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          timeStr,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 10),
                        ),
                      ),
                    )
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // Selectable text with clickable URLs & keyword search highlighting
  Widget _buildTextContent() {
    if (message.content.isEmpty) return const SizedBox.shrink();

    final text = message.content;
    final urlRegex = RegExp(r'https?:\/\/[^\s]+', caseSensitive: false);
    final spans = <InlineSpan>[];

    int lastMatchEnd = 0;
    for (final match in urlRegex.allMatches(text)) {
      if (match.start > lastMatchEnd) {
        final precedingText = text.substring(lastMatchEnd, match.start);
        spans.addAll(_buildHighlightedSpans(precedingText));
      }

      final url = match.group(0)!;
      spans.add(
        TextSpan(
          text: url,
          style: const TextStyle(
            color: Color(0xFF53BDEB),
            decoration: TextDecoration.underline,
            decorationColor: Color(0xFF53BDEB),
          ),
          recognizer: TapGestureRecognizer()..onTap = () => _openUrl(url),
        ),
      );

      lastMatchEnd = match.end;
    }

    if (lastMatchEnd < text.length) {
      final trailingText = text.substring(lastMatchEnd);
      spans.addAll(_buildHighlightedSpans(trailingText));
    }

    return SelectableText.rich(
      TextSpan(
        children: spans,
        style: const TextStyle(fontSize: 14, color: Colors.white),
      ),
    );
  }

  List<InlineSpan> _buildHighlightedSpans(String rawSegment) {
    if (searchHighlight.isEmpty ||
        !rawSegment.toLowerCase().contains(searchHighlight)) {
      return [
        TextSpan(text: rawSegment, style: const TextStyle(color: Colors.white))
      ];
    }

    final spans = <InlineSpan>[];
    int start = 0;
    while (true) {
      final index = rawSegment.toLowerCase().indexOf(searchHighlight, start);
      if (index == -1) {
        spans.add(TextSpan(
            text: rawSegment.substring(start),
            style: const TextStyle(color: Colors.white)));
        break;
      }
      if (index > start) {
        spans.add(TextSpan(
            text: rawSegment.substring(start, index),
            style: const TextStyle(color: Colors.white)));
      }
      spans.add(TextSpan(
        text: rawSegment.substring(index, index + searchHighlight.length),
        style: const TextStyle(
          backgroundColor: Colors.yellow,
          color: Colors.black,
          fontWeight: FontWeight.bold,
        ),
      ));
      start = index + searchHighlight.length;
    }
    return spans;
  }

  Widget _buildMedia(BuildContext context) {
    return FutureBuilder<Directory>(
      future: ArchiveStorage.getBaseDir(),
      builder: (ctx, snap) {
        if (!snap.hasData) return const SizedBox.shrink();

        final baseDir = snap.data!;
        final chatDir = Directory(p.join(baseDir.path, chatId));
        final mediaDir = Directory(p.join(chatDir.path, 'media'));
        final rawAttachment = message.attachmentFileName!.trim();

        File file = File(p.join(mediaDir.path, rawAttachment));
        if (!file.existsSync()) {
          file = File(p.join(chatDir.path, rawAttachment));
        }

        if (!file.existsSync() && mediaDir.existsSync()) {
          try {
            final files = mediaDir.listSync().whereType<File>();
            final match = files.firstWhere(
              (f) =>
                  p.basename(f.path).toLowerCase() ==
                  rawAttachment.toLowerCase(),
              orElse: () => file,
            );
            file = match;
          } catch (_) {}
        }

        if (!file.existsSync()) {
          return Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
                color: Colors.black26, borderRadius: BorderRadius.circular(6)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.broken_image,
                    color: Colors.orangeAccent, size: 18),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    rawAttachment,
                    style: const TextStyle(
                        color: Colors.orangeAccent, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        }

        switch (message.type) {
          case MessageType.image:
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => _openImageFullscreen(context, file),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  width: 260,
                  height: 260,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    color: Colors.black12,
                  ),
                  child: Hero(
                    tag: file.path,
                    child: Image.file(
                      file,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
            );

          case MessageType.audio:
            return AudioPlayerWidget(filePath: file.path);

          case MessageType.video:
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => _openWithSystemDefault(file.path),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  height: 180,
                  width: 240,
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const Icon(Icons.play_circle_fill,
                          size: 54, color: Colors.white70),
                      Positioned(
                        bottom: 8,
                        left: 8,
                        right: 8,
                        child: Text(
                          rawAttachment,
                          style: const TextStyle(
                              color: Colors.white60, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );

          default:
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => _openWithSystemDefault(file.path),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.insert_drive_file,
                          color: Color(0xFF53BDEB), size: 28),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              rawAttachment,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const Text(
                              'Click to open',
                              style: TextStyle(
                                  color: Colors.white54, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
        }
      },
    );
  }

  void _openImageFullscreen(BuildContext context, File imageFile) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Stack(
        children: [
          Center(
            child: InteractiveViewer(
              clipBehavior: Clip.none,
              minScale: 0.5,
              maxScale: 5.0,
              child: Hero(
                tag: imageFile.path,
                child: Image.file(imageFile, fit: BoxFit.contain),
              ),
            ),
          ),
          Positioned(
            top: 20,
            right: 20,
            child: Material(
              color: Colors.transparent,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ),
          Positioned(
            bottom: 20,
            right: 20,
            child: Material(
              color: Colors.transparent,
              child: TextButton.icon(
                icon: const Icon(Icons.open_in_new,
                    color: Colors.white70, size: 16),
                label: const Text('Open in System App',
                    style: TextStyle(color: Colors.white70)),
                onPressed: () => _openWithSystemDefault(imageFile.path),
              ),
            ),
          )
        ],
      ),
    );
  }

  void _openWithSystemDefault(String filePath) {
    if (Platform.isMacOS) {
      Process.run('open', [filePath]);
    } else if (Platform.isWindows) {
      Process.run('cmd', ['/c', 'start', '', filePath]);
    }
  }

  void _openUrl(String url) {
    if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else if (Platform.isWindows) {
      Process.run('cmd', ['/c', 'start', '', url]);
    }
  }
}

// -----------------------------------------------------------------------------
// Voice Note / Audio Player
// -----------------------------------------------------------------------------

class AudioPlayerWidget extends StatefulWidget {
  final String filePath;
  const AudioPlayerWidget({super.key, required this.filePath});

  @override
  State<AudioPlayerWidget> createState() => _AudioPlayerWidgetState();
}

class _AudioPlayerWidgetState extends State<AudioPlayerWidget> {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    _initAudio();
  }

  Future<void> _initAudio() async {
    try {
      final dur = await _player.setFilePath(widget.filePath);
      if (!mounted) return;
      if (dur != null) setState(() => _duration = dur);

      _player.positionStream.listen((p) {
        if (mounted) setState(() => _position = p);
      });
      _player.playerStateStream.listen((s) {
        if (mounted) {
          setState(() => _isPlaying =
              s.playing && s.processingState != ProcessingState.completed);
        }
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 260,
      margin: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          IconButton(
            icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white),
            onPressed: () {
              if (_isPlaying) {
                _player.pause();
              } else {
                _player.play();
              }
            },
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6)),
              child: Slider(
                value: _position.inMilliseconds
                    .clamp(0, _duration.inMilliseconds)
                    .toDouble(),
                max: _duration.inMilliseconds.toDouble() > 0
                    ? _duration.inMilliseconds.toDouble()
                    : 1.0,
                activeColor: const Color(0xFF00A884),
                inactiveColor: Colors.white24,
                onChanged: (v) =>
                    _player.seek(Duration(milliseconds: v.toInt())),
              ),
            ),
          ),
          InkWell(
            onTap: () {
              setState(() {
                if (_speed == 1.0) {
                  _speed = 1.5;
                } else if (_speed == 1.5) {
                  _speed = 2.0;
                } else {
                  _speed = 1.0;
                }
                _player.setSpeed(_speed);
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(4)),
              child: Text('${_speed}x',
                  style: const TextStyle(fontSize: 11, color: Colors.white70)),
            ),
          )
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Interactive Media, Links & Docs Drawer
// -----------------------------------------------------------------------------

class MediaDrawer extends StatelessWidget {
  final String chatId;
  final List<ChatMessage> messages;
  final VoidCallback onClose;

  const MediaDrawer({
    super.key,
    required this.chatId,
    required this.messages,
    required this.onClose,
  });

  void _openFile(String filePath) {
    if (Platform.isMacOS) {
      Process.run('open', [filePath]);
    } else if (Platform.isWindows) {
      Process.run('cmd', ['/c', 'start', '', filePath]);
    }
  }

  void _openUrl(String rawUrl) {
    final uriMatch = RegExp(r'https?:\/\/[^\s]+').firstMatch(rawUrl);
    if (uriMatch != null) {
      final url = uriMatch.group(0)!;
      if (Platform.isMacOS) {
        Process.run('open', [url]);
      } else if (Platform.isWindows) {
        Process.run('cmd', ['/c', 'start', '', url]);
      }
    }
  }

  void _openImageFullscreen(BuildContext context, File imageFile) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Stack(
        children: [
          Center(
            child: InteractiveViewer(
              clipBehavior: Clip.none,
              minScale: 0.5,
              maxScale: 5.0,
              child: Hero(
                tag: 'drawer_${imageFile.path}',
                child: Image.file(imageFile, fit: BoxFit.contain),
              ),
            ),
          ),
          Positioned(
            top: 20,
            right: 20,
            child: Material(
              color: Colors.transparent,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ),
          Positioned(
            bottom: 20,
            right: 20,
            child: Material(
              color: Colors.transparent,
              child: TextButton.icon(
                icon: const Icon(Icons.open_in_new,
                    color: Colors.white70, size: 16),
                label: const Text('Open in System App',
                    style: TextStyle(color: Colors.white70)),
                onPressed: () => _openFile(imageFile.path),
              ),
            ),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaMsgs = messages
        .where((m) =>
            m.type == MessageType.image ||
            m.type == MessageType.video)
        .toList();
    final docMsgs =
        messages.where((m) => m.type == MessageType.document).toList();
    final linkMsgs = messages
        .where((m) =>
            m.content.contains('http://') || m.content.contains('https://'))
        .toList();

    return DefaultTabController(
      length: 3,
      child: Container(
        color: const Color(0xFF242424),
        child: Column(
          children: [
            Container(
              height: 60,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              color: const Color(0xFF1C1C1C),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: onClose,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Contact Info / Media',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const TabBar(
              indicatorColor: Color(0xFF00A884),
              labelColor: Color(0xFF00A884),
              unselectedLabelColor: Color(0xFF8696A0),
              tabs: [
                Tab(text: 'Media'),
                Tab(text: 'Docs'),
                Tab(text: 'Links'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  // 1. Interactive Media Grid
                  FutureBuilder<Directory>(
                    future: ArchiveStorage.getBaseDir(),
                    builder: (ctx, snap) {
                      if (!snap.hasData) return const SizedBox.shrink();
                      final mediaDir =
                          Directory(p.join(snap.data!.path, chatId, 'media'));

                      if (mediaMsgs.isEmpty) {
                        return const Center(
                          child: Text('No media found',
                              style: TextStyle(color: Color(0xFF8696A0))),
                        );
                      }

                      return GridView.builder(
                        padding: const EdgeInsets.all(8),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 4,
                          mainAxisSpacing: 4,
                        ),
                        itemCount: mediaMsgs.length,
                        itemBuilder: (ctx, i) {
                          final msg = mediaMsgs[i];
                          final filename = msg.attachmentFileName ?? '';
                          final file = File(p.join(mediaDir.path, filename));

                          if (!file.existsSync()) {
                            return Container(
                              color: Colors.white10,
                              child: const Icon(Icons.broken_image,
                                  color: Colors.white24),
                            );
                          }

                          if (msg.type == MessageType.video) {
                            return MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: () => _openFile(file.path),
                                child: Container(
                                  color: Colors.black45,
                                  child: const Center(
                                    child: Icon(Icons.play_circle_fill,
                                        color: Colors.white70, size: 36),
                                  ),
                                ),
                              ),
                            );
                          }

                          return MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () => _openImageFullscreen(context, file),
                              child: Hero(
                                tag: 'drawer_${file.path}',
                                child: Image.file(
                                  file,
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true,
                                  errorBuilder: (_, __, ___) => Container(
                                    color: Colors.white10,
                                    child: const Center(
                                      child: Icon(Icons.broken_image,
                                          color: Colors.white24),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),

                  // 2. Interactive Docs List
                  FutureBuilder<Directory>(
                    future: ArchiveStorage.getBaseDir(),
                    builder: (ctx, snap) {
                      if (docMsgs.isEmpty) {
                        return const Center(
                          child: Text('No documents found',
                              style: TextStyle(color: Color(0xFF8696A0))),
                        );
                      }

                      return ListView.builder(
                        itemCount: docMsgs.length,
                        itemBuilder: (ctx, i) {
                          final msg = docMsgs[i];
                          final name = msg.attachmentFileName ?? 'Document';
                          return ListTile(
                            leading: const Icon(Icons.description,
                                color: Color(0xFF53BDEB)),
                            title: Text(name,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 13)),
                            subtitle: Text(
                              DateFormat('dd/MM/yyyy').format(msg.timestamp),
                              style: const TextStyle(
                                  color: Color(0xFF8696A0), fontSize: 11),
                            ),
                            trailing: const Icon(Icons.open_in_new,
                                size: 16, color: Color(0xFF8696A0)),
                            onTap: () {
                              if (snap.hasData) {
                                final path = p.join(
                                    snap.data!.path, chatId, 'media', name);
                                _openFile(path);
                              }
                            },
                          );
                        },
                      );
                    },
                  ),

                  // 3. Interactive Links List
                  linkMsgs.isEmpty
                      ? const Center(
                          child: Text('No links found',
                              style: TextStyle(color: Color(0xFF8696A0))),
                        )
                      : ListView.builder(
                          itemCount: linkMsgs.length,
                          itemBuilder: (ctx, i) {
                            final linkText = linkMsgs[i].content;
                            return ListTile(
                              leading: const Icon(Icons.link,
                                  color: Color(0xFF00A884)),
                              title: Text(
                                linkText,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF53BDEB),
                                  fontSize: 13,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                              subtitle: Text(
                                DateFormat('dd/MM/yyyy')
                                    .format(linkMsgs[i].timestamp),
                                style: const TextStyle(
                                    color: Color(0xFF8696A0), fontSize: 11),
                              ),
                              trailing: const Icon(Icons.launch,
                                  size: 16, color: Color(0xFF8696A0)),
                              onTap: () => _openUrl(linkText),
                            );
                          },
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}