import 'package:flutter_test/flutter_test.dart';
import 'package:sakinah/data.dart';
import 'package:sakinah/extra_pages.dart';
import 'package:sakinah/main.dart' as app;

void main() {
  test('Quran chapter index contains all 114 chapters and 6236 verses', () {
    expect(surahs, hasLength(114));
    expect(surahs.fold<int>(0, (sum, s) => sum + s.verses), 6236);
    expect(surahs.first.name, 'الفاتحة');
    expect(surahs.last.name, 'الناس');
  });

  test('Arabic Quran search normalizes tashkeel and common letter variants', () {
    expect(normalizeArabic('إِنَّ اللَّهَ'), normalizeArabic('ان الله'));
    expect(normalizeArabic('هَٰذَا'), normalizeArabic('هذا'));
    expect(normalizeArabic('مُوسَى'), normalizeArabic('موسي'));
    expect(normalizeArabic('رحمة'), isNot(normalizeArabic('رحمه')));
  });

  test('Ali Jaber audio uses the verified MP3Quran full-surah directory', () {
    expect(
      app.AudioLibrary.surahAudioUrl(1, 'mp3quran_ali_jaber'),
      'https://cdn.mp3quran.net/audio/ali-jaber/r1/001.mp3',
    );
    expect(
      app.AudioLibrary.surahAudioUrl(114, 'mp3quran_ali_jaber'),
      'https://cdn.mp3quran.net/audio/ali-jaber/r1/114.mp3',
    );
  });

  test('AlQuran Cloud fallback readers use the documented surah audio route', () {
    expect(
      app.AudioLibrary.surahAudioUrl(1, 'ar.alafasy'),
      'https://cdn.islamic.network/quran/audio-surah/128/ar.alafasy/1.mp3',
    );
    expect(
      app.AudioLibrary.surahAudioUrl(1, 'ar.sudais'),
      'https://cdn.islamic.network/quran/audio-surah/192/ar.sudais/1.mp3',
    );
  });

  test('Static reciters have unique editions, valid sources and correct bitrates', () {
    // The built-in fallback catalogue contains nine AlQuran Cloud readers
    // plus Ali Jaber, whose verified full-surah recordings come from MP3Quran.
    expect(reciters, hasLength(10));
    expect(reciters.map((r) => r['edition']).toSet(), hasLength(reciters.length));

    expect(
      reciters.singleWhere((r) => r['name'] == 'علي جابر'),
      containsPair('edition', 'mp3quran_ali_jaber'),
    );
    final aliJaber = reciters.singleWhere((r) => r['name'] == 'علي جابر');
    expect(aliJaber['source'], 'mp3quran_fallback');
    expect(aliJaber['bitrate'], 'API');

    final alQuranReaders = reciters.where((r) => r['source'] == 'alquran').toList();
    expect(alQuranReaders, hasLength(9));
    expect(alQuranReaders.every((r) => r['bitrate'] != 'API'), isTrue);
    expect(
      reciters.map((r) => r['name']).toSet(),
      containsAll(['مشاري العفاسي', 'سعود الشريم', 'عبدالرحمن السديس']),
    );
    expect(reciters.firstWhere((r) => r['edition'] == 'ar.alafasy')['bitrate'], '128');
    expect(reciters.firstWhere((r) => r['edition'] == 'ar.shuraim')['bitrate'], '128');
    expect(reciters.firstWhere((r) => r['edition'] == 'ar.sudais')['bitrate'], '192');
  });

  test('Manual prayer times match the approved Al Mukalla schedule', () {
    final date = DateTime(2026, 11, 22);
    final times = app.ApprovedPrayerSchedule.forDate(date);
    expect(times.map((entry) => '${entry.key} ${entry.value.hour.toString().padLeft(2, "0")}:${entry.value.minute.toString().padLeft(2, "0")}').toList(), [
      'الفجر 04:31',
      'الشروق 05:46',
      'الظهر 11:30',
      'العصر 14:46',
      'المغرب 17:11',
      'العشاء 18:41',
    ]);
    expect(app.ApprovedPrayerSchedule.nextPrayer(DateTime(2026, 11, 22, 4, 20)).key, 'الفجر');
    expect(app.ApprovedPrayerSchedule.nextPrayer(DateTime(2026, 11, 22, 17, 30)).key, 'العشاء');
    expect(app.ApprovedPrayerSchedule.nextPrayer(DateTime(2026, 11, 22, 20, 0)).key, 'الفجر');
  });

  test('Adhkar, hadiths and supplications are present', () {
    expect(adhkar, isNotEmpty);
    expect(hadiths, isNotEmpty);
    expect(duas, isNotEmpty);
    expect(adhkarCategories, containsAll(['أذكار الصباح والمساء', 'أذكار الصلاة', 'أذكار بعد الصلاة', 'أذكار النوم', 'أذكار السفر', 'أذكار المسجد']));
    expect(hadithCategories, contains('الأخلاق والمعاملة'));
    expect(duaCategories, contains('أدعية من القرآن'));
    expect(adhkar.length, greaterThanOrEqualTo(30));
    expect(hadiths.length, greaterThanOrEqualTo(20));
    expect(duas.length, greaterThanOrEqualTo(18));
    expect(duaCategories, containsAll(['الهم والكرب', 'الهداية والثبات', 'الوالدان والأسرة', 'الرزق والخير', 'قبول العمل', 'الصبر والثبات']));
    expect(adhkar.every((item) => item.text.trim().isNotEmpty && item.source.trim().isNotEmpty), isTrue);
    expect(adhkar.every((item) => adhkarCategories.contains(item.category)), isTrue);
    expect(hadiths.every((item) => item.text.trim().isNotEmpty && item.source.trim().isNotEmpty), isTrue);
    expect(hadiths.every((item) => hadithCategories.contains(item.category)), isTrue);
    expect(duas.every((item) => item.text.trim().isNotEmpty && item.source.trim().isNotEmpty), isTrue);
    expect(duas.every((item) => duaCategories.contains(item.category) && duaCategories.contains(item.topic)), isTrue);
  });
}
