import 'package:fl_clash/common/utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Utils.getTimeText', () {
    final subject = Utils();

    test('formats sub-day uptime', () {
      expect(
        subject.getTimeText(
          const Duration(hours: 23, minutes: 59, seconds: 59).inMilliseconds,
        ),
        '23:59:59',
      );
    });

    test('continues past the old 99 hour limit', () {
      expect(
        subject.getTimeText(
          const Duration(hours: 100, minutes: 2, seconds: 3).inMilliseconds,
        ),
        '4d 04:02:03',
      );
    });

    test('handles null and negative values', () {
      expect(subject.getTimeText(null), '00:00:00');
      expect(subject.getTimeText(-1), '00:00:00');
    });
  });
}
