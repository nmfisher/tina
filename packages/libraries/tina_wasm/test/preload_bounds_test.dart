// Regression tests for the boot preload bounds.
//
// The bug: PreloadedAppIo.load read EVERY regular file fully into
// Latin1 strings before the assembly booted. With the real preopen
// layout (workspace preopened as '.', config as 'config'), the '.tina'
// root resolves to the WORKSPACE ROOT descriptor, so the walk slurps
// the whole workspace tree (depth <= 4) under '.tina/'-prefixed keys —
// a large file anywhere in it went String.fromCharCodes ->
// Latin1String.fromAsciiBytes -> cloneTyped and trapped the guest.
//
// The admission decisions live in PreloadBudget, deliberately free of
// wasm-component imports so they run on the plain VM (the walk itself
// drives the wasi:filesystem port and only runs compiled to wasm —
// wasm_components' barrel cannot compile for the VM platform, which is
// why these tests target the budget, not the walk; the walk-level
// regression is covered by the component boot smoke in a big-file
// workspace).
library;

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tina_wasm/src/preload_budget.dart';

void main() {
  test('defaults: 2MB per file, 64MB total, 8KB sniff window', () {
    final budget = PreloadBudget();
    expect(budget.maxFileBytes, PreloadBudget.defaultMaxFileBytes);
    expect(PreloadBudget.defaultMaxFileBytes, 2 * 1024 * 1024);
    expect(budget.maxTotalBytes, PreloadBudget.defaultMaxTotalBytes);
    expect(PreloadBudget.defaultMaxTotalBytes, 64 * 1024 * 1024);
    expect(budget.binarySniffWindow, PreloadBudget.defaultBinarySniffWindow);
    expect(PreloadBudget.defaultBinarySniffWindow, 8 * 1024);
  });

  test('a 60MB workspace file is refused by stat and never read',
      () async {
    final budget = PreloadBudget();
    expect(budget.admitStatSize(60 * 1024 * 1024), isFalse);
    expect(budget.preloadedBytes, 0);
    expect(budget.exhausted, isFalse,
        reason: 'an oversized file must not burn the shared budget');
    // The read-time guard agrees even if something read it anyway.
    expect(budget.admitReadBytes(60 * 1024 * 1024), isFalse);
  });

  test('100 x 1MB files: exactly 64 admitted, 36 refused, then exhausted',
      () {
    final budget = PreloadBudget();
    var admitted = 0;
    for (var i = 0; i < 100; i++) {
      if (!budget.admitStatSize(1024 * 1024)) continue;
      if (!budget.admitReadBytes(1024 * 1024)) continue;
      admitted++;
    }
    expect(admitted, 64);
    expect(budget.preloadedBytes, 64 * 1024 * 1024);
    expect(budget.exhausted, isTrue);
    // Once exhausted, even a tiny file is refused.
    expect(budget.admitStatSize(10), isFalse);
  });

  test('reaching the budget exactly is not exhaustion by itself', () {
    // Default per-file cap is 2MB, so prove the ==boundary on a budget
    // where a single file may fill it exactly.
    final budget =
        PreloadBudget(maxFileBytes: 8 * 1024 * 1024, maxTotalBytes: 8 * 1024 * 1024);
    expect(budget.admitStatSize(8 * 1024 * 1024), isTrue,
        reason: 'preloaded(0) + 8MB == budget, not >');
    expect(budget.admitReadBytes(8 * 1024 * 1024), isTrue);
    expect(budget.preloadedBytes, 8 * 1024 * 1024);
    expect(budget.exhausted, isFalse,
        reason: 'the flag flips on the first REFUSAL, not on a full budget');
  });

  test('a file that grew between stat and read is re-clipped', () {
    final budget = PreloadBudget();
    expect(budget.admitStatSize(1024), isTrue);
    // The read came back 3MB: over the per-file cap regardless of stat.
    expect(budget.admitReadBytes(3 * 1024 * 1024), isFalse);
    expect(budget.preloadedBytes, 0);
    // A growth that only busts the TOTAL budget flips exhaustion.
    final tight = PreloadBudget(maxTotalBytes: 1024 * 1024);
    expect(tight.admitStatSize(512 * 1024), isTrue);
    expect(tight.admitReadBytes(2 * 1024 * 1024), isFalse);
    expect(tight.exhausted, isTrue);
  });

  test('binary sniff: NUL inside the window skips, past it does not', () {
    final budget = PreloadBudget();
    final text = Uint8List.fromList(List.filled(32 * 1024, 0x61));
    expect(budget.looksBinary(text), isFalse);
    final leadingNul = Uint8List.fromList([0x61, 0x00, 0x61]);
    expect(budget.looksBinary(leadingNul), isTrue);
    final allNul = Uint8List.fromList(List.filled(1024, 0x00));
    expect(budget.looksBinary(allNul), isTrue);
    // A NUL at byte 9000 (past the 8KB window) is NOT detected — the
    // documented heuristic window.
    final lateNul = Uint8List.fromList(List.filled(32 * 1024, 0x61))
      ..[9000] = 0x00;
    expect(budget.looksBinary(lateNul), isFalse);
  });

  test('a refused binary file gives its bytes back to the budget', () {
    final budget = PreloadBudget(maxTotalBytes: 4 * 1024 * 1024);
    // Admit a 1MB binary file, then release it like the walk does.
    expect(budget.admitStatSize(1024 * 1024), isTrue);
    expect(budget.admitReadBytes(1024 * 1024), isTrue);
    budget.releaseBytes(1024 * 1024);
    expect(budget.preloadedBytes, 0);
    // The released budget is available again for real text (2MB is the
    // default per-file cap, allowed again now that the bytes came back).
    expect(budget.admitStatSize(2 * 1024 * 1024), isTrue);
  });

  test('boot-critical caches admit past the per-file cap, still bounded',
      () {
    // The regression: the host snapshots the models.dev provider catalog
    // (a >2MB JSON) into config/.tina/cache/; configuredDescriptors reads
    // it through the preload snapshot, so the default per-file cap must
    // not drop it or config providers lose their builtin descriptor.
    final budget = PreloadBudget();
    const cacheCap = PreloadBudget.bootCriticalFileBytes;
    const catalog = 3 * 1024 * 1024; // > 2MB default, < 16MB carve-out
    expect(budget.admitStatSize(catalog, maxFileBytes: cacheCap), isTrue);
    expect(budget.admitReadBytes(catalog, maxFileBytes: cacheCap), isTrue);
    expect(budget.preloadedBytes, catalog);
    expect(budget.exhausted, isFalse);
    // The carve-out is a bigger cap, not an unbounded one.
    expect(budget.admitStatSize(cacheCap + 1, maxFileBytes: cacheCap),
        isFalse);
    // The total budget still applies to caches.
    final tight = PreloadBudget(maxTotalBytes: 4 * 1024 * 1024);
    expect(
        tight.admitStatSize(3 * 1024 * 1024, maxFileBytes: cacheCap), isTrue);
    expect(
        tight.admitReadBytes(3 * 1024 * 1024, maxFileBytes: cacheCap), isTrue);
    expect(tight.admitStatSize(2 * 1024 * 1024, maxFileBytes: cacheCap),
        isFalse,
        reason: '3MB recorded + 2MB > the 4MB total budget');
    expect(tight.exhausted, isTrue);
  });
}
