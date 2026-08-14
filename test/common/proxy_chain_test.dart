import 'package:fl_clash/common/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps the internal chain proxy wherever GUI text contains it', () {
    expect(displayProxyName(internalChainProxyName), 'Chain');
    expect(
      displayProxyText('Selector($internalChainProxyName)'),
      'Selector(Chain)',
    );
  });

  test('maps an embedded internal hop back to its proxy name', () {
    final hopName = internalChainHopName(2, '🇺🇸 US-CO');

    expect(displayProxyText('Relay($hopName)'), 'Relay(🇺🇸 US-CO)');
  });
}
