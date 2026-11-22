import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data.dart';

const Color sakinahGreen = Color(0xFF176B50);
const Color sakinahDeep = Color(0xFF104A3A);
const Color sakinahMint = Color(0xFFE8F1E9);
const Color sakinahInk = Color(0xFF1D3028);

String normalizeArabic(String input) {
  return input
      .replaceAll(RegExp(r'[\u064B-\u065F\u0670\u0640]'), '')
      .replaceAll(RegExp('[أإآٱ]'), 'ا')
      .replaceAll('ى', 'ي')
      .replaceAll('ؤ', 'و')
      .replaceAll('ئ', 'ي')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

class DailyWorshipPage extends StatefulWidget {
  const DailyWorshipPage({super.key});

  @override
  State<DailyWorshipPage> createState() => _DailyWorshipPageState();
}

class _DailyWorshipPageState extends State<DailyWorshipPage> {
  final Map<String, bool> _values = {};
  bool _loading = true;

  static const _prayers = <(String, String)>[
    ('fajr', 'صلاة الفجر'),
    ('dhuhr', 'صلاة الظهر'),
    ('asr', 'صلاة العصر'),
    ('maghrib', 'صلاة المغرب'),
    ('isha', 'صلاة العشاء'),
  ];
  static const _habits = <(String, String)>[
    ('quran', 'ورد القرآن الكريم'),
    ('morning', 'أذكار الصباح'),
    ('evening', 'أذكار المساء'),
    ('witr', 'صلاة الوتر'),
    ('duha', 'صلاة الضحى'),
    ('fast', 'صيام تطوع'),
    ('salawat', 'الصلاة على النبي ﷺ'),
  ];

  String get _dateKey {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  String _key(String id) => 'worship_${_dateKey}_$id';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    for (final item in [..._prayers, ..._habits]) {
      _values[item.$1] = prefs.getBool(_key(item.$1)) ?? false;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _toggle(String id, bool value) async {
    setState(() => _values[id] = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key(id), value);
  }

  Future<int> _streak() async {
    final prefs = await SharedPreferences.getInstance();
    var day = DateTime.now();
    bool complete(DateTime date) {
      final keyDate = '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      return _prayers.every((p) => prefs.getBool('worship_${keyDate}_${p.$1}') == true);
    }
    if (!complete(day)) day = day.subtract(const Duration(days: 1));
    var count = 0;
    for (var i = 0; i < 365; i++) {
      if (!complete(day)) break;
      count++;
      day = day.subtract(const Duration(days: 1));
    }
    return count;
  }

  @override
  Widget build(BuildContext context) {
    final prayerDone = _prayers.where((p) => _values[p.$1] == true).length;
    final habitDone = _habits.where((p) => _values[p.$1] == true).length;
    return Scaffold(
      appBar: AppBar(title: const Text('متابعة عباداتي')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: sakinahGreen))
          : FutureBuilder<int>(
              future: _streak(),
              builder: (context, snapshot) => ListView(
                padding: const EdgeInsets.all(18),
                children: [
                  _ProgressCard(
                    title: 'إنجازك اليوم',
                    subtitle: 'تابع عباداتك بهدوء ودون مقارنة مع الآخرين',
                    value: (prayerDone + habitDone) / (_prayers.length + _habits.length),
                    trailing: '$prayerDone / 5 صلوات',
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: const CircleAvatar(backgroundColor: sakinahMint, child: Icon(Icons.local_fire_department, color: sakinahGreen)),
                      title: const Text('أيام المحافظة على الصلوات الخمس', style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: const Text('يُحسب اليوم ضمن السلسلة عند تسجيل الصلوات الخمس'),
                      trailing: Text('${snapshot.data ?? 0} يوم', style: const TextStyle(color: sakinahDeep, fontWeight: FontWeight.w900, fontSize: 18)),
                    ),
                  ),
                  const _ExtraSectionTitle('الصلوات المفروضة'),
                  for (final item in _prayers) _CheckTile(title: item.$2, checked: _values[item.$1] ?? false, onChanged: (v) => _toggle(item.$1, v)),
                  const _ExtraSectionTitle('أعمال نافعة'),
                  for (final item in _habits) _CheckTile(title: item.$2, checked: _values[item.$1] ?? false, onChanged: (v) => _toggle(item.$1, v)),
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text('هذه الصفحة للتذكير والتنظيم الشخصي فقط. لا تُصدر أحكاماً على صحة العبادة أو قبولها.', style: TextStyle(color: Colors.black54, height: 1.6, fontSize: 12)),
                  ),
                ],
              ),
            ),
    );
  }
}

class KhatmahPlannerPage extends StatefulWidget {
  const KhatmahPlannerPage({super.key});

  @override
  State<KhatmahPlannerPage> createState() => _KhatmahPlannerPageState();
}

class _KhatmahPlannerPageState extends State<KhatmahPlannerPage> {
  int _days = 30;
  int _page = 0;
  DateTime? _started;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final rawDate = prefs.getString('khatmah_started');
    if (!mounted) return;
    setState(() {
      _days = prefs.getInt('khatmah_days') ?? 30;
      _page = prefs.getInt('khatmah_page') ?? 0;
      _started = rawDate == null ? null : DateTime.tryParse(rawDate);
      _loading = false;
    });
  }

  Future<void> _start(int days, {bool resetProgress = true}) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final startDate = resetProgress ? DateTime(now.year, now.month, now.day) : (_started ?? DateTime(now.year, now.month, now.day));
    await prefs.setInt('khatmah_days', days);
    if (resetProgress) await prefs.setInt('khatmah_page', 0);
    await prefs.setString('khatmah_started', startDate.toIso8601String());
    if (!mounted) return;
    setState(() {
      _days = days;
      if (resetProgress) _page = 0;
      _started = startDate;
    });
  }

  Future<void> _setPage(int value) async {
    final next = value.clamp(0, 604).toInt();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('khatmah_page', next);
    if (mounted) setState(() => _page = next);
  }

  Future<void> _choosePlan() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 22),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('اختر مدة ختم القرآن', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: sakinahDeep)),
            const SizedBox(height: 12),
            for (final days in [7, 15, 30, 40, 60, 90])
              ListTile(title: Text('ختمة خلال $days يوماً'), subtitle: Text('نحو ${ (604 / days).ceil() } صفحة يومياً'), trailing: const Icon(Icons.chevron_left), onTap: () => Navigator.pop(context, days)),
          ]),
        ),
      ),
    );
    if (selected != null) await _start(selected, resetProgress: _started == null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator(color: sakinahGreen)));
    final daily = (604 / _days).ceil();
    final daysElapsed = _started == null ? 0 : DateTime.now().difference(_started!).inDays + 1;
    final targetByNow = math.min(604, daily * daysElapsed);
    final remainingToday = math.max(0, targetByNow - _page);
    final progress = _page / 604;
    return Scaffold(
      appBar: AppBar(title: const Text('خطة ختم القرآن')),
      body: ListView(padding: const EdgeInsets.all(18), children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(gradient: const LinearGradient(colors: [sakinahDeep, sakinahGreen]), borderRadius: BorderRadius.circular(25)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.menu_book_rounded, color: Colors.white, size: 35),
            const SizedBox(height: 12),
            Text(_started == null ? 'ابدأ ختمتك على مهل' : 'رحلتك مع القرآن مستمرة', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text(_started == null ? 'اختر مدة تناسب وقتك، ويمكنك تعديل الخطة لاحقاً.' : 'خطة $_days يوماً · $_page من 604 صفحة', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 18),
            ClipRRect(borderRadius: BorderRadius.circular(20), child: LinearProgressIndicator(value: progress, minHeight: 10, backgroundColor: Colors.white24, color: Colors.white)),
            const SizedBox(height: 8),
            Text('${(progress * 100).toStringAsFixed(1)}٪ من المصحف', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ]),
        ),
        const SizedBox(height: 14),
        if (_started == null)
          FilledButton.icon(onPressed: _choosePlan, icon: const Icon(Icons.add_task), label: const Text('إنشاء خطة ختمة'))
        else ...[
          _ProgressCard(title: 'هدفك اليوم', subtitle: 'المعدل اليومي التقريبي: $daily صفحة', value: math.min(1.0, _page / math.max(1, targetByNow)).toDouble(), trailing: remainingToday == 0 ? 'أنجزت هدف اليوم' : 'باقي $remainingToday صفحة'),
          const SizedBox(height: 12),
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('تحديث موضع القراءة', style: TextStyle(fontWeight: FontWeight.w900, color: sakinahDeep, fontSize: 17)),
            const SizedBox(height: 8),
            Text('آخر صفحة أنهيتها: ${_page == 0 ? 'لم تبدأ بعد' : _page}'),
            Slider(value: _page.toDouble(), min: 0, max: 604, divisions: 604, onChanged: (v) => setState(() => _page = v.round()), onChangeEnd: (v) => _setPage(v.round())),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(onPressed: () => _setPage(_page + 1), child: const Text('+ صفحة')),
              OutlinedButton(onPressed: () => _setPage(_page + 5), child: const Text('+ 5 صفحات')),
              OutlinedButton(onPressed: () => _setPage(_page + 10), child: const Text('+ 10 صفحات')),
              TextButton(onPressed: _choosePlan, child: const Text('تغيير مدة الخطة')),
            ]),
            const SizedBox(height: 4),
            const Text('المصحف المدني الشائع يتكون من 604 صفحات تقريباً؛ قد يختلف ترقيم الصفحات باختلاف طبعة المصحف.', style: TextStyle(color: Colors.black54, fontSize: 11, height: 1.5)),
          ]))),
          if (_page >= 604) const Card(child: ListTile(leading: Icon(Icons.celebration, color: sakinahGreen), title: Text('ما شاء الله! أكملت صفحات الخطة.'), subtitle: Text('يمكنك بدء ختمة جديدة متى أحببت.'))),
          OutlinedButton.icon(onPressed: () async { final confirm = await showDialog<bool>(context: context, builder: (c) => AlertDialog(title: const Text('إعادة بدء الخطة؟'), content: const Text('سيتم تصفير تقدم هذه الختمة وبدء خطة جديدة.'), actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('إعادة البدء'))])); if (confirm == true) await _start(_days); }, icon: const Icon(Icons.restart_alt), label: const Text('بدء الخطة من جديد')),
        ],
      ]),
    );
  }
}

class QuranSearchPage extends StatefulWidget {
  final ValueChanged<int>? onOpenSurah;
  const QuranSearchPage({super.key, this.onOpenSurah});

  @override
  State<QuranSearchPage> createState() => _QuranSearchPageState();
}

class _QuranSearchPageState extends State<QuranSearchPage> {
  final _controller = TextEditingController();
  List<Map<String, dynamic>> _allAyahs = [];
  List<Map<String, dynamic>> _results = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadQuran();
  }

  Future<void> _loadQuran() async {
    try {
      final root = await getApplicationSupportDirectory();
      final file = File('${root.path}/quran/quran-uthmani.json');
      Map<String, dynamic> decoded;
      if (await file.exists()) {
        decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      } else {
        final response = await http.get(Uri.parse('https://api.alquran.cloud/v1/quran/quran-uthmani')).timeout(const Duration(minutes: 2));
        if (response.statusCode != 200) throw Exception('تعذر الاتصال بمصدر القرآن');
        decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final list = (decoded['data'] as Map?)?['surahs'];
        final count = list is List ? list.fold<int>(0, (sum, s) => sum + ((s as Map)['ayahs'] as List).length) : 0;
        if (list is! List || list.length != 114 || count != 6236) throw Exception('لم تكتمل بيانات المصحف من المصدر');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(response.bodyBytes, flush: true);
      }
      final chapters = (decoded['data'] as Map<String, dynamic>)['surahs'] as List;
      final all = <Map<String, dynamic>>[];
      for (final chapter in chapters) {
        for (final ayah in (chapter as Map)['ayahs'] as List) {
          all.add({'surah': chapter['number'], 'surahName': chapter['name'], 'ayah': ayah['numberInSurah'], 'text': ayah['text']});
        }
      }
      if (!mounted) return;
      setState(() { _allAyahs = all; _loading = false; });
      if (_controller.text.trim().length >= 2) _search(_controller.text);
    } catch (e) {
      if (mounted) setState(() { _error = e.toString().replaceFirst('Exception: ', ''); _loading = false; });
    }
  }

  void _search(String value) {
    final query = normalizeArabic(value);
    if (query.length < 2) { setState(() => _results = []); return; }
    final matches = <Map<String, dynamic>>[];
    for (final ayah in _allAyahs) {
      if (normalizeArabic(ayah['text'] as String).contains(query)) {
        matches.add(ayah);
        if (matches.length >= 150) break;
      }
    }
    setState(() => _results = matches);
  }

  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('البحث في القرآن')),
    body: Column(children: [
      Padding(padding: const EdgeInsets.all(16), child: TextField(controller: _controller, onChanged: _search, textDirection: TextDirection.rtl, decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'اكتب كلمة أو جزءاً من آية', filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none)))),
      if (_loading) const Expanded(child: Center(child: CircularProgressIndicator(color: sakinahGreen)))
      else if (_error != null) Expanded(child: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('$_error\nاتصل بالإنترنت أول مرة لتحميل نص المصحف.', textAlign: TextAlign.center))))
      else Expanded(child: _results.isEmpty ? Center(child: Text(_controller.text.length < 2 ? 'ابدأ بكتابة كلمتين على الأقل' : 'لا توجد نتائج مطابقة', style: const TextStyle(color: Colors.black54))) : ListView.builder(padding: const EdgeInsets.symmetric(horizontal: 16), itemCount: _results.length, itemBuilder: (context, i) {
        final a = _results[i];
        return Card(child: ListTile(onTap: () => widget.onOpenSurah?.call(a['surah'] as int), title: Text(a['text'] as String, textAlign: TextAlign.right, style: const TextStyle(fontSize: 19, height: 1.8, color: sakinahInk)), subtitle: Text('سورة ${surahs[(a['surah'] as int) - 1].name} · الآية ${a['ayah']}'), trailing: const Icon(Icons.menu_book, color: sakinahGreen))); 
      })),
    ]),
  );
}

class BookmarkStore {
  static const _storageKey = 'quran_bookmarks_v1';

  static Future<List<Map<String, dynamic>>> all() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null) return [];
    try { return (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList(); } catch (_) { return []; }
  }

  static Future<void> add(Map<String, dynamic> bookmark) async {
    final items = await all();
    final exists = items.any((e) => e['surah'] == bookmark['surah'] && e['ayah'] == bookmark['ayah']);
    if (!exists) items.insert(0, bookmark);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(items));
  }

  static Future<void> remove(int surah, int ayah) async {
    final items = await all();
    items.removeWhere((e) => e['surah'] == surah && e['ayah'] == ayah);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(items));
  }
}

class BookmarksPage extends StatefulWidget {
  final ValueChanged<int>? onOpenSurah;
  const BookmarksPage({super.key, this.onOpenSurah});
  @override
  State<BookmarksPage> createState() => _BookmarksPageState();
}

class _BookmarksPageState extends State<BookmarksPage> {
  List<Map<String, dynamic>> _items = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async { final rows = await BookmarkStore.all(); if (mounted) setState(() => _items = rows); }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('علاماتي المحفوظة')),
    body: _items.isEmpty
        ? const Center(child: Text('لم تحفظ آيات بعد', style: TextStyle(color: Colors.black54)))
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final item in _items)
                Card(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => widget.onOpenSurah?.call(item['surah'] as int),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item['text'] as String, textAlign: TextAlign.right, style: const TextStyle(fontSize: 21, height: 1.9, color: sakinahInk)),
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(child: Text('سورة ${item['surahName']} · الآية ${item['ayah']} · اضغط للفتح', style: const TextStyle(color: sakinahGreen, fontWeight: FontWeight.bold))),
                            IconButton(
                              tooltip: 'حذف العلامة',
                              onPressed: () async {
                                await BookmarkStore.remove(item['surah'] as int, item['ayah'] as int);
                                await _load();
                              },
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ]),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
  );

}

class AyahCardPage extends StatefulWidget {
  final String ayahText;
  final String reference;
  const AyahCardPage({super.key, required this.ayahText, required this.reference});

  @override
  State<AyahCardPage> createState() => _AyahCardPageState();
}

class _AyahCardPageState extends State<AyahCardPage> {
  bool _busy = false;

  Future<void> _shareImage() async {
    setState(() => _busy = true);
    try {
      const width = 1080.0;
      const height = 1350.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, width, height));
      final bounds = const Rect.fromLTWH(0, 0, width, height);
      final bg = Paint()..shader = const LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [Color(0xFF063F30), Color(0xFF0B8B61), Color(0xFF062F27)]).createShader(bounds);
      canvas.drawRect(bounds, bg);
      final border = Paint()..color = const Color(0xFFD5BD7A)..style = PaintingStyle.stroke..strokeWidth = 4;
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(42, 42, 996, 1266), const Radius.circular(42)), border);
      final ornament = Paint()..color = const Color(0x44FFFFFF)..style = PaintingStyle.stroke..strokeWidth = 2;
      canvas.drawCircle(const Offset(540, 160), 62, ornament);
      _drawCentered(canvas, 'سَكينة', 104, 145, 870, 56, const Color(0xFFFFF4D2), FontWeight.w800);
      _drawCentered(canvas, 'آية من القرآن الكريم', 104, 260, 870, 38, const Color(0xFFD9F1E6), FontWeight.w500);
      final ayahFontSize = widget.ayahText.length > 300 ? 38.0 : widget.ayahText.length > 180 ? 44.0 : 53.0;
      final text = TextPainter(text: TextSpan(text: widget.ayahText, style: TextStyle(fontSize: ayahFontSize, height: 1.65, color: Colors.white, fontWeight: FontWeight.w500)), textDirection: TextDirection.rtl, textAlign: TextAlign.center);
      text.layout(maxWidth: 850);
      final textY = (height - text.height) / 2 - 30;
      text.paint(canvas, Offset((width - text.width) / 2, textY));
      canvas.drawLine(const Offset(390, 1090), const Offset(690, 1090), Paint()..color = const Color(0xFFD5BD7A)..strokeWidth = 3);
      _drawCentered(canvas, widget.reference, 100, 1120, 880, 34, const Color(0xFFFFF4D2), FontWeight.w700);
      _drawCentered(canvas, 'تلاوة وتدبّر · تطبيق سَكينة', 100, 1200, 880, 27, const Color(0xFFD9F1E6), FontWeight.w400);
      final picture = recorder.endRecording();
      ui.Image? image;
      try {
        image = await picture.toImage(width.toInt(), height.toInt());
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw Exception('تعذر إنشاء الصورة');
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/sakinah_ayah_${DateTime.now().millisecondsSinceEpoch}.png');
        await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
        await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: '${widget.ayahText}\n${widget.reference}\nتطبيق سَكينة'));
      } finally {
        image?.dispose();
        picture.dispose();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر إنشاء بطاقة الآية: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _drawCentered(Canvas canvas, String text, double x, double y, double maxWidth, double size, Color color, FontWeight weight) {
    final painter = TextPainter(text: TextSpan(text: text, style: TextStyle(fontSize: size, color: color, fontWeight: weight)), textDirection: TextDirection.rtl, textAlign: TextAlign.center);
    painter.layout(maxWidth: maxWidth);
    painter.paint(canvas, Offset(x + (maxWidth - painter.width) / 2, y));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('بطاقة آية')),
    body: ListView(padding: const EdgeInsets.all(18), children: [
      Container(padding: const EdgeInsets.all(22), decoration: BoxDecoration(gradient: const LinearGradient(colors: [sakinahDeep, sakinahGreen]), borderRadius: BorderRadius.circular(25)), child: Column(children: [const Text('سَكينة', style: TextStyle(color: Color(0xFFFFF4D2), fontSize: 27, fontWeight: FontWeight.w900)), const SizedBox(height: 22), Text(widget.ayahText, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 23, height: 2)), const SizedBox(height: 20), Text(widget.reference, style: const TextStyle(color: Color(0xFFFFF4D2), fontWeight: FontWeight.bold)), const SizedBox(height: 10), const Text('تلاوة وتدبّر', style: TextStyle(color: Colors.white70))])),
      const SizedBox(height: 16),
      FilledButton.icon(onPressed: _busy ? null : _shareImage, icon: const Icon(Icons.image_outlined), label: Text(_busy ? 'جارٍ تجهيز البطاقة...' : 'إنشاء الصورة ومشاركتها')),
      const Padding(padding: EdgeInsets.only(top: 12), child: Text('تُنشأ البطاقة من نص الآية الذي وصل من مصدر المصحف، مع إبقاء مرجع السورة والآية ظاهراً.', style: TextStyle(color: Colors.black54, height: 1.6, fontSize: 12))),
    ]),
  );
}

class _ProgressCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final double value;
  final String trailing;
  const _ProgressCard({required this.title, required this.subtitle, required this.value, required this.trailing});
  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: const EdgeInsets.all(17), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: sakinahDeep)), const SizedBox(height: 4), Text(subtitle, style: const TextStyle(color: Colors.black54, fontSize: 12)), const SizedBox(height: 13), ClipRRect(borderRadius: BorderRadius.circular(20), child: LinearProgressIndicator(value: value.clamp(0, 1).toDouble(), minHeight: 9, color: sakinahGreen, backgroundColor: sakinahMint)), const SizedBox(height: 7), Align(alignment: Alignment.centerLeft, child: Text(trailing, style: const TextStyle(fontWeight: FontWeight.bold, color: sakinahGreen)))])));
}

class _ExtraSectionTitle extends StatelessWidget {
  final String text;
  const _ExtraSectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.fromLTRB(3, 18, 3, 8), child: Text(text, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: sakinahDeep)));
}

class _CheckTile extends StatelessWidget {
  final String title;
  final bool checked;
  final ValueChanged<bool> onChanged;
  const _CheckTile({required this.title, required this.checked, required this.onChanged});
  @override
  Widget build(BuildContext context) => Card(child: CheckboxListTile(value: checked, activeColor: sakinahGreen, onChanged: (value) => onChanged(value ?? false), title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)), controlAffinity: ListTileControlAffinity.leading));
}
