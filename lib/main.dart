import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:adhan_dart/adhan_dart.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data.dart';
import 'extra_pages.dart';

const Color forest = Color(0xFF15935A);
const Color deepGreen = Color(0xFF55C58A);
const Color mint = Color(0xFF14251C);
const Color gold = Color(0xFFD6B56D);
const Color goldSoft = Color(0xFF302818);
const Color ivory = Color(0xFF050706);
const Color ink = Color(0xFFF0F5F1);
const String appName = 'سَكينة';
const String quranApi = 'https://api.alquran.cloud/v1';
const String adhanUrl = 'https://upload.wikimedia.org/wikipedia/commons/b/b0/Beautiful_adhan.ogg';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SakinahApp());
}

class QuranStore {
  static Future<Directory> _dir() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/quran');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _fullFile() async => File('${(await _dir()).path}/quran-uthmani.json');
  static Future<File> _surahFile(int number) async => File('${(await _dir()).path}/surah-$number.json');

  static Future<bool> hasFullQuran() async => (await _fullFile()).exists();

  static Future<void> downloadFull({required void Function(double) onProgress}) async {
    final response = await http.get(Uri.parse('$quranApi/quran/quran-uthmani')).timeout(const Duration(minutes: 2));
    if (response.statusCode != 200) throw Exception('تعذر تنزيل نص القرآن (${response.statusCode})');
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final data = decoded['data'];
    if (data is! Map || data['surahs'] is! List || (data['surahs'] as List).length != 114) {
      throw Exception('استجابة مصدر القرآن غير مكتملة');
    }
    final totalAyahs = (data['surahs'] as List).fold<int>(
      0,
      (sum, item) => sum + ((item as Map)['ayahs'] as List).length,
    );
    if (totalAyahs != 6236) {
      throw Exception('عدد آيات القرآن في الاستجابة غير مكتمل');
    }
    final file = await _fullFile();
    await file.writeAsBytes(response.bodyBytes, flush: true);
    onProgress(1);
  }

  static Future<List<dynamic>> loadSurah(int number) async {
    final full = await _fullFile();
    if (await full.exists()) {
      final decoded = jsonDecode(await full.readAsString()) as Map<String, dynamic>;
      final data = decoded['data'] as Map<String, dynamic>;
      final chapters = data['surahs'] as List<dynamic>;
      final match = chapters.cast<Map<String, dynamic>>().firstWhere((s) => s['number'] == number);
      return (match['ayahs'] as List<dynamic>);
    }
    final file = await _surahFile(number);
    if (await file.exists()) {
      final cached = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (cached['data']['ayahs'] as List<dynamic>);
    }
    final response = await http.get(Uri.parse('$quranApi/surah/$number/quran-uthmani')).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) throw Exception('تعذر تحميل السورة. تحقق من الاتصال بالإنترنت.');
    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (decoded['data']?['ayahs'] is! List) throw Exception('بيانات السورة غير صحيحة');
    await file.writeAsBytes(response.bodyBytes, flush: true);
    return decoded['data']['ayahs'] as List<dynamic>;
  }
}

class AudioLibrary {
  static final Map<String, String> _externalServers = {};
  static final Map<String, Set<int>> _externalSurahs = {};
  static bool _requestedCatalogLoaded = false;

  static Future<void> loadRequestedReciters() async {
    if (_requestedCatalogLoaded) return;
    try {
      final response = await http.get(Uri.parse('https://mp3quran.net/api/v3/reciters?language=ar')).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw HttpException('MP3Quran HTTP ${response.statusCode}');
      final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final rows = (decoded['reciters'] as List<dynamic>? ?? []);
      const requested = <String>['خالد الجليل', 'ماهر المعيقلي', 'بدر التركي'];
      reciters.removeWhere((item) => item['source'] == 'mp3quran');
      for (final target in requested) {
        Map<String, dynamic>? reader;
        final normalizedTarget = normalizeArabic(target);
        for (final raw in rows) {
          if (raw is! Map<String, dynamic>) continue;
          final normalizedName = normalizeArabic(raw['name']?.toString() ?? '');
          if (normalizedName == normalizedTarget ||
              normalizedName.contains(normalizedTarget) ||
              normalizedTarget.contains(normalizedName)) {
            reader = raw;
            if (normalizedName == normalizedTarget) break;
          }
        }
        if (reader == null) continue;
        final moshafs = (reader['moshaf'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
        Map<String, dynamic>? selected;
        for (final moshaf in moshafs) {
          final count = int.tryParse(moshaf['surah_total']?.toString() ?? '') ?? 0;
          final title = moshaf['name']?.toString() ?? '';
          if (count >= 114 && (title.contains('حفص') || selected == null)) { selected = moshaf; if (title.contains('حفص')) break; }
        }
        if (selected == null) continue;
        final server = selected['server']?.toString();
        if (server == null || !server.startsWith('https://')) continue;
        final moshafId = selected['id']?.toString();
        if (moshafId == null || moshafId.isEmpty) continue;
        final edition = 'mp3quran_$moshafId';
        _externalServers[edition] = server.endsWith('/') ? server : '$server/';
        final rawSurahs = selected['surah_list']?.toString() ?? '';
        _externalSurahs[edition] = rawSurahs.split(',').map((v) => int.tryParse(v.trim())).whereType<int>().toSet();
        reciters.add({'name': target, 'edition': edition, 'bitrate': 'API', 'source': 'mp3quran'});
      }
      _requestedCatalogLoaded = true;
    } catch (_) {
      // Keep the verified AlQuran Cloud readers available when the device is offline.
    }
  }

  static Set<int>? availableSurahs(String edition) => _externalSurahs[edition];

  static Future<Directory> _dir() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/audio');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> adhanFile() async => File('${(await _dir()).path}/adhan.ogg');

  static Future<File> reciterDir(String edition) async {
    final dir = Directory('${(await _dir()).path}/recitations/$edition');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/.folder');
  }

  static String bitrateFor(String edition) =>
      reciters.firstWhere((item) => item['edition'] == edition, orElse: () => {'bitrate': '128'})['bitrate'] ?? '128';

  static String surahAudioUrl(int surah, String edition) {
    final externalServer = _externalServers[edition];
    if (externalServer != null) return '$externalServer${surah.toString().padLeft(3, '0')}.mp3';
    return 'https://cdn.islamic.network/quran/audio-surah/${bitrateFor(edition)}/$edition/$surah.mp3';
  }

  /// Downloads into a .part file. If a previous download was interrupted,
  /// the next request asks the server to continue from the existing byte count.
  static Future<File> downloadResumable(
    String url,
    File destination, {
    void Function(int received, int? total)? onProgress,
  }) async {
    await destination.parent.create(recursive: true);
    final partial = File('${destination.path}.part');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 25);
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        var existing = await partial.exists() ? await partial.length() : 0;
        final request = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 35));
        if (existing > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
        final response = await request.close().timeout(const Duration(minutes: 5));

        if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable && existing > 0) {
          await partial.delete();
          continue;
        }
        final append = response.statusCode == HttpStatus.partialContent;
        if (!append && response.statusCode != HttpStatus.ok) {
          throw HttpException('تعذر تنزيل الملف الصوتي (HTTP ${response.statusCode})', uri: Uri.parse(url));
        }
        if (!append) existing = 0; // Server ignored Range: restart safely.
        final total = response.contentLength >= 0
            ? response.contentLength + (append ? existing : 0)
            : null;
        var received = existing;
        onProgress?.call(received, total);
        final sink = partial.openWrite(mode: append ? FileMode.append : FileMode.write);
        try {
          await for (final chunk in response) {
            sink.add(chunk);
            received += chunk.length;
            onProgress?.call(received, total);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }

        final actualLength = await partial.length();
        if (actualLength < 1024) {
          throw const FormatException('الملف الصوتي المستلم قصير أو غير صالح؛ أعد المحاولة مع الاتصال بالإنترنت.');
        }
        if (total != null && actualLength != total) {
          throw const HttpException('انقطع التنزيل قبل اكتماله. أعد المحاولة وسيُستكمل من موضع التوقف.');
        }
        if (await destination.exists()) await destination.delete();
        return partial.rename(destination.path);
      }
      throw const HttpException('تعذر استكمال التنزيل. حاول مرة أخرى.');
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> downloadAdhan({required void Function(double) onProgress}) async {
    final file = await adhanFile();
    await downloadResumable(adhanUrl, file, onProgress: (received, total) {
      if (total != null && total > 0) onProgress((received / total).clamp(0.0, 1.0).toDouble());
    });
  }

  static Future<File> downloadSurah(String edition, int surah,
      {void Function(int, int?)? onProgress}) async {
    final allowed = _externalSurahs[edition];
    if (allowed != null && !allowed.contains(surah)) {
      throw const FormatException('هذه السورة غير متاحة في الإصدار الصوتي المختار.');
    }
    final marker = await reciterDir(edition);
    final destination = File('${marker.parent.path}/${surah.toString().padLeft(3, '0')}.mp3');
    if (await destination.exists() && await destination.length() > 1024) return destination;
    return downloadResumable(surahAudioUrl(surah, edition), destination, onProgress: onProgress);
  }

  static Future<void> downloadWholeQuran(
    String edition, {
    required void Function(int, int, int?, int?) onProgress,
  }) async {
    final allowed = _externalSurahs[edition];
    if (allowed != null && allowed.length < 114) {
      throw const FormatException('هذا الإصدار لا يحتوي على جميع سور القرآن؛ يمكن تنزيل السور المتاحة منفردة.');
    }
    for (var number = 1; number <= 114; number++) {
      final marker = await reciterDir(edition);
      final destination = File('${marker.parent.path}/${number.toString().padLeft(3, '0')}.mp3');
      if (!await destination.exists() || await destination.length() <= 1024) {
        await downloadResumable(surahAudioUrl(number, edition), destination,
            onProgress: (received, total) => onProgress(number, 114, received, total));
      }
      onProgress(number, 114, null, null);
    }
  }

  static Future<File?> downloadedSurah(String edition, int surah) async {
    final marker = await reciterDir(edition);
    final file = File('${marker.parent.path}/${surah.toString().padLeft(3, '0')}.mp3');
    return await file.exists() && await file.length() > 1024 ? file : null;
  }

  static Future<int> downloadedCount(String edition) async {
    final marker = await reciterDir(edition);
    var count = 0;
    for (var number = 1; number <= 114; number++) {
      final file = File('${marker.parent.path}/${number.toString().padLeft(3, '0')}.mp3');
      if (await file.exists() && await file.length() > 1024) count++;
    }
    return count;
  }

  static Future<void> deleteRecitations(String edition) async {
    final marker = await reciterDir(edition);
    final directory = marker.parent;
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// One app-wide player keeps a recitation alive when the user navigates away.
class SakinahAudioEngine {
  static final AudioPlayer player = AudioPlayer();
  static String? loadedKey;
}

class SakinahApp extends StatelessWidget {
  const SakinahApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'sans-serif',
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: forest,
          brightness: Brightness.dark,
        ).copyWith(
          primary: forest,
          onPrimary: Colors.white,
          secondary: gold,
          onSecondary: const Color(0xFF17130A),
          surface: const Color(0xFF101512),
          onSurface: ink,
          surfaceContainerHighest: const Color(0xFF17221B),
          outline: const Color(0xFF2A3A30),
        ),
        scaffoldBackgroundColor: ivory,
        appBarTheme: const AppBarTheme(
          backgroundColor: ivory,
          foregroundColor: Colors.white,
          centerTitle: true,
          elevation: 0,
          scrolledUnderElevation: 0,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 19,
            fontWeight: FontWeight.w800,
            fontFamily: 'sans-serif',
          ),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF101512),
          elevation: 0,
          shadowColor: Colors.black.withValues(alpha: .18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFF24352B)),
          ),
          margin: const EdgeInsets.symmetric(vertical: 6),
        ),
        dividerTheme: const DividerThemeData(color: Color(0xFF24352B), thickness: 1),
        iconTheme: const IconThemeData(color: Colors.white70),
        textTheme: ThemeData.dark().textTheme.apply(
          bodyColor: ink,
          displayColor: Colors.white,
          fontFamily: 'sans-serif',
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: forest,
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFF24352B),
            disabledForegroundColor: Colors.white38,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF101512),
          hintStyle: const TextStyle(color: Colors.white54),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFF2A3A30)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFF2A3A30)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: forest, width: 1.6),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFF0B100D),
          indicatorColor: const Color(0xFF174A31),
          elevation: 0,
          labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
            color: states.contains(WidgetState.selected) ? Colors.white : Colors.white60,
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w500,
          )),
          iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? const Color(0xFF72D69D) : Colors.white60,
          )),
        ),
        pageTransitionsTheme: const PageTransitionsTheme(builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        }),
      ),
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child ?? const SizedBox.shrink()),
      home: const MainShell(),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int tab = 0;
  final pages = const [HomePage(), QuranPage(), PrayerPage(), AzkarPage(), MorePage()];
  final labels = const ['الرئيسية', 'القرآن', 'الصلاة', 'الأذكار', 'المزيد'];
  final icons = const [Icons.home_rounded, Icons.menu_book_rounded, Icons.mosque_rounded, Icons.favorite_rounded, Icons.grid_view_rounded];
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: tab, children: pages)),
      bottomNavigationBar: SafeArea(top: false, child: NavigationBar(
        height: 72,
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        backgroundColor: const Color(0xFF0B100D),
        indicatorColor: const Color(0xFF174A31),
        elevation: 2,
        destinations: [for (var i = 0; i < labels.length; i++) NavigationDestination(icon: Icon(icons[i]), selectedIcon: Icon(icons[i], color: const Color(0xFF70D6A0)), label: labels[i])],
      )),
    );
  }
}

class SCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const SCard({super.key, required this.child, this.padding = const EdgeInsets.all(16)});
  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: padding, child: child));
}

class SectionTitle extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onTap;
  const SectionTitle(this.title, {super.key, this.action, this.onTap});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(3, 18, 3, 10),
    child: Row(children: [Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: deepGreen))), if (action != null) TextButton(onPressed: onTap, child: Text(action!))]),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String location = 'المكلا';
  int tasbih = 0;

  static const featuredReciters = <String>[
    'خالد الجليل',
    'سعود الشريم',
    'ماهر المعيقلي',
    'بدر التركي',
    'عبدالرحمن السديس',
    'مشاري العفاسي',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      location = prefs.getString('city') ?? 'المكلا';
      tasbih = prefs.getInt('tasbih') ?? 0;
    });
  }

  void _open(Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final hijri = toHijri(today);
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return ListView(
      padding: EdgeInsets.fromLTRB(18, 13, 18, 28 + bottomInset),
      children: [
        Row(
          children: [
            _SakinahLogoMark(size: 54),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('سَكينة', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Color(0xFF69D49A), letterSpacing: .1)),
                  SizedBox(height: 2),
                  Text('طمأنينة لقلبك في كل يوم', style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.5)),
                ],
              ),
            ),
            IconButton(
              tooltip: 'الإعدادات',
              onPressed: () => _open(const SettingsPage()),
              icon: const Icon(Icons.tune_rounded, color: Colors.white, size: 25),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _MosqueHeroCard(
          location: location,
          date: today,
          hijriText: '${hijri.day} ${hijriMonths[hijri.month]} ${hijri.year} هـ',
          onRead: () => _open(const QuranStandalonePage()),
          onListen: () => _open(const RecitersPage()),
        ),
        Padding(
      padding: const EdgeInsets.fromLTRB(3, 18, 3, 10),
      child: Row(children: [
        const Expanded(child: Text('استمع إلى قرائك المفضلين', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: deepGreen))),
        TextButton(onPressed: () => _open(const RecitersPage()), child: const Text('كل القراء')),
      ]),
    ),
        SizedBox(
          height: 116,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: featuredReciters.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, index) => _ReciterSpotlightTile(
              name: featuredReciters[index],
              onTap: () => _open(RecitersPage(initialReciterName: featuredReciters[index])),
            ),
          ),
        ),
        const SizedBox(height: 14),
        const _PrayerCountdownCard(),
        const SectionTitle('مساحتك الإيمانية'),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 3,
          mainAxisSpacing: 11,
          crossAxisSpacing: 11,
          childAspectRatio: .92,
          children: [
            _HomeTile(icon: Icons.menu_book_rounded, title: 'القرآن الكريم', onTap: () => _open(const QuranStandalonePage()), accent: forest),
            _HomeTile(icon: Icons.auto_stories_rounded, title: 'الأحاديث', onTap: () => _open(const HadithDuaPage()), accent: gold),
            _HomeTile(icon: Icons.spa_rounded, title: 'الأذكار', onTap: () => _open(const AzkarStandalonePage()), accent: forest),
            _HomeTile(icon: Icons.mosque_rounded, title: 'مواقيت الصلاة', onTap: () => _open(const PrayerStandalonePage()), accent: gold),
            _HomeTile(icon: Icons.explore_rounded, title: 'القبلة', onTap: () => _open(const QiblaPage()), accent: forest),
            _HomeTile(icon: Icons.volunteer_activism_rounded, title: 'الأدعية', onTap: () => _open(const HadithDuaPage(initialTab: 1)), accent: gold),
            _HomeTile(icon: Icons.spa_rounded, title: 'السبحة', onTap: () => _open(const TasbihPage()), accent: forest),
            _HomeTile(icon: Icons.calendar_month_rounded, title: 'التقويم الهجري', onTap: () => _open(const HijriPage()), accent: gold),
            _HomeTile(icon: Icons.headphones_rounded, title: 'التلاوات', onTap: () => _open(const RecitersPage()), accent: forest),
          ],
        ),
        const SectionTitle('ورد التسبيح اليومي'),
        SCard(child: Row(children: [
          Container(width: 48, height: 48, decoration: BoxDecoration(color: goldSoft, borderRadius: BorderRadius.circular(16), border: Border.all(color: gold.withValues(alpha: .2))), child: const Icon(Icons.spa_rounded, color: gold)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('سبحتك اليوم', style: TextStyle(fontWeight: FontWeight.w800, color: deepGreen)), Text('$tasbih تسبيحة محفوظة', style: const TextStyle(color: Colors.white70, fontSize: 12))])),
          FilledButton(onPressed: () => _open(const TasbihPage()), child: const Text('ابدأ الذكر')),
        ])),
        const SectionTitle('دعاء اليوم'),
        SCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('﴿ رَبَّنَا آتِنَا فِي الدُّنْيَا حَسَنَةً وَفِي الْآخِرَةِ حَسَنَةً وَقِنَا عَذَابَ النَّارِ ﴾', textAlign: TextAlign.center, style: TextStyle(fontSize: 19, height: 2, color: ink, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Align(alignment: Alignment.centerLeft, child: Text('سورة البقرة · 201', style: TextStyle(color: gold, fontWeight: FontWeight.w800, fontSize: 12))),
        ])),
        const SizedBox(height: 22),
        const Center(child: Text('تطوير وإنتاج: عبد العزيز عوض بن ثابت · © 2026', style: TextStyle(color: Colors.white54, fontSize: 11))),
      ],
    );
  }
}

class _SakinahLogoMark extends StatelessWidget {
  final double size;
  const _SakinahLogoMark({this.size = 54});
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF0B4D34), Color(0xFF092218)]),
      borderRadius: BorderRadius.circular(size * .31),
      border: Border.all(color: gold.withValues(alpha: .58), width: 1.1),
      boxShadow: [BoxShadow(color: forest.withValues(alpha: .22), blurRadius: 18, offset: const Offset(0, 6))],
    ),
    child: Stack(alignment: Alignment.center, children: [
      Icon(Icons.nightlight_round, color: gold, size: size * .49),
      Positioned(top: size * .17, right: size * .19, child: Icon(Icons.auto_awesome, size: size * .13, color: const Color(0xFFFFE8A8))),
    ]),
  );
}

class _MosqueHeroCard extends StatelessWidget {
  final String location;
  final DateTime date;
  final String hijriText;
  final VoidCallback onRead;
  final VoidCallback onListen;
  const _MosqueHeroCard({required this.location, required this.date, required this.hijriText, required this.onRead, required this.onListen});

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(27),
    child: Container(
      height: 300,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(27),
        border: Border.all(color: gold.withValues(alpha: .46), width: 1),
        boxShadow: [BoxShadow(color: forest.withValues(alpha: .16), blurRadius: 24, offset: const Offset(0, 10))],
      ),
      child: Stack(fit: StackFit.expand, children: [
        Image.asset('assets/images/sakinah_mosque_hero.png', fit: BoxFit.cover),
        const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [Color(0x99030806), Color(0x33030806), Color(0xE6000805)],
          stops: [0, .42, 1],
        ))),
        Padding(
          padding: const EdgeInsets.all(19),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.location_on_outlined, color: gold, size: 17),
                const SizedBox(width: 5),
                Text(location, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
                const Spacer(),
                Text('${date.day}/${date.month}/${date.year} م', style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ]),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: .38), borderRadius: BorderRadius.circular(99), border: Border.all(color: gold.withValues(alpha: .4))),
                child: Text(hijriText, style: const TextStyle(color: Color(0xFFFFDFA0), fontWeight: FontWeight.w800, fontSize: 12)),
              ),
              const SizedBox(height: 11),
              const Text('﴿ أَلَا بِذِكْرِ اللَّهِ تَطْمَئِنُّ الْقُلُوبُ ﴾', textAlign: TextAlign.start,
                style: TextStyle(color: Colors.white, fontSize: 22, height: 1.85, fontWeight: FontWeight.w800, shadows: [Shadow(color: Colors.black87, blurRadius: 8)])),
              const Text('سورة الرعد · الآية 28', style: TextStyle(color: Colors.white70, fontSize: 11)),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: _HeroAction(icon: Icons.menu_book_rounded, label: 'ورد القرآن', onTap: onRead)),
                const SizedBox(width: 9),
                Expanded(child: _HeroAction(icon: Icons.headphones_rounded, label: 'استمع للقرآن', onTap: onListen)),
              ]),
            ],
          ),
        ),
      ]),
    ),
  );
}

class _ReciterSpotlightTile extends StatelessWidget {
  final String name;
  final VoidCallback onTap;
  const _ReciterSpotlightTile({required this.name, required this.onTap});
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 102,
    child: Material(
      color: const Color(0xFF101512),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFF263A2E))),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(width: 45, height: 45, decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF153425), border: Border.all(color: gold.withValues(alpha: .32))),
              child: const Icon(Icons.graphic_eq_rounded, color: Color(0xFF69D49A), size: 24)),
            const SizedBox(height: 7),
            Text(name, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800, height: 1.25)),
          ]),
        ),
      ),
    ),
  );
}

class _HeroAction extends StatelessWidget {
  final IconData icon; final String label; final VoidCallback onTap;
  const _HeroAction({required this.icon, required this.label, required this.onTap});
  @override Widget build(BuildContext context) => Material(color: Colors.white.withValues(alpha: .12), borderRadius: BorderRadius.circular(15), child: InkWell(borderRadius: BorderRadius.circular(15), onTap: onTap, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 12), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, color: gold, size: 19), const SizedBox(width: 7), Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)))]))));
}

class _HomeTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final Color accent;
  const _HomeTile({required this.icon, required this.title, required this.onTap, this.accent = forest});

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF101512),
    borderRadius: BorderRadius.circular(19),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(19),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: const Color(0xFF24352B)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: accent == gold ? goldSoft : mint,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: accent == gold ? gold : const Color(0xFF55C58A), size: 27),
            ),
            const SizedBox(height: 10),
            Text(title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: Colors.white)),
          ],
        ),
      ),
    ),
  );
}

class QuranPage extends StatefulWidget { const QuranPage({super.key}); @override State<QuranPage> createState()=>_QuranPageState(); }
class _QuranPageState extends State<QuranPage> {
  String query=''; bool full=false; bool busy=false; double progress=0; String? error; int lastSurah = 0; int lastAyah = 0;
  @override void initState(){super.initState();_check();}
  Future<void> _check() async { final b=await QuranStore.hasFullQuran(); final prefs=await SharedPreferences.getInstance(); if(mounted)setState(() { full=b; lastSurah=prefs.getInt('quran_last_surah')??0; lastAyah=prefs.getInt('quran_last_ayah')??0; }); }
  Future<void> _download() async { setState(() { busy = true; error = null; progress = 0; }); try {await QuranStore.downloadFull(onProgress:(p){if(mounted)setState(()=>progress=p);}); if(mounted)setState(()=>full=true); _snack('تم حفظ نص القرآن الكريم كاملاً على جهازك');} catch(e){if(mounted)setState(()=>error=e.toString());} finally{if(mounted)setState(()=>busy=false);} }
  void _snack(String s)=>ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));
  @override Widget build(BuildContext context){final normalized=normalizeArabic(query); final filtered=surahs.where((s)=>normalizeArabic(s.name).contains(normalized)||s.number.toString()==query).toList(); return ListView(padding: EdgeInsets.fromLTRB(18, 18, 18, 28 + MediaQuery.of(context).padding.bottom), children:[Row(children:[const Expanded(child:Text('القرآن الكريم',style:TextStyle(fontSize:25,fontWeight:FontWeight.w900,color:deepGreen))),IconButton(tooltip:'البحث في القرآن',onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>QuranSearchPage(onOpenSurah:(number)=>Navigator.push(context,MaterialPageRoute(builder:(_)=>SurahPage(surah:surahs[number-1])))))),icon:const Icon(Icons.search,color:forest)),IconButton(tooltip:'علاماتي المحفوظة',onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>BookmarksPage(onOpenSurah:(number)=>Navigator.push(context,MaterialPageRoute(builder:(_)=>SurahPage(surah:surahs[number-1])))))),icon:const Icon(Icons.bookmark_outline,color:forest))]),const Text('كلام الله تعالى · 114 سورة',style:TextStyle(color:Colors.white70)),if(lastSurah>0)Padding(padding:const EdgeInsets.only(top:12),child:Card(child:ListTile(leading:const CircleAvatar(backgroundColor:mint,child:Icon(Icons.play_arrow_rounded,color:forest)),title:const Text('تابع آخر قراءة',style:TextStyle(fontWeight:FontWeight.bold)),subtitle:Text('سورة ${surahs[lastSurah-1].name}${lastAyah > 0 ? ' · الآية $lastAyah' : ''}'),trailing:const Icon(Icons.chevron_left,color:forest),onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>SurahPage(surah:surahs[lastSurah-1])))))),const SizedBox(height:15),TextField(textDirection:TextDirection.rtl,decoration:InputDecoration(hintText:'ابحث عن سورة',prefixIcon:const Icon(Icons.search),filled:true,fillColor:const Color(0xFF101512),border:OutlineInputBorder(borderRadius:BorderRadius.circular(16),borderSide:BorderSide.none)),onChanged:(v)=>setState(()=>query=v)),const SizedBox(height:12),Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:mint,borderRadius:BorderRadius.circular(17)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Row(children:[const Icon(Icons.download_for_offline_outlined,color:forest),const SizedBox(width:8),Expanded(child:Text(full?'نص القرآن محفوظ دون إنترنت':'نزّل نص القرآن كاملاً للعمل دون إنترنت',style:const TextStyle(fontWeight:FontWeight.bold,color:deepGreen))),if(full)const Icon(Icons.check_circle,color:forest)]),if(busy)Padding(padding:const EdgeInsets.only(top:10),child:LinearProgressIndicator(value:progress)),if(error!=null)Text(error!,style:const TextStyle(color:Colors.red)),if(!full&&!busy)Align(alignment:Alignment.centerLeft,child:TextButton.icon(onPressed:_download,icon:const Icon(Icons.download),label:const Text('تنزيل القرآن كاملاً')))])),const SizedBox(height:8),for(final s in filtered) Card(child:ListTile(leading:CircleAvatar(backgroundColor:mint,foregroundColor:forest,child:Text('${s.number}')),title:Text(s.name,style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text('${s.verses} آية · ${s.type}'),trailing:const Icon(Icons.chevron_left,color:forest),onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>SurahPage(surah:s)))),),const SizedBox(height:15),const Text('مصدر النص: AlQuran Cloud. يُعرض النص كما يرد من المصدر دون تعديل.',style:TextStyle(color:Colors.white60,fontSize:11))]);}
}

class SurahPage extends StatefulWidget {
  final SurahInfo surah;
  const SurahPage({super.key, required this.surah});
  @override
  State<SurahPage> createState() => _SurahPageState();
}

class _SurahPageState extends State<SurahPage> {
  List<dynamic>? ayahs;
  String? error;
  bool loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final result = await QuranStore.loadSurah(widget.surah.number);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('quran_last_surah', widget.surah.number);
      if (mounted) setState(() { ayahs = result; loading = false; });
    } catch (e) {
      if (mounted) setState(() { error = e.toString(); loading = false; });
    }
  }

  Future<void> _bookmark(Map<String, dynamic> ayah) async {
    await BookmarkStore.add({
      'surah': widget.surah.number,
      'surahName': widget.surah.name,
      'ayah': ayah['numberInSurah'],
      'text': ayah['text'],
    });
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ الآية في علاماتك')));
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return Scaffold(appBar: AppBar(title: Text('سورة ${widget.surah.name}')), body: const Center(child: CircularProgressIndicator(color: forest)));
    if (error != null) {
      return Scaffold(appBar: AppBar(title: Text('سورة ${widget.surah.name}')), body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(error!, textAlign: TextAlign.center), const SizedBox(height: 10), FilledButton(onPressed: () { setState(() { loading = true; error = null; }); _load(); }, child: const Text('إعادة المحاولة'))]))));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('سورة ${widget.surah.name}'),
        actions: [IconButton(tooltip: 'علاماتي المحفوظة', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BookmarksPage(onOpenSurah: (number) => Navigator.push(context, MaterialPageRoute(builder: (_) => SurahPage(surah: surahs[number - 1])))))), icon: const Icon(Icons.bookmark_outline))],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 26), children: [
        if (widget.surah.number != 1 && widget.surah.number != 9)
          const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Text('بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ', textAlign: TextAlign.center, style: TextStyle(fontSize: 25, color: deepGreen, height: 2))),
        Container(padding: const EdgeInsets.all(13), decoration: BoxDecoration(color: mint, borderRadius: BorderRadius.circular(16)), child: Text('سورة ${widget.surah.name} · ${widget.surah.verses} آية', textAlign: TextAlign.center, style: const TextStyle(color: deepGreen, fontWeight: FontWeight.bold))),
        const SizedBox(height: 12),
        for (final raw in ayahs!)
          Builder(builder: (context) {
            final ayah = Map<String, dynamic>.from(raw as Map);
            return Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 13, 14, 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  GestureDetector(
                    onTap: () async {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setInt('quran_last_surah', widget.surah.number);
                      await prefs.setInt('quran_last_ayah', ayah['numberInSurah'] as int);
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('تم حفظ موضع القراءة: ${widget.surah.name} · الآية ${ayah['numberInSurah']}'),
                        duration: const Duration(seconds: 1),
                      ));
                    },
                    child: Text('${ayah['text']} ﴿${ayah['numberInSurah']}﴾', textAlign: TextAlign.justify, style: const TextStyle(fontSize: 24, height: 2.05, color: ink)),
                  ),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    IconButton(tooltip: 'حفظ الآية', onPressed: () => _bookmark(ayah), icon: const Icon(Icons.bookmark_add_outlined, color: forest)),
                    IconButton(tooltip: 'التفسير الميسّر', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TafsirPage(globalAyah: ayah['number'] as int, surahName: widget.surah.name, ayahNumber: ayah['numberInSurah'] as int))), icon: const Icon(Icons.menu_book_outlined, color: deepGreen)),
                    IconButton(tooltip: 'إنشاء بطاقة للآية', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AyahCardPage(ayahText: ayah['text'] as String, reference: 'سورة ${widget.surah.name} · الآية ${ayah['numberInSurah']}'))), icon: const Icon(Icons.image_outlined, color: forest)),
                  ]),
                ]),
              ),
            );
          }),
        const Divider(),
        const Text('النص من AlQuran Cloud ويُعرض كما ورد من المصدر دون تغيير.', style: TextStyle(fontSize: 11, color: Colors.white60)),
      ]),
    );
  }
}

class TafsirPage extends StatefulWidget {
  final int globalAyah;
  final String surahName;
  final int ayahNumber;
  const TafsirPage({super.key, required this.globalAyah, required this.surahName, required this.ayahNumber});
  @override State<TafsirPage> createState() => _TafsirPageState();
}

class _TafsirPageState extends State<TafsirPage> {
  static const _edition = 'ar.muyassar';
  String? _text;
  String? _error;
  bool _loading = true;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'tafsir_muyassar_${widget.globalAyah}';
    final cached = prefs.getString(key);
    if (cached != null && cached.isNotEmpty) {
      if (mounted) setState(() { _text = cached; _loading = false; });
      return;
    }
    try {
      final response = await http.get(Uri.parse('$quranApi/ayah/${widget.globalAyah}/$_edition')).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) throw Exception('تعذر جلب التفسير (${response.statusCode})');
      final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final text = (decoded['data'] as Map<String, dynamic>)['text'] as String?;
      if (text == null || text.trim().isEmpty) throw Exception('لا يتوفر تفسير لهذه الآية من المصدر حالياً');
      await prefs.setString(key, text);
      if (mounted) setState(() { _text = text; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString().replaceFirst('Exception: ', ''); _loading = false; });
    }
  }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('التفسير الميسّر')),
    body: ListView(padding: const EdgeInsets.all(18), children: [
      Container(padding: const EdgeInsets.all(17), decoration: BoxDecoration(color: mint, borderRadius: BorderRadius.circular(20), border: Border.all(color: forest.withValues(alpha: .10))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('سورة ${widget.surahName} · الآية ${widget.ayahNumber}', style: const TextStyle(color: deepGreen, fontWeight: FontWeight.w900)),
        const SizedBox(height: 5), const Text('التفسير الميسّر', style: TextStyle(color: Colors.white70, fontSize: 12)),
      ])),
      const SizedBox(height: 14),
      if (_loading) const Center(child: Padding(padding: EdgeInsets.all(30), child: CircularProgressIndicator(color: forest)))
      else if (_error != null) Column(children: [Text(_error!, textAlign: TextAlign.center), const SizedBox(height: 10), OutlinedButton.icon(onPressed: () { setState(() { _loading = true; _error = null; }); _load(); }, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة'))])
      else SCard(child: Text(_text!, textAlign: TextAlign.justify, style: const TextStyle(fontSize: 19, height: 2, color: ink))),
      const SizedBox(height: 12), const Text('يعرض التطبيق التفسير الميسّر من مصدر خارجي، ويُحفظ التفسير الذي فتحته على جهازك لقراءته لاحقاً دون إنترنت.', style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.6)),
    ]),
  );
}

class ApprovedPrayerSchedule {
  static const entries = <(String, int, int)>[
    ('الفجر', 4, 31),
    ('الشروق', 5, 46),
    ('الظهر', 11, 30),
    ('العصر', 14, 46),
    ('المغرب', 17, 11),
    ('العشاء', 18, 41),
  ];

  static List<MapEntry<String, DateTime>> forDate(DateTime date) => [
    for (final item in entries)
      MapEntry(item.$1, DateTime(date.year, date.month, date.day, item.$2, item.$3)),
  ];

  static MapEntry<String, DateTime> nextPrayer(DateTime now) {
    final today = forDate(now);
    for (final item in today.where((entry) => entry.key != 'الشروق')) {
      if (!item.value.isBefore(now)) return item;
    }
    final tomorrow = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    return MapEntry('الفجر', DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 4, 31));
  }

  static String format(DateTime date) {
    final hour24 = date.hour;
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final minute = date.minute.toString().padLeft(2, '0');
    return '$hour12:$minute ${hour24 < 12 ? 'ص' : 'م'}';
  }

  static String remaining(DateTime time, DateTime now) {
    final difference = time.difference(now);
    final hours = difference.inHours;
    final minutes = difference.inMinutes.remainder(60);
    if (hours <= 0) return 'باقي $minutes دقيقة';
    return 'باقي $hours ساعة و$minutes دقيقة';
  }
}

class PrayerPage extends StatefulWidget {
  const PrayerPage({super.key});
  @override State<PrayerPage> createState() => _PrayerPageState();
}

class _PrayerPageState extends State<PrayerPage> {
  Timer? refreshTimer;

  @override
  void initState() {
    super.initState();
    refreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final next = ApprovedPrayerSchedule.nextPrayer(now);
    final times = ApprovedPrayerSchedule.forDate(now);
    return ListView(
      padding: EdgeInsets.fromLTRB(18, 18, 18, 28 + MediaQuery.of(context).padding.bottom),
      children: [
        const Text('مواقيت الصلاة', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900, color: deepGreen)),
        const SizedBox(height: 4),
        const Text('المكلا · المواقيت المعتمدة يدوياً', style: TextStyle(color: Colors.white70)),
        const SizedBox(height: 14),
        _PrayerCountdownCard(compact: false),
        const SectionTitle('مواقيت اليوم'),
        for (final item in times)
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: mint,
                child: Icon(item.key == 'الشروق' ? Icons.wb_sunny_outlined : Icons.access_time_rounded,
                    color: item.key == 'الشروق' ? gold : forest),
              ),
              title: Text(item.key, style: const TextStyle(fontWeight: FontWeight.bold)),
              trailing: Text(ApprovedPrayerSchedule.format(item.value),
                  style: const TextStyle(fontSize: 17, color: deepGreen, fontWeight: FontWeight.w900)),
            ),
          ),
        const SizedBox(height: 10),
        const Text(
          'هذه هي المواقيت اليدوية التي اعتمدتها لسَكينة. تبقى 
