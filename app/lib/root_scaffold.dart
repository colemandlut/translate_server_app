import 'package:flutter/material.dart';
import 'home_page.dart';
import 'recordings_list_page.dart';

/// Two-tab shell: Live translator + Recordings list. Uses IndexedStack so
/// HomePage keeps its mic / ws / sherpa state alive when the user dips into
/// the recordings tab and back.
class RootScaffold extends StatefulWidget {
  const RootScaffold({super.key});

  @override
  State<RootScaffold> createState() => _RootScaffoldState();
}

class _RootScaffoldState extends State<RootScaffold> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      body: IndexedStack(
        index: _index,
        children: const [
          HomePage(),
          RecordingsListPage(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        backgroundColor: const Color(0xFF16213e),
        selectedItemColor: const Color(0xFF53a8ff),
        unselectedItemColor: const Color(0xFF7f8fa6),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.translate),
            label: '实时翻译',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.library_music),
            label: '录音',
          ),
        ],
      ),
    );
  }
}
