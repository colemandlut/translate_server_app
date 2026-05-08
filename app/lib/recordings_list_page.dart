import 'package:flutter/material.dart';
import 'models/recording.dart';
import 'services/recording_store.dart';
import 'recording_detail_page.dart';

class RecordingsListPage extends StatefulWidget {
  const RecordingsListPage({super.key});

  @override
  State<RecordingsListPage> createState() => _RecordingsListPageState();
}

class _RecordingsListPageState extends State<RecordingsListPage> {
  final _store = RecordingStore.instance;

  @override
  void initState() {
    super.initState();
    _store.ensureLoaded();
    _store.addListener(_rebuild);
  }

  @override
  void dispose() {
    _store.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  String _fmtDate(DateTime d) {
    final two = (int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  String _fmtDuration(Duration d) {
    final s = d.inSeconds;
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final items = _store.sessions;
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16213e),
        elevation: 0,
        title: const Text('录音', style: TextStyle(color: Color(0xFFe0e0ff))),
      ),
      body: SafeArea(
        child: !_store.loaded
            ? const Center(child: CircularProgressIndicator())
            : items.isEmpty
                ? const Center(
                    child: Text(
                      '还没有录音\n按主页的 Start 录一段试试',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF7f8fa6), fontSize: 16),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: items.length,
                    itemBuilder: (_, i) => _buildCard(items[i]),
                  ),
      ),
    );
  }

  Widget _buildCard(RecordingSession s) {
    final preview = s.liveTranscripts.isEmpty
        ? '(无识别结果)'
        : s.liveTranscripts.map((e) => e.original).where((t) => t.isNotEmpty).join('  ');
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => RecordingDetailPage(sessionId: s.id)),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF16213e),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(_fmtDate(s.createdAt),
                    style: const TextStyle(
                        color: Color(0xFFe0e0ff),
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(_fmtDuration(s.duration),
                    style: const TextStyle(
                        color: Color(0xFF7f8fa6), fontSize: 12)),
              ],
            ),
            const SizedBox(height: 4),
            Text('${s.langA} → ${s.langB}  ·  ${s.serverName}',
                style: const TextStyle(
                    color: Color(0xFF7f8fa6), fontSize: 11, letterSpacing: 0.5)),
            const SizedBox(height: 8),
            Text(
              preview.isEmpty ? '(空)' : preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Color(0xFFe0e0ff), fontSize: 14, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
