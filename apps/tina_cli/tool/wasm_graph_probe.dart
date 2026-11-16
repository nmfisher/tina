// Local reproduction of the wasm component builds' import graph.
//
// The release compiles bin/engine.dart and bin/tui.dart with
// wasm_tools (dart2wasm). The TUI component imports tui_session.dart,
// whose transitive imports reach the plugin catalog; the channel
// package must compile under dart2wasm with the in-memory store only.
// This entry mirrors exactly that graph:
//
//     dart compile wasm tool/wasm_graph_probe.dart -o /tmp/probe.wasm
//
// It fails with the sqlite3 dart:ffi error whenever anything in the
// graph imports the sqlite channel variant, and compiles clean when
// the graph is FFI-free.
//
// The imports below are the probe's payload — they pull the graph in
// without executing anything, so main() stays empty.
// ignore_for_file: unused_import
import 'package:tina/src/tui_session.dart' show TuiSessionHandle;
import 'package:tina_channel/tina_channel.dart' show ChannelPlugin;

void main() {}
