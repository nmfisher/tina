import 'package:test/test.dart';
import 'package:tina_persistence/session_store_api.dart';
import 'package:tina_wasm/src/wasm_preopen_paths.dart';

void main() {
  test('tools resolve only the workspace mount', () {
    final mounts = WasmPreopenPaths<int>([
      (1, '.'),
      (2, '/tina-config'),
      (3, '/tina-store'),
      (4, 'config'),
    ]);
    expect(mounts.resolve('/tina-config/config')?.$1, 2);
    expect(mounts.resolve('config/example')?.$1, 4);
    expect(mounts.resolve('/tina-config/../tina-store/sessions.jsonl'), isNull);
    final tools = mounts.workspaceOnly;
    expect(tools.resolve('config/example')?.$1, 1);
    expect(tools.resolve('/tina-config/config'), isNull);
    expect(tools.resolve('/tina-store/sessions.jsonl'), isNull);
  });

  test('session summaries use file order across interleaved metadata', () {
    final rows = decodeWasmSessionLog('''
{"t":"marker","id":"a","_key":100}
{"t":"entry","id":"a","seq":0}
{"t":"details","id":"a","model":"updated"}
{"t":"marker","id":"b"}
{"t":"entry","id":"a","seq":1}
''');
    final session = listWasmSessions(rows).first;
    expect(session.registryKey, 1);
    expect(session.lastActivityKey, 5);
    expect(session.entries, 2);
    expect(session.model, 'updated');
  });
}
