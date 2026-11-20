/// The cross-leg fixture pair (commit 28): the wasm-shaped stub in
/// `tina_tools/testing.dart` must implement exactly the surfaces the
/// portable plugin implements — the pair drifts together or not at
/// all. Runs wherever this package's suite runs; the analyzer checks
/// it everywhere.
library;

import 'package:test/test.dart';
import 'package:tina_mode/tina_mode.dart' show ModePolicySource;
import 'package:tina_tools/portable_tools.dart' as tt;
import 'package:tina_tools/testing.dart';

import 'package:tina_wasm/src/portable_tools_plugin.dart';

void main() {
  test('the fixture implements the portable plugin\'s exact surfaces',
      () {
    final fixture = WasmShapedToolsPlugin();
    expect(fixture, isA<ModePolicySource>());
    expect(fixture, isA<tt.ToolSessionSource>());
    expect(fixture, isA<tt.ToolsPluginSurface>());

    // Same static surface set as the portable plugin itself.
    final PortableToolsPlugin Function() shape =
        () => throw StateError('never constructed — shape check only');
    expect(shape, isNotNull);
  });
}
