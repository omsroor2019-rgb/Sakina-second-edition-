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

  test('Selected reciter list contains five entries', () {
    expect(reciters, hasLength(5));
    expect(reciters.map((r) => r['edition']).toSet(), hasLength(5));
  });

  test('Adhkar, hadiths and supplications are present', () {
    expect(adhkar, isNotEmpty);
    expect(hadiths, isNotEmpty);
    expect(duas, isNotEmpty);
  });
}
