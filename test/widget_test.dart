import 'package:flutter_test/flutter_test.dart';
import 'package:sakinah/data.dart';
import 'package:sakinah/extra_pages.dart';

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

  test('Supported reciter list contains distinct editions and bitrates', () {
    expect(reciters.length, greaterThanOrEqualTo(10));
    expect(reciters.map((r) => r['edition']).toSet(), hasLength(reciters.length));
    expect(reciters.every((r) => r['bitrate'] == '128'), isTrue);
    expect(reciters.map((r) => r['edition']).toSet(), containsAll([
      'ar.alafasy', 'ar.abdulbasitmurattal', 'ar.saudalshuraim',
      'ar.abdullahbasfar', 'ar.nasseralqatami', 'ar.bandarbalila',
      'ar.ibrahimalakhdar', 'ar.mahmoudalialbanna',
      'ar.abdullahalmatrood', 'ar.abdulazizazzahrani',
    ]));
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
