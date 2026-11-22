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
        fontFamily: 'sans-serif',
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
          'هذه هي المواقيت اليدوية التي اعتمدتها لسَكينة. تبقى ثابتة على الجهاز ولا تتغير بتغيير الموقع أو طريقة الحساب.',
          style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.7),
        ),
      ],
    );
  }
}

class _PrayerCountdownCard extends StatefulWidget {
  final bool compact;
  const _PrayerCountdownCard({this.compact = true});
  @override State<_PrayerCountdownCard> createState() => _PrayerCountdownCardState();
}

class _PrayerCountdownCardState extends State<_PrayerCountdownCard> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final next = ApprovedPrayerSchedule.nextPrayer(now);
    final time = next.value;
    return Container(
      padding: EdgeInsets.all(widget.compact ? 17 : 21),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [Color(0xFF0C3928), Color(0xFF10251B), Color(0xFF0A1711)],
        ),
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: gold.withValues(alpha: .34), width: 1),
        boxShadow: [BoxShadow(color: forest.withValues(alpha: .12), blurRadius: 20, offset: const Offset(0, 8))],
      ),
      child: Row(
        children: [
          Container(
            width: widget.compact ? 48 : 58,
            height: widget.compact ? 48 : 58,
            decoration: BoxDecoration(color: goldSoft, borderRadius: BorderRadius.circular(17), border: Border.all(color: gold.withValues(alpha: .35))),
            child: Icon(Icons.mosque_rounded, color: gold, size: widget.compact ? 25 : 30),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('الصلاة القادمة', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(next.key, style: TextStyle(color: Colors.white, fontSize: widget.compact ? 20 : 25, fontWeight: FontWeight.w900)),
                Text(ApprovedPrayerSchedule.remaining(time, now), style: const TextStyle(color: Color(0xFF9BDDB5), fontSize: 12, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(ApprovedPrayerSchedule.format(time), style: TextStyle(color: gold, fontSize: widget.compact ? 18 : 22, fontWeight: FontWeight.w900)),
              Text('${now.day}/${now.month}/${now.year}', style: const TextStyle(color: Colors.white54, fontSize: 10)),
            ],
          ),
        ],
      ),
    );
  }
}

class AzkarPage extends StatefulWidget {
  const AzkarPage({super.key});

  @override
  State<AzkarPage> createState() => _AzkarPageState();
}

class _AzkarPageState extends State<AzkarPage> {
  int count = 0;
  String selectedCategory = 'الكل';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => count = prefs.getInt('tasbih') ?? 0);
  }

  String _countLabel(Zikr item) {
    if (item.count == 0) return 'بلا عدد محدد';
    return '${item.count} ${item.count == 1 ? 'مرة' : 'مرات'}';
  }

  @override
  Widget build(BuildContext context) {
    final items = adhkar.where((item) =>
      selectedCategory == 'الكل' || item.category == selectedCategory).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      children: [
        const Text('الأذكار', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900, color: Colors.white)),
        const SizedBox(height: 5),
        const Text('أذكار مأثورة مصنّفة بحسب وقتها ومناسبتها، مع ذكر المصدر.',
          style: TextStyle(color: Colors.white70, height: 1.6)),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(17),
          decoration: BoxDecoration(
            gradient: const LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft,
              colors: [Color(0xFF073A29), Color(0xFF0D6942)]),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFF277B52)),
          ),
          child: Row(children: [
            const Icon(Icons.spa_rounded, color: Color(0xFF83D9A5), size: 32),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('وردك من الذكر', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900)),
              Text('$count تسبيحة محفوظة على جهازك', style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ])),
            IconButton.filledTonal(
              tooltip: 'افتح السبحة',
              style: IconButton.styleFrom(backgroundColor: const Color(0xFF174A31), foregroundColor: Colors.white),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TasbihPage())),
              icon: const Icon(Icons.add),
            ),
          ]),
        ),
        const SizedBox(height: 18),
        const Text('التصنيفات', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 9),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final category in adhkarCategories)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 7),
                child: ChoiceChip(
                  label: Text(category),
                  selected: selectedCategory == category,
                  onSelected: (_) => setState(() => selectedCategory = category),
                  selectedColor: const Color(0xFF145B39),
                  backgroundColor: const Color(0xFF101512),
                  side: BorderSide(color: selectedCategory == category ? forest : const Color(0xFF293A30)),
                  labelStyle: TextStyle(color: selectedCategory == category ? Colors.white : Colors.white70,
                    fontWeight: selectedCategory == category ? FontWeight.w800 : FontWeight.w500),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 8),
        Text('${items.length} أذكار في هذا التصنيف', style: const TextStyle(color: Colors.white54, fontSize: 12)),
        for (final item in items)
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
              leading: Container(width: 42, height: 42,
                decoration: BoxDecoration(color: mint, borderRadius: BorderRadius.circular(14)),
                child: const Icon(Icons.menu_book_rounded, color: Color(0xFF55C58A))),
              title: Text(item.title, style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.white)),
              subtitle: Padding(padding: const EdgeInsets.only(top: 5), child: Text(
                '${_countLabel(item)} · ${item.category}',
                style: const TextStyle(color: Colors.white60, fontSize: 11))),
              trailing: const Icon(Icons.chevron_left, color: Color(0xFF55C58A)),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ZikrDetailPage(zikr: item))),
            ),
          ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HadithDuaPage())),
          icon: const Icon(Icons.auto_stories_rounded),
          label: const Text('تصفح الأحاديث والأدعية'),
        ),
      ],
    );
  }
}

class ZikrDetailPage extends StatefulWidget {
  final Zikr zikr;
  const ZikrDetailPage({super.key, required this.zikr});

  @override
  State<ZikrDetailPage> createState() => _ZikrDetailPageState();
}

class _ZikrDetailPageState extends State<ZikrDetailPage> {
  int count = 0;
  bool loading = true;
  String get _storageKey => 'zikr_count_${Uri.encodeComponent(widget.zikr.title)}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      count = prefs.getInt(_storageKey) ?? 0;
      loading = false;
    });
  }

  Future<void> _increment() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => count++);
    await prefs.setInt(_storageKey, count);
    HapticFeedback.selectionClick();
  }

  Future<void> _reset() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => count = 0);
    await prefs.setInt(_storageKey, 0);
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.zikr.count;
    final progress = target > 0 ? (count / target).clamp(0.0, 1.0).toDouble() : 0.0;
    return Scaffold(
      appBar: AppBar(title: Text(widget.zikr.title)),
      body: SafeArea(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Align(alignment: Alignment.centerRight, child: Chip(
            label: Text(widget.zikr.category), backgroundColor: mint,
            labelStyle: const TextStyle(color: Color(0xFF72D69D), fontWeight: FontWeight.w700))),
          const SizedBox(height: 12),
          Expanded(child: Center(child: SingleChildScrollView(child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(color: const Color(0xFF101512), borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFF293A30))),
            child: Text(widget.zikr.text, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 23, height: 2.05, color: Color(0xFFF1F5F2))),
          )))),
          const SizedBox(height: 12),
          Text(widget.zikr.source, textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.6)),
          const SizedBox(height: 18),
          Text(loading ? '—' : '$count', style: const TextStyle(fontSize: 54, fontWeight: FontWeight.w900, color: Color(0xFF55C58A))),
          Text(target > 0 ? 'العدد الوارد أو المقترح: $target' : 'لم يرد لهذا الذكر عدد محدد هنا', style: const TextStyle(color: Colors.white60)),
          const SizedBox(height: 11),
          ClipRRect(borderRadius: BorderRadius.circular(20), child: LinearProgressIndicator(
            value: progress, minHeight: 7, color: forest, backgroundColor: mint)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: FilledButton.icon(
              onPressed: loading ? null : _increment,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(60)),
              icon: const Icon(Icons.touch_app_rounded), label: const Text('تسبيح / تم'),
            )),
            const SizedBox(width: 10),
            IconButton.outlined(onPressed: loading ? null : _reset,
              tooltip: 'تصفير العداد', icon: const Icon(Icons.refresh_rounded),
              style: IconButton.styleFrom(minimumSize: const Size(60, 60), foregroundColor: gold)),
          ]),
          const SizedBox(height: 8),
        ]),
      )),
    );
  }
}

class TasbihPage extends StatefulWidget {
  const TasbihPage({super.key});
  @override State<TasbihPage> createState() => _TasbihPageState();
}

class _TasbihPageState extends State<TasbihPage> {
  int count = 0;
  String phrase = 'سُبْحَانَ اللَّهِ وَبِحَمْدِهِ';
  static const phrases = <String>[
    'سُبْحَانَ اللَّهِ وَبِحَمْدِهِ',
    'سُبْحَانَ اللَّهِ الْعَظِيمِ',
    'الْحَمْدُ لِلَّهِ',
    'لَا إِلَهَ إِلَّا اللَّهُ',
    'اللَّهُ أَكْبَرُ',
    'أَسْتَغْفِرُ اللَّهَ وَأَتُوبُ إِلَيْهِ',
  ];

  String _keyFor(String value) => 'tasbih_${Uri.encodeComponent(value)}';

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final storedPhrase = prefs.getString('tasbih_phrase') ?? phrase;
    final validPhrase = phrases.contains(storedPhrase) ? storedPhrase : phrases.first;
    final savedCount = prefs.getInt(_keyFor(validPhrase)) ??
        (validPhrase == phrases.first ? (prefs.getInt('tasbih') ?? 0) : 0);
    if (!mounted) return;
    setState(() {
      phrase = validPhrase;
      count = savedCount;
    });
    // Migrate the previous single counter into the selected phrase's own counter.
    await prefs.setInt(_keyFor(phrase), count);
    await prefs.setString('tasbih_phrase', phrase);
  }
  Future<void> _increment() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => count++);
    await prefs.setInt(_keyFor(phrase), count);
    await prefs.setInt('tasbih', count); // dashboard compatibility
    HapticFeedback.selectionClick();
  }
  Future<void> _reset() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => count = 0);
    await prefs.setInt(_keyFor(phrase), 0);
    await prefs.setInt('tasbih', 0);
  }
  Future<void> _setPhrase(String? value) async {
    if (value == null) return;
    final prefs = await SharedPreferences.getInstance();
    final nextCount = prefs.getInt(_keyFor(value)) ?? 0;
    if (!mounted) return;
    setState(() { phrase = value; count = nextCount; });
    await prefs.setString('tasbih_phrase', value);
    await prefs.setInt('tasbih', nextCount); // dashboard compatibility
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('السبحة الإلكترونية')),
    body: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(
      mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(width: 112, height: 112, decoration: BoxDecoration(shape: BoxShape.circle,
          color: mint, border: Border.all(color: forest.withValues(alpha: .6), width: 1.5)),
          child: const Icon(Icons.spa_rounded, color: Color(0xFF68D69A), size: 57)),
        const SizedBox(height: 23),
        const Text('اختر الذكر', style: TextStyle(color: Colors.white60)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: phrase,
          isExpanded: true,
          dropdownColor: const Color(0xFF101512),
          decoration: const InputDecoration(border: OutlineInputBorder()),
          items: [for (final value in phrases) DropdownMenuItem(value: value, child: Text(value, textAlign: TextAlign.center))],
          onChanged: _setPhrase,
        ),
        const SizedBox(height: 24),
        Text('$count', style: const TextStyle(fontSize: 72, color: Color(0xFF62D394), fontWeight: FontWeight.w900)),
        const SizedBox(height: 18),
        SizedBox(width: 205, height: 205, child: FilledButton(
          onPressed: _increment,
          style: FilledButton.styleFrom(shape: const CircleBorder(), backgroundColor: const Color(0xFF0D6942),
            side: const BorderSide(color: Color(0xFF62D394), width: 2)),
          child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.touch_app_rounded, size: 42), SizedBox(height: 8),
            Text('اضغط للتسبيح', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ]),
        )),
        const SizedBox(height: 16),
        TextButton.icon(onPressed: _reset, icon: const Icon(Icons.refresh_rounded), label: const Text('تصفير العداد')),
        const SizedBox(height: 7),
        const Text('يُحفظ العداد تلقائياً على جهازك.', style: TextStyle(color: Colors.white54, fontSize: 12)),
      ],
    ))),
  );
}

class MorePage extends StatelessWidget {
  const MorePage({super.key});
  @override
  Widget build(BuildContext context) => ListView(padding: EdgeInsets.fromLTRB(18, 18, 18, 28 + MediaQuery.of(context).padding.bottom), children: [
    const Text('المزيد', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900, color: deepGreen)),
    const SizedBox(height: 12),
    _MoreTile(icon: Icons.checklist_rounded, title: 'متابعة عباداتي', subtitle: 'الصلوات والورد والعادات اليومية', page: const DailyWorshipPage()),
    _MoreTile(icon: Icons.menu_book_rounded, title: 'خطة ختم القرآن', subtitle: 'اختر مدة الختمة وتابع تقدمك', page: const KhatmahPlannerPage()),
    _MoreTile(icon: Icons.search_rounded, title: 'البحث في القرآن', subtitle: 'ابحث داخل الآيات مع تطبيع الهمزات والتشكيل', page: QuranSearchPage(onOpenSurah: (number) => Navigator.push(context, MaterialPageRoute(builder: (_) => SurahPage(surah: surahs[number - 1]))))),
    _MoreTile(icon: Icons.bookmark_outline_rounded, title: 'علاماتي المحفوظة', subtitle: 'ارجع إلى الآيات التي حفظتها', page: BookmarksPage(onOpenSurah: (number) => Navigator.push(context, MaterialPageRoute(builder: (_) => SurahPage(surah: surahs[number - 1]))))),
    _MoreTile(icon: Icons.explore, title: 'اتجاه القبلة', subtitle: 'بوصلة نحو الكعبة', page: const QiblaPage()),
    _MoreTile(icon: Icons.headphones, title: 'التلاوات الصوتية', subtitle: 'قراء من مصادر صوتية متعددة · تنزيل واستماع دون إنترنت', page: const RecitersPage()),
    _MoreTile(icon: Icons.download_for_offline_rounded, title: 'إدارة التنزيلات', subtitle: 'إدارة التلاوات المحفوظة على الجهاز', page: const AudioDownloadsPage()),
    _MoreTile(icon: Icons.volume_up, title: 'الأذان الكامل', subtitle: 'تشغيل وتنزيل الأذان للاستماع دون إنترنت', page: const AdhanPage()),
    _MoreTile(icon: Icons.menu_book, title: 'الأحاديث والأدعية', subtitle: 'نصوص مختارة مع المراجع', page: const HadithDuaPage()),
    _MoreTile(icon: Icons.calendar_month, title: 'التقويم الهجري', subtitle: 'تاريخ هجري تقريبي', page: const HijriPage()),
    _MoreTile(icon: Icons.favorite_outline, title: 'ادعم تطوير التطبيق', subtitle: 'مساهمة اختيارية لتطوير سكينة', page: const SupportPage()),
    _MoreTile(icon: Icons.settings, title: 'الإعدادات', subtitle: 'الموقع وطريقة الاستخدام', page: const SettingsPage()),
    _MoreTile(icon: Icons.info_outline, title: 'عن التطبيق والمصادر', subtitle: 'الحقوق والمراجع والتراخيص', page: const AboutPage()),
  ]);
}

class _MoreTile extends StatelessWidget{final IconData icon;final String title,subtitle;final Widget page;const _MoreTile({required this.icon,required this.title,required this.subtitle,required this.page});@override Widget build(BuildContext context)=>Card(child:ListTile(leading:CircleAvatar(backgroundColor:mint,child:Icon(icon,color:forest)),title:Text(title,style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text(subtitle),trailing:const Icon(Icons.chevron_left,color:forest),onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>page))));}

class HadithDuaPage extends StatefulWidget {
  final int initialTab;
  const HadithDuaPage({super.key, this.initialTab = 0});
  @override State<HadithDuaPage> createState() => _HadithDuaPageState();
}

class _HadithDuaPageState extends State<HadithDuaPage> {
  @override Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    initialIndex: widget.initialTab.clamp(0, 1).toInt(),
    child: Scaffold(
      appBar: AppBar(
        title: const Text('الأحاديث والأدعية'),
        bottom: const TabBar(
          indicatorColor: Color(0xFF55C58A),
          labelColor: Color(0xFF75D69D),
          unselectedLabelColor: Colors.white60,
          tabs: [Tab(icon: Icon(Icons.auto_stories_rounded), text: 'أحاديث نبوية'), Tab(icon: Icon(Icons.volunteer_activism_rounded), text: 'أدعية')],
        ),
      ),
      body: const TabBarView(children: [_HadithCatalog(), _DuaCatalog()]),
    ),
  );
}

class _HadithCatalog extends StatefulWidget {
  const _HadithCatalog();
  @override State<_HadithCatalog> createState() => _HadithCatalogState();
}

class _HadithCatalogState extends State<_HadithCatalog> {
  String category = 'الكل';
  String query = '';
  @override Widget build(BuildContext context) {
    final results = hadiths.where((item) =>
      (category == 'الكل' || item.category == category) &&
      (query.trim().isEmpty || item.text.contains(query.trim()) || item.source.contains(query.trim()))).toList();
    return ListView(padding: const EdgeInsets.all(16), children: [
      TextField(
        onChanged: (value) => setState(() => query = value),
        decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'ابحث في الأحاديث'),
      ),
      const SizedBox(height: 12),
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
        for (final item in hadithCategories) Padding(padding: const EdgeInsetsDirectional.only(end: 7), child: ChoiceChip(
          label: Text(item), selected: category == item,
          onSelected: (_) => setState(() => category = item),
          selectedColor: const Color(0xFF145B39), backgroundColor: const Color(0xFF101512),
          side: BorderSide(color: category == item ? forest : const Color(0xFF293A30)),
          labelStyle: TextStyle(color: category == item ? Colors.white : Colors.white70),
        )),
      ])),
      const SizedBox(height: 7),
      Text('${results.length} حديثاً', style: const TextStyle(color: Colors.white54, fontSize: 12)),
      for (final item in results) Card(child: Padding(padding: const EdgeInsets.all(17), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(item.text, textAlign: TextAlign.start, style: const TextStyle(fontSize: 20, height: 1.9, color: Colors.white)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Text(item.category, style: const TextStyle(color: Color(0xFF75D69D), fontWeight: FontWeight.w700, fontSize: 11))),
            IconButton(tooltip: 'نسخ الحديث', visualDensity: VisualDensity.compact,
              onPressed: () { Clipboard.setData(ClipboardData(text: '${item.text}\n${item.source}')); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم نسخ الحديث ومصدره'))); },
              icon: const Icon(Icons.copy_rounded, size: 17, color: Colors.white60)),
          ]),
          Text(item.source, style: const TextStyle(color: Color(0xFFD6B56D), fontSize: 12, height: 1.5)),
        ],
      ))),
      if (results.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('لا توجد نتائج مطابقة.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white60))),
      const Padding(padding: EdgeInsets.only(top: 14), child: Text('أُدرجت المراجع بجانب كل حديث. يُستحسن الرجوع إلى طبعة محققة عند البحث العلمي أو الاستدلال التفصيلي.', style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.7))),
    ]);
  }
}

class _DuaCatalog extends StatefulWidget {
  const _DuaCatalog();
  @override State<_DuaCatalog> createState() => _DuaCatalogState();
}

class _DuaCatalogState extends State<_DuaCatalog> {
  String category = 'الكل';
  String query = '';
  @override Widget build(BuildContext context) {
    final results = duas.where((item) =>
      (category == 'الكل' || item.category == category || item.topic == category) &&
      (query.trim().isEmpty || item.title.contains(query.trim()) || item.text.contains(query.trim()) || item.source.contains(query.trim()))).toList();
    return ListView(padding: const EdgeInsets.all(16), children: [
      TextField(onChanged: (value) => setState(() => query = value),
        decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'ابحث في الأدعية')),
      const SizedBox(height: 12),
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
        for (final item in duaCategories) Padding(padding: const EdgeInsetsDirectional.only(end: 7), child: ChoiceChip(
          label: Text(item), selected: category == item,
          onSelected: (_) => setState(() => category = item),
          selectedColor: const Color(0xFF145B39), backgroundColor: const Color(0xFF101512),
          side: BorderSide(color: category == item ? forest : const Color(0xFF293A30)),
          labelStyle: TextStyle(color: category == item ? Colors.white : Colors.white70),
        )),
      ])),
      const SizedBox(height: 7),
      Text('${results.length} أدعية', style: const TextStyle(color: Colors.white54, fontSize: 12)),
      for (final item in results) Card(child: Padding(padding: const EdgeInsets.all(17), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(item.title, style: const TextStyle(color: Color(0xFF75D69D), fontWeight: FontWeight.w900, fontSize: 16)),
          const SizedBox(height: 4),
          Text('${item.category} · ${item.topic}', style: const TextStyle(color: Colors.white54, fontSize: 11)),
          const SizedBox(height: 10),
          Text(item.text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, height: 2, color: Colors.white)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: Text(item.source, style: const TextStyle(color: Color(0xFFD6B56D), fontSize: 11, height: 1.5))),
            IconButton(tooltip: 'نسخ الدعاء', visualDensity: VisualDensity.compact,
              onPressed: () { Clipboard.setData(ClipboardData(text: '${item.title}\n${item.text}\n${item.source}')); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم نسخ الدعاء'))); },
              icon: const Icon(Icons.copy_rounded, size: 17, color: Colors.white60)),
          ]),
        ],
      ))),
      if (results.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('لا توجد نتائج مطابقة.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white60))),
      const Padding(padding: EdgeInsets.only(top: 14), child: Text('تنبيه: الأدعية القرآنية موثقة بمواضعها، والأدعية النبوية أُرفقت بمراجعها. بعض الألفاظ المختصرة تحتاج مراجعة النص الكامل في المصدر قبل الاستشهاد.', style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.7))),
    ]);
  }
}

class RecitersPage extends StatefulWidget {
  final String? initialReciterName;
  const RecitersPage({super.key, this.initialReciterName});
  @override State<RecitersPage> createState() => _RecitersPageState();
}

class _RecitersPageState extends State<RecitersPage> {
  final AudioPlayer player = SakinahAudioEngine.player;
  StreamSubscription<PlayerState>? playerSub;
  StreamSubscription<PlayerException>? errorSub;
  int surah = 1;
  String edition = 'ar.alafasy';
  String? loadedKey;
  bool playing = false;
  bool downloading = false;
  bool repeatOne = false;
  bool _advancingAfterCompletion = false;
  int done = 0;
  int downloaded = 0;
  int? receivedBytes;
  int? totalBytes;
  String? status;

  @override void initState() {
    super.initState();
    loadedKey = SakinahAudioEngine.loadedKey;
    playing = player.playing;
    playerSub = player.playerStateStream.listen((state) {
      if (mounted) setState(() => playing = state.playing);
      if (state.processingState == ProcessingState.completed &&
          !repeatOne && !_advancingAfterCompletion && surah < 114) {
        unawaited(_playNextSurah());
      }
    });
    errorSub = player.errorStream.listen((error) {
      if (mounted) setState(() => status = 'تعذر تشغيل التسجيل: ${error.message}');
    });
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    await AudioLibrary.loadRequestedReciters();
    final prefs = await SharedPreferences.getInstance();
    final matchingReaders = widget.initialReciterName == null
        ? <Map<String, String>>[]
        : reciters.where((item) {
            final actualName = normalizeArabic(item['name'] ?? '');
            final requestedName = normalizeArabic(widget.initialReciterName!);
            return actualName == requestedName || actualName.contains(requestedName) || requestedName.contains(actualName);
          }).toList();
    final requestedEdition = matchingReaders.isEmpty ? null : matchingReaders.first['edition'];
    final savedRaw = requestedEdition ?? prefs.getString('selected_reciter') ?? edition;
    final saved = reciters.any((item) => item['edition'] == savedRaw) ? savedRaw : reciters.first['edition']!;
    if (saved != savedRaw) await prefs.setString('selected_reciter', saved);
    final savedSurah = (prefs.getInt('selected_surah') ?? surah).clamp(1, 114).toInt();
    if (mounted) setState(() {
      edition = saved;
      surah = savedSurah;
      playing = player.playing;
      loadedKey = SakinahAudioEngine.loadedKey;
      if (widget.initialReciterName != null && requestedEdition == null) {
        status = 'تعذر جلب رابط ${widget.initialReciterName} حالياً. تحقق من الإنترنت ثم أعد فتح قائمة القراء.';
      }
    });
    await _refreshDownloaded();
  }

  Future<void> _refreshDownloaded() async {
    final count = await AudioLibrary.downloadedCount(edition);
    if (mounted) setState(() => downloaded = count);
  }

  Future<void> _selectEdition(String value) async {
    if (playing) await player.pause();
    await player.stop();
    SakinahAudioEngine.loadedKey = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_reciter', value);
    if (mounted) setState(() { edition = value; loadedKey = null; playing = false; status = null; });
    await _refreshDownloaded();
  }

  Future<void> _playNextSurah() async {
    if (_advancingAfterCompletion || surah >= 114) return;
    _advancingAfterCompletion = true;
    try {
      final nextSurah = surah + 1;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('selected_surah', nextSurah);
      if (!mounted) return;
      setState(() {
        surah = nextSurah;
        status = 'انتهت السورة السابقة؛ جارٍ تشغيل سورة ${surahs[nextSurah - 1].name}';
        loadedKey = null;
      });
      SakinahAudioEngine.loadedKey = null;
      await _play();
    } finally {
      _advancingAfterCompletion = false;
    }
  }

  Future<void> _play() async {
    final key = '$edition:$surah';
    try {
      if (playing) {
        await player.pause();
        return;
      }
      if (loadedKey != key || player.processingState == ProcessingState.completed) {
        final file = await AudioLibrary.downloadedSurah(edition, surah);
        if (file != null) {
          await player.setFilePath(file.path);
        } else {
          await player.setUrl(AudioLibrary.surahAudioUrl(surah, edition));
        }
        await player.setLoopMode(repeatOne ? LoopMode.one : LoopMode.off);
        loadedKey = key;
        SakinahAudioEngine.loadedKey = key;
      }
      setState(() => status = null);
      unawaited(player.play());
    } catch (e) {
      if (mounted) setState(() => status = 'تعذر تشغيل السورة. تحقق من الإنترنت أو أعد تنزيل الملف.\n${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> _downloadCurrent() async {
    setState(() { downloading = true; status = 'جارٍ تنزيل سورة ${surahs[surah - 1].name}'; receivedBytes = 0; totalBytes = null; });
    try {
      await AudioLibrary.downloadSurah(edition, surah, onProgress: (received, total) {
        if (mounted) setState(() { receivedBytes = received; totalBytes = total; });
      });
      await _refreshDownloaded();
      if (mounted) setState(() => status = 'تم حفظ سورة ${surahs[surah - 1].name} على الجهاز');
    } catch (e) {
      if (mounted) setState(() => status = '${e.toString().replaceFirst('Exception: ', '')}\nيمكنك إعادة المحاولة وسيُستكمل الجزء المحفوظ.');
    } finally {
      if (mounted) setState(() => downloading = false);
    }
  }

  Future<void> _downloadAll() async {
    setState(() { downloading = true; done = downloaded; status = 'سيتم تجاوز السور المحفوظة واستكمال الناقص'; receivedBytes = null; totalBytes = null; });
    try {
      await AudioLibrary.downloadWholeQuran(edition, onProgress: (number, total, received, length) {
        if (mounted) setState(() { done = number; receivedBytes = received; totalBytes = length; });
      });
      await _refreshDownloaded();
      if (mounted) setState(() => status = 'اكتمل حفظ المصحف الصوتي لهذا القارئ (114 سورة)');
    } catch (e) {
      await _refreshDownloaded();
      if (mounted) setState(() => status = '${e.toString().replaceFirst('Exception: ', '')}\nيمكن إعادة المحاولة لاستكمال التنزيل.');
    } finally {
      if (mounted) setState(() => downloading = false);
    }
  }

  String _bytes(int? value) {
    if (value == null) return '—';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(0)} KB';
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override void dispose() {
    playerSub?.cancel(); errorSub?.cancel(); super.dispose();
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('التلاوات الصوتية'), actions: [
      IconButton(tooltip: 'إدارة التنزيلات', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AudioDownloadsPage())), icon: const Icon(Icons.folder_rounded)),
    ]),
    body: ListView(padding: const EdgeInsets.fromLTRB(18, 12, 18, 28), children: [
      Container(padding: const EdgeInsets.all(19), decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF073A29), Color(0xFF0D6942)]), borderRadius: BorderRadius.circular(23)), child: Row(children: [
        Container(width: 54, height: 54, decoration: BoxDecoration(color: Colors.white.withValues(alpha: .13), borderRadius: BorderRadius.circular(17)), child: const Icon(Icons.headphones_rounded, color: gold, size: 30)),
        const SizedBox(width: 13), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('أنصت بقلبك', style: TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w900)), Text('$downloaded من 114 سورة محفوظة لهذا القارئ', style: const TextStyle(color: Colors.white70, fontSize: 12))])),
      ])),
      const SectionTitle('اختر القارئ'),
      for (final reciter in reciters) _ReciterChoice(
        name: reciter['name']!, edition: reciter['edition']!, selected: edition == reciter['edition'],
        onTap: () => _selectEdition(reciter['edition']!),
      ),
      const SectionTitle('اختر السورة'),
      DropdownButtonFormField<int>(value: surah, decoration: const InputDecoration(prefixIcon: Icon(Icons.menu_book_rounded), border: OutlineInputBorder()),
        items: [for (final item in surahs) DropdownMenuItem(value: item.number, child: Text('${item.number}. ${item.name}'))],
        onChanged: downloading ? null : (value) async { await player.stop(); loadedKey = null; SakinahAudioEngine.loadedKey = null; final selected = value ?? 1; final prefs = await SharedPreferences.getInstance(); await prefs.setInt('selected_surah', selected); if (mounted) setState(() { surah = selected; status = null; }); }),
      const SizedBox(height: 14),
      Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xFF101512), borderRadius: BorderRadius.circular(22), border: Border.all(color: const Color(0xFF293A30))), child: Column(children: [
        Row(children: [const Icon(Icons.graphic_eq_rounded, color: forest), const SizedBox(width: 8), Expanded(child: Text('سورة ${surahs[surah - 1].name}', style: const TextStyle(fontWeight: FontWeight.w900, color: deepGreen, fontSize: 17))), if (downloaded >= 114) const Icon(Icons.offline_pin_rounded, color: forest)]),
        const SizedBox(height: 8),
        StreamBuilder<Duration>(stream: player.positionStream, initialData: Duration.zero, builder: (context, positionSnapshot) {
          final position = positionSnapshot.data ?? Duration.zero;
          return StreamBuilder<Duration?>(stream: player.durationStream, initialData: player.duration, builder: (context, durationSnapshot) {
            final duration = durationSnapshot.data ?? Duration.zero;
            final maxMs = duration.inMilliseconds;
            final currentMs = position.inMilliseconds.clamp(0, maxMs > 0 ? maxMs : 0);
            return Column(children: [
              Slider(value: maxMs > 0 ? currentMs / maxMs : 0, onChanged: maxMs > 0 ? (value) => player.seek(Duration(milliseconds: (value * maxMs).round())) : null, activeColor: forest, inactiveColor: mint),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(_time(position), style: const TextStyle(color: Colors.white70, fontSize: 11)), Text(_time(duration), style: const TextStyle(color: Colors.white70, fontSize: 11))]),
            ]);
          });
        }),
        const SizedBox(height: 5),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(tooltip: repeatOne ? 'إيقاف التكرار' : 'تكرار السورة', onPressed: () async { setState(() => repeatOne = !repeatOne); await player.setLoopMode(repeatOne ? LoopMode.one : LoopMode.off); }, icon: Icon(Icons.repeat_one_rounded, color: repeatOne ? forest : Colors.white60)),
          const SizedBox(width: 13),
          FilledButton.tonal(onPressed: () { final next = player.position - const Duration(seconds: 10); player.seek(next.isNegative ? Duration.zero : next); }, child: const Icon(Icons.replay_10_rounded)),
          const SizedBox(width: 12),
          FilledButton(onPressed: downloading ? null : _play, style: FilledButton.styleFrom(shape: const CircleBorder(), padding: const EdgeInsets.all(19), backgroundColor: forest), child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30)),
          const SizedBox(width: 12),
          FilledButton.tonal(onPressed: () { final duration = player.duration; final next = player.position + const Duration(seconds: 10); player.seek(duration != null && next > duration ? duration : next); }, child: const Icon(Icons.forward_10_rounded)),
        ]),
      ])),
      const SizedBox(height: 12),
      OutlinedButton.icon(onPressed: downloading ? null : _downloadCurrent, icon: const Icon(Icons.download_rounded), label: Text('تنزيل السورة المختارة (${_bytes(receivedBytes)}/${_bytes(totalBytes)})')),
      FilledButton.icon(onPressed: downloading ? null : _downloadAll, icon: const Icon(Icons.download_for_offline_rounded), label: Text(downloading ? 'تنزيل ${done.clamp(0, 114)} / 114' : 'تنزيل المصحف الصوتي كاملاً')),
      if (downloading) Padding(padding: const EdgeInsets.only(top: 9), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [LinearProgressIndicator(value: totalBytes != null && totalBytes! > 0 && receivedBytes != null ? receivedBytes! / totalBytes! : (done / 114), minHeight: 6, borderRadius: BorderRadius.circular(99), color: gold, backgroundColor: mint), if (receivedBytes != null) Padding(padding: const EdgeInsets.only(top: 5), child: Text('حجم الملف الحالي: ${_bytes(receivedBytes)} / ${_bytes(totalBytes)}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: Colors.white70)))])),
      if (status != null) Container(margin: const EdgeInsets.only(top: 12), padding: const EdgeInsets.all(13), decoration: BoxDecoration(color: goldSoft, borderRadius: BorderRadius.circular(15)), child: Text(status!, style: const TextStyle(color: deepGreen, height: 1.5))),
      const SizedBox(height: 12),
      const Text('يُحفظ كل ملف داخل مساحة التطبيق الخاصة. عند انقطاع التنزيل، يمكن إعادة المحاولة لاستكمال الملف الجزئي متى دعم الخادم طلب الاستكمال.', style: TextStyle(color: Colors.white70, fontSize: 11, height: 1.7)),
      const Text('مصادر التلاوات: AlQuran Cloud وMP3Quran.net. التسجيلات لأصحابها؛ راجع شروط كل مصدر قبل إعادة النشر.', style: TextStyle(color: Colors.white60, fontSize: 11, height: 1.7)),
    ]),
  );

  String _time(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${value.inHours > 0 ? '${value.inHours}:' : ''}$minutes:$seconds';
  }
}

class _ReciterChoice extends StatelessWidget {
  final String name, edition; final bool selected; final VoidCallback onTap;
  const _ReciterChoice({required this.name, required this.edition, required this.selected, required this.onTap});
  @override Widget build(BuildContext context) => Card(color: selected ? const Color(0xFF143A29) : const Color(0xFF101512), child: ListTile(
    onTap: onTap, leading: CircleAvatar(backgroundColor: selected ? gold : mint, foregroundColor: deepGreen, child: Icon(selected ? Icons.graphic_eq_rounded : Icons.person_outline_rounded)),
    title: Text(name, style: TextStyle(fontWeight: FontWeight.w900, color: selected ? deepGreen : ink)),
    subtitle: Text(edition, style: const TextStyle(color: Colors.white70, fontSize: 12)),
    trailing: Icon(selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, color: selected ? forest : Colors.white54),
  ));
}

class AudioDownloadsPage extends StatefulWidget {
  const AudioDownloadsPage({super.key});
  @override State<AudioDownloadsPage> createState() => _AudioDownloadsPageState();
}

class _AudioDownloadsPageState extends State<AudioDownloadsPage> {
  String edition = 'ar.alafasy';
  int count = 0;
  bool adhan = false;
  bool loading = true;
  @override void initState() { super.initState(); _refresh(); }
  Future<void> _refresh() async {
    final prefs = await SharedPreferences.getInstance();
    final selected = prefs.getString('selected_reciter') ?? edition;
    final total = await AudioLibrary.downloadedCount(selected);
    final adhanFile = await AudioLibrary.adhanFile();
    if (mounted) setState(() { edition = selected; count = total; adhan = adhanFile.existsSync(); loading = false; });
  }
  Future<void> _delete() async {
    final confirm = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('حذف التلاوات المحفوظة؟'), content: const Text('سيتم حذف ملفات هذا القارئ من الجهاز فقط.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حذف'))],
    ));
    if (confirm == true) { await AudioLibrary.deleteRecitations(edition); await _refresh(); }
  }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('إدارة التنزيلات')), body: loading
    ? const Center(child: CircularProgressIndicator(color: forest))
    : ListView(padding: const EdgeInsets.all(18), children: [
      SCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('المكتبة الصوتية على جهازك', style: TextStyle(color: deepGreen, fontSize: 19, fontWeight: FontWeight.w900)),
        const SizedBox(height: 8), Text('القارئ: ${reciters.firstWhere((r) => r['edition'] == edition, orElse: () => {'name': edition})['name']}'),
        const SizedBox(height: 6), Text('$count من 114 سورة محفوظة', style: const TextStyle(color: forest, fontWeight: FontWeight.w800)),
        const SizedBox(height: 9), LinearProgressIndicator(value: count / 114, color: gold, backgroundColor: mint, minHeight: 7),
        const SizedBox(height: 12), OutlinedButton.icon(onPressed: count == 0 ? null : _delete, icon: const Icon(Icons.delete_outline), label: const Text('حذف تلاوات هذا القارئ')),
      ])),
      SCard(child: ListTile(leading: Icon(adhan ? Icons.check_circle : Icons.music_note, color: forest), title: const Text('ملف الأذان'), subtitle: Text(adhan ? 'محفوظ على الجهاز' : 'لم يتم تنزيله بعد'))),
      const Text('الملفات تحفظ في مساحة التطبيق الخاصة ولا تظهر في تطبيقات الملفات العادية. حذف التطبيق يؤدي عادةً إلى حذف هذه الملفات.', style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.7)),
    ]));
}

class AdhanPage extends StatefulWidget {
  const AdhanPage({super.key});
  @override State<AdhanPage> createState() => _AdhanPageState();
}

class _AdhanPageState extends State<AdhanPage> {
  final AudioPlayer player = AudioPlayer();
  StreamSubscription<PlayerState>? playerSub;
  StreamSubscription<PlayerException>? errorSub;
  bool playing = false, downloading = false, available = false;
  double progress = 0;
  String? status;

  @override void initState() {
    super.initState();
    playing = player.playing;
    playerSub = player.playerStateStream.listen((state) {
      if (mounted) setState(() => playing = state.playing);
    });
    errorSub = player.errorStream.listen((error) {
      if (mounted) setState(() => status = 'تعذر تشغيل ملف الأذان: ${error.message ?? 'مصدر الصوت غير متاح'}');
    });
    _check();
  }

  Future<void> _check() async {
    final file = await AudioLibrary.adhanFile();
    final exists = await file.exists() && await file.length() > 1024;
    if (mounted) setState(() => available = exists);
  }

  Future<void> _download() async {
    setState(() { downloading = true; progress = 0; status = null; });
    try {
      await AudioLibrary.downloadAdhan(onProgress: (value) {
        if (mounted) setState(() => progress = value);
      });
      if (mounted) setState(() { available = true; status = 'تم حفظ الأذان على جهازك ويمكن تشغيله دون إنترنت.'; });
    } catch (e) {
      if (mounted) setState(() => status = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => downloading = false);
    }
  }

  Future<void> _toggle() async {
    try {
      if (playing) { await player.pause(); return; }
      final file = await AudioLibrary.adhanFile();
      if (await file.exists() && await file.length() > 1024) {
        await player.setFilePath(file.path);
      } else {
        await player.setUrl(adhanUrl);
      }
      if (mounted) setState(() => status = null);
      unawaited(player.play().catchError((Object error) {
        if (mounted) setState(() => status = 'تعذر تشغيل الأذان: $error');
      }));
    } catch (e) {
      if (mounted) setState(() => status = 'تعذر تشغيل الأذان: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  @override void dispose() {
    playerSub?.cancel(); errorSub?.cancel(); unawaited(player.dispose()); super.dispose();
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('الأذان الكامل')),
    body: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(width: 154, height: 154, decoration: BoxDecoration(shape: BoxShape.circle, color: goldSoft, border: Border.all(color: gold, width: 2)), child: const Icon(Icons.mosque_rounded, color: forest, size: 72)),
      const SizedBox(height: 22), const Text('الأذان', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: deepGreen)),
      const SizedBox(height: 8), const Text('نزّل التسجيل مرة واحدة ثم استمع إليه دون اتصال.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, height: 1.6)),
      const SizedBox(height: 20),
      SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _toggle, icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded), label: Text(playing ? 'إيقاف مؤقت' : 'استمع إلى الأذان'))),
      const SizedBox(height: 9),
      SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: downloading ? null : _download, icon: const Icon(Icons.download_for_offline_rounded), label: Text(downloading ? 'جارٍ التنزيل ${(progress * 100).round()}%' : available ? 'إعادة تنزيل الأذان' : 'تنزيل الأذان دون إنترنت'))),
      if (downloading) Padding(padding: const EdgeInsets.only(top: 8), child: LinearProgressIndicator(value: progress, color: gold, backgroundColor: mint)),
      if (status != null) Padding(padding: const EdgeInsets.all(12), child: Text(status!, textAlign: TextAlign.center, style: const TextStyle(color: deepGreen, height: 1.6))),
      const SizedBox(height: 15),
      const Text('صاحب التسجيل: Adam-synagda · CC0 1.0 Universal Public Domain Dedication. المصدر: Wikimedia Commons.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white60, fontSize: 11, height: 1.6)),
    ]))),
  );
}

class QiblaPage extends StatefulWidget{const QiblaPage({super.key});@override State<QiblaPage> createState()=>_QiblaPageState();}
class _QiblaPageState extends State<QiblaPage>{double lat=14.5425,lon=49.1242,heading=0;StreamSubscription<MagnetometerEvent>? sub;bool locating=false;String place='المكلا (إعداد افتراضي)';double get bearing=>Qibla.qibla(Coordinates(lat,lon));@override void initState(){super.initState();_sensor();_load();}void _sensor(){sub=magnetometerEventStream().listen((e){final h=(math.atan2(-e.x,e.y)*180/math.pi+360)%360;if(mounted)setState(()=>heading=h);},onError:(_){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تعذر قراءة بوصلة الهاتف')));});}Future<void> _load()async{final p=await SharedPreferences.getInstance();if(!mounted)return;setState(() { lat = p.getDouble('lat') ?? lat; lon = p.getDouble('lon') ?? lon; place = p.getString('city') ?? place; });}Future<void> _locate()async{setState(()=>locating=true);try{if(!await Geolocator.isLocationServiceEnabled())throw Exception('فعّل الموقع');var p=await Geolocator.checkPermission();if(p==LocationPermission.denied)p=await Geolocator.requestPermission();if(p==LocationPermission.denied||p==LocationPermission.deniedForever)throw Exception('إذن الموقع غير متاح');final pos=await Geolocator.getCurrentPosition();final prefs=await SharedPreferences.getInstance();if(!mounted)return;await prefs.setDouble('lat',pos.latitude);await prefs.setDouble('lon',pos.longitude);await prefs.setString('city','موقعي الحالي');setState(() { lat = pos.latitude; lon = pos.longitude; place = 'موقعي الحالي'; });}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString())));}finally{if(mounted)setState(()=>locating=false);}}@override void dispose(){sub?.cancel();super.dispose();}@override Widget build(BuildContext context){final angle=(bearing-heading)*math.pi/180;return Scaffold(appBar:AppBar(title:const Text('اتجاه القبلة')),body:Center(child:Padding(padding:const EdgeInsets.all(20),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[Text(place,style:const TextStyle(color:Colors.white70)),const SizedBox(height:20),Container(width:280,height:280,decoration:BoxDecoration(shape:BoxShape.circle,color:mint,border:Border.all(color:forest,width:2),boxShadow:[BoxShadow(color:forest.withValues(alpha:.1),blurRadius:20)]),child:Stack(alignment:Alignment.center,children:[const Positioned(top:14,child:Text('N',style:TextStyle(color:deepGreen,fontWeight:FontWeight.bold))),const Positioned(bottom:14,child:Text('S',style:TextStyle(color:deepGreen,fontWeight:FontWeight.bold))),const Positioned(left:15,child:Text('W')),const Positioned(right:15,child:Text('E')),Transform.rotate(angle:angle,child:const Icon(Icons.navigation_rounded,size:105,color:forest)),const Positioned(bottom:72,child:Icon(Icons.mosque,color:gold,size:24))])),const SizedBox(height:20),Text('اتجاه القبلة ${bearing.toStringAsFixed(1)}° من الشمال',style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold,color:deepGreen)),const SizedBox(height:5),const Text('ضع الهاتف أفقياً وبعيداً عن المعادن، وحرّكه بشكل رقم 8 لمعايرة البوصلة.',textAlign:TextAlign.center,style:TextStyle(color:Colors.white70,height:1.5)),const SizedBox(height:15),FilledButton.icon(onPressed:locating?null:_locate,icon:const Icon(Icons.my_location),label:const Text('تحديث موقعي'))]))));}}

class HijriDate{final int year,month,day;const HijriDate(this.year,this.month,this.day);}
HijriDate toHijri(DateTime date){final gy=date.year,gm=date.month,gd=date.day;final a=(14-gm)~/12;final y=gy+4800-a;final m=gm+12*a-3;final jd=gd+(153*m+2)~/5+365*y+y~/4-y~/100+y~/400-32045;var l=jd-1948440+10632;final n=(l-1)~/10631;l=l-10631*n+354;final j=((10985-l)~/5316)*((50*l)~/17719)+(l~/5670)*((43*l)~/15238);l=l-((30-j)~/15)*((17719*j)~/50)-(j~/16)*((15238*j)~/43)+29;final month=(24*l)~/709;final day=l-(709*month)~/24;final year=30*n+j-30;return HijriDate(year,month,day);}
const hijriMonths=['','محرم','صفر','ربيع الأول','ربيع الآخر','جمادى الأولى','جمادى الآخرة','رجب','شعبان','رمضان','شوال','ذو القعدة','ذو الحجة'];
class HijriPage extends StatelessWidget{const HijriPage({super.key});@override Widget build(BuildContext context){final h=toHijri(DateTime.now());return Scaffold(appBar:AppBar(title:const Text('التقويم الهجري')),body:Center(child:Padding(padding:const EdgeInsets.all(22),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[const Icon(Icons.calendar_month,color:forest,size:55),const SizedBox(height:20),const Text('تاريخ اليوم الهجري التقريبي',style:TextStyle(color:Colors.white70)),Text('${h.day} ${hijriMonths[h.month]} ${h.year} هـ',style:const TextStyle(fontSize:27,fontWeight:FontWeight.w900,color:deepGreen)),const SizedBox(height:16),const Text('قد يختلف التاريخ الهجري يوماً حسب ثبوت رؤية الهلال والجهة الشرعية المحلية.',textAlign:TextAlign.center,style:TextStyle(color:Colors.white70,height:1.6))]))));}}

class SupportPage extends StatelessWidget{const SupportPage({super.key});Future<void> _copy(BuildContext context,String s)async{await Clipboard.setData(ClipboardData(text:s));if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تم النسخ')));}@override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('ادعم تطوير سكينة')),body:ListView(padding:const EdgeInsets.all(18),children:[Container(padding:const EdgeInsets.all(22),decoration:BoxDecoration(gradient:const LinearGradient(colors:[deepGreen,forest]),borderRadius:BorderRadius.circular(24)),child:const Column(children:[Icon(Icons.volunteer_activism,color:Colors.white,size:48),SizedBox(height:12),Text('ساهم في الخير',style:TextStyle(color:Colors.white,fontSize:25,fontWeight:FontWeight.w900)),SizedBox(height:8),Text('دعمك يساعدنا على مواصلة تطوير تطبيق سكينة وتحسين خدمات القرآن والأذكار ومواقيت الصلاة.',textAlign:TextAlign.center,style:TextStyle(color:Colors.white,height:1.7))])),const SizedBox(height:14),const SCard(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('لماذا تدعم سكينة؟',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold,color:deepGreen)),SizedBox(height:8),Text('• تطوير التطبيق وإضافة خدمات إسلامية جديدة\n• تحسين الأداء والصيانة\n• توفير محتوى موثوق\n• تغطية تكاليف الاستضافة والتطوير',style:TextStyle(height:1.9))])),const SizedBox(height:14),SCard(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('بيانات المساهمة والتحويل',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18,color:deepGreen)),const SizedBox(height:14),const Text('شركة المشقاص للصرافة',style:TextStyle(fontWeight:FontWeight.bold)),const SizedBox(height:10),_CopyRow(label:'اسم المستفيد',value:'عبد العزيز عوض',onCopy:()=>_copy(context,'عبد العزيز عوض')),_CopyRow(label:'رقم الحساب',value:'254264392',onCopy:()=>_copy(context,'254264392'))])),const SizedBox(height:14),const Text('الدعم اختياري تماماً، وجميع خدمات التطبيق متاحة دون اشتراط المساهمة. نسأل الله أن يبارك لكم ويجزيكم خيراً.',textAlign:TextAlign.center,style:TextStyle(color:Colors.white70,height:1.7)),const SizedBox(height:10),const Center(child:Text('تطوير وإنتاج: عبد العزيز عوض بن ثابت\n© 2026 سَكينة',textAlign:TextAlign.center,style:TextStyle(color:Colors.white60,fontSize:12)))]));}
class _CopyRow extends StatelessWidget{final String label,value;final VoidCallback onCopy;const _CopyRow({required this.label,required this.value,required this.onCopy});@override Widget build(BuildContext context)=>Padding(padding:const EdgeInsets.symmetric(vertical:7),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:const TextStyle(color:Colors.white60,fontSize:12)),Text(value,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:17))])),IconButton(onPressed:onCopy,icon:const Icon(Icons.copy,color:forest))]));}

class SettingsPage extends StatelessWidget{const SettingsPage({super.key});@override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('الإعدادات')),body:ListView(padding:const EdgeInsets.all(18),children:[const SCard(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('إعدادات الصلاة',style:TextStyle(fontWeight:FontWeight.bold,color:deepGreen,fontSize:18)),SizedBox(height:8),Text('المواقيت اليدوية المعتمدة للمكلا: الفجر 04:31، الشروق 05:46، الظهر 11:30، العصر 14:46، المغرب 17:11، العشاء 18:41.') ])),const SCard(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('الموقع',style:TextStyle(fontWeight:FontWeight.bold,color:deepGreen,fontSize:18)),SizedBox(height:8),Text('يستخدم التطبيق موقع الهاتف اختيارياً لتحديد اتجاه القبلة. مواقيت الصلاة اليدوية المعتمدة لا تحتاج إلى إذن الموقع.')]))]));}

class AboutPage extends StatelessWidget{const AboutPage({super.key});@override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('عن سكينة والمصادر')),body:ListView(padding:const EdgeInsets.all(18),children:[const Text('سَكينة',style:TextStyle(fontSize:28,fontWeight:FontWeight.w900,color:deepGreen)),const Text('تطبيق إسلامي للقرآن والأذكار والصلاة والقبلة. لا يتطلب حساباً أو تسجيل دخول، ولا يحتوي على إعلانات أو أدوات تحليلات. تُحفظ العلامات والتقدم والإعدادات على الجهاز.'),const SectionTitle('الخصوصية'),const Text('إذن الموقع اختياري ويُستخدم محلياً لحساب مواقيت الصلاة واتجاه القبلة. يتصل التطبيق بمصادر المحتوى عند طلب النص أو الصوت، ولا يرسل سجل عبادات المستخدم أو علامات القرآن إلى خادم.',style:TextStyle(height:1.7)),const SectionTitle('مصادر المحتوى'),const Text('• نص القرآن وبعض التلاوات: AlQuran Cloud — https://alquran.cloud/\n• تلاوات القراء الإضافيين: فهرس MP3Quran API — https://mp3quran.net/\n• مصادر التلاوات تخضع لحقوق أصحاب التسجيلات؛ التطبيق لا يعيد استضافة الملفات.\n• مواقيت الصلاة: جدول يدوي معتمد للمكلا حسب الأوقات التي أدخلها المستخدم.\n• الأذان: Beautiful adhan.ogg — Adam-synagda، CC0 1.0 عبر Wikimedia Commons.\n• الأذكار والأحاديث مختارة مع إحالات إلى كتب الحديث المذكورة داخل الصفحات.',style:TextStyle(height:1.8)),const SectionTitle('ملاحظة علمية'),const Text('المواقيت ثابتة يدوياً وفق الجدول المعتمد للمكلا. التاريخ الهجري تقريبي ويخضع لرؤية الهلال. راجع المصادر الشرعية المحلية عند الحاجة.',style:TextStyle(height:1.7)),const SectionTitle('الحقوق'),const Text('تطوير وإنتاج: عبد العزيز عوض بن ثابت\n© 2026 — سَكينة',style:TextStyle(height:1.8))]));}

class PrayerStandalonePage extends StatelessWidget{const PrayerStandalonePage({super.key});@override Widget build(BuildContext context)=>const Scaffold(body:SafeArea(child:PrayerPage()));}
class QuranStandalonePage extends StatelessWidget{const QuranStandalonePage({super.key});@override Widget build(BuildContext context)=>const Scaffold(body:SafeArea(child:QuranPage()));}
class AzkarStandalonePage extends StatelessWidget{const AzkarStandalonePage({super.key});@override Widget build(BuildContext context)=>const Scaffold(body:SafeArea(child:AzkarPage()));}
