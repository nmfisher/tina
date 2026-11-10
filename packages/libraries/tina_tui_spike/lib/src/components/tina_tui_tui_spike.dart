// ignore_for_file: type=warning
import r'package:wasm_components/wasm_components.dart' as i0;

import r'tina_term.dart' as i1;

// ignore: import_internal_library
import r'dart:_wasm' as i2;

import r'wasi_cli.dart' as i3;

import r'dart:typed_data' as i4;

import r'wasi_clocks.dart' as i5;
import r'wasi_filesystem.dart' as i6;
import r'wasi_sockets.dart' as i7;
import r'wasi_random.dart' as i8;

import r'package:meta/meta.dart' as i9;

@pragma("wasm:import", r"component._import0")
external i2.WasmVoid _import0(i2.WasmI32 p0);

final class _Imported$0 implements i1.Tty {
  const _Imported$0();
  @override
  (int, int) getSize() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import0(tmp0);
    final tmp1 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
    final tmp3 = (tmp1.toIntUnsigned(), tmp2.toIntUnsigned());
    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp3;
  }
}

@pragma("wasm:import", r"component._import1")
external i2.WasmVoid _import1(i2.WasmI32 p0);
@pragma("wasm:import", r"component._import2")
external i2.WasmVoid _import2(i2.WasmI32 p0);
@pragma("wasm:import", r"component._import3")
external i2.WasmVoid _import3(i2.WasmI32 p0);

final class _Imported$12 implements i3.Environment {
  const _Imported$12();
  @override
  List<(String, String)> getEnvironment() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import1(tmp0);
    final tmp1 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);

    final tmp9 = tmp1.toIntUnsigned();
    final tmp8 = List.generate(tmp2.toIntUnsigned(), growable: false, (i) {
      final elementPtr = i2.WasmI32.fromInt(tmp9 + i * 16);
      final tmp3 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 0);
      final tmp4 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 4);
      final tmp5 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 8);
      final tmp6 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 12);
      final tmp7 = (
        i0.AllocatedString.read(tmp3, tmp4),
        i0.AllocatedString.read(tmp5, tmp6),
      );

      return tmp7;
    });

    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp8;
  }

  @override
  List<String> getArguments() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import2(tmp0);
    final tmp1 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);

    final tmp6 = tmp1.toIntUnsigned();
    final tmp5 = List.generate(tmp2.toIntUnsigned(), growable: false, (i) {
      final elementPtr = i2.WasmI32.fromInt(tmp6 + i * 8);
      final tmp3 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 0);
      final tmp4 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 4);

      return i0.AllocatedString.read(tmp3, tmp4);
    });

    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp5;
  }

  @override
  i0.Option<String> getInitialCwd() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(12));
    _import3(tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Option<String> tmp4;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 8);

      tmp4 = .some(i0.AllocatedString.read(tmp2, tmp3));
    } else {
      tmp4 = .none;
    }

    i0.dartFree(tmp0, const i2.WasmI32(12), const i2.WasmI32(4));
    return tmp4;
  }
}

@pragma("wasm:import", r"component._import4")
external i2.WasmVoid _import4(i2.WasmI32 p0);
@pragma("wasm:import", r"component._import5")
external i2.WasmVoid _import5(i2.WasmI32 p0);

final class _Imported$13 implements i3.Exit {
  const _Imported$13();
  @override
  void exit({required i0.Result<void, void> status}) {
    i2.WasmI32 tmp0;
    switch (status) {
      case i0.OkResult(:final value):
        tmp0 = const i2.WasmI32(0);

      case i0.ErrorResult(:final value):
        tmp0 = const i2.WasmI32(1);
    }
    _import4(tmp0);
  }

  @override
  void exitWithCode({required int statusCode}) {
    _import5(i2.WasmI32.uint8FromInt(statusCode));
  }
}

final class _Imported$15 implements i3.Types {
  const _Imported$15();
}

@pragma('wasm:import', 'component.stream90.new')
external i2.WasmI64 _streamNew90();
@pragma('wasm:import', 'component.stream90.read')
external i2.WasmI32 _streamRead90(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream90.write')
external i2.WasmI32 _streamWrite90(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream90.drop-readable')
external i2.WasmVoid _streamDropReadable90(i2.WasmI32 stream);
@pragma('wasm:import', 'component.stream90.drop-writable')
external i2.WasmVoid _streamDropWritable90(i2.WasmI32 stream);

final class _Vtable90 implements i0.StreamVtable<i4.Uint8List> {
  const _Vtable90();

  @override
  int get elementSize => 1;
  @override
  int allocateBuffer(int size) {
    return i0
        .mallocAligned(const i2.WasmI32(1), (size * 1).toWasmI32())
        .toIntUnsigned();
  }

  @override
  void freeBuffer(int address, int totalSize, int start, int end) {
    i0.dartFree(
      address.toWasmI32(),
      (totalSize * 1).toWasmI32(),
      const i2.WasmI32(1),
    );
  }

  @override
  void writeToBuffer(int address, i4.Uint8List elements) {
    for (final (i, element) in elements.indexed) {
      final wasmAddress = i2.WasmI32.fromInt(address + i);

      i0.memory.storeInt8(
        wasmAddress.toIntUnsigned(),
        i2.WasmI32.uint8FromInt(element),
        offset: 0,
      );
    }
  }

  @override
  i4.Uint8List readFromBuffer(int address, int count) {
    final typedList = i4.Uint8List(count);
    for (var i = 0; i < count; i++) {
      final ptr = i2.WasmI32.fromInt(address + i * 1);
      final tmp0 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 0);

      typedList[i] = tmp0.toIntUnsigned();
    }
    return typedList;
  }

  @override
  int newStream() => _streamNew90().toInt();
  @override
  void dropReadable(int stream) {
    _streamDropReadable90(i2.WasmI32.fromInt(stream));
  }

  @override
  void dropWritable(int stream) {
    _streamDropWritable90(i2.WasmI32.fromInt(stream));
  }

  @override
  int read(int stream, int ptr, int n) {
    return _streamRead90(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }

  @override
  int write(int stream, int ptr, int n) {
    return _streamWrite90(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }
}

@pragma('wasm:import', 'component.future92.new')
external i2.WasmI64 _futureNew92();
@pragma('wasm:import', 'component.future92.write')
external i2.WasmI32 _futureWrite92(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future92.read')
external i2.WasmI32 _futureRead92(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future92.drop-readable')
external i2.WasmVoid _futureDropReadable92(i2.WasmI32 future);
@pragma('wasm:import', 'component.future92.drop-writable')
external i2.WasmVoid _futureDropWritable92(i2.WasmI32 future);

final class _Vtable92
    implements i0.FutureVtable<i0.Result<void, i3.TypesErrorCode>> {
  const _Vtable92();

  @override
  int newFuture() => _futureNew92().toInt();

  @override
  int read(int future, int buffer) {
    return _futureRead92(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  int write(int future, int buffer) {
    return _futureWrite92(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  void dropRead(int future) {
    _futureDropReadable92(i2.WasmI32.fromInt(future));
  }

  @override
  void dropWrite(int future) {
    _futureDropWritable92(i2.WasmI32.fromInt(future));
  }

  @override
  int allocateBuffer() {
    return i0
        .mallocAligned(const i2.WasmI32(1), const i2.WasmI32(2))
        .toIntUnsigned();
  }

  @override
  void freeBuffer(int address, {required bool containsValue}) {
    i0.dartFree(address.toWasmI32(), const i2.WasmI32(2), const i2.WasmI32(1));
  }

  @override
  void store(int address, i0.Result<void, i3.TypesErrorCode> value) {
    final wasmAddress = i2.WasmI32.fromInt(address);

    switch (value) {
      case i0.OkResult(:final value):
        i0.memory.storeInt8(
          wasmAddress.toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 0,
        );

      case i0.ErrorResult(:final value):
        i0.memory.storeInt8(
          wasmAddress.toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 0,
        );
        i0.memory.storeInt8(
          wasmAddress.toIntUnsigned(),
          value.index.toWasmI32(),
          offset: 1,
        );
    }
  }

  @override
  i0.Result<void, i3.TypesErrorCode> load(int address) {
    final wasmAddress = i2.WasmI32.fromInt(address);

    final tmp0 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 0);
    final i0.Result<void, i3.TypesErrorCode> tmp2;
    if (tmp0.toBool()) {
      final tmp1 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 1);

      tmp2 = .error(i3.TypesErrorCode.values[tmp1.toIntUnsigned()]);
    } else {
      tmp2 = .ok(null);
    }

    return tmp2;
  }
}

@pragma("wasm:import", r"component._import16")
external i2.WasmVoid _import16(i2.WasmI32 p0);

final class _Imported$16 implements i3.Stdin {
  const _Imported$16();
  @override
  (Stream<i4.Uint8List>, Future<i0.Result<void, i3.TypesErrorCode>>)
  readViaStream() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import16(tmp0);
    final tmp1 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.ReadableStream(tmp1.toIntUnsigned(), const _Vtable90());
    final tmp3 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
    final tmp4 = i0.readFuture(const _Vtable92(), tmp3.toIntUnsigned());
    final tmp5 = (tmp2, tmp4);
    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp5;
  }
}

@pragma('wasm:import', 'component.future96.new')
external i2.WasmI64 _futureNew96();
@pragma('wasm:import', 'component.future96.write')
external i2.WasmI32 _futureWrite96(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future96.read')
external i2.WasmI32 _futureRead96(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future96.drop-readable')
external i2.WasmVoid _futureDropReadable96(i2.WasmI32 future);
@pragma('wasm:import', 'component.future96.drop-writable')
external i2.WasmVoid _futureDropWritable96(i2.WasmI32 future);

final class _Vtable96
    implements i0.FutureVtable<i0.Result<void, i3.TypesErrorCode>> {
  const _Vtable96();

  @override
  int newFuture() => _futureNew96().toInt();

  @override
  int read(int future, int buffer) {
    return _futureRead96(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  int write(int future, int buffer) {
    return _futureWrite96(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  void dropRead(int future) {
    _futureDropReadable96(i2.WasmI32.fromInt(future));
  }

  @override
  void dropWrite(int future) {
    _futureDropWritable96(i2.WasmI32.fromInt(future));
  }

  @override
  int allocateBuffer() {
    return i0
        .mallocAligned(const i2.WasmI32(1), const i2.WasmI32(2))
        .toIntUnsigned();
  }

  @override
  void freeBuffer(int address, {required bool containsValue}) {
    i0.dartFree(address.toWasmI32(), const i2.WasmI32(2), const i2.WasmI32(1));
  }

  @override
  void store(int address, i0.Result<void, i3.TypesErrorCode> value) {
    final wasmAddress = i2.WasmI32.fromInt(address);

    switch (value) {
      case i0.OkResult(:final value):
        i0.memory.storeInt8(
          wasmAddress.toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 0,
        );

      case i0.ErrorResult(:final value):
        i0.memory.storeInt8(
          wasmAddress.toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 0,
        );
        i0.memory.storeInt8(
          wasmAddress.toIntUnsigned(),
          value.index.toWasmI32(),
          offset: 1,
        );
    }
  }

  @override
  i0.Result<void, i3.TypesErrorCode> load(int address) {
    final wasmAddress = i2.WasmI32.fromInt(address);

    final tmp0 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 0);
    final i0.Result<void, i3.TypesErrorCode> tmp2;
    if (tmp0.toBool()) {
      final tmp1 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 1);

      tmp2 = .error(i3.TypesErrorCode.values[tmp1.toIntUnsigned()]);
    } else {
      tmp2 = .ok(null);
    }

    return tmp2;
  }
}

@pragma("wasm:import", r"component._import22")
external i2.WasmI32 _import22(i2.WasmI32 p0);

final class _Imported$17 implements i3.Stdout {
  const _Imported$17();
  @override
  Future<i0.Result<void, i3.TypesErrorCode>> writeViaStream({
    required Stream<i4.Uint8List> data,
  }) {
    final tmp0 = i0.newReadableStream(const _Vtable90(), data).toWasmI32();
    final tmp1 = _import22(tmp0);
    final tmp2 = i0.readFuture(const _Vtable96(), tmp1.toIntUnsigned());
    return tmp2;
  }
}

@pragma('wasm:import', 'component.future99.new')
external i2.WasmI64 _futureNew99();
@pragma('wasm:import', 'component.future99.write')
external i2.WasmI32 _futureWrite99(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future99.read')
external i2.WasmI32 _futureRead99(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future99.drop-readable')
external i2.WasmVoid _futureDropReadable99(i2.WasmI32 future);
@pragma('wasm:import', 'component.future99.drop-writable')
external i2.WasmVoid _futureDropWritable99(i2.WasmI32 future);

final class _Vtable99
    implements i0.FutureVtable<i0.Result<void, i3.TypesErrorCode>> {
  const _Vtable99();

  @override
  int newFuture() => _futureNew99().toInt();

  @override
  int read(int future, int buffer) {
    return _futureRead99(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  int write(int future, int buffer) {
    return _futureWrite99(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  void dropRead(int future) {
    _futureDropReadable99(i2.WasmI32.fromInt(future));
  }

  @override
  void dropWrite(int future) {
    _futureDropWritable99(i2.WasmI32.fromInt(future));
  }

  @override
  int allocateBuffer() {
    return i0
        .mallocAligned(const i2.WasmI32(1), const i2.WasmI32(2))
        .toIntUnsigned();
  }

  @override
  void freeBuffer(int address, {required bool containsValue}) {
    i0.dartFree(address.toWasmI32(), const i2.WasmI32(2), const i2.WasmI32(1));
  }

  @override
  void store(int address, i0.Result<void, i3.TypesErrorCode> value) {
    final wasmAddress = i2.WasmI32.fromInt(address);

    switch (value) {
      case i0.OkResult(:final value):
        i0.memory.storeInt8(
          wasmAddress.toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 0,
        );

      case i0.ErrorResult(:final value):
        i0.memory.storeInt8(
          wasmAddress.toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 0,
        );
        i0.memory.storeInt8(
          wasmAddress.toIntUnsigned(),
          value.index.toWasmI32(),
          offset: 1,
        );
    }
  }

  @override
  i0.Result<void, i3.TypesErrorCode> load(int address) {
    final wasmAddress = i2.WasmI32.fromInt(address);

    final tmp0 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 0);
    final i0.Result<void, i3.TypesErrorCode> tmp2;
    if (tmp0.toBool()) {
      final tmp1 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 1);

      tmp2 = .error(i3.TypesErrorCode.values[tmp1.toIntUnsigned()]);
    } else {
      tmp2 = .ok(null);
    }

    return tmp2;
  }
}

@pragma("wasm:import", r"component._import28")
external i2.WasmI32 _import28(i2.WasmI32 p0);

final class _Imported$18 implements i3.Stderr {
  const _Imported$18();
  @override
  Future<i0.Result<void, i3.TypesErrorCode>> writeViaStream({
    required Stream<i4.Uint8List> data,
  }) {
    final tmp0 = i0.newReadableStream(const _Vtable90(), data).toWasmI32();
    final tmp1 = _import28(tmp0);
    final tmp2 = i0.readFuture(const _Vtable99(), tmp1.toIntUnsigned());
    return tmp2;
  }
}

final class _Imported$19 implements i3.TerminalInput {
  const _Imported$19();
}

final class _Imported$20 implements i3.TerminalOutput {
  const _Imported$20();
}

@pragma('wasm:import', r'component._drop$102')
external i2.WasmVoid _drop$102Raw(i2.WasmI32 handle);

void _drop$102(int handle) {
  _drop$102Raw(i2.WasmI32.fromInt(handle));
}

@pragma("wasm:import", r"component._import29")
external i2.WasmVoid _import29(i2.WasmI32 p0);

final class _Imported$21 implements i3.TerminalStdin {
  const _Imported$21();
  @override
  i0.Option<i0.Owned<i3.TerminalInputTerminalInput>> getTerminalStdin() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import29(tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Option<i0.Owned<i3.TerminalInputTerminalInput>> tmp4;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i0.Owned<i3.TerminalInputTerminalInput>(
        tmp2.toIntUnsigned(),
        _drop$102,
      );
      tmp4 = .some(tmp3);
    } else {
      tmp4 = .none;
    }

    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp4;
  }
}

@pragma('wasm:import', r'component._drop$105')
external i2.WasmVoid _drop$105Raw(i2.WasmI32 handle);

void _drop$105(int handle) {
  _drop$105Raw(i2.WasmI32.fromInt(handle));
}

@pragma("wasm:import", r"component._import31")
external i2.WasmVoid _import31(i2.WasmI32 p0);

final class _Imported$22 implements i3.TerminalStdout {
  const _Imported$22();
  @override
  i0.Option<i0.Owned<i3.TerminalOutputTerminalOutput>> getTerminalStdout() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import31(tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Option<i0.Owned<i3.TerminalOutputTerminalOutput>> tmp4;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i0.Owned<i3.TerminalOutputTerminalOutput>(
        tmp2.toIntUnsigned(),
        _drop$105,
      );
      tmp4 = .some(tmp3);
    } else {
      tmp4 = .none;
    }

    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp4;
  }
}

@pragma('wasm:import', r'component._drop$108')
external i2.WasmVoid _drop$108Raw(i2.WasmI32 handle);

void _drop$108(int handle) {
  _drop$108Raw(i2.WasmI32.fromInt(handle));
}

@pragma("wasm:import", r"component._import33")
external i2.WasmVoid _import33(i2.WasmI32 p0);

final class _Imported$23 implements i3.TerminalStderr {
  const _Imported$23();
  @override
  i0.Option<i0.Owned<i3.TerminalOutputTerminalOutput>> getTerminalStderr() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import33(tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Option<i0.Owned<i3.TerminalOutputTerminalOutput>> tmp4;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i0.Owned<i3.TerminalOutputTerminalOutput>(
        tmp2.toIntUnsigned(),
        _drop$108,
      );
      tmp4 = .some(tmp3);
    } else {
      tmp4 = .none;
    }

    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp4;
  }
}

final class _Imported$1 implements i5.Types {
  const _Imported$1();
}

@pragma("wasm:import", r"component._import35")
external i2.WasmI64 _import35();
@pragma("wasm:import", r"component._import36")
external i2.WasmI64 _import36();
@pragma("wasm:import", r"component._import37")
external i2.WasmI32 _import37(i2.WasmI64 p0);
@pragma("wasm:import", r"component._import38")
external i2.WasmI32 _import38(i2.WasmI64 p0);

final class _Imported$2 implements i5.MonotonicClock {
  const _Imported$2();
  @override
  int now() {
    final tmp0 = _import35();
    return tmp0.toInt();
  }

  @override
  int getResolution() {
    final tmp0 = _import36();
    return tmp0.toInt();
  }

  @override
  Future<void> waitUntil({required int when}) async {
    await i0.createSubtask(_import37(i2.WasmI64.fromInt(when))).completion;
  }

  @override
  Future<void> waitFor({required int howLong}) async {
    await i0.createSubtask(_import38(i2.WasmI64.fromInt(howLong))).completion;
  }
}

@pragma("wasm:import", r"component._import39")
external i2.WasmVoid _import39(i2.WasmI32 p0);
@pragma("wasm:import", r"component._import40")
external i2.WasmI64 _import40();

final class _Imported$3 implements i5.SystemClock {
  const _Imported$3();
  @override
  ({int seconds, int nanoseconds}) now() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(16));
    _import39(tmp0);
    final tmp1 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 8);
    final tmp3 = (seconds: tmp1.toInt(), nanoseconds: tmp2.toIntUnsigned());
    i0.dartFree(tmp0, const i2.WasmI32(16), const i2.WasmI32(8));
    return tmp3;
  }

  @override
  int getResolution() {
    final tmp0 = _import40();
    return tmp0.toInt();
  }
}

@pragma('wasm:import', 'component.stream26.new')
external i2.WasmI64 _streamNew26();
@pragma('wasm:import', 'component.stream26.read')
external i2.WasmI32 _streamRead26(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream26.write')
external i2.WasmI32 _streamWrite26(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream26.drop-readable')
external i2.WasmVoid _streamDropReadable26(i2.WasmI32 stream);
@pragma('wasm:import', 'component.stream26.drop-writable')
external i2.WasmVoid _streamDropWritable26(i2.WasmI32 stream);

final class _Vtable26 implements i0.StreamVtable<i4.Uint8List> {
  const _Vtable26();

  @override
  int get elementSize => 1;
  @override
  int allocateBuffer(int size) {
    return i0
        .mallocAligned(const i2.WasmI32(1), (size * 1).toWasmI32())
        .toIntUnsigned();
  }

  @override
  void freeBuffer(int address, int totalSize, int start, int end) {
    i0.dartFree(
      address.toWasmI32(),
      (totalSize * 1).toWasmI32(),
      const i2.WasmI32(1),
    );
  }

  @override
  void writeToBuffer(int address, i4.Uint8List elements) {
    for (final (i, element) in elements.indexed) {
      final wasmAddress = i2.WasmI32.fromInt(address + i);

      i0.memory.storeInt8(
        wasmAddress.toIntUnsigned(),
        i2.WasmI32.uint8FromInt(element),
        offset: 0,
      );
    }
  }

  @override
  i4.Uint8List readFromBuffer(int address, int count) {
    final typedList = i4.Uint8List(count);
    for (var i = 0; i < count; i++) {
      final ptr = i2.WasmI32.fromInt(address + i * 1);
      final tmp0 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 0);

      typedList[i] = tmp0.toIntUnsigned();
    }
    return typedList;
  }

  @override
  int newStream() => _streamNew26().toInt();
  @override
  void dropReadable(int stream) {
    _streamDropReadable26(i2.WasmI32.fromInt(stream));
  }

  @override
  void dropWritable(int stream) {
    _streamDropWritable26(i2.WasmI32.fromInt(stream));
  }

  @override
  int read(int stream, int ptr, int n) {
    return _streamRead26(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }

  @override
  int write(int stream, int ptr, int n) {
    return _streamWrite26(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }
}

@pragma('wasm:import', 'component.future28.new')
external i2.WasmI64 _futureNew28();
@pragma('wasm:import', 'component.future28.write')
external i2.WasmI32 _futureWrite28(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future28.read')
external i2.WasmI32 _futureRead28(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future28.drop-readable')
external i2.WasmVoid _futureDropReadable28(i2.WasmI32 future);
@pragma('wasm:import', 'component.future28.drop-writable')
external i2.WasmVoid _futureDropWritable28(i2.WasmI32 future);

final class _Vtable28
    implements i0.FutureVtable<i0.Result<void, i6.TypesErrorCode>> {
  const _Vtable28();

  @override
  int newFuture() => _futureNew28().toInt();

  @override
  int read(int future, int buffer) {
    return _futureRead28(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  int write(int future, int buffer) {
    return _futureWrite28(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  void dropRead(int future) {
    _futureDropReadable28(i2.WasmI32.fromInt(future));
  }

  @override
  void dropWrite(int future) {
    _futureDropWritable28(i2.WasmI32.fromInt(future));
  }

  @override
  int allocateBuffer() {
    return i0
        .mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20))
        .toIntUnsigned();
  }

  @override
  void freeBuffer(int address, {required bool containsValue}) {
    if (containsValue) {
      final ptr = i2.WasmI32.fromInt(address);
      final tmp0 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 0);
      switch (tmp0) {
        case 0:
          break;
        case 1:
          final tmp1 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 4);
          switch (tmp1) {
            case 0:
              break;
            case 1:
              break;
            case 2:
              break;
            case 3:
              break;
            case 4:
              break;
            case 5:
              break;
            case 6:
              break;
            case 7:
              break;
            case 8:
              break;
            case 9:
              break;
            case 10:
              break;
            case 11:
              break;
            case 12:
              break;
            case 13:
              break;
            case 14:
              break;
            case 15:
              break;
            case 16:
              break;
            case 17:
              break;
            case 18:
              break;
            case 19:
              break;
            case 20:
              break;
            case 21:
              break;
            case 22:
              break;
            case 23:
              break;
            case 24:
              break;
            case 25:
              break;
            case 26:
              break;
            case 27:
              break;
            case 28:
              break;
            case 29:
              break;
            case 30:
              break;
            case 31:
              break;
            case 32:
              break;
            case 33:
              break;
            case 34:
              break;
            case 35:
              break;
            case 36:
              final tmp2 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 8);
              switch (tmp2) {
                case 0:
                  break;
                case 1:
                  final tmp3 = i0.memory.loadInt32(
                    ptr.toIntUnsigned(),
                    offset: 12,
                  );
                  final tmp4 = i0.memory.loadInt32(
                    ptr.toIntUnsigned(),
                    offset: 16,
                  );
                  i0.AllocatedString(tmp3, tmp4).free();
                  break;
              }
              break;
          }
          break;
      }
    }
    i0.dartFree(address.toWasmI32(), const i2.WasmI32(20), const i2.WasmI32(4));
  }

  @override
  void store(int address, i0.Result<void, i6.TypesErrorCode> value) {
    final wasmAddress = i2.WasmI32.fromInt(address);

    switch (value) {
      case i0.OkResult(:final value):
        i0.memory.storeInt8(
          wasmAddress.toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 0,
        );

      case i0.ErrorResult(:final value):
        i0.memory.storeInt8(
          wasmAddress.toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 0,
        );
        switch (value) {
          case i6.TypesErrorCodeAccess():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(0),
              offset: 4,
            );

          case i6.TypesErrorCodeAlready():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(1),
              offset: 4,
            );

          case i6.TypesErrorCodeBadDescriptor():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(2),
              offset: 4,
            );

          case i6.TypesErrorCodeBusy():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(3),
              offset: 4,
            );

          case i6.TypesErrorCodeDeadlock():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(4),
              offset: 4,
            );

          case i6.TypesErrorCodeQuota():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(5),
              offset: 4,
            );

          case i6.TypesErrorCodeExist():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(6),
              offset: 4,
            );

          case i6.TypesErrorCodeFileTooLarge():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(7),
              offset: 4,
            );

          case i6.TypesErrorCodeIllegalByteSequence():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(8),
              offset: 4,
            );

          case i6.TypesErrorCodeInProgress():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(9),
              offset: 4,
            );

          case i6.TypesErrorCodeInterrupted():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(10),
              offset: 4,
            );

          case i6.TypesErrorCodeInvalid():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(11),
              offset: 4,
            );

          case i6.TypesErrorCodeIo():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(12),
              offset: 4,
            );

          case i6.TypesErrorCodeIsDirectory():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(13),
              offset: 4,
            );

          case i6.TypesErrorCodeLoop():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(14),
              offset: 4,
            );

          case i6.TypesErrorCodeTooManyLinks():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(15),
              offset: 4,
            );

          case i6.TypesErrorCodeMessageSize():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(16),
              offset: 4,
            );

          case i6.TypesErrorCodeNameTooLong():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(17),
              offset: 4,
            );

          case i6.TypesErrorCodeNoDevice():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(18),
              offset: 4,
            );

          case i6.TypesErrorCodeNoEntry():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(19),
              offset: 4,
            );

          case i6.TypesErrorCodeNoLock():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(20),
              offset: 4,
            );

          case i6.TypesErrorCodeInsufficientMemory():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(21),
              offset: 4,
            );

          case i6.TypesErrorCodeInsufficientSpace():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(22),
              offset: 4,
            );

          case i6.TypesErrorCodeNotDirectory():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(23),
              offset: 4,
            );

          case i6.TypesErrorCodeNotEmpty():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(24),
              offset: 4,
            );

          case i6.TypesErrorCodeNotRecoverable():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(25),
              offset: 4,
            );

          case i6.TypesErrorCodeUnsupported():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(26),
              offset: 4,
            );

          case i6.TypesErrorCodeNoTty():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(27),
              offset: 4,
            );

          case i6.TypesErrorCodeNoSuchDevice():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(28),
              offset: 4,
            );

          case i6.TypesErrorCodeOverflow():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(29),
              offset: 4,
            );

          case i6.TypesErrorCodeNotPermitted():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(30),
              offset: 4,
            );

          case i6.TypesErrorCodePipe():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(31),
              offset: 4,
            );

          case i6.TypesErrorCodeReadOnly():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(32),
              offset: 4,
            );

          case i6.TypesErrorCodeInvalidSeek():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(33),
              offset: 4,
            );

          case i6.TypesErrorCodeTextFileBusy():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(34),
              offset: 4,
            );

          case i6.TypesErrorCodeCrossDevice():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(35),
              offset: 4,
            );

          case i6.TypesErrorCodeOther(payload: final value):
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(36),
              offset: 4,
            );
            final tmp1 = value;
            if (tmp1.hasValue) {
              final value = tmp1.requireValue();
              i0.memory.storeInt8(
                wasmAddress.toIntUnsigned(),
                const i2.WasmI32(1),
                offset: 8,
              );
              final tmp0 = i0.AllocatedString.allocateUtf16(value);
              i0.memory.storeInt32(
                wasmAddress.toIntUnsigned(),
                tmp0.packedLength,
                offset: 16,
              );
              i0.memory.storeInt32(
                wasmAddress.toIntUnsigned(),
                tmp0.ptr,
                offset: 12,
              );
            } else {
              i0.memory.storeInt8(
                wasmAddress.toIntUnsigned(),
                const i2.WasmI32(0),
                offset: 8,
              );
            }
        }
    }
  }

  @override
  i0.Result<void, i6.TypesErrorCode> load(int address) {
    final wasmAddress = i2.WasmI32.fromInt(address);

    final tmp0 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 0);
    final i0.Result<void, i6.TypesErrorCode> tmp7;
    if (tmp0.toBool()) {
      final tmp1 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp6;
      switch (tmp1.toIntUnsigned()) {
        case 0:
          tmp6 = i6.TypesErrorCodeAccess();
        case 1:
          tmp6 = i6.TypesErrorCodeAlready();
        case 2:
          tmp6 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp6 = i6.TypesErrorCodeBusy();
        case 4:
          tmp6 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp6 = i6.TypesErrorCodeQuota();
        case 6:
          tmp6 = i6.TypesErrorCodeExist();
        case 7:
          tmp6 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp6 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp6 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp6 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp6 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp6 = i6.TypesErrorCodeIo();
        case 13:
          tmp6 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp6 = i6.TypesErrorCodeLoop();
        case 15:
          tmp6 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp6 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp6 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp6 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp6 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp6 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp6 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp6 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp6 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp6 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp6 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp6 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp6 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp6 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp6 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp6 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp6 = i6.TypesErrorCodePipe();
        case 32:
          tmp6 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp6 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp6 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp6 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp2 = i0.memory.loadUint8(
            wasmAddress.toIntUnsigned(),
            offset: 8,
          );
          final i0.Option<String> tmp5;
          if (tmp2.toBool()) {
            final tmp3 = i0.memory.loadInt32(
              wasmAddress.toIntUnsigned(),
              offset: 12,
            );
            final tmp4 = i0.memory.loadInt32(
              wasmAddress.toIntUnsigned(),
              offset: 16,
            );

            tmp5 = .some(i0.AllocatedString.read(tmp3, tmp4));
          } else {
            tmp5 = .none;
          }

          tmp6 = i6.TypesErrorCodeOther(tmp5);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp7 = .error(tmp6);
    } else {
      tmp7 = .ok(null);
    }

    return tmp7;
  }
}

@pragma('wasm:import', 'component.stream32.new')
external i2.WasmI64 _streamNew32();
@pragma('wasm:import', 'component.stream32.read')
external i2.WasmI32 _streamRead32(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream32.write')
external i2.WasmI32 _streamWrite32(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream32.drop-readable')
external i2.WasmVoid _streamDropReadable32(i2.WasmI32 stream);
@pragma('wasm:import', 'component.stream32.drop-writable')
external i2.WasmVoid _streamDropWritable32(i2.WasmI32 stream);

final class _Vtable32
    implements
        i0.StreamVtable<List<({i6.TypesDescriptorType type, String name})>> {
  const _Vtable32();

  @override
  int get elementSize => 24;
  @override
  int allocateBuffer(int size) {
    return i0
        .mallocAligned(const i2.WasmI32(4), (size * 24).toWasmI32())
        .toIntUnsigned();
  }

  @override
  void freeBuffer(int address, int totalSize, int start, int end) {
    for (var i = start; i < end; i++) {
      final ptr = i2.WasmI32.fromInt(address + i * 24);
      final tmp0 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 0);
      switch (tmp0) {
        case 0:
          break;
        case 1:
          break;
        case 2:
          break;
        case 3:
          break;
        case 4:
          break;
        case 5:
          break;
        case 6:
          break;
        case 7:
          final tmp1 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 4);
          switch (tmp1) {
            case 0:
              break;
            case 1:
              final tmp2 = i0.memory.loadInt32(ptr.toIntUnsigned(), offset: 8);
              final tmp3 = i0.memory.loadInt32(ptr.toIntUnsigned(), offset: 12);
              i0.AllocatedString(tmp2, tmp3).free();
              break;
          }
          break;
      }
      final tmp4 = i0.memory.loadInt32(ptr.toIntUnsigned(), offset: 16);
      final tmp5 = i0.memory.loadInt32(ptr.toIntUnsigned(), offset: 20);
      i0.AllocatedString(tmp4, tmp5).free();
    }

    i0.dartFree(
      address.toWasmI32(),
      (totalSize * 24).toWasmI32(),
      const i2.WasmI32(4),
    );
  }

  @override
  void writeToBuffer(
    int address,
    List<({i6.TypesDescriptorType type, String name})> elements,
  ) {
    for (final (i, element) in elements.indexed) {
      final wasmAddress = i2.WasmI32.fromInt(address + i);

      switch (element.type) {
        case i6.TypesDescriptorTypeBlockDevice():
          i0.memory.storeInt8(
            wasmAddress.toIntUnsigned(),
            const i2.WasmI32(0),
            offset: 0,
          );

        case i6.TypesDescriptorTypeCharacterDevice():
          i0.memory.storeInt8(
            wasmAddress.toIntUnsigned(),
            const i2.WasmI32(1),
            offset: 0,
          );

        case i6.TypesDescriptorTypeDirectory():
          i0.memory.storeInt8(
            wasmAddress.toIntUnsigned(),
            const i2.WasmI32(2),
            offset: 0,
          );

        case i6.TypesDescriptorTypeFifo():
          i0.memory.storeInt8(
            wasmAddress.toIntUnsigned(),
            const i2.WasmI32(3),
            offset: 0,
          );

        case i6.TypesDescriptorTypeSymbolicLink():
          i0.memory.storeInt8(
            wasmAddress.toIntUnsigned(),
            const i2.WasmI32(4),
            offset: 0,
          );

        case i6.TypesDescriptorTypeRegularFile():
          i0.memory.storeInt8(
            wasmAddress.toIntUnsigned(),
            const i2.WasmI32(5),
            offset: 0,
          );

        case i6.TypesDescriptorTypeSocket():
          i0.memory.storeInt8(
            wasmAddress.toIntUnsigned(),
            const i2.WasmI32(6),
            offset: 0,
          );

        case i6.TypesDescriptorTypeOther(payload: final value):
          i0.memory.storeInt8(
            wasmAddress.toIntUnsigned(),
            const i2.WasmI32(7),
            offset: 0,
          );
          final tmp1 = value;
          if (tmp1.hasValue) {
            final value = tmp1.requireValue();
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(1),
              offset: 4,
            );
            final tmp0 = i0.AllocatedString.allocateUtf16(value);
            i0.memory.storeInt32(
              wasmAddress.toIntUnsigned(),
              tmp0.packedLength,
              offset: 12,
            );
            i0.memory.storeInt32(
              wasmAddress.toIntUnsigned(),
              tmp0.ptr,
              offset: 8,
            );
          } else {
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(0),
              offset: 4,
            );
          }
      }
      final tmp2 = i0.AllocatedString.allocateUtf16(element.name);
      i0.memory.storeInt32(
        wasmAddress.toIntUnsigned(),
        tmp2.packedLength,
        offset: 20,
      );
      i0.memory.storeInt32(wasmAddress.toIntUnsigned(), tmp2.ptr, offset: 16);
    }
  }

  @override
  List<({i6.TypesDescriptorType type, String name})> readFromBuffer(
    int address,
    int count,
  ) {
    return List.generate(count, (i) {
      final ptr = i2.WasmI32.fromInt(address + i * 24);
      final tmp0 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 0);
      final i6.TypesDescriptorType tmp5;
      switch (tmp0.toIntUnsigned()) {
        case 0:
          tmp5 = i6.TypesDescriptorTypeBlockDevice();
        case 1:
          tmp5 = i6.TypesDescriptorTypeCharacterDevice();
        case 2:
          tmp5 = i6.TypesDescriptorTypeDirectory();
        case 3:
          tmp5 = i6.TypesDescriptorTypeFifo();
        case 4:
          tmp5 = i6.TypesDescriptorTypeSymbolicLink();
        case 5:
          tmp5 = i6.TypesDescriptorTypeRegularFile();
        case 6:
          tmp5 = i6.TypesDescriptorTypeSocket();
        case 7:
          final tmp1 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 4);
          final i0.Option<String> tmp4;
          if (tmp1.toBool()) {
            final tmp2 = i0.memory.loadInt32(ptr.toIntUnsigned(), offset: 8);
            final tmp3 = i0.memory.loadInt32(ptr.toIntUnsigned(), offset: 12);

            tmp4 = .some(i0.AllocatedString.read(tmp2, tmp3));
          } else {
            tmp4 = .none;
          }

          tmp5 = i6.TypesDescriptorTypeOther(tmp4);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }
      final tmp6 = i0.memory.loadInt32(ptr.toIntUnsigned(), offset: 16);
      final tmp7 = i0.memory.loadInt32(ptr.toIntUnsigned(), offset: 20);
      final tmp8 = (type: tmp5, name: i0.AllocatedString.read(tmp6, tmp7));

      return tmp8;
    });
  }

  @override
  int newStream() => _streamNew32().toInt();
  @override
  void dropReadable(int stream) {
    _streamDropReadable32(i2.WasmI32.fromInt(stream));
  }

  @override
  void dropWritable(int stream) {
    _streamDropWritable32(i2.WasmI32.fromInt(stream));
  }

  @override
  int read(int stream, int ptr, int n) {
    return _streamRead32(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }

  @override
  int write(int stream, int ptr, int n) {
    return _streamWrite32(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }
}

@pragma("wasm:import", r"component._import56")
external i2.WasmVoid _import56(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import57")
external i2.WasmI32 _import57(i2.WasmI32 p0, i2.WasmI32 p1, i2.WasmI64 p2);
@pragma("wasm:import", r"component._import58")
external i2.WasmI32 _import58(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import59")
external i2.WasmI32 _import59(
  i2.WasmI32 p0,
  i2.WasmI64 p1,
  i2.WasmI64 p2,
  i2.WasmI32 p3,
  i2.WasmI32 p4,
);
@pragma("wasm:import", r"component._import60")
external i2.WasmI32 _import60(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import61")
external i2.WasmI32 _import61(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import62")
external i2.WasmI32 _import62(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import63")
external i2.WasmI32 _import63(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import64")
external i2.WasmI32 _import64(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import65")
external i2.WasmVoid _import65(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import66")
external i2.WasmI32 _import66(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import67")
external i2.WasmI32 _import67(
  i2.WasmI32 p0,
  i2.WasmI32 p1,
  i2.WasmI32 p2,
  i2.WasmI32 p3,
);
@pragma("wasm:import", r"component._import68")
external i2.WasmI32 _import68(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import69")
external i2.WasmI32 _import69(
  i2.WasmI32 p0,
  i2.WasmI32 p1,
  i2.WasmI32 p2,
  i2.WasmI32 p3,
  i2.WasmI32 p4,
);
@pragma("wasm:import", r"component._import70")
external i2.WasmI32 _import70(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import71")
external i2.WasmI32 _import71(i2.WasmI32 p0, i2.WasmI32 p1);

@pragma('wasm:import', r'component._drop$24')
external i2.WasmVoid _drop$24Raw(i2.WasmI32 handle);

void _drop$24(int handle) {
  _drop$24Raw(i2.WasmI32.fromInt(handle));
}

@pragma("wasm:import", r"component._import72")
external i2.WasmI32 _import72(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import74")
external i2.WasmI32 _import74(
  i2.WasmI32 p0,
  i2.WasmI32 p1,
  i2.WasmI32 p2,
  i2.WasmI32 p3,
);
@pragma("wasm:import", r"component._import75")
external i2.WasmI32 _import75(
  i2.WasmI32 p0,
  i2.WasmI32 p1,
  i2.WasmI32 p2,
  i2.WasmI32 p3,
);
@pragma("wasm:import", r"component._import76")
external i2.WasmI32 _import76(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import77")
external i2.WasmI32 _import77(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import78")
external i2.WasmI32 _import78(
  i2.WasmI32 p0,
  i2.WasmI32 p1,
  i2.WasmI32 p2,
  i2.WasmI32 p3,
);
@pragma("wasm:import", r"component._import79")
external i2.WasmI32 _import79(i2.WasmI32 p0, i2.WasmI32 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import80")
external i2.WasmI32 _import80(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import81")
external i2.WasmI32 _import81(
  i2.WasmI32 p0,
  i2.WasmI32 p1,
  i2.WasmI32 p2,
  i2.WasmI32 p3,
  i2.WasmI32 p4,
);

final class _Imported$5 implements i6.Types {
  const _Imported$5();
  @override
  (Stream<i4.Uint8List>, Future<i0.Result<void, i6.TypesErrorCode>>)
  methodDescriptorReadViaStream({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required int offset,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import56(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI64.fromInt(offset),
      tmp0,
    );
    final tmp1 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.ReadableStream(tmp1.toIntUnsigned(), const _Vtable26());
    final tmp3 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
    final tmp4 = i0.readFuture(const _Vtable28(), tmp3.toIntUnsigned());
    final tmp5 = (tmp2, tmp4);
    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp5;
  }

  @override
  Future<i0.Result<void, i6.TypesErrorCode>> methodDescriptorWriteViaStream({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required Stream<i4.Uint8List> data,
    required int offset,
  }) {
    final tmp0 = i0.newReadableStream(const _Vtable26(), data).toWasmI32();
    final tmp1 = _import57(
      i2.WasmI32.fromInt(self.handle),
      tmp0,
      i2.WasmI64.fromInt(offset),
    );
    final tmp2 = i0.readFuture(const _Vtable28(), tmp1.toIntUnsigned());
    return tmp2;
  }

  @override
  Future<i0.Result<void, i6.TypesErrorCode>> methodDescriptorAppendViaStream({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required Stream<i4.Uint8List> data,
  }) {
    final tmp0 = i0.newReadableStream(const _Vtable26(), data).toWasmI32();
    final tmp1 = _import58(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp2 = i0.readFuture(const _Vtable28(), tmp1.toIntUnsigned());
    return tmp2;
  }

  @override
  Future<i0.Result<void, i6.TypesErrorCode>> methodDescriptorAdvise({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required int offset,
    required int length,
    required i6.TypesAdvice advice,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(
          _import59(
            i2.WasmI32.fromInt(self.handle),
            i2.WasmI64.fromInt(offset),
            i2.WasmI64.fromInt(length),
            advice.index.toWasmI32(),
            tmp0,
          ),
        )
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i6.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i6.TypesErrorCodeAccess();
        case 1:
          tmp7 = i6.TypesErrorCodeAlready();
        case 2:
          tmp7 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp7 = i6.TypesErrorCodeBusy();
        case 4:
          tmp7 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp7 = i6.TypesErrorCodeQuota();
        case 6:
          tmp7 = i6.TypesErrorCodeExist();
        case 7:
          tmp7 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp7 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp7 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp7 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp7 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp7 = i6.TypesErrorCodeIo();
        case 13:
          tmp7 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp7 = i6.TypesErrorCodeLoop();
        case 15:
          tmp7 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp7 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp7 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp7 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp7 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp7 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp7 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp7 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp7 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp7 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp7 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp7 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp7 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp7 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp7 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp7 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp7 = i6.TypesErrorCodePipe();
        case 32:
          tmp7 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp7 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp7 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp7 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i6.TypesErrorCodeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp8 = .error(tmp7);
    } else {
      tmp8 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp8;
  }

  @override
  Future<i0.Result<void, i6.TypesErrorCode>> methodDescriptorSyncData({
    required i0.Borrowed<i6.TypesDescriptor> self,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(_import60(i2.WasmI32.fromInt(self.handle), tmp0))
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i6.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i6.TypesErrorCodeAccess();
        case 1:
          tmp7 = i6.TypesErrorCodeAlready();
        case 2:
          tmp7 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp7 = i6.TypesErrorCodeBusy();
        case 4:
          tmp7 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp7 = i6.TypesErrorCodeQuota();
        case 6:
          tmp7 = i6.TypesErrorCodeExist();
        case 7:
          tmp7 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp7 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp7 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp7 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp7 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp7 = i6.TypesErrorCodeIo();
        case 13:
          tmp7 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp7 = i6.TypesErrorCodeLoop();
        case 15:
          tmp7 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp7 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp7 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp7 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp7 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp7 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp7 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp7 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp7 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp7 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp7 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp7 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp7 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp7 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp7 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp7 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp7 = i6.TypesErrorCodePipe();
        case 32:
          tmp7 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp7 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp7 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp7 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i6.TypesErrorCodeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp8 = .error(tmp7);
    } else {
      tmp8 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp8;
  }

  @override
  Future<i0.Result<i6.TypesDescriptorFlags, i6.TypesErrorCode>>
  methodDescriptorGetFlags({
    required i0.Borrowed<i6.TypesDescriptor> self,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(_import61(i2.WasmI32.fromInt(self.handle), tmp0))
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i6.TypesDescriptorFlags, i6.TypesErrorCode> tmp10;
    if (tmp1.toBool()) {
      final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp9;
      switch (tmp4.toIntUnsigned()) {
        case 0:
          tmp9 = i6.TypesErrorCodeAccess();
        case 1:
          tmp9 = i6.TypesErrorCodeAlready();
        case 2:
          tmp9 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp9 = i6.TypesErrorCodeBusy();
        case 4:
          tmp9 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp9 = i6.TypesErrorCodeQuota();
        case 6:
          tmp9 = i6.TypesErrorCodeExist();
        case 7:
          tmp9 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp9 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp9 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp9 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp9 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp9 = i6.TypesErrorCodeIo();
        case 13:
          tmp9 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp9 = i6.TypesErrorCodeLoop();
        case 15:
          tmp9 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp9 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp9 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp9 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp9 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp9 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp9 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp9 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp9 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp9 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp9 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp9 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp9 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp9 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp9 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp9 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp9 = i6.TypesErrorCodePipe();
        case 32:
          tmp9 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp9 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp9 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp9 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp5 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp8;
          if (tmp5.toBool()) {
            final tmp6 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp7 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp8 = .some(i0.AllocatedString.read(tmp6, tmp7));
          } else {
            tmp8 = .none;
          }

          tmp9 = i6.TypesErrorCodeOther(tmp8);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp10 = .error(tmp9);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i6.TypesDescriptorFlags(tmp2.toIntUnsigned());

      tmp10 = .ok(tmp3);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp10;
  }

  @override
  Future<i0.Result<i6.TypesDescriptorType, i6.TypesErrorCode>>
  methodDescriptorGetType({
    required i0.Borrowed<i6.TypesDescriptor> self,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(_import62(i2.WasmI32.fromInt(self.handle), tmp0))
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i6.TypesDescriptorType, i6.TypesErrorCode> tmp14;
    if (tmp1.toBool()) {
      final tmp8 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp13;
      switch (tmp8.toIntUnsigned()) {
        case 0:
          tmp13 = i6.TypesErrorCodeAccess();
        case 1:
          tmp13 = i6.TypesErrorCodeAlready();
        case 2:
          tmp13 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp13 = i6.TypesErrorCodeBusy();
        case 4:
          tmp13 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp13 = i6.TypesErrorCodeQuota();
        case 6:
          tmp13 = i6.TypesErrorCodeExist();
        case 7:
          tmp13 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp13 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp13 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp13 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp13 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp13 = i6.TypesErrorCodeIo();
        case 13:
          tmp13 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp13 = i6.TypesErrorCodeLoop();
        case 15:
          tmp13 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp13 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp13 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp13 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp13 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp13 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp13 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp13 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp13 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp13 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp13 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp13 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp13 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp13 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp13 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp13 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp13 = i6.TypesErrorCodePipe();
        case 32:
          tmp13 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp13 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp13 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp13 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp9 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp12;
          if (tmp9.toBool()) {
            final tmp10 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp11 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp12 = .some(i0.AllocatedString.read(tmp10, tmp11));
          } else {
            tmp12 = .none;
          }

          tmp13 = i6.TypesErrorCodeOther(tmp12);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp14 = .error(tmp13);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i6.TypesDescriptorType tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i6.TypesDescriptorTypeBlockDevice();
        case 1:
          tmp7 = i6.TypesDescriptorTypeCharacterDevice();
        case 2:
          tmp7 = i6.TypesDescriptorTypeDirectory();
        case 3:
          tmp7 = i6.TypesDescriptorTypeFifo();
        case 4:
          tmp7 = i6.TypesDescriptorTypeSymbolicLink();
        case 5:
          tmp7 = i6.TypesDescriptorTypeRegularFile();
        case 6:
          tmp7 = i6.TypesDescriptorTypeSocket();
        case 7:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i6.TypesDescriptorTypeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp14 = .ok(tmp7);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp14;
  }

  @override
  Future<i0.Result<void, i6.TypesErrorCode>> methodDescriptorSetSize({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required int size,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(
          _import63(
            i2.WasmI32.fromInt(self.handle),
            i2.WasmI64.fromInt(size),
            tmp0,
          ),
        )
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i6.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i6.TypesErrorCodeAccess();
        case 1:
          tmp7 = i6.TypesErrorCodeAlready();
        case 2:
          tmp7 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp7 = i6.TypesErrorCodeBusy();
        case 4:
          tmp7 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp7 = i6.TypesErrorCodeQuota();
        case 6:
          tmp7 = i6.TypesErrorCodeExist();
        case 7:
          tmp7 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp7 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp7 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp7 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp7 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp7 = i6.TypesErrorCodeIo();
        case 13:
          tmp7 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp7 = i6.TypesErrorCodeLoop();
        case 15:
          tmp7 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp7 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp7 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp7 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp7 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp7 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp7 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp7 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp7 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp7 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp7 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp7 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp7 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp7 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp7 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp7 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp7 = i6.TypesErrorCodePipe();
        case 32:
          tmp7 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp7 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp7 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp7 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i6.TypesErrorCodeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp8 = .error(tmp7);
    } else {
      tmp8 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp8;
  }

  @override
  Future<i0.Result<void, i6.TypesErrorCode>> methodDescriptorSetTimes({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required i6.TypesNewTimestamp dataAccessTimestamp,
    required i6.TypesNewTimestamp dataModificationTimestamp,
  }) async {
    final tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(56));
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      i2.WasmI32.fromInt(self.handle),
      offset: 0,
    );
    switch (dataAccessTimestamp) {
      case i6.TypesNewTimestampNoChange():
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(8)).toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 0,
        );

      case i6.TypesNewTimestampNow():
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(8)).toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 0,
        );

      case i6.TypesNewTimestampTimestamp(payload: final value):
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(8)).toIntUnsigned(),
          const i2.WasmI32(2),
          offset: 0,
        );
        i0.memory.storeInt64(
          (tmp0 + const i2.WasmI32(8)).toIntUnsigned(),
          i2.WasmI64.fromInt(value.seconds),
          offset: 8,
        );
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(8)).toIntUnsigned(),
          i2.WasmI32.fromInt(value.nanoseconds),
          offset: 16,
        );
    }
    switch (dataModificationTimestamp) {
      case i6.TypesNewTimestampNoChange():
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(32)).toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 0,
        );

      case i6.TypesNewTimestampNow():
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(32)).toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 0,
        );

      case i6.TypesNewTimestampTimestamp(payload: final value):
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(32)).toIntUnsigned(),
          const i2.WasmI32(2),
          offset: 0,
        );
        i0.memory.storeInt64(
          (tmp0 + const i2.WasmI32(32)).toIntUnsigned(),
          i2.WasmI64.fromInt(value.seconds),
          offset: 8,
        );
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(32)).toIntUnsigned(),
          i2.WasmI32.fromInt(value.nanoseconds),
          offset: 16,
        );
    }
    var tmp1 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0.createSubtask(_import64(tmp0, tmp1)).completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<void, i6.TypesErrorCode> tmp9;
    if (tmp2.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i6.TypesErrorCodeAccess();
        case 1:
          tmp8 = i6.TypesErrorCodeAlready();
        case 2:
          tmp8 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp8 = i6.TypesErrorCodeBusy();
        case 4:
          tmp8 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp8 = i6.TypesErrorCodeQuota();
        case 6:
          tmp8 = i6.TypesErrorCodeExist();
        case 7:
          tmp8 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp8 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp8 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp8 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp8 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp8 = i6.TypesErrorCodeIo();
        case 13:
          tmp8 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp8 = i6.TypesErrorCodeLoop();
        case 15:
          tmp8 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp8 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp8 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp8 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp8 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp8 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp8 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp8 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp8 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp8 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp8 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp8 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp8 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp8 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp8 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp8 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp8 = i6.TypesErrorCodePipe();
        case 32:
          tmp8 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp8 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp8 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp8 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp4 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp7;
          if (tmp4.toBool()) {
            final tmp5 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 12);
            final tmp6 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 16);

            tmp7 = .some(i0.AllocatedString.read(tmp5, tmp6));
          } else {
            tmp7 = .none;
          }

          tmp8 = i6.TypesErrorCodeOther(tmp7);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp9 = .error(tmp8);
    } else {
      tmp9 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(56), const i2.WasmI32(8));
    i0.dartFree(tmp1, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp9;
  }

  @override
  (
    Stream<List<({i6.TypesDescriptorType type, String name})>>,
    Future<i0.Result<void, i6.TypesErrorCode>>,
  )
  methodDescriptorReadDirectory({
    required i0.Borrowed<i6.TypesDescriptor> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import65(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.ReadableStream(tmp1.toIntUnsigned(), const _Vtable32());
    final tmp3 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
    final tmp4 = i0.readFuture(const _Vtable28(), tmp3.toIntUnsigned());
    final tmp5 = (tmp2, tmp4);
    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp5;
  }

  @override
  Future<i0.Result<void, i6.TypesErrorCode>> methodDescriptorSync({
    required i0.Borrowed<i6.TypesDescriptor> self,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(_import66(i2.WasmI32.fromInt(self.handle), tmp0))
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i6.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i6.TypesErrorCodeAccess();
        case 1:
          tmp7 = i6.TypesErrorCodeAlready();
        case 2:
          tmp7 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp7 = i6.TypesErrorCodeBusy();
        case 4:
          tmp7 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp7 = i6.TypesErrorCodeQuota();
        case 6:
          tmp7 = i6.TypesErrorCodeExist();
        case 7:
          tmp7 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp7 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp7 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp7 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp7 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp7 = i6.TypesErrorCodeIo();
        case 13:
          tmp7 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp7 = i6.TypesErrorCodeLoop();
        case 15:
          tmp7 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp7 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp7 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp7 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp7 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp7 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp7 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp7 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp7 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp7 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp7 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp7 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp7 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp7 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp7 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp7 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp7 = i6.TypesErrorCodePipe();
        case 32:
          tmp7 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp7 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp7 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp7 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i6.TypesErrorCodeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp8 = .error(tmp7);
    } else {
      tmp8 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp8;
  }

  @override
  Future<i0.Result<void, i6.TypesErrorCode>> methodDescriptorCreateDirectoryAt({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required String path,
  }) async {
    final tmp0 = i0.AllocatedString.allocateUtf16(path);
    var tmp1 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(
          _import67(
            i2.WasmI32.fromInt(self.handle),
            tmp0.ptr,
            tmp0.packedLength,
            tmp1,
          ),
        )
        .completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<void, i6.TypesErrorCode> tmp9;
    if (tmp2.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i6.TypesErrorCodeAccess();
        case 1:
          tmp8 = i6.TypesErrorCodeAlready();
        case 2:
          tmp8 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp8 = i6.TypesErrorCodeBusy();
        case 4:
          tmp8 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp8 = i6.TypesErrorCodeQuota();
        case 6:
          tmp8 = i6.TypesErrorCodeExist();
        case 7:
          tmp8 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp8 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp8 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp8 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp8 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp8 = i6.TypesErrorCodeIo();
        case 13:
          tmp8 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp8 = i6.TypesErrorCodeLoop();
        case 15:
          tmp8 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp8 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp8 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp8 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp8 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp8 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp8 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp8 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp8 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp8 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp8 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp8 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp8 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp8 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp8 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp8 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp8 = i6.TypesErrorCodePipe();
        case 32:
          tmp8 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp8 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp8 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp8 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp4 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp7;
          if (tmp4.toBool()) {
            final tmp5 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 12);
            final tmp6 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 16);

            tmp7 = .some(i0.AllocatedString.read(tmp5, tmp6));
          } else {
            tmp7 = .none;
          }

          tmp8 = i6.TypesErrorCodeOther(tmp7);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp9 = .error(tmp8);
    } else {
      tmp9 = .ok(null);
    }

    i0.dartFree(tmp1, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp9;
  }

  @override
  Future<
    i0.Result<
      ({
        i6.TypesDescriptorType type,
        int linkCount,
        int size,
        i0.Option<({int seconds, int nanoseconds})> dataAccessTimestamp,
        i0.Option<({int seconds, int nanoseconds})> dataModificationTimestamp,
        i0.Option<({int seconds, int nanoseconds})> statusChangeTimestamp,
      }),
      i6.TypesErrorCode
    >
  >
  methodDescriptorStat({required i0.Borrowed<i6.TypesDescriptor> self}) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(112));
    await i0
        .createSubtask(_import68(i2.WasmI32.fromInt(self.handle), tmp0))
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<
      ({
        i6.TypesDescriptorType type,
        int linkCount,
        int size,
        i0.Option<({int seconds, int nanoseconds})> dataAccessTimestamp,
        i0.Option<({int seconds, int nanoseconds})> dataModificationTimestamp,
        i0.Option<({int seconds, int nanoseconds})> statusChangeTimestamp,
      }),
      i6.TypesErrorCode
    >
    tmp32;
    if (tmp1.toBool()) {
      final tmp26 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i6.TypesErrorCode tmp31;
      switch (tmp26.toIntUnsigned()) {
        case 0:
          tmp31 = i6.TypesErrorCodeAccess();
        case 1:
          tmp31 = i6.TypesErrorCodeAlready();
        case 2:
          tmp31 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp31 = i6.TypesErrorCodeBusy();
        case 4:
          tmp31 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp31 = i6.TypesErrorCodeQuota();
        case 6:
          tmp31 = i6.TypesErrorCodeExist();
        case 7:
          tmp31 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp31 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp31 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp31 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp31 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp31 = i6.TypesErrorCodeIo();
        case 13:
          tmp31 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp31 = i6.TypesErrorCodeLoop();
        case 15:
          tmp31 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp31 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp31 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp31 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp31 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp31 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp31 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp31 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp31 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp31 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp31 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp31 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp31 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp31 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp31 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp31 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp31 = i6.TypesErrorCodePipe();
        case 32:
          tmp31 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp31 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp31 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp31 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp27 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 12);
          final i0.Option<String> tmp30;
          if (tmp27.toBool()) {
            final tmp28 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);
            final tmp29 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 20);

            tmp30 = .some(i0.AllocatedString.read(tmp28, tmp29));
          } else {
            tmp30 = .none;
          }

          tmp31 = i6.TypesErrorCodeOther(tmp30);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp32 = .error(tmp31);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i6.TypesDescriptorType tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i6.TypesDescriptorTypeBlockDevice();
        case 1:
          tmp7 = i6.TypesDescriptorTypeCharacterDevice();
        case 2:
          tmp7 = i6.TypesDescriptorTypeDirectory();
        case 3:
          tmp7 = i6.TypesDescriptorTypeFifo();
        case 4:
          tmp7 = i6.TypesDescriptorTypeSymbolicLink();
        case 5:
          tmp7 = i6.TypesDescriptorTypeRegularFile();
        case 6:
          tmp7 = i6.TypesDescriptorTypeSocket();
        case 7:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 12);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 20);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i6.TypesDescriptorTypeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }
      final tmp8 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 24);
      final tmp9 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 32);
      final tmp10 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 40);
      final i0.Option<({int seconds, int nanoseconds})> tmp14;
      if (tmp10.toBool()) {
        final tmp11 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 48);
        final tmp12 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 56);
        final tmp13 = (
          seconds: tmp11.toInt(),
          nanoseconds: tmp12.toIntUnsigned(),
        );

        tmp14 = .some(tmp13);
      } else {
        tmp14 = .none;
      }

      final tmp15 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 64);
      final i0.Option<({int seconds, int nanoseconds})> tmp19;
      if (tmp15.toBool()) {
        final tmp16 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 72);
        final tmp17 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 80);
        final tmp18 = (
          seconds: tmp16.toInt(),
          nanoseconds: tmp17.toIntUnsigned(),
        );

        tmp19 = .some(tmp18);
      } else {
        tmp19 = .none;
      }

      final tmp20 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 88);
      final i0.Option<({int seconds, int nanoseconds})> tmp24;
      if (tmp20.toBool()) {
        final tmp21 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 96);
        final tmp22 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 104);
        final tmp23 = (
          seconds: tmp21.toInt(),
          nanoseconds: tmp22.toIntUnsigned(),
        );

        tmp24 = .some(tmp23);
      } else {
        tmp24 = .none;
      }

      final tmp25 = (
        type: tmp7,
        linkCount: tmp8.toInt(),
        size: tmp9.toInt(),
        dataAccessTimestamp: tmp14,
        dataModificationTimestamp: tmp19,
        statusChangeTimestamp: tmp24,
      );

      tmp32 = .ok(tmp25);
    }

    i0.dartFree(tmp0, const i2.WasmI32(112), const i2.WasmI32(8));
    return tmp32;
  }

  @override
  Future<
    i0.Result<
      ({
        i6.TypesDescriptorType type,
        int linkCount,
        int size,
        i0.Option<({int seconds, int nanoseconds})> dataAccessTimestamp,
        i0.Option<({int seconds, int nanoseconds})> dataModificationTimestamp,
        i0.Option<({int seconds, int nanoseconds})> statusChangeTimestamp,
      }),
      i6.TypesErrorCode
    >
  >
  methodDescriptorStatAt({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required i6.TypesPathFlags pathFlags,
    required String path,
  }) async {
    final tmp0 = i0.AllocatedString.allocateUtf16(path);
    var tmp1 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(112));
    await i0
        .createSubtask(
          _import69(
            i2.WasmI32.fromInt(self.handle),
            pathFlags.toWasmI32(),
            tmp0.ptr,
            tmp0.packedLength,
            tmp1,
          ),
        )
        .completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<
      ({
        i6.TypesDescriptorType type,
        int linkCount,
        int size,
        i0.Option<({int seconds, int nanoseconds})> dataAccessTimestamp,
        i0.Option<({int seconds, int nanoseconds})> dataModificationTimestamp,
        i0.Option<({int seconds, int nanoseconds})> statusChangeTimestamp,
      }),
      i6.TypesErrorCode
    >
    tmp33;
    if (tmp2.toBool()) {
      final tmp27 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 8);
      final i6.TypesErrorCode tmp32;
      switch (tmp27.toIntUnsigned()) {
        case 0:
          tmp32 = i6.TypesErrorCodeAccess();
        case 1:
          tmp32 = i6.TypesErrorCodeAlready();
        case 2:
          tmp32 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp32 = i6.TypesErrorCodeBusy();
        case 4:
          tmp32 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp32 = i6.TypesErrorCodeQuota();
        case 6:
          tmp32 = i6.TypesErrorCodeExist();
        case 7:
          tmp32 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp32 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp32 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp32 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp32 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp32 = i6.TypesErrorCodeIo();
        case 13:
          tmp32 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp32 = i6.TypesErrorCodeLoop();
        case 15:
          tmp32 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp32 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp32 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp32 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp32 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp32 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp32 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp32 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp32 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp32 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp32 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp32 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp32 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp32 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp32 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp32 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp32 = i6.TypesErrorCodePipe();
        case 32:
          tmp32 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp32 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp32 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp32 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp28 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 12);
          final i0.Option<String> tmp31;
          if (tmp28.toBool()) {
            final tmp29 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 16);
            final tmp30 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 20);

            tmp31 = .some(i0.AllocatedString.read(tmp29, tmp30));
          } else {
            tmp31 = .none;
          }

          tmp32 = i6.TypesErrorCodeOther(tmp31);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp33 = .error(tmp32);
    } else {
      final tmp3 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 8);
      final i6.TypesDescriptorType tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i6.TypesDescriptorTypeBlockDevice();
        case 1:
          tmp8 = i6.TypesDescriptorTypeCharacterDevice();
        case 2:
          tmp8 = i6.TypesDescriptorTypeDirectory();
        case 3:
          tmp8 = i6.TypesDescriptorTypeFifo();
        case 4:
          tmp8 = i6.TypesDescriptorTypeSymbolicLink();
        case 5:
          tmp8 = i6.TypesDescriptorTypeRegularFile();
        case 6:
          tmp8 = i6.TypesDescriptorTypeSocket();
        case 7:
          final tmp4 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 12);
          final i0.Option<String> tmp7;
          if (tmp4.toBool()) {
            final tmp5 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 16);
            final tmp6 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 20);

            tmp7 = .some(i0.AllocatedString.read(tmp5, tmp6));
          } else {
            tmp7 = .none;
          }

          tmp8 = i6.TypesDescriptorTypeOther(tmp7);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }
      final tmp9 = i0.memory.loadInt64(tmp1.toIntUnsigned(), offset: 24);
      final tmp10 = i0.memory.loadInt64(tmp1.toIntUnsigned(), offset: 32);
      final tmp11 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 40);
      final i0.Option<({int seconds, int nanoseconds})> tmp15;
      if (tmp11.toBool()) {
        final tmp12 = i0.memory.loadInt64(tmp1.toIntUnsigned(), offset: 48);
        final tmp13 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 56);
        final tmp14 = (
          seconds: tmp12.toInt(),
          nanoseconds: tmp13.toIntUnsigned(),
        );

        tmp15 = .some(tmp14);
      } else {
        tmp15 = .none;
      }

      final tmp16 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 64);
      final i0.Option<({int seconds, int nanoseconds})> tmp20;
      if (tmp16.toBool()) {
        final tmp17 = i0.memory.loadInt64(tmp1.toIntUnsigned(), offset: 72);
        final tmp18 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 80);
        final tmp19 = (
          seconds: tmp17.toInt(),
          nanoseconds: tmp18.toIntUnsigned(),
        );

        tmp20 = .some(tmp19);
      } else {
        tmp20 = .none;
      }

      final tmp21 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 88);
      final i0.Option<({int seconds, int nanoseconds})> tmp25;
      if (tmp21.toBool()) {
        final tmp22 = i0.memory.loadInt64(tmp1.toIntUnsigned(), offset: 96);
        final tmp23 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 104);
        final tmp24 = (
          seconds: tmp22.toInt(),
          nanoseconds: tmp23.toIntUnsigned(),
        );

        tmp25 = .some(tmp24);
      } else {
        tmp25 = .none;
      }

      final tmp26 = (
        type: tmp8,
        linkCount: tmp9.toInt(),
        size: tmp10.toInt(),
        dataAccessTimestamp: tmp15,
        dataModificationTimestamp: tmp20,
        statusChangeTimestamp: tmp25,
      );

      tmp33 = .ok(tmp26);
    }

    i0.dartFree(tmp1, const i2.WasmI32(112), const i2.WasmI32(8));
    return tmp33;
  }

  @override
  Future<i0.Result<void, i6.TypesErrorCode>> methodDescriptorSetTimesAt({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required i6.TypesPathFlags pathFlags,
    required String path,
    required i6.TypesNewTimestamp dataAccessTimestamp,
    required i6.TypesNewTimestamp dataModificationTimestamp,
  }) async {
    final tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(64));
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      i2.WasmI32.fromInt(self.handle),
      offset: 0,
    );
    i0.memory.storeInt8(
      (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
      pathFlags.toWasmI32(),
      offset: 0,
    );
    final tmp1 = i0.AllocatedString.allocateUtf16(path);
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(8)).toIntUnsigned(),
      tmp1.packedLength,
      offset: 4,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(8)).toIntUnsigned(),
      tmp1.ptr,
      offset: 0,
    );
    switch (dataAccessTimestamp) {
      case i6.TypesNewTimestampNoChange():
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(16)).toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 0,
        );

      case i6.TypesNewTimestampNow():
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(16)).toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 0,
        );

      case i6.TypesNewTimestampTimestamp(payload: final value):
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(16)).toIntUnsigned(),
          const i2.WasmI32(2),
          offset: 0,
        );
        i0.memory.storeInt64(
          (tmp0 + const i2.WasmI32(16)).toIntUnsigned(),
          i2.WasmI64.fromInt(value.seconds),
          offset: 8,
        );
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(16)).toIntUnsigned(),
          i2.WasmI32.fromInt(value.nanoseconds),
          offset: 16,
        );
    }
    switch (dataModificationTimestamp) {
      case i6.TypesNewTimestampNoChange():
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(40)).toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 0,
        );

      case i6.TypesNewTimestampNow():
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(40)).toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 0,
        );

      case i6.TypesNewTimestampTimestamp(payload: final value):
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(40)).toIntUnsigned(),
          const i2.WasmI32(2),
          offset: 0,
        );
        i0.memory.storeInt64(
          (tmp0 + const i2.WasmI32(40)).toIntUnsigned(),
          i2.WasmI64.fromInt(value.seconds),
          offset: 8,
        );
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(40)).toIntUnsigned(),
          i2.WasmI32.fromInt(value.nanoseconds),
          offset: 16,
        );
    }
    var tmp2 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0.createSubtask(_import70(tmp0, tmp2)).completion;
    final tmp3 = i0.memory.loadUint8(tmp2.toIntUnsigned(), offset: 0);
    final i0.Result<void, i6.TypesErrorCode> tmp10;
    if (tmp3.toBool()) {
      final tmp4 = i0.memory.loadUint8(tmp2.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp9;
      switch (tmp4.toIntUnsigned()) {
        case 0:
          tmp9 = i6.TypesErrorCodeAccess();
        case 1:
          tmp9 = i6.TypesErrorCodeAlready();
        case 2:
          tmp9 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp9 = i6.TypesErrorCodeBusy();
        case 4:
          tmp9 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp9 = i6.TypesErrorCodeQuota();
        case 6:
          tmp9 = i6.TypesErrorCodeExist();
        case 7:
          tmp9 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp9 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp9 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp9 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp9 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp9 = i6.TypesErrorCodeIo();
        case 13:
          tmp9 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp9 = i6.TypesErrorCodeLoop();
        case 15:
          tmp9 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp9 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp9 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp9 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp9 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp9 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp9 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp9 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp9 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp9 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp9 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp9 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp9 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp9 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp9 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp9 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp9 = i6.TypesErrorCodePipe();
        case 32:
          tmp9 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp9 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp9 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp9 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp5 = i0.memory.loadUint8(tmp2.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp8;
          if (tmp5.toBool()) {
            final tmp6 = i0.memory.loadInt32(tmp2.toIntUnsigned(), offset: 12);
            final tmp7 = i0.memory.loadInt32(tmp2.toIntUnsigned(), offset: 16);

            tmp8 = .some(i0.AllocatedString.read(tmp6, tmp7));
          } else {
            tmp8 = .none;
          }

          tmp9 = i6.TypesErrorCodeOther(tmp8);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp10 = .error(tmp9);
    } else {
      tmp10 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(64), const i2.WasmI32(8));
    i0.dartFree(tmp2, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp10;
  }

  @override
  Future<i0.Result<void, i6.TypesErrorCode>> methodDescriptorLinkAt({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required i6.TypesPathFlags oldPathFlags,
    required String oldPath,
    required i0.Borrowed<i6.TypesDescriptor> newDescriptor,
    required String newPath,
  }) async {
    final tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(28));
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      i2.WasmI32.fromInt(self.handle),
      offset: 0,
    );
    i0.memory.storeInt8(
      (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
      oldPathFlags.toWasmI32(),
      offset: 0,
    );
    final tmp1 = i0.AllocatedString.allocateUtf16(oldPath);
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(8)).toIntUnsigned(),
      tmp1.packedLength,
      offset: 4,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(8)).toIntUnsigned(),
      tmp1.ptr,
      offset: 0,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(16)).toIntUnsigned(),
      i2.WasmI32.fromInt(newDescriptor.handle),
      offset: 0,
    );
    final tmp2 = i0.AllocatedString.allocateUtf16(newPath);
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(20)).toIntUnsigned(),
      tmp2.packedLength,
      offset: 4,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(20)).toIntUnsigned(),
      tmp2.ptr,
      offset: 0,
    );
    var tmp3 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0.createSubtask(_import71(tmp0, tmp3)).completion;
    final tmp4 = i0.memory.loadUint8(tmp3.toIntUnsigned(), offset: 0);
    final i0.Result<void, i6.TypesErrorCode> tmp11;
    if (tmp4.toBool()) {
      final tmp5 = i0.memory.loadUint8(tmp3.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp10;
      switch (tmp5.toIntUnsigned()) {
        case 0:
          tmp10 = i6.TypesErrorCodeAccess();
        case 1:
          tmp10 = i6.TypesErrorCodeAlready();
        case 2:
          tmp10 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp10 = i6.TypesErrorCodeBusy();
        case 4:
          tmp10 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp10 = i6.TypesErrorCodeQuota();
        case 6:
          tmp10 = i6.TypesErrorCodeExist();
        case 7:
          tmp10 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp10 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp10 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp10 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp10 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp10 = i6.TypesErrorCodeIo();
        case 13:
          tmp10 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp10 = i6.TypesErrorCodeLoop();
        case 15:
          tmp10 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp10 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp10 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp10 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp10 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp10 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp10 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp10 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp10 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp10 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp10 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp10 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp10 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp10 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp10 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp10 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp10 = i6.TypesErrorCodePipe();
        case 32:
          tmp10 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp10 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp10 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp10 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp6 = i0.memory.loadUint8(tmp3.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp9;
          if (tmp6.toBool()) {
            final tmp7 = i0.memory.loadInt32(tmp3.toIntUnsigned(), offset: 12);
            final tmp8 = i0.memory.loadInt32(tmp3.toIntUnsigned(), offset: 16);

            tmp9 = .some(i0.AllocatedString.read(tmp7, tmp8));
          } else {
            tmp9 = .none;
          }

          tmp10 = i6.TypesErrorCodeOther(tmp9);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp11 = .error(tmp10);
    } else {
      tmp11 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(28), const i2.WasmI32(4));
    i0.dartFree(tmp3, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp11;
  }

  @override
  Future<i0.Result<i0.Owned<i6.TypesDescriptor>, i6.TypesErrorCode>>
  methodDescriptorOpenAt({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required i6.TypesPathFlags pathFlags,
    required String path,
    required i6.TypesOpenFlags openFlags,
    required i6.TypesDescriptorFlags flags,
  }) async {
    final tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      i2.WasmI32.fromInt(self.handle),
      offset: 0,
    );
    i0.memory.storeInt8(
      (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
      pathFlags.toWasmI32(),
      offset: 0,
    );
    final tmp1 = i0.AllocatedString.allocateUtf16(path);
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(8)).toIntUnsigned(),
      tmp1.packedLength,
      offset: 4,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(8)).toIntUnsigned(),
      tmp1.ptr,
      offset: 0,
    );
    i0.memory.storeInt8(
      (tmp0 + const i2.WasmI32(16)).toIntUnsigned(),
      openFlags.toWasmI32(),
      offset: 0,
    );
    i0.memory.storeInt8(
      (tmp0 + const i2.WasmI32(17)).toIntUnsigned(),
      flags.toWasmI32(),
      offset: 0,
    );
    var tmp2 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0.createSubtask(_import72(tmp0, tmp2)).completion;
    final tmp3 = i0.memory.loadUint8(tmp2.toIntUnsigned(), offset: 0);
    final i0.Result<i0.Owned<i6.TypesDescriptor>, i6.TypesErrorCode> tmp12;
    if (tmp3.toBool()) {
      final tmp6 = i0.memory.loadUint8(tmp2.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp11;
      switch (tmp6.toIntUnsigned()) {
        case 0:
          tmp11 = i6.TypesErrorCodeAccess();
        case 1:
          tmp11 = i6.TypesErrorCodeAlready();
        case 2:
          tmp11 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp11 = i6.TypesErrorCodeBusy();
        case 4:
          tmp11 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp11 = i6.TypesErrorCodeQuota();
        case 6:
          tmp11 = i6.TypesErrorCodeExist();
        case 7:
          tmp11 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp11 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp11 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp11 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp11 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp11 = i6.TypesErrorCodeIo();
        case 13:
          tmp11 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp11 = i6.TypesErrorCodeLoop();
        case 15:
          tmp11 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp11 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp11 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp11 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp11 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp11 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp11 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp11 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp11 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp11 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp11 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp11 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp11 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp11 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp11 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp11 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp11 = i6.TypesErrorCodePipe();
        case 32:
          tmp11 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp11 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp11 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp11 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp7 = i0.memory.loadUint8(tmp2.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp10;
          if (tmp7.toBool()) {
            final tmp8 = i0.memory.loadInt32(tmp2.toIntUnsigned(), offset: 12);
            final tmp9 = i0.memory.loadInt32(tmp2.toIntUnsigned(), offset: 16);

            tmp10 = .some(i0.AllocatedString.read(tmp8, tmp9));
          } else {
            tmp10 = .none;
          }

          tmp11 = i6.TypesErrorCodeOther(tmp10);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp12 = .error(tmp11);
    } else {
      final tmp4 = i0.memory.loadInt32(tmp2.toIntUnsigned(), offset: 4);
      final tmp5 = i0.Owned<i6.TypesDescriptor>(tmp4.toIntUnsigned(), _drop$24);
      tmp12 = .ok(tmp5);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    i0.dartFree(tmp2, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp12;
  }

  @override
  Future<i0.Result<String, i6.TypesErrorCode>> methodDescriptorReadlinkAt({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required String path,
  }) async {
    final tmp0 = i0.AllocatedString.allocateUtf16(path);
    var tmp1 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(
          _import74(
            i2.WasmI32.fromInt(self.handle),
            tmp0.ptr,
            tmp0.packedLength,
            tmp1,
          ),
        )
        .completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<String, i6.TypesErrorCode> tmp11;
    if (tmp2.toBool()) {
      final tmp5 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp10;
      switch (tmp5.toIntUnsigned()) {
        case 0:
          tmp10 = i6.TypesErrorCodeAccess();
        case 1:
          tmp10 = i6.TypesErrorCodeAlready();
        case 2:
          tmp10 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp10 = i6.TypesErrorCodeBusy();
        case 4:
          tmp10 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp10 = i6.TypesErrorCodeQuota();
        case 6:
          tmp10 = i6.TypesErrorCodeExist();
        case 7:
          tmp10 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp10 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp10 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp10 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp10 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp10 = i6.TypesErrorCodeIo();
        case 13:
          tmp10 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp10 = i6.TypesErrorCodeLoop();
        case 15:
          tmp10 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp10 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp10 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp10 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp10 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp10 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp10 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp10 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp10 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp10 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp10 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp10 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp10 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp10 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp10 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp10 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp10 = i6.TypesErrorCodePipe();
        case 32:
          tmp10 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp10 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp10 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp10 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp6 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp9;
          if (tmp6.toBool()) {
            final tmp7 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 12);
            final tmp8 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 16);

            tmp9 = .some(i0.AllocatedString.read(tmp7, tmp8));
          } else {
            tmp9 = .none;
          }

          tmp10 = i6.TypesErrorCodeOther(tmp9);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp11 = .error(tmp10);
    } else {
      final tmp3 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 4);
      final tmp4 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 8);

      tmp11 = .ok(i0.AllocatedString.read(tmp3, tmp4));
    }

    i0.dartFree(tmp1, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp11;
  }

  @override
  Future<i0.Result<void, i6.TypesErrorCode>> methodDescriptorRemoveDirectoryAt({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required String path,
  }) async {
    final tmp0 = i0.AllocatedString.allocateUtf16(path);
    var tmp1 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(
          _import75(
            i2.WasmI32.fromInt(self.handle),
            tmp0.ptr,
            tmp0.packedLength,
            tmp1,
          ),
        )
        .completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<void, i6.TypesErrorCode> tmp9;
    if (tmp2.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i6.TypesErrorCodeAccess();
        case 1:
          tmp8 = i6.TypesErrorCodeAlready();
        case 2:
          tmp8 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp8 = i6.TypesErrorCodeBusy();
        case 4:
          tmp8 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp8 = i6.TypesErrorCodeQuota();
        case 6:
          tmp8 = i6.TypesErrorCodeExist();
        case 7:
          tmp8 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp8 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp8 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp8 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp8 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp8 = i6.TypesErrorCodeIo();
        case 13:
          tmp8 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp8 = i6.TypesErrorCodeLoop();
        case 15:
          tmp8 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp8 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp8 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp8 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp8 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp8 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp8 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp8 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp8 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp8 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp8 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp8 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp8 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp8 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp8 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp8 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp8 = i6.TypesErrorCodePipe();
        case 32:
          tmp8 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp8 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp8 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp8 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp4 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp7;
          if (tmp4.toBool()) {
            final tmp5 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 12);
            final tmp6 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 16);

            tmp7 = .some(i0.AllocatedString.read(tmp5, tmp6));
          } else {
            tmp7 = .none;
          }

          tmp8 = i6.TypesErrorCodeOther(tmp7);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp9 = .error(tmp8);
    } else {
      tmp9 = .ok(null);
    }

    i0.dartFree(tmp1, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp9;
  }

  @override
  Future<i0.Result<void, i6.TypesErrorCode>> methodDescriptorRenameAt({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required String oldPath,
    required i0.Borrowed<i6.TypesDescriptor> newDescriptor,
    required String newPath,
  }) async {
    final tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(24));
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      i2.WasmI32.fromInt(self.handle),
      offset: 0,
    );
    final tmp1 = i0.AllocatedString.allocateUtf16(oldPath);
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
      tmp1.packedLength,
      offset: 4,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
      tmp1.ptr,
      offset: 0,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
      i2.WasmI32.fromInt(newDescriptor.handle),
      offset: 0,
    );
    final tmp2 = i0.AllocatedString.allocateUtf16(newPath);
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(16)).toIntUnsigned(),
      tmp2.packedLength,
      offset: 4,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(16)).toIntUnsigned(),
      tmp2.ptr,
      offset: 0,
    );
    var tmp3 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0.createSubtask(_import76(tmp0, tmp3)).completion;
    final tmp4 = i0.memory.loadUint8(tmp3.toIntUnsigned(), offset: 0);
    final i0.Result<void, i6.TypesErrorCode> tmp11;
    if (tmp4.toBool()) {
      final tmp5 = i0.memory.loadUint8(tmp3.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp10;
      switch (tmp5.toIntUnsigned()) {
        case 0:
          tmp10 = i6.TypesErrorCodeAccess();
        case 1:
          tmp10 = i6.TypesErrorCodeAlready();
        case 2:
          tmp10 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp10 = i6.TypesErrorCodeBusy();
        case 4:
          tmp10 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp10 = i6.TypesErrorCodeQuota();
        case 6:
          tmp10 = i6.TypesErrorCodeExist();
        case 7:
          tmp10 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp10 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp10 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp10 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp10 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp10 = i6.TypesErrorCodeIo();
        case 13:
          tmp10 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp10 = i6.TypesErrorCodeLoop();
        case 15:
          tmp10 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp10 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp10 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp10 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp10 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp10 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp10 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp10 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp10 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp10 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp10 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp10 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp10 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp10 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp10 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp10 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp10 = i6.TypesErrorCodePipe();
        case 32:
          tmp10 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp10 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp10 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp10 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp6 = i0.memory.loadUint8(tmp3.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp9;
          if (tmp6.toBool()) {
            final tmp7 = i0.memory.loadInt32(tmp3.toIntUnsigned(), offset: 12);
            final tmp8 = i0.memory.loadInt32(tmp3.toIntUnsigned(), offset: 16);

            tmp9 = .some(i0.AllocatedString.read(tmp7, tmp8));
          } else {
            tmp9 = .none;
          }

          tmp10 = i6.TypesErrorCodeOther(tmp9);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp11 = .error(tmp10);
    } else {
      tmp11 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(24), const i2.WasmI32(4));
    i0.dartFree(tmp3, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp11;
  }

  @override
  Future<i0.Result<void, i6.TypesErrorCode>> methodDescriptorSymlinkAt({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required String oldPath,
    required String newPath,
  }) async {
    final tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      i2.WasmI32.fromInt(self.handle),
      offset: 0,
    );
    final tmp1 = i0.AllocatedString.allocateUtf16(oldPath);
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
      tmp1.packedLength,
      offset: 4,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
      tmp1.ptr,
      offset: 0,
    );
    final tmp2 = i0.AllocatedString.allocateUtf16(newPath);
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
      tmp2.packedLength,
      offset: 4,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
      tmp2.ptr,
      offset: 0,
    );
    var tmp3 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0.createSubtask(_import77(tmp0, tmp3)).completion;
    final tmp4 = i0.memory.loadUint8(tmp3.toIntUnsigned(), offset: 0);
    final i0.Result<void, i6.TypesErrorCode> tmp11;
    if (tmp4.toBool()) {
      final tmp5 = i0.memory.loadUint8(tmp3.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp10;
      switch (tmp5.toIntUnsigned()) {
        case 0:
          tmp10 = i6.TypesErrorCodeAccess();
        case 1:
          tmp10 = i6.TypesErrorCodeAlready();
        case 2:
          tmp10 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp10 = i6.TypesErrorCodeBusy();
        case 4:
          tmp10 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp10 = i6.TypesErrorCodeQuota();
        case 6:
          tmp10 = i6.TypesErrorCodeExist();
        case 7:
          tmp10 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp10 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp10 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp10 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp10 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp10 = i6.TypesErrorCodeIo();
        case 13:
          tmp10 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp10 = i6.TypesErrorCodeLoop();
        case 15:
          tmp10 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp10 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp10 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp10 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp10 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp10 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp10 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp10 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp10 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp10 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp10 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp10 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp10 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp10 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp10 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp10 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp10 = i6.TypesErrorCodePipe();
        case 32:
          tmp10 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp10 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp10 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp10 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp6 = i0.memory.loadUint8(tmp3.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp9;
          if (tmp6.toBool()) {
            final tmp7 = i0.memory.loadInt32(tmp3.toIntUnsigned(), offset: 12);
            final tmp8 = i0.memory.loadInt32(tmp3.toIntUnsigned(), offset: 16);

            tmp9 = .some(i0.AllocatedString.read(tmp7, tmp8));
          } else {
            tmp9 = .none;
          }

          tmp10 = i6.TypesErrorCodeOther(tmp9);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp11 = .error(tmp10);
    } else {
      tmp11 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    i0.dartFree(tmp3, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp11;
  }

  @override
  Future<i0.Result<void, i6.TypesErrorCode>> methodDescriptorUnlinkFileAt({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required String path,
  }) async {
    final tmp0 = i0.AllocatedString.allocateUtf16(path);
    var tmp1 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(
          _import78(
            i2.WasmI32.fromInt(self.handle),
            tmp0.ptr,
            tmp0.packedLength,
            tmp1,
          ),
        )
        .completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<void, i6.TypesErrorCode> tmp9;
    if (tmp2.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 4);
      final i6.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i6.TypesErrorCodeAccess();
        case 1:
          tmp8 = i6.TypesErrorCodeAlready();
        case 2:
          tmp8 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp8 = i6.TypesErrorCodeBusy();
        case 4:
          tmp8 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp8 = i6.TypesErrorCodeQuota();
        case 6:
          tmp8 = i6.TypesErrorCodeExist();
        case 7:
          tmp8 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp8 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp8 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp8 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp8 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp8 = i6.TypesErrorCodeIo();
        case 13:
          tmp8 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp8 = i6.TypesErrorCodeLoop();
        case 15:
          tmp8 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp8 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp8 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp8 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp8 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp8 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp8 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp8 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp8 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp8 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp8 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp8 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp8 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp8 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp8 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp8 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp8 = i6.TypesErrorCodePipe();
        case 32:
          tmp8 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp8 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp8 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp8 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp4 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp7;
          if (tmp4.toBool()) {
            final tmp5 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 12);
            final tmp6 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 16);

            tmp7 = .some(i0.AllocatedString.read(tmp5, tmp6));
          } else {
            tmp7 = .none;
          }

          tmp8 = i6.TypesErrorCodeOther(tmp7);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp9 = .error(tmp8);
    } else {
      tmp9 = .ok(null);
    }

    i0.dartFree(tmp1, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp9;
  }

  @override
  Future<bool> methodDescriptorIsSameObject({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required i0.Borrowed<i6.TypesDescriptor> other,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(1), const i2.WasmI32(1));
    await i0
        .createSubtask(
          _import79(
            i2.WasmI32.fromInt(self.handle),
            i2.WasmI32.fromInt(other.handle),
            tmp0,
          ),
        )
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    i0.dartFree(tmp0, const i2.WasmI32(1), const i2.WasmI32(1));
    return tmp1.toBool();
  }

  @override
  Future<i0.Result<({int lower, int upper}), i6.TypesErrorCode>>
  methodDescriptorMetadataHash({
    required i0.Borrowed<i6.TypesDescriptor> self,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(24));
    await i0
        .createSubtask(_import80(i2.WasmI32.fromInt(self.handle), tmp0))
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<({int lower, int upper}), i6.TypesErrorCode> tmp11;
    if (tmp1.toBool()) {
      final tmp5 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i6.TypesErrorCode tmp10;
      switch (tmp5.toIntUnsigned()) {
        case 0:
          tmp10 = i6.TypesErrorCodeAccess();
        case 1:
          tmp10 = i6.TypesErrorCodeAlready();
        case 2:
          tmp10 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp10 = i6.TypesErrorCodeBusy();
        case 4:
          tmp10 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp10 = i6.TypesErrorCodeQuota();
        case 6:
          tmp10 = i6.TypesErrorCodeExist();
        case 7:
          tmp10 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp10 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp10 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp10 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp10 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp10 = i6.TypesErrorCodeIo();
        case 13:
          tmp10 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp10 = i6.TypesErrorCodeLoop();
        case 15:
          tmp10 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp10 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp10 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp10 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp10 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp10 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp10 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp10 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp10 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp10 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp10 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp10 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp10 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp10 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp10 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp10 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp10 = i6.TypesErrorCodePipe();
        case 32:
          tmp10 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp10 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp10 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp10 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp6 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 12);
          final i0.Option<String> tmp9;
          if (tmp6.toBool()) {
            final tmp7 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);
            final tmp8 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 20);

            tmp9 = .some(i0.AllocatedString.read(tmp7, tmp8));
          } else {
            tmp9 = .none;
          }

          tmp10 = i6.TypesErrorCodeOther(tmp9);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp11 = .error(tmp10);
    } else {
      final tmp2 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 8);
      final tmp3 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 16);
      final tmp4 = (lower: tmp2.toInt(), upper: tmp3.toInt());

      tmp11 = .ok(tmp4);
    }

    i0.dartFree(tmp0, const i2.WasmI32(24), const i2.WasmI32(8));
    return tmp11;
  }

  @override
  Future<i0.Result<({int lower, int upper}), i6.TypesErrorCode>>
  methodDescriptorMetadataHashAt({
    required i0.Borrowed<i6.TypesDescriptor> self,
    required i6.TypesPathFlags pathFlags,
    required String path,
  }) async {
    final tmp0 = i0.AllocatedString.allocateUtf16(path);
    var tmp1 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(24));
    await i0
        .createSubtask(
          _import81(
            i2.WasmI32.fromInt(self.handle),
            pathFlags.toWasmI32(),
            tmp0.ptr,
            tmp0.packedLength,
            tmp1,
          ),
        )
        .completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<({int lower, int upper}), i6.TypesErrorCode> tmp12;
    if (tmp2.toBool()) {
      final tmp6 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 8);
      final i6.TypesErrorCode tmp11;
      switch (tmp6.toIntUnsigned()) {
        case 0:
          tmp11 = i6.TypesErrorCodeAccess();
        case 1:
          tmp11 = i6.TypesErrorCodeAlready();
        case 2:
          tmp11 = i6.TypesErrorCodeBadDescriptor();
        case 3:
          tmp11 = i6.TypesErrorCodeBusy();
        case 4:
          tmp11 = i6.TypesErrorCodeDeadlock();
        case 5:
          tmp11 = i6.TypesErrorCodeQuota();
        case 6:
          tmp11 = i6.TypesErrorCodeExist();
        case 7:
          tmp11 = i6.TypesErrorCodeFileTooLarge();
        case 8:
          tmp11 = i6.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp11 = i6.TypesErrorCodeInProgress();
        case 10:
          tmp11 = i6.TypesErrorCodeInterrupted();
        case 11:
          tmp11 = i6.TypesErrorCodeInvalid();
        case 12:
          tmp11 = i6.TypesErrorCodeIo();
        case 13:
          tmp11 = i6.TypesErrorCodeIsDirectory();
        case 14:
          tmp11 = i6.TypesErrorCodeLoop();
        case 15:
          tmp11 = i6.TypesErrorCodeTooManyLinks();
        case 16:
          tmp11 = i6.TypesErrorCodeMessageSize();
        case 17:
          tmp11 = i6.TypesErrorCodeNameTooLong();
        case 18:
          tmp11 = i6.TypesErrorCodeNoDevice();
        case 19:
          tmp11 = i6.TypesErrorCodeNoEntry();
        case 20:
          tmp11 = i6.TypesErrorCodeNoLock();
        case 21:
          tmp11 = i6.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp11 = i6.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp11 = i6.TypesErrorCodeNotDirectory();
        case 24:
          tmp11 = i6.TypesErrorCodeNotEmpty();
        case 25:
          tmp11 = i6.TypesErrorCodeNotRecoverable();
        case 26:
          tmp11 = i6.TypesErrorCodeUnsupported();
        case 27:
          tmp11 = i6.TypesErrorCodeNoTty();
        case 28:
          tmp11 = i6.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp11 = i6.TypesErrorCodeOverflow();
        case 30:
          tmp11 = i6.TypesErrorCodeNotPermitted();
        case 31:
          tmp11 = i6.TypesErrorCodePipe();
        case 32:
          tmp11 = i6.TypesErrorCodeReadOnly();
        case 33:
          tmp11 = i6.TypesErrorCodeInvalidSeek();
        case 34:
          tmp11 = i6.TypesErrorCodeTextFileBusy();
        case 35:
          tmp11 = i6.TypesErrorCodeCrossDevice();
        case 36:
          final tmp7 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 12);
          final i0.Option<String> tmp10;
          if (tmp7.toBool()) {
            final tmp8 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 16);
            final tmp9 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 20);

            tmp10 = .some(i0.AllocatedString.read(tmp8, tmp9));
          } else {
            tmp10 = .none;
          }

          tmp11 = i6.TypesErrorCodeOther(tmp10);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp12 = .error(tmp11);
    } else {
      final tmp3 = i0.memory.loadInt64(tmp1.toIntUnsigned(), offset: 8);
      final tmp4 = i0.memory.loadInt64(tmp1.toIntUnsigned(), offset: 16);
      final tmp5 = (lower: tmp3.toInt(), upper: tmp4.toInt());

      tmp12 = .ok(tmp5);
    }

    i0.dartFree(tmp1, const i2.WasmI32(24), const i2.WasmI32(8));
    return tmp12;
  }
}

@pragma('wasm:import', r'component._drop$39')
external i2.WasmVoid _drop$39Raw(i2.WasmI32 handle);

void _drop$39(int handle) {
  _drop$39Raw(i2.WasmI32.fromInt(handle));
}

@pragma("wasm:import", r"component._import82")
external i2.WasmVoid _import82(i2.WasmI32 p0);

final class _Imported$6 implements i6.Preopens {
  const _Imported$6();
  @override
  List<(i0.Owned<i6.TypesDescriptor>, String)> getDirectories() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import82(tmp0);
    final tmp1 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);

    final tmp9 = tmp1.toIntUnsigned();
    final tmp8 = List.generate(tmp2.toIntUnsigned(), growable: false, (i) {
      final elementPtr = i2.WasmI32.fromInt(tmp9 + i * 12);
      final tmp3 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 0);
      final tmp4 = i0.Owned<i6.TypesDescriptor>(tmp3.toIntUnsigned(), _drop$39);
      final tmp5 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 4);
      final tmp6 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 8);
      final tmp7 = (tmp4, i0.AllocatedString.read(tmp5, tmp6));

      return tmp7;
    });

    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp8;
  }
}

@pragma('wasm:import', r'component._drop$53')
external i2.WasmVoid _drop$53Raw(i2.WasmI32 handle);

void _drop$53(int handle) {
  _drop$53Raw(i2.WasmI32.fromInt(handle));
}

@pragma('wasm:import', 'component.stream59.new')
external i2.WasmI64 _streamNew59();
@pragma('wasm:import', 'component.stream59.read')
external i2.WasmI32 _streamRead59(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream59.write')
external i2.WasmI32 _streamWrite59(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream59.drop-readable')
external i2.WasmVoid _streamDropReadable59(i2.WasmI32 stream);
@pragma('wasm:import', 'component.stream59.drop-writable')
external i2.WasmVoid _streamDropWritable59(i2.WasmI32 stream);

final class _Vtable59
    implements i0.StreamVtable<List<i0.Owned<i7.TypesTcpSocket>>> {
  const _Vtable59();

  @override
  int get elementSize => 4;
  @override
  int allocateBuffer(int size) {
    return i0
        .mallocAligned(const i2.WasmI32(4), (size * 4).toWasmI32())
        .toIntUnsigned();
  }

  @override
  void freeBuffer(int address, int totalSize, int start, int end) {
    for (var i = start; i < end; i++) {
      final ptr = i2.WasmI32.fromInt(address + i * 4);
      final tmp0 = i0.memory.loadInt32(ptr.toIntUnsigned(), offset: 0);
      final tmp1 = i0.Owned<i7.TypesTcpSocket>(tmp0.toIntUnsigned(), _drop$53);
      tmp1.drop();
    }

    i0.dartFree(
      address.toWasmI32(),
      (totalSize * 4).toWasmI32(),
      const i2.WasmI32(4),
    );
  }

  @override
  void writeToBuffer(int address, List<i0.Owned<i7.TypesTcpSocket>> elements) {
    for (final (i, element) in elements.indexed) {
      final wasmAddress = i2.WasmI32.fromInt(address + i);

      i0.memory.storeInt32(
        wasmAddress.toIntUnsigned(),
        i2.WasmI32.fromInt(element.handle),
        offset: 0,
      );
    }
  }

  @override
  List<i0.Owned<i7.TypesTcpSocket>> readFromBuffer(int address, int count) {
    return List.generate(count, (i) {
      final ptr = i2.WasmI32.fromInt(address + i * 4);
      final tmp0 = i0.memory.loadInt32(ptr.toIntUnsigned(), offset: 0);
      final tmp1 = i0.Owned<i7.TypesTcpSocket>(tmp0.toIntUnsigned(), _drop$53);
      return tmp1;
    });
  }

  @override
  int newStream() => _streamNew59().toInt();
  @override
  void dropReadable(int stream) {
    _streamDropReadable59(i2.WasmI32.fromInt(stream));
  }

  @override
  void dropWritable(int stream) {
    _streamDropWritable59(i2.WasmI32.fromInt(stream));
  }

  @override
  int read(int stream, int ptr, int n) {
    return _streamRead59(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }

  @override
  int write(int stream, int ptr, int n) {
    return _streamWrite59(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }
}

@pragma('wasm:import', 'component.stream61.new')
external i2.WasmI64 _streamNew61();
@pragma('wasm:import', 'component.stream61.read')
external i2.WasmI32 _streamRead61(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream61.write')
external i2.WasmI32 _streamWrite61(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream61.drop-readable')
external i2.WasmVoid _streamDropReadable61(i2.WasmI32 stream);
@pragma('wasm:import', 'component.stream61.drop-writable')
external i2.WasmVoid _streamDropWritable61(i2.WasmI32 stream);

final class _Vtable61 implements i0.StreamVtable<i4.Uint8List> {
  const _Vtable61();

  @override
  int get elementSize => 1;
  @override
  int allocateBuffer(int size) {
    return i0
        .mallocAligned(const i2.WasmI32(1), (size * 1).toWasmI32())
        .toIntUnsigned();
  }

  @override
  void freeBuffer(int address, int totalSize, int start, int end) {
    i0.dartFree(
      address.toWasmI32(),
      (totalSize * 1).toWasmI32(),
      const i2.WasmI32(1),
    );
  }

  @override
  void writeToBuffer(int address, i4.Uint8List elements) {
    for (final (i, element) in elements.indexed) {
      final wasmAddress = i2.WasmI32.fromInt(address + i);

      i0.memory.storeInt8(
        wasmAddress.toIntUnsigned(),
        i2.WasmI32.uint8FromInt(element),
        offset: 0,
      );
    }
  }

  @override
  i4.Uint8List readFromBuffer(int address, int count) {
    final typedList = i4.Uint8List(count);
    for (var i = 0; i < count; i++) {
      final ptr = i2.WasmI32.fromInt(address + i * 1);
      final tmp0 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 0);

      typedList[i] = tmp0.toIntUnsigned();
    }
    return typedList;
  }

  @override
  int newStream() => _streamNew61().toInt();
  @override
  void dropReadable(int stream) {
    _streamDropReadable61(i2.WasmI32.fromInt(stream));
  }

  @override
  void dropWritable(int stream) {
    _streamDropWritable61(i2.WasmI32.fromInt(stream));
  }

  @override
  int read(int stream, int ptr, int n) {
    return _streamRead61(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }

  @override
  int write(int stream, int ptr, int n) {
    return _streamWrite61(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }
}

@pragma('wasm:import', 'component.future62.new')
external i2.WasmI64 _futureNew62();
@pragma('wasm:import', 'component.future62.write')
external i2.WasmI32 _futureWrite62(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future62.read')
external i2.WasmI32 _futureRead62(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future62.drop-readable')
external i2.WasmVoid _futureDropReadable62(i2.WasmI32 future);
@pragma('wasm:import', 'component.future62.drop-writable')
external i2.WasmVoid _futureDropWritable62(i2.WasmI32 future);

final class _Vtable62
    implements i0.FutureVtable<i0.Result<void, i7.TypesErrorCode>> {
  const _Vtable62();

  @override
  int newFuture() => _futureNew62().toInt();

  @override
  int read(int future, int buffer) {
    return _futureRead62(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  int write(int future, int buffer) {
    return _futureWrite62(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  void dropRead(int future) {
    _futureDropReadable62(i2.WasmI32.fromInt(future));
  }

  @override
  void dropWrite(int future) {
    _futureDropWritable62(i2.WasmI32.fromInt(future));
  }

  @override
  int allocateBuffer() {
    return i0
        .mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20))
        .toIntUnsigned();
  }

  @override
  void freeBuffer(int address, {required bool containsValue}) {
    if (containsValue) {
      final ptr = i2.WasmI32.fromInt(address);
      final tmp0 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 0);
      switch (tmp0) {
        case 0:
          break;
        case 1:
          final tmp1 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 4);
          switch (tmp1) {
            case 0:
              break;
            case 1:
              break;
            case 2:
              break;
            case 3:
              break;
            case 4:
              break;
            case 5:
              break;
            case 6:
              break;
            case 7:
              break;
            case 8:
              break;
            case 9:
              break;
            case 10:
              break;
            case 11:
              break;
            case 12:
              break;
            case 13:
              break;
            case 14:
              final tmp2 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 8);
              switch (tmp2) {
                case 0:
                  break;
                case 1:
                  final tmp3 = i0.memory.loadInt32(
                    ptr.toIntUnsigned(),
                    offset: 12,
                  );
                  final tmp4 = i0.memory.loadInt32(
                    ptr.toIntUnsigned(),
                    offset: 16,
                  );
                  i0.AllocatedString(tmp3, tmp4).free();
                  break;
              }
              break;
          }
          break;
      }
    }
    i0.dartFree(address.toWasmI32(), const i2.WasmI32(20), const i2.WasmI32(4));
  }

  @override
  void store(int address, i0.Result<void, i7.TypesErrorCode> value) {
    final wasmAddress = i2.WasmI32.fromInt(address);

    switch (value) {
      case i0.OkResult(:final value):
        i0.memory.storeInt8(
          wasmAddress.toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 0,
        );

      case i0.ErrorResult(:final value):
        i0.memory.storeInt8(
          wasmAddress.toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 0,
        );
        switch (value) {
          case i7.TypesErrorCodeAccessDenied():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(0),
              offset: 4,
            );

          case i7.TypesErrorCodeNotSupported():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(1),
              offset: 4,
            );

          case i7.TypesErrorCodeInvalidArgument():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(2),
              offset: 4,
            );

          case i7.TypesErrorCodeOutOfMemory():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(3),
              offset: 4,
            );

          case i7.TypesErrorCodeTimeout():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(4),
              offset: 4,
            );

          case i7.TypesErrorCodeInvalidState():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(5),
              offset: 4,
            );

          case i7.TypesErrorCodeAddressNotBindable():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(6),
              offset: 4,
            );

          case i7.TypesErrorCodeAddressInUse():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(7),
              offset: 4,
            );

          case i7.TypesErrorCodeRemoteUnreachable():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(8),
              offset: 4,
            );

          case i7.TypesErrorCodeConnectionRefused():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(9),
              offset: 4,
            );

          case i7.TypesErrorCodeConnectionBroken():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(10),
              offset: 4,
            );

          case i7.TypesErrorCodeConnectionReset():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(11),
              offset: 4,
            );

          case i7.TypesErrorCodeConnectionAborted():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(12),
              offset: 4,
            );

          case i7.TypesErrorCodeDatagramTooLarge():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(13),
              offset: 4,
            );

          case i7.TypesErrorCodeOther(payload: final value):
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(14),
              offset: 4,
            );
            final tmp1 = value;
            if (tmp1.hasValue) {
              final value = tmp1.requireValue();
              i0.memory.storeInt8(
                wasmAddress.toIntUnsigned(),
                const i2.WasmI32(1),
                offset: 8,
              );
              final tmp0 = i0.AllocatedString.allocateUtf16(value);
              i0.memory.storeInt32(
                wasmAddress.toIntUnsigned(),
                tmp0.packedLength,
                offset: 16,
              );
              i0.memory.storeInt32(
                wasmAddress.toIntUnsigned(),
                tmp0.ptr,
                offset: 12,
              );
            } else {
              i0.memory.storeInt8(
                wasmAddress.toIntUnsigned(),
                const i2.WasmI32(0),
                offset: 8,
              );
            }
        }
    }
  }

  @override
  i0.Result<void, i7.TypesErrorCode> load(int address) {
    final wasmAddress = i2.WasmI32.fromInt(address);

    final tmp0 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp7;
    if (tmp0.toBool()) {
      final tmp1 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp6;
      switch (tmp1.toIntUnsigned()) {
        case 0:
          tmp6 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp6 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp6 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp6 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp6 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp6 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp6 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp6 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp6 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp6 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp6 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp6 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp6 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp6 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp2 = i0.memory.loadUint8(
            wasmAddress.toIntUnsigned(),
            offset: 8,
          );
          final i0.Option<String> tmp5;
          if (tmp2.toBool()) {
            final tmp3 = i0.memory.loadInt32(
              wasmAddress.toIntUnsigned(),
              offset: 12,
            );
            final tmp4 = i0.memory.loadInt32(
              wasmAddress.toIntUnsigned(),
              offset: 16,
            );

            tmp5 = .some(i0.AllocatedString.read(tmp3, tmp4));
          } else {
            tmp5 = .none;
          }

          tmp6 = i7.TypesErrorCodeOther(tmp5);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp7 = .error(tmp6);
    } else {
      tmp7 = .ok(null);
    }

    return tmp7;
  }
}

@pragma("wasm:import", r"component._import100")
external i2.WasmVoid _import100(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import101")
external i2.WasmVoid _import101(
  i2.WasmI32 p0,
  i2.WasmI32 p1,
  i2.WasmI32 p2,
  i2.WasmI32 p3,
  i2.WasmI32 p4,
  i2.WasmI32 p5,
  i2.WasmI32 p6,
  i2.WasmI32 p7,
  i2.WasmI32 p8,
  i2.WasmI32 p9,
  i2.WasmI32 p10,
  i2.WasmI32 p11,
  i2.WasmI32 p12,
  i2.WasmI32 p13,
);
@pragma("wasm:import", r"component._import102")
external i2.WasmI32 _import102(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import103")
external i2.WasmVoid _import103(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import104")
external i2.WasmI32 _import104(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import105")
external i2.WasmVoid _import105(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import106")
external i2.WasmVoid _import106(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import107")
external i2.WasmVoid _import107(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import108")
external i2.WasmI32 _import108(i2.WasmI32 p0);
@pragma("wasm:import", r"component._import109")
external i2.WasmI32 _import109(i2.WasmI32 p0);
@pragma("wasm:import", r"component._import110")
external i2.WasmVoid _import110(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import111")
external i2.WasmVoid _import111(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import112")
external i2.WasmVoid _import112(i2.WasmI32 p0, i2.WasmI32 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import113")
external i2.WasmVoid _import113(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import114")
external i2.WasmVoid _import114(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import115")
external i2.WasmVoid _import115(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import116")
external i2.WasmVoid _import116(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import117")
external i2.WasmVoid _import117(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import118")
external i2.WasmVoid _import118(i2.WasmI32 p0, i2.WasmI32 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import119")
external i2.WasmVoid _import119(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import120")
external i2.WasmVoid _import120(i2.WasmI32 p0, i2.WasmI32 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import121")
external i2.WasmVoid _import121(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import122")
external i2.WasmVoid _import122(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import123")
external i2.WasmVoid _import123(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import124")
external i2.WasmVoid _import124(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);

@pragma('wasm:import', r'component._drop$54')
external i2.WasmVoid _drop$54Raw(i2.WasmI32 handle);

void _drop$54(int handle) {
  _drop$54Raw(i2.WasmI32.fromInt(handle));
}

@pragma("wasm:import", r"component._import125")
external i2.WasmVoid _import125(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import127")
external i2.WasmVoid _import127(
  i2.WasmI32 p0,
  i2.WasmI32 p1,
  i2.WasmI32 p2,
  i2.WasmI32 p3,
  i2.WasmI32 p4,
  i2.WasmI32 p5,
  i2.WasmI32 p6,
  i2.WasmI32 p7,
  i2.WasmI32 p8,
  i2.WasmI32 p9,
  i2.WasmI32 p10,
  i2.WasmI32 p11,
  i2.WasmI32 p12,
  i2.WasmI32 p13,
);
@pragma("wasm:import", r"component._import128")
external i2.WasmVoid _import128(
  i2.WasmI32 p0,
  i2.WasmI32 p1,
  i2.WasmI32 p2,
  i2.WasmI32 p3,
  i2.WasmI32 p4,
  i2.WasmI32 p5,
  i2.WasmI32 p6,
  i2.WasmI32 p7,
  i2.WasmI32 p8,
  i2.WasmI32 p9,
  i2.WasmI32 p10,
  i2.WasmI32 p11,
  i2.WasmI32 p12,
  i2.WasmI32 p13,
);
@pragma("wasm:import", r"component._import129")
external i2.WasmVoid _import129(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import130")
external i2.WasmI32 _import130(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import131")
external i2.WasmI32 _import131(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import132")
external i2.WasmVoid _import132(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import133")
external i2.WasmVoid _import133(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import134")
external i2.WasmI32 _import134(i2.WasmI32 p0);
@pragma("wasm:import", r"component._import135")
external i2.WasmVoid _import135(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import136")
external i2.WasmVoid _import136(i2.WasmI32 p0, i2.WasmI32 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import137")
external i2.WasmVoid _import137(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import138")
external i2.WasmVoid _import138(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import139")
external i2.WasmVoid _import139(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import140")
external i2.WasmVoid _import140(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);

final class _Imported$7 implements i7.Types {
  const _Imported$7();
  @override
  i0.Result<i0.Owned<i7.TypesTcpSocket>, i7.TypesErrorCode>
  staticTcpSocketCreate({required i7.TypesIpAddressFamily addressFamily}) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import100(addressFamily.index.toWasmI32(), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i0.Owned<i7.TypesTcpSocket>, i7.TypesErrorCode> tmp10;
    if (tmp1.toBool()) {
      final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp9;
      switch (tmp4.toIntUnsigned()) {
        case 0:
          tmp9 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp9 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp9 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp9 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp9 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp9 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp9 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp9 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp9 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp9 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp9 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp9 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp9 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp9 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp5 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp8;
          if (tmp5.toBool()) {
            final tmp6 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp7 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp8 = .some(i0.AllocatedString.read(tmp6, tmp7));
          } else {
            tmp8 = .none;
          }

          tmp9 = i7.TypesErrorCodeOther(tmp8);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp10 = .error(tmp9);
    } else {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i0.Owned<i7.TypesTcpSocket>(tmp2.toIntUnsigned(), _drop$53);
      tmp10 = .ok(tmp3);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp10;
  }

  @override
  i0.Result<void, i7.TypesErrorCode> methodTcpSocketBind({
    required i0.Borrowed<i7.TypesTcpSocket> self,
    required i7.TypesIpSocketAddress localAddress,
  }) {
    i2.WasmI32 tmp0;
    i2.WasmI32 tmp1;
    i2.WasmI32 tmp2;
    i2.WasmI32 tmp3;
    i2.WasmI32 tmp4;
    i2.WasmI32 tmp5;
    i2.WasmI32 tmp6;
    i2.WasmI32 tmp7;
    i2.WasmI32 tmp8;
    i2.WasmI32 tmp9;
    i2.WasmI32 tmp10;
    i2.WasmI32 tmp11;
    switch (localAddress) {
      case i7.TypesIpSocketAddressIpv4(payload: final value):
        tmp0 = const i2.WasmI32(0);
        tmp1 = i2.WasmI32.uint16FromInt(value.port);
        tmp2 = i2.WasmI32.uint8FromInt(value.address.$1);
        tmp3 = i2.WasmI32.uint8FromInt(value.address.$2);
        tmp4 = i2.WasmI32.uint8FromInt(value.address.$3);
        tmp5 = i2.WasmI32.uint8FromInt(value.address.$4);
        tmp6 = const i2.WasmI32(0);
        tmp7 = const i2.WasmI32(0);
        tmp8 = const i2.WasmI32(0);
        tmp9 = const i2.WasmI32(0);
        tmp10 = const i2.WasmI32(0);
        tmp11 = const i2.WasmI32(0);

      case i7.TypesIpSocketAddressIpv6(payload: final value):
        tmp0 = const i2.WasmI32(1);
        tmp1 = i2.WasmI32.uint16FromInt(value.port);
        tmp2 = i2.WasmI32.fromInt(value.flowInfo);
        tmp3 = i2.WasmI32.uint16FromInt(value.address.$1);
        tmp4 = i2.WasmI32.uint16FromInt(value.address.$2);
        tmp5 = i2.WasmI32.uint16FromInt(value.address.$3);
        tmp6 = i2.WasmI32.uint16FromInt(value.address.$4);
        tmp7 = i2.WasmI32.uint16FromInt(value.address.$5);
        tmp8 = i2.WasmI32.uint16FromInt(value.address.$6);
        tmp9 = i2.WasmI32.uint16FromInt(value.address.$7);
        tmp10 = i2.WasmI32.uint16FromInt(value.address.$8);
        tmp11 = i2.WasmI32.fromInt(value.scopeId);
    }
    var tmp12 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import101(
      i2.WasmI32.fromInt(self.handle),
      tmp0,
      tmp1,
      tmp2,
      tmp3,
      tmp4,
      tmp5,
      tmp6,
      tmp7,
      tmp8,
      tmp9,
      tmp10,
      tmp11,
      tmp12,
    );
    final tmp13 = i0.memory.loadUint8(tmp12.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp20;
    if (tmp13.toBool()) {
      final tmp14 = i0.memory.loadUint8(tmp12.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp19;
      switch (tmp14.toIntUnsigned()) {
        case 0:
          tmp19 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp19 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp19 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp19 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp19 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp19 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp19 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp19 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp19 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp19 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp19 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp19 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp19 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp19 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp15 = i0.memory.loadUint8(tmp12.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp18;
          if (tmp15.toBool()) {
            final tmp16 = i0.memory.loadInt32(
              tmp12.toIntUnsigned(),
              offset: 12,
            );
            final tmp17 = i0.memory.loadInt32(
              tmp12.toIntUnsigned(),
              offset: 16,
            );

            tmp18 = .some(i0.AllocatedString.read(tmp16, tmp17));
          } else {
            tmp18 = .none;
          }

          tmp19 = i7.TypesErrorCodeOther(tmp18);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp20 = .error(tmp19);
    } else {
      tmp20 = .ok(null);
    }

    i0.dartFree(tmp12, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp20;
  }

  @override
  Future<i0.Result<void, i7.TypesErrorCode>> methodTcpSocketConnect({
    required i0.Borrowed<i7.TypesTcpSocket> self,
    required i7.TypesIpSocketAddress remoteAddress,
  }) async {
    final tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(36));
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      i2.WasmI32.fromInt(self.handle),
      offset: 0,
    );
    switch (remoteAddress) {
      case i7.TypesIpSocketAddressIpv4(payload: final value):
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 0,
        );
        i0.memory.storeInt16(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          i2.WasmI32.uint16FromInt(value.port),
          offset: 4,
        );
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          i2.WasmI32.uint8FromInt(value.address.$1),
          offset: 6,
        );
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          i2.WasmI32.uint8FromInt(value.address.$2),
          offset: 7,
        );
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          i2.WasmI32.uint8FromInt(value.address.$3),
          offset: 8,
        );
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          i2.WasmI32.uint8FromInt(value.address.$4),
          offset: 9,
        );

      case i7.TypesIpSocketAddressIpv6(payload: final value):
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 0,
        );
        i0.memory.storeInt16(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          i2.WasmI32.uint16FromInt(value.port),
          offset: 4,
        );
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          i2.WasmI32.fromInt(value.flowInfo),
          offset: 8,
        );
        i0.memory.storeInt16(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          i2.WasmI32.uint16FromInt(value.address.$1),
          offset: 12,
        );
        i0.memory.storeInt16(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          i2.WasmI32.uint16FromInt(value.address.$2),
          offset: 14,
        );
        i0.memory.storeInt16(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          i2.WasmI32.uint16FromInt(value.address.$3),
          offset: 16,
        );
        i0.memory.storeInt16(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          i2.WasmI32.uint16FromInt(value.address.$4),
          offset: 18,
        );
        i0.memory.storeInt16(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          i2.WasmI32.uint16FromInt(value.address.$5),
          offset: 20,
        );
        i0.memory.storeInt16(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          i2.WasmI32.uint16FromInt(value.address.$6),
          offset: 22,
        );
        i0.memory.storeInt16(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          i2.WasmI32.uint16FromInt(value.address.$7),
          offset: 24,
        );
        i0.memory.storeInt16(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          i2.WasmI32.uint16FromInt(value.address.$8),
          offset: 26,
        );
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
          i2.WasmI32.fromInt(value.scopeId),
          offset: 28,
        );
    }
    var tmp1 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0.createSubtask(_import102(tmp0, tmp1)).completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp9;
    if (tmp2.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp4 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp7;
          if (tmp4.toBool()) {
            final tmp5 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 12);
            final tmp6 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 16);

            tmp7 = .some(i0.AllocatedString.read(tmp5, tmp6));
          } else {
            tmp7 = .none;
          }

          tmp8 = i7.TypesErrorCodeOther(tmp7);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp9 = .error(tmp8);
    } else {
      tmp9 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(36), const i2.WasmI32(4));
    i0.dartFree(tmp1, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp9;
  }

  @override
  i0.Result<Stream<List<i0.Owned<i7.TypesTcpSocket>>>, i7.TypesErrorCode>
  methodTcpSocketListen({required i0.Borrowed<i7.TypesTcpSocket> self}) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import103(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<
      Stream<List<i0.Owned<i7.TypesTcpSocket>>>,
      i7.TypesErrorCode
    >
    tmp10;
    if (tmp1.toBool()) {
      final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp9;
      switch (tmp4.toIntUnsigned()) {
        case 0:
          tmp9 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp9 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp9 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp9 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp9 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp9 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp9 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp9 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp9 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp9 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp9 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp9 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp9 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp9 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp5 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp8;
          if (tmp5.toBool()) {
            final tmp6 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp7 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp8 = .some(i0.AllocatedString.read(tmp6, tmp7));
          } else {
            tmp8 = .none;
          }

          tmp9 = i7.TypesErrorCodeOther(tmp8);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp10 = .error(tmp9);
    } else {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i0.ReadableStream(tmp2.toIntUnsigned(), const _Vtable59());

      tmp10 = .ok(tmp3);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp10;
  }

  @override
  Future<i0.Result<void, i7.TypesErrorCode>> methodTcpSocketSend({
    required i0.Borrowed<i7.TypesTcpSocket> self,
    required Stream<i4.Uint8List> data,
  }) {
    final tmp0 = i0.newReadableStream(const _Vtable61(), data).toWasmI32();
    final tmp1 = _import104(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp2 = i0.readFuture(const _Vtable62(), tmp1.toIntUnsigned());
    return tmp2;
  }

  @override
  (Stream<i4.Uint8List>, Future<i0.Result<void, i7.TypesErrorCode>>)
  methodTcpSocketReceive({required i0.Borrowed<i7.TypesTcpSocket> self}) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import105(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.ReadableStream(tmp1.toIntUnsigned(), const _Vtable61());
    final tmp3 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
    final tmp4 = i0.readFuture(const _Vtable62(), tmp3.toIntUnsigned());
    final tmp5 = (tmp2, tmp4);
    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp5;
  }

  @override
  i0.Result<i7.TypesIpSocketAddress, i7.TypesErrorCode>
  methodTcpSocketGetLocalAddress({
    required i0.Borrowed<i7.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(36));
    _import106(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i7.TypesIpSocketAddress, i7.TypesErrorCode> tmp30;
    if (tmp1.toBool()) {
      final tmp24 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp29;
      switch (tmp24.toIntUnsigned()) {
        case 0:
          tmp29 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp29 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp29 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp29 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp29 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp29 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp29 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp29 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp29 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp29 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp29 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp29 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp29 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp29 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp25 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp28;
          if (tmp25.toBool()) {
            final tmp26 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp27 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp28 = .some(i0.AllocatedString.read(tmp26, tmp27));
          } else {
            tmp28 = .none;
          }

          tmp29 = i7.TypesErrorCodeOther(tmp28);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp30 = .error(tmp29);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesIpSocketAddress tmp23;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          final tmp3 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 8);
          final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 10);
          final tmp5 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 11);
          final tmp6 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 12);
          final tmp7 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 13);
          final tmp8 = (
            tmp4.toIntUnsigned(),
            tmp5.toIntUnsigned(),
            tmp6.toIntUnsigned(),
            tmp7.toIntUnsigned(),
          );
          final tmp9 = (port: tmp3.toIntUnsigned(), address: tmp8);

          tmp23 = i7.TypesIpSocketAddressIpv4(tmp9);
        case 1:
          final tmp10 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 8);
          final tmp11 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
          final tmp12 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 16);
          final tmp13 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 18);
          final tmp14 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 20);
          final tmp15 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 22);
          final tmp16 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 24);
          final tmp17 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 26);
          final tmp18 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 28);
          final tmp19 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 30);
          final tmp20 = (
            tmp12.toIntUnsigned(),
            tmp13.toIntUnsigned(),
            tmp14.toIntUnsigned(),
            tmp15.toIntUnsigned(),
            tmp16.toIntUnsigned(),
            tmp17.toIntUnsigned(),
            tmp18.toIntUnsigned(),
            tmp19.toIntUnsigned(),
          );
          final tmp21 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 32);
          final tmp22 = (
            port: tmp10.toIntUnsigned(),
            flowInfo: tmp11.toIntUnsigned(),
            address: tmp20,
            scopeId: tmp21.toIntUnsigned(),
          );

          tmp23 = i7.TypesIpSocketAddressIpv6(tmp22);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp30 = .ok(tmp23);
    }

    i0.dartFree(tmp0, const i2.WasmI32(36), const i2.WasmI32(4));
    return tmp30;
  }

  @override
  i0.Result<i7.TypesIpSocketAddress, i7.TypesErrorCode>
  methodTcpSocketGetRemoteAddress({
    required i0.Borrowed<i7.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(36));
    _import107(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i7.TypesIpSocketAddress, i7.TypesErrorCode> tmp30;
    if (tmp1.toBool()) {
      final tmp24 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp29;
      switch (tmp24.toIntUnsigned()) {
        case 0:
          tmp29 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp29 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp29 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp29 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp29 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp29 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp29 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp29 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp29 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp29 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp29 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp29 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp29 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp29 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp25 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp28;
          if (tmp25.toBool()) {
            final tmp26 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp27 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp28 = .some(i0.AllocatedString.read(tmp26, tmp27));
          } else {
            tmp28 = .none;
          }

          tmp29 = i7.TypesErrorCodeOther(tmp28);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp30 = .error(tmp29);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesIpSocketAddress tmp23;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          final tmp3 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 8);
          final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 10);
          final tmp5 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 11);
          final tmp6 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 12);
          final tmp7 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 13);
          final tmp8 = (
            tmp4.toIntUnsigned(),
            tmp5.toIntUnsigned(),
            tmp6.toIntUnsigned(),
            tmp7.toIntUnsigned(),
          );
          final tmp9 = (port: tmp3.toIntUnsigned(), address: tmp8);

          tmp23 = i7.TypesIpSocketAddressIpv4(tmp9);
        case 1:
          final tmp10 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 8);
          final tmp11 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
          final tmp12 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 16);
          final tmp13 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 18);
          final tmp14 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 20);
          final tmp15 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 22);
          final tmp16 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 24);
          final tmp17 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 26);
          final tmp18 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 28);
          final tmp19 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 30);
          final tmp20 = (
            tmp12.toIntUnsigned(),
            tmp13.toIntUnsigned(),
            tmp14.toIntUnsigned(),
            tmp15.toIntUnsigned(),
            tmp16.toIntUnsigned(),
            tmp17.toIntUnsigned(),
            tmp18.toIntUnsigned(),
            tmp19.toIntUnsigned(),
          );
          final tmp21 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 32);
          final tmp22 = (
            port: tmp10.toIntUnsigned(),
            flowInfo: tmp11.toIntUnsigned(),
            address: tmp20,
            scopeId: tmp21.toIntUnsigned(),
          );

          tmp23 = i7.TypesIpSocketAddressIpv6(tmp22);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp30 = .ok(tmp23);
    }

    i0.dartFree(tmp0, const i2.WasmI32(36), const i2.WasmI32(4));
    return tmp30;
  }

  @override
  bool methodTcpSocketGetIsListening({
    required i0.Borrowed<i7.TypesTcpSocket> self,
  }) {
    final tmp0 = _import108(i2.WasmI32.fromInt(self.handle));
    return tmp0.toBool();
  }

  @override
  i7.TypesIpAddressFamily methodTcpSocketGetAddressFamily({
    required i0.Borrowed<i7.TypesTcpSocket> self,
  }) {
    final tmp0 = _import109(i2.WasmI32.fromInt(self.handle));
    return i7.TypesIpAddressFamily.values[tmp0.toIntUnsigned()];
  }

  @override
  i0.Result<void, i7.TypesErrorCode> methodTcpSocketSetListenBacklogSize({
    required i0.Borrowed<i7.TypesTcpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import110(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI64.fromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i7.TypesErrorCodeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp8 = .error(tmp7);
    } else {
      tmp8 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp8;
  }

  @override
  i0.Result<bool, i7.TypesErrorCode> methodTcpSocketGetKeepAliveEnabled({
    required i0.Borrowed<i7.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import111(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<bool, i7.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp7;
          if (tmp4.toBool()) {
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp6 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp7 = .some(i0.AllocatedString.read(tmp5, tmp6));
          } else {
            tmp7 = .none;
          }

          tmp8 = i7.TypesErrorCodeOther(tmp7);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp9 = .error(tmp8);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);

      tmp9 = .ok(tmp2.toBool());
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp9;
  }

  @override
  i0.Result<void, i7.TypesErrorCode> methodTcpSocketSetKeepAliveEnabled({
    required i0.Borrowed<i7.TypesTcpSocket> self,
    required bool value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import112(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI32.fromBool(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i7.TypesErrorCodeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp8 = .error(tmp7);
    } else {
      tmp8 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp8;
  }

  @override
  i0.Result<int, i7.TypesErrorCode> methodTcpSocketGetKeepAliveIdleTime({
    required i0.Borrowed<i7.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(24));
    _import113(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i7.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i7.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 12);
          final i0.Option<String> tmp7;
          if (tmp4.toBool()) {
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);
            final tmp6 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 20);

            tmp7 = .some(i0.AllocatedString.read(tmp5, tmp6));
          } else {
            tmp7 = .none;
          }

          tmp8 = i7.TypesErrorCodeOther(tmp7);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp9 = .error(tmp8);
    } else {
      final tmp2 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 8);

      tmp9 = .ok(tmp2.toInt());
    }

    i0.dartFree(tmp0, const i2.WasmI32(24), const i2.WasmI32(8));
    return tmp9;
  }

  @override
  i0.Result<void, i7.TypesErrorCode> methodTcpSocketSetKeepAliveIdleTime({
    required i0.Borrowed<i7.TypesTcpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import114(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI64.fromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i7.TypesErrorCodeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp8 = .error(tmp7);
    } else {
      tmp8 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp8;
  }

  @override
  i0.Result<int, i7.TypesErrorCode> methodTcpSocketGetKeepAliveInterval({
    required i0.Borrowed<i7.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(24));
    _import115(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i7.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i7.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 12);
          final i0.Option<String> tmp7;
          if (tmp4.toBool()) {
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);
            final tmp6 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 20);

            tmp7 = .some(i0.AllocatedString.read(tmp5, tmp6));
          } else {
            tmp7 = .none;
          }

          tmp8 = i7.TypesErrorCodeOther(tmp7);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp9 = .error(tmp8);
    } else {
      final tmp2 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 8);

      tmp9 = .ok(tmp2.toInt());
    }

    i0.dartFree(tmp0, const i2.WasmI32(24), const i2.WasmI32(8));
    return tmp9;
  }

  @override
  i0.Result<void, i7.TypesErrorCode> methodTcpSocketSetKeepAliveInterval({
    required i0.Borrowed<i7.TypesTcpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import116(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI64.fromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i7.TypesErrorCodeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp8 = .error(tmp7);
    } else {
      tmp8 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp8;
  }

  @override
  i0.Result<int, i7.TypesErrorCode> methodTcpSocketGetKeepAliveCount({
    required i0.Borrowed<i7.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import117(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i7.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp7;
          if (tmp4.toBool()) {
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp6 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp7 = .some(i0.AllocatedString.read(tmp5, tmp6));
          } else {
            tmp7 = .none;
          }

          tmp8 = i7.TypesErrorCodeOther(tmp7);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp9 = .error(tmp8);
    } else {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);

      tmp9 = .ok(tmp2.toIntUnsigned());
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp9;
  }

  @override
  i0.Result<void, i7.TypesErrorCode> methodTcpSocketSetKeepAliveCount({
    required i0.Borrowed<i7.TypesTcpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import118(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI32.fromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i7.TypesErrorCodeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp8 = .error(tmp7);
    } else {
      tmp8 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp8;
  }

  @override
  i0.Result<int, i7.TypesErrorCode> methodTcpSocketGetHopLimit({
    required i0.Borrowed<i7.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import119(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i7.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp7;
          if (tmp4.toBool()) {
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp6 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp7 = .some(i0.AllocatedString.read(tmp5, tmp6));
          } else {
            tmp7 = .none;
          }

          tmp8 = i7.TypesErrorCodeOther(tmp7);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp9 = .error(tmp8);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);

      tmp9 = .ok(tmp2.toIntUnsigned());
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp9;
  }

  @override
  i0.Result<void, i7.TypesErrorCode> methodTcpSocketSetHopLimit({
    required i0.Borrowed<i7.TypesTcpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import120(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI32.uint8FromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i7.TypesErrorCodeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp8 = .error(tmp7);
    } else {
      tmp8 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp8;
  }

  @override
  i0.Result<int, i7.TypesErrorCode> methodTcpSocketGetReceiveBufferSize({
    required i0.Borrowed<i7.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(24));
    _import121(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i7.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i7.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 12);
          final i0.Option<String> tmp7;
          if (tmp4.toBool()) {
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);
            final tmp6 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 20);

            tmp7 = .some(i0.AllocatedString.read(tmp5, tmp6));
          } else {
            tmp7 = .none;
          }

          tmp8 = i7.TypesErrorCodeOther(tmp7);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp9 = .error(tmp8);
    } else {
      final tmp2 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 8);

      tmp9 = .ok(tmp2.toInt());
    }

    i0.dartFree(tmp0, const i2.WasmI32(24), const i2.WasmI32(8));
    return tmp9;
  }

  @override
  i0.Result<void, i7.TypesErrorCode> methodTcpSocketSetReceiveBufferSize({
    required i0.Borrowed<i7.TypesTcpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import122(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI64.fromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i7.TypesErrorCodeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp8 = .error(tmp7);
    } else {
      tmp8 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp8;
  }

  @override
  i0.Result<int, i7.TypesErrorCode> methodTcpSocketGetSendBufferSize({
    required i0.Borrowed<i7.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(24));
    _import123(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i7.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i7.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 12);
          final i0.Option<String> tmp7;
          if (tmp4.toBool()) {
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);
            final tmp6 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 20);

            tmp7 = .some(i0.AllocatedString.read(tmp5, tmp6));
          } else {
            tmp7 = .none;
          }

          tmp8 = i7.TypesErrorCodeOther(tmp7);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp9 = .error(tmp8);
    } else {
      final tmp2 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 8);

      tmp9 = .ok(tmp2.toInt());
    }

    i0.dartFree(tmp0, const i2.WasmI32(24), const i2.WasmI32(8));
    return tmp9;
  }

  @override
  i0.Result<void, i7.TypesErrorCode> methodTcpSocketSetSendBufferSize({
    required i0.Borrowed<i7.TypesTcpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import124(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI64.fromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i7.TypesErrorCodeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp8 = .error(tmp7);
    } else {
      tmp8 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp8;
  }

  @override
  i0.Result<i0.Owned<i7.TypesUdpSocket>, i7.TypesErrorCode>
  staticUdpSocketCreate({required i7.TypesIpAddressFamily addressFamily}) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import125(addressFamily.index.toWasmI32(), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i0.Owned<i7.TypesUdpSocket>, i7.TypesErrorCode> tmp10;
    if (tmp1.toBool()) {
      final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp9;
      switch (tmp4.toIntUnsigned()) {
        case 0:
          tmp9 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp9 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp9 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp9 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp9 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp9 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp9 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp9 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp9 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp9 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp9 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp9 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp9 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp9 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp5 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp8;
          if (tmp5.toBool()) {
            final tmp6 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp7 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp8 = .some(i0.AllocatedString.read(tmp6, tmp7));
          } else {
            tmp8 = .none;
          }

          tmp9 = i7.TypesErrorCodeOther(tmp8);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp10 = .error(tmp9);
    } else {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i0.Owned<i7.TypesUdpSocket>(tmp2.toIntUnsigned(), _drop$54);
      tmp10 = .ok(tmp3);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp10;
  }

  @override
  i0.Result<void, i7.TypesErrorCode> methodUdpSocketBind({
    required i0.Borrowed<i7.TypesUdpSocket> self,
    required i7.TypesIpSocketAddress localAddress,
  }) {
    i2.WasmI32 tmp0;
    i2.WasmI32 tmp1;
    i2.WasmI32 tmp2;
    i2.WasmI32 tmp3;
    i2.WasmI32 tmp4;
    i2.WasmI32 tmp5;
    i2.WasmI32 tmp6;
    i2.WasmI32 tmp7;
    i2.WasmI32 tmp8;
    i2.WasmI32 tmp9;
    i2.WasmI32 tmp10;
    i2.WasmI32 tmp11;
    switch (localAddress) {
      case i7.TypesIpSocketAddressIpv4(payload: final value):
        tmp0 = const i2.WasmI32(0);
        tmp1 = i2.WasmI32.uint16FromInt(value.port);
        tmp2 = i2.WasmI32.uint8FromInt(value.address.$1);
        tmp3 = i2.WasmI32.uint8FromInt(value.address.$2);
        tmp4 = i2.WasmI32.uint8FromInt(value.address.$3);
        tmp5 = i2.WasmI32.uint8FromInt(value.address.$4);
        tmp6 = const i2.WasmI32(0);
        tmp7 = const i2.WasmI32(0);
        tmp8 = const i2.WasmI32(0);
        tmp9 = const i2.WasmI32(0);
        tmp10 = const i2.WasmI32(0);
        tmp11 = const i2.WasmI32(0);

      case i7.TypesIpSocketAddressIpv6(payload: final value):
        tmp0 = const i2.WasmI32(1);
        tmp1 = i2.WasmI32.uint16FromInt(value.port);
        tmp2 = i2.WasmI32.fromInt(value.flowInfo);
        tmp3 = i2.WasmI32.uint16FromInt(value.address.$1);
        tmp4 = i2.WasmI32.uint16FromInt(value.address.$2);
        tmp5 = i2.WasmI32.uint16FromInt(value.address.$3);
        tmp6 = i2.WasmI32.uint16FromInt(value.address.$4);
        tmp7 = i2.WasmI32.uint16FromInt(value.address.$5);
        tmp8 = i2.WasmI32.uint16FromInt(value.address.$6);
        tmp9 = i2.WasmI32.uint16FromInt(value.address.$7);
        tmp10 = i2.WasmI32.uint16FromInt(value.address.$8);
        tmp11 = i2.WasmI32.fromInt(value.scopeId);
    }
    var tmp12 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import127(
      i2.WasmI32.fromInt(self.handle),
      tmp0,
      tmp1,
      tmp2,
      tmp3,
      tmp4,
      tmp5,
      tmp6,
      tmp7,
      tmp8,
      tmp9,
      tmp10,
      tmp11,
      tmp12,
    );
    final tmp13 = i0.memory.loadUint8(tmp12.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp20;
    if (tmp13.toBool()) {
      final tmp14 = i0.memory.loadUint8(tmp12.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp19;
      switch (tmp14.toIntUnsigned()) {
        case 0:
          tmp19 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp19 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp19 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp19 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp19 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp19 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp19 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp19 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp19 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp19 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp19 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp19 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp19 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp19 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp15 = i0.memory.loadUint8(tmp12.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp18;
          if (tmp15.toBool()) {
            final tmp16 = i0.memory.loadInt32(
              tmp12.toIntUnsigned(),
              offset: 12,
            );
            final tmp17 = i0.memory.loadInt32(
              tmp12.toIntUnsigned(),
              offset: 16,
            );

            tmp18 = .some(i0.AllocatedString.read(tmp16, tmp17));
          } else {
            tmp18 = .none;
          }

          tmp19 = i7.TypesErrorCodeOther(tmp18);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp20 = .error(tmp19);
    } else {
      tmp20 = .ok(null);
    }

    i0.dartFree(tmp12, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp20;
  }

  @override
  i0.Result<void, i7.TypesErrorCode> methodUdpSocketConnect({
    required i0.Borrowed<i7.TypesUdpSocket> self,
    required i7.TypesIpSocketAddress remoteAddress,
  }) {
    i2.WasmI32 tmp0;
    i2.WasmI32 tmp1;
    i2.WasmI32 tmp2;
    i2.WasmI32 tmp3;
    i2.WasmI32 tmp4;
    i2.WasmI32 tmp5;
    i2.WasmI32 tmp6;
    i2.WasmI32 tmp7;
    i2.WasmI32 tmp8;
    i2.WasmI32 tmp9;
    i2.WasmI32 tmp10;
    i2.WasmI32 tmp11;
    switch (remoteAddress) {
      case i7.TypesIpSocketAddressIpv4(payload: final value):
        tmp0 = const i2.WasmI32(0);
        tmp1 = i2.WasmI32.uint16FromInt(value.port);
        tmp2 = i2.WasmI32.uint8FromInt(value.address.$1);
        tmp3 = i2.WasmI32.uint8FromInt(value.address.$2);
        tmp4 = i2.WasmI32.uint8FromInt(value.address.$3);
        tmp5 = i2.WasmI32.uint8FromInt(value.address.$4);
        tmp6 = const i2.WasmI32(0);
        tmp7 = const i2.WasmI32(0);
        tmp8 = const i2.WasmI32(0);
        tmp9 = const i2.WasmI32(0);
        tmp10 = const i2.WasmI32(0);
        tmp11 = const i2.WasmI32(0);

      case i7.TypesIpSocketAddressIpv6(payload: final value):
        tmp0 = const i2.WasmI32(1);
        tmp1 = i2.WasmI32.uint16FromInt(value.port);
        tmp2 = i2.WasmI32.fromInt(value.flowInfo);
        tmp3 = i2.WasmI32.uint16FromInt(value.address.$1);
        tmp4 = i2.WasmI32.uint16FromInt(value.address.$2);
        tmp5 = i2.WasmI32.uint16FromInt(value.address.$3);
        tmp6 = i2.WasmI32.uint16FromInt(value.address.$4);
        tmp7 = i2.WasmI32.uint16FromInt(value.address.$5);
        tmp8 = i2.WasmI32.uint16FromInt(value.address.$6);
        tmp9 = i2.WasmI32.uint16FromInt(value.address.$7);
        tmp10 = i2.WasmI32.uint16FromInt(value.address.$8);
        tmp11 = i2.WasmI32.fromInt(value.scopeId);
    }
    var tmp12 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import128(
      i2.WasmI32.fromInt(self.handle),
      tmp0,
      tmp1,
      tmp2,
      tmp3,
      tmp4,
      tmp5,
      tmp6,
      tmp7,
      tmp8,
      tmp9,
      tmp10,
      tmp11,
      tmp12,
    );
    final tmp13 = i0.memory.loadUint8(tmp12.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp20;
    if (tmp13.toBool()) {
      final tmp14 = i0.memory.loadUint8(tmp12.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp19;
      switch (tmp14.toIntUnsigned()) {
        case 0:
          tmp19 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp19 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp19 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp19 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp19 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp19 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp19 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp19 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp19 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp19 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp19 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp19 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp19 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp19 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp15 = i0.memory.loadUint8(tmp12.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp18;
          if (tmp15.toBool()) {
            final tmp16 = i0.memory.loadInt32(
              tmp12.toIntUnsigned(),
              offset: 12,
            );
            final tmp17 = i0.memory.loadInt32(
              tmp12.toIntUnsigned(),
              offset: 16,
            );

            tmp18 = .some(i0.AllocatedString.read(tmp16, tmp17));
          } else {
            tmp18 = .none;
          }

          tmp19 = i7.TypesErrorCodeOther(tmp18);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp20 = .error(tmp19);
    } else {
      tmp20 = .ok(null);
    }

    i0.dartFree(tmp12, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp20;
  }

  @override
  i0.Result<void, i7.TypesErrorCode> methodUdpSocketDisconnect({
    required i0.Borrowed<i7.TypesUdpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import129(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i7.TypesErrorCodeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp8 = .error(tmp7);
    } else {
      tmp8 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp8;
  }

  @override
  Future<i0.Result<void, i7.TypesErrorCode>> methodUdpSocketSend({
    required i0.Borrowed<i7.TypesUdpSocket> self,
    required List<int> data,
    required i0.Option<i7.TypesIpSocketAddress> remoteAddress,
  }) async {
    final tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(48));
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      i2.WasmI32.fromInt(self.handle),
      offset: 0,
    );

    final tmp1 = i2.WasmI32.fromInt(1 * data.length);
    final tmp2 = i0.mallocAligned(const i2.WasmI32(1), tmp1);
    var tmp3 = tmp2;
    for (final element in data) {
      final elementPtr = tmp3;
      i0.memory.storeInt8(
        elementPtr.toIntUnsigned(),
        i2.WasmI32.uint8FromInt(element),
        offset: 0,
      );

      tmp3 += const i2.WasmI32(1);
    }

    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
      i2.WasmI32.fromInt(data.length),
      offset: 4,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(4)).toIntUnsigned(),
      tmp2,
      offset: 0,
    );
    final tmp4 = remoteAddress;
    if (tmp4.hasValue) {
      final value = tmp4.requireValue();
      i0.memory.storeInt8(
        (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
        const i2.WasmI32(1),
        offset: 0,
      );
      switch (value) {
        case i7.TypesIpSocketAddressIpv4(payload: final value):
          i0.memory.storeInt8(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            const i2.WasmI32(0),
            offset: 4,
          );
          i0.memory.storeInt16(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            i2.WasmI32.uint16FromInt(value.port),
            offset: 8,
          );
          i0.memory.storeInt8(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            i2.WasmI32.uint8FromInt(value.address.$1),
            offset: 10,
          );
          i0.memory.storeInt8(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            i2.WasmI32.uint8FromInt(value.address.$2),
            offset: 11,
          );
          i0.memory.storeInt8(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            i2.WasmI32.uint8FromInt(value.address.$3),
            offset: 12,
          );
          i0.memory.storeInt8(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            i2.WasmI32.uint8FromInt(value.address.$4),
            offset: 13,
          );

        case i7.TypesIpSocketAddressIpv6(payload: final value):
          i0.memory.storeInt8(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            const i2.WasmI32(1),
            offset: 4,
          );
          i0.memory.storeInt16(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            i2.WasmI32.uint16FromInt(value.port),
            offset: 8,
          );
          i0.memory.storeInt32(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            i2.WasmI32.fromInt(value.flowInfo),
            offset: 12,
          );
          i0.memory.storeInt16(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            i2.WasmI32.uint16FromInt(value.address.$1),
            offset: 16,
          );
          i0.memory.storeInt16(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            i2.WasmI32.uint16FromInt(value.address.$2),
            offset: 18,
          );
          i0.memory.storeInt16(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            i2.WasmI32.uint16FromInt(value.address.$3),
            offset: 20,
          );
          i0.memory.storeInt16(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            i2.WasmI32.uint16FromInt(value.address.$4),
            offset: 22,
          );
          i0.memory.storeInt16(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            i2.WasmI32.uint16FromInt(value.address.$5),
            offset: 24,
          );
          i0.memory.storeInt16(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            i2.WasmI32.uint16FromInt(value.address.$6),
            offset: 26,
          );
          i0.memory.storeInt16(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            i2.WasmI32.uint16FromInt(value.address.$7),
            offset: 28,
          );
          i0.memory.storeInt16(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            i2.WasmI32.uint16FromInt(value.address.$8),
            offset: 30,
          );
          i0.memory.storeInt32(
            (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
            i2.WasmI32.fromInt(value.scopeId),
            offset: 32,
          );
      }
    } else {
      i0.memory.storeInt8(
        (tmp0 + const i2.WasmI32(12)).toIntUnsigned(),
        const i2.WasmI32(0),
        offset: 0,
      );
    }
    var tmp5 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0.createSubtask(_import130(tmp0, tmp5)).completion;
    final tmp6 = i0.memory.loadUint8(tmp5.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp13;
    if (tmp6.toBool()) {
      final tmp7 = i0.memory.loadUint8(tmp5.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp12;
      switch (tmp7.toIntUnsigned()) {
        case 0:
          tmp12 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp12 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp12 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp12 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp12 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp12 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp12 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp12 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp12 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp12 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp12 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp12 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp12 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp12 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp8 = i0.memory.loadUint8(tmp5.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp11;
          if (tmp8.toBool()) {
            final tmp9 = i0.memory.loadInt32(tmp5.toIntUnsigned(), offset: 12);
            final tmp10 = i0.memory.loadInt32(tmp5.toIntUnsigned(), offset: 16);

            tmp11 = .some(i0.AllocatedString.read(tmp9, tmp10));
          } else {
            tmp11 = .none;
          }

          tmp12 = i7.TypesErrorCodeOther(tmp11);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp13 = .error(tmp12);
    } else {
      tmp13 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(48), const i2.WasmI32(4));
    i0.dartFree(tmp5, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp13;
  }

  @override
  Future<i0.Result<(List<int>, i7.TypesIpSocketAddress), i7.TypesErrorCode>>
  methodUdpSocketReceive({required i0.Borrowed<i7.TypesUdpSocket> self}) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(44));
    await i0
        .createSubtask(_import131(i2.WasmI32.fromInt(self.handle), tmp0))
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<(List<int>, i7.TypesIpSocketAddress), i7.TypesErrorCode>
    tmp36;
    if (tmp1.toBool()) {
      final tmp30 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp35;
      switch (tmp30.toIntUnsigned()) {
        case 0:
          tmp35 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp35 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp35 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp35 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp35 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp35 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp35 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp35 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp35 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp35 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp35 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp35 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp35 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp35 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp31 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp34;
          if (tmp31.toBool()) {
            final tmp32 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp33 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp34 = .some(i0.AllocatedString.read(tmp32, tmp33));
          } else {
            tmp34 = .none;
          }

          tmp35 = i7.TypesErrorCodeOther(tmp34);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp36 = .error(tmp35);
    } else {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 8);

      final tmp6 = tmp2.toIntUnsigned();
      final tmp5 = List.generate(tmp3.toIntUnsigned(), growable: false, (i) {
        final elementPtr = i2.WasmI32.fromInt(tmp6 + i * 1);
        final tmp4 = i0.memory.loadUint8(elementPtr.toIntUnsigned(), offset: 0);

        return tmp4.toIntUnsigned();
      });

      final tmp7 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 12);
      final i7.TypesIpSocketAddress tmp28;
      switch (tmp7.toIntUnsigned()) {
        case 0:
          final tmp8 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 16);
          final tmp9 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 18);
          final tmp10 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 19);
          final tmp11 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 20);
          final tmp12 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 21);
          final tmp13 = (
            tmp9.toIntUnsigned(),
            tmp10.toIntUnsigned(),
            tmp11.toIntUnsigned(),
            tmp12.toIntUnsigned(),
          );
          final tmp14 = (port: tmp8.toIntUnsigned(), address: tmp13);

          tmp28 = i7.TypesIpSocketAddressIpv4(tmp14);
        case 1:
          final tmp15 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 16);
          final tmp16 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 20);
          final tmp17 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 24);
          final tmp18 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 26);
          final tmp19 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 28);
          final tmp20 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 30);
          final tmp21 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 32);
          final tmp22 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 34);
          final tmp23 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 36);
          final tmp24 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 38);
          final tmp25 = (
            tmp17.toIntUnsigned(),
            tmp18.toIntUnsigned(),
            tmp19.toIntUnsigned(),
            tmp20.toIntUnsigned(),
            tmp21.toIntUnsigned(),
            tmp22.toIntUnsigned(),
            tmp23.toIntUnsigned(),
            tmp24.toIntUnsigned(),
          );
          final tmp26 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 40);
          final tmp27 = (
            port: tmp15.toIntUnsigned(),
            flowInfo: tmp16.toIntUnsigned(),
            address: tmp25,
            scopeId: tmp26.toIntUnsigned(),
          );

          tmp28 = i7.TypesIpSocketAddressIpv6(tmp27);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }
      final tmp29 = (tmp5, tmp28);

      tmp36 = .ok(tmp29);
    }

    i0.dartFree(tmp0, const i2.WasmI32(44), const i2.WasmI32(4));
    return tmp36;
  }

  @override
  i0.Result<i7.TypesIpSocketAddress, i7.TypesErrorCode>
  methodUdpSocketGetLocalAddress({
    required i0.Borrowed<i7.TypesUdpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(36));
    _import132(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i7.TypesIpSocketAddress, i7.TypesErrorCode> tmp30;
    if (tmp1.toBool()) {
      final tmp24 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp29;
      switch (tmp24.toIntUnsigned()) {
        case 0:
          tmp29 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp29 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp29 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp29 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp29 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp29 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp29 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp29 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp29 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp29 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp29 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp29 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp29 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp29 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp25 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp28;
          if (tmp25.toBool()) {
            final tmp26 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp27 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp28 = .some(i0.AllocatedString.read(tmp26, tmp27));
          } else {
            tmp28 = .none;
          }

          tmp29 = i7.TypesErrorCodeOther(tmp28);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp30 = .error(tmp29);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesIpSocketAddress tmp23;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          final tmp3 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 8);
          final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 10);
          final tmp5 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 11);
          final tmp6 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 12);
          final tmp7 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 13);
          final tmp8 = (
            tmp4.toIntUnsigned(),
            tmp5.toIntUnsigned(),
            tmp6.toIntUnsigned(),
            tmp7.toIntUnsigned(),
          );
          final tmp9 = (port: tmp3.toIntUnsigned(), address: tmp8);

          tmp23 = i7.TypesIpSocketAddressIpv4(tmp9);
        case 1:
          final tmp10 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 8);
          final tmp11 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
          final tmp12 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 16);
          final tmp13 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 18);
          final tmp14 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 20);
          final tmp15 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 22);
          final tmp16 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 24);
          final tmp17 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 26);
          final tmp18 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 28);
          final tmp19 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 30);
          final tmp20 = (
            tmp12.toIntUnsigned(),
            tmp13.toIntUnsigned(),
            tmp14.toIntUnsigned(),
            tmp15.toIntUnsigned(),
            tmp16.toIntUnsigned(),
            tmp17.toIntUnsigned(),
            tmp18.toIntUnsigned(),
            tmp19.toIntUnsigned(),
          );
          final tmp21 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 32);
          final tmp22 = (
            port: tmp10.toIntUnsigned(),
            flowInfo: tmp11.toIntUnsigned(),
            address: tmp20,
            scopeId: tmp21.toIntUnsigned(),
          );

          tmp23 = i7.TypesIpSocketAddressIpv6(tmp22);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp30 = .ok(tmp23);
    }

    i0.dartFree(tmp0, const i2.WasmI32(36), const i2.WasmI32(4));
    return tmp30;
  }

  @override
  i0.Result<i7.TypesIpSocketAddress, i7.TypesErrorCode>
  methodUdpSocketGetRemoteAddress({
    required i0.Borrowed<i7.TypesUdpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(36));
    _import133(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i7.TypesIpSocketAddress, i7.TypesErrorCode> tmp30;
    if (tmp1.toBool()) {
      final tmp24 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp29;
      switch (tmp24.toIntUnsigned()) {
        case 0:
          tmp29 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp29 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp29 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp29 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp29 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp29 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp29 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp29 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp29 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp29 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp29 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp29 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp29 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp29 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp25 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp28;
          if (tmp25.toBool()) {
            final tmp26 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp27 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp28 = .some(i0.AllocatedString.read(tmp26, tmp27));
          } else {
            tmp28 = .none;
          }

          tmp29 = i7.TypesErrorCodeOther(tmp28);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp30 = .error(tmp29);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesIpSocketAddress tmp23;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          final tmp3 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 8);
          final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 10);
          final tmp5 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 11);
          final tmp6 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 12);
          final tmp7 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 13);
          final tmp8 = (
            tmp4.toIntUnsigned(),
            tmp5.toIntUnsigned(),
            tmp6.toIntUnsigned(),
            tmp7.toIntUnsigned(),
          );
          final tmp9 = (port: tmp3.toIntUnsigned(), address: tmp8);

          tmp23 = i7.TypesIpSocketAddressIpv4(tmp9);
        case 1:
          final tmp10 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 8);
          final tmp11 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
          final tmp12 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 16);
          final tmp13 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 18);
          final tmp14 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 20);
          final tmp15 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 22);
          final tmp16 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 24);
          final tmp17 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 26);
          final tmp18 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 28);
          final tmp19 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 30);
          final tmp20 = (
            tmp12.toIntUnsigned(),
            tmp13.toIntUnsigned(),
            tmp14.toIntUnsigned(),
            tmp15.toIntUnsigned(),
            tmp16.toIntUnsigned(),
            tmp17.toIntUnsigned(),
            tmp18.toIntUnsigned(),
            tmp19.toIntUnsigned(),
          );
          final tmp21 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 32);
          final tmp22 = (
            port: tmp10.toIntUnsigned(),
            flowInfo: tmp11.toIntUnsigned(),
            address: tmp20,
            scopeId: tmp21.toIntUnsigned(),
          );

          tmp23 = i7.TypesIpSocketAddressIpv6(tmp22);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp30 = .ok(tmp23);
    }

    i0.dartFree(tmp0, const i2.WasmI32(36), const i2.WasmI32(4));
    return tmp30;
  }

  @override
  i7.TypesIpAddressFamily methodUdpSocketGetAddressFamily({
    required i0.Borrowed<i7.TypesUdpSocket> self,
  }) {
    final tmp0 = _import134(i2.WasmI32.fromInt(self.handle));
    return i7.TypesIpAddressFamily.values[tmp0.toIntUnsigned()];
  }

  @override
  i0.Result<int, i7.TypesErrorCode> methodUdpSocketGetUnicastHopLimit({
    required i0.Borrowed<i7.TypesUdpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import135(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i7.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp7;
          if (tmp4.toBool()) {
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp6 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp7 = .some(i0.AllocatedString.read(tmp5, tmp6));
          } else {
            tmp7 = .none;
          }

          tmp8 = i7.TypesErrorCodeOther(tmp7);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp9 = .error(tmp8);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);

      tmp9 = .ok(tmp2.toIntUnsigned());
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp9;
  }

  @override
  i0.Result<void, i7.TypesErrorCode> methodUdpSocketSetUnicastHopLimit({
    required i0.Borrowed<i7.TypesUdpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import136(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI32.uint8FromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i7.TypesErrorCodeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp8 = .error(tmp7);
    } else {
      tmp8 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp8;
  }

  @override
  i0.Result<int, i7.TypesErrorCode> methodUdpSocketGetReceiveBufferSize({
    required i0.Borrowed<i7.TypesUdpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(24));
    _import137(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i7.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i7.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 12);
          final i0.Option<String> tmp7;
          if (tmp4.toBool()) {
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);
            final tmp6 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 20);

            tmp7 = .some(i0.AllocatedString.read(tmp5, tmp6));
          } else {
            tmp7 = .none;
          }

          tmp8 = i7.TypesErrorCodeOther(tmp7);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp9 = .error(tmp8);
    } else {
      final tmp2 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 8);

      tmp9 = .ok(tmp2.toInt());
    }

    i0.dartFree(tmp0, const i2.WasmI32(24), const i2.WasmI32(8));
    return tmp9;
  }

  @override
  i0.Result<void, i7.TypesErrorCode> methodUdpSocketSetReceiveBufferSize({
    required i0.Borrowed<i7.TypesUdpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import138(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI64.fromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i7.TypesErrorCodeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp8 = .error(tmp7);
    } else {
      tmp8 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp8;
  }

  @override
  i0.Result<int, i7.TypesErrorCode> methodUdpSocketGetSendBufferSize({
    required i0.Borrowed<i7.TypesUdpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(24));
    _import139(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i7.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i7.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 12);
          final i0.Option<String> tmp7;
          if (tmp4.toBool()) {
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);
            final tmp6 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 20);

            tmp7 = .some(i0.AllocatedString.read(tmp5, tmp6));
          } else {
            tmp7 = .none;
          }

          tmp8 = i7.TypesErrorCodeOther(tmp7);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp9 = .error(tmp8);
    } else {
      final tmp2 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 8);

      tmp9 = .ok(tmp2.toInt());
    }

    i0.dartFree(tmp0, const i2.WasmI32(24), const i2.WasmI32(8));
    return tmp9;
  }

  @override
  i0.Result<void, i7.TypesErrorCode> methodUdpSocketSetSendBufferSize({
    required i0.Borrowed<i7.TypesUdpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import140(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI64.fromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i7.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i7.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i7.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i7.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i7.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i7.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i7.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i7.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i7.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i7.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i7.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i7.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i7.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i7.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i7.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i7.TypesErrorCodeDatagramTooLarge();
        case 14:
          final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp6;
          if (tmp3.toBool()) {
            final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
            final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

            tmp6 = .some(i0.AllocatedString.read(tmp4, tmp5));
          } else {
            tmp6 = .none;
          }

          tmp7 = i7.TypesErrorCodeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp8 = .error(tmp7);
    } else {
      tmp8 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp8;
  }
}

@pragma("wasm:import", r"component._import141")
external i2.WasmI32 _import141(i2.WasmI32 p0, i2.WasmI32 p1, i2.WasmI32 p2);

final class _Imported$8 implements i7.IpNameLookup {
  const _Imported$8();
  @override
  Future<i0.Result<List<i7.TypesIpAddress>, i7.IpNameLookupErrorCode>>
  resolveAddresses({required String name}) async {
    final tmp0 = i0.AllocatedString.allocateUtf16(name);
    var tmp1 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(_import141(tmp0.ptr, tmp0.packedLength, tmp1))
        .completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<List<i7.TypesIpAddress>, i7.IpNameLookupErrorCode> tmp29;
    if (tmp2.toBool()) {
      final tmp23 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 4);
      final i7.IpNameLookupErrorCode tmp28;
      switch (tmp23.toIntUnsigned()) {
        case 0:
          tmp28 = i7.IpNameLookupErrorCodeAccessDenied();
        case 1:
          tmp28 = i7.IpNameLookupErrorCodeInvalidArgument();
        case 2:
          tmp28 = i7.IpNameLookupErrorCodeNameUnresolvable();
        case 3:
          tmp28 = i7.IpNameLookupErrorCodeTemporaryResolverFailure();
        case 4:
          tmp28 = i7.IpNameLookupErrorCodePermanentResolverFailure();
        case 5:
          final tmp24 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 8);
          final i0.Option<String> tmp27;
          if (tmp24.toBool()) {
            final tmp25 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 12);
            final tmp26 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 16);

            tmp27 = .some(i0.AllocatedString.read(tmp25, tmp26));
          } else {
            tmp27 = .none;
          }

          tmp28 = i7.IpNameLookupErrorCodeOther(tmp27);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp29 = .error(tmp28);
    } else {
      final tmp3 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 4);
      final tmp4 = i0.memory.loadInt32(tmp1.toIntUnsigned(), offset: 8);

      final tmp22 = tmp3.toIntUnsigned();
      final tmp21 = List.generate(tmp4.toIntUnsigned(), growable: false, (i) {
        final elementPtr = i2.WasmI32.fromInt(tmp22 + i * 18);
        final tmp5 = i0.memory.loadUint8(elementPtr.toIntUnsigned(), offset: 0);
        final i7.TypesIpAddress tmp20;
        switch (tmp5.toIntUnsigned()) {
          case 0:
            final tmp6 = i0.memory.loadUint8(
              elementPtr.toIntUnsigned(),
              offset: 2,
            );
            final tmp7 = i0.memory.loadUint8(
              elementPtr.toIntUnsigned(),
              offset: 3,
            );
            final tmp8 = i0.memory.loadUint8(
              elementPtr.toIntUnsigned(),
              offset: 4,
            );
            final tmp9 = i0.memory.loadUint8(
              elementPtr.toIntUnsigned(),
              offset: 5,
            );
            final tmp10 = (
              tmp6.toIntUnsigned(),
              tmp7.toIntUnsigned(),
              tmp8.toIntUnsigned(),
              tmp9.toIntUnsigned(),
            );

            tmp20 = i7.TypesIpAddressIpv4(tmp10);
          case 1:
            final tmp11 = i0.memory.loadUint16(
              elementPtr.toIntUnsigned(),
              offset: 2,
            );
            final tmp12 = i0.memory.loadUint16(
              elementPtr.toIntUnsigned(),
              offset: 4,
            );
            final tmp13 = i0.memory.loadUint16(
              elementPtr.toIntUnsigned(),
              offset: 6,
            );
            final tmp14 = i0.memory.loadUint16(
              elementPtr.toIntUnsigned(),
              offset: 8,
            );
            final tmp15 = i0.memory.loadUint16(
              elementPtr.toIntUnsigned(),
              offset: 10,
            );
            final tmp16 = i0.memory.loadUint16(
              elementPtr.toIntUnsigned(),
              offset: 12,
            );
            final tmp17 = i0.memory.loadUint16(
              elementPtr.toIntUnsigned(),
              offset: 14,
            );
            final tmp18 = i0.memory.loadUint16(
              elementPtr.toIntUnsigned(),
              offset: 16,
            );
            final tmp19 = (
              tmp11.toIntUnsigned(),
              tmp12.toIntUnsigned(),
              tmp13.toIntUnsigned(),
              tmp14.toIntUnsigned(),
              tmp15.toIntUnsigned(),
              tmp16.toIntUnsigned(),
              tmp17.toIntUnsigned(),
              tmp18.toIntUnsigned(),
            );

            tmp20 = i7.TypesIpAddressIpv6(tmp19);

          default:
            throw ArgumentError('Invalid discrimant value for variant');
        }

        return tmp20;
      });

      tmp29 = .ok(tmp21);
    }

    i0.dartFree(tmp1, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp29;
  }
}

@pragma("wasm:import", r"component._import142")
external i2.WasmVoid _import142(i2.WasmI64 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import143")
external i2.WasmI64 _import143();

final class _Imported$9 implements i8.Random {
  const _Imported$9();
  @override
  List<int> getRandomBytes({required int maxLen}) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import142(i2.WasmI64.fromInt(maxLen), tmp0);
    final tmp1 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);

    final tmp5 = tmp1.toIntUnsigned();
    final tmp4 = List.generate(tmp2.toIntUnsigned(), growable: false, (i) {
      final elementPtr = i2.WasmI32.fromInt(tmp5 + i * 1);
      final tmp3 = i0.memory.loadUint8(elementPtr.toIntUnsigned(), offset: 0);

      return tmp3.toIntUnsigned();
    });

    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp4;
  }

  @override
  int getRandomU64() {
    final tmp0 = _import143();
    return tmp0.toInt();
  }
}

@pragma("wasm:import", r"component._import144")
external i2.WasmVoid _import144(i2.WasmI64 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import145")
external i2.WasmI64 _import145();

final class _Imported$10 implements i8.Insecure {
  const _Imported$10();
  @override
  List<int> getInsecureRandomBytes({required int maxLen}) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import144(i2.WasmI64.fromInt(maxLen), tmp0);
    final tmp1 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);

    final tmp5 = tmp1.toIntUnsigned();
    final tmp4 = List.generate(tmp2.toIntUnsigned(), growable: false, (i) {
      final elementPtr = i2.WasmI32.fromInt(tmp5 + i * 1);
      final tmp3 = i0.memory.loadUint8(elementPtr.toIntUnsigned(), offset: 0);

      return tmp3.toIntUnsigned();
    });

    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp4;
  }

  @override
  int getInsecureRandomU64() {
    final tmp0 = _import145();
    return tmp0.toInt();
  }
}

@pragma("wasm:import", r"component._import146")
external i2.WasmVoid _import146(i2.WasmI32 p0);

final class _Imported$11 implements i8.InsecureSeed {
  const _Imported$11();
  @override
  (int, int) getInsecureSeed() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(16));
    _import146(tmp0);
    final tmp1 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 8);
    final tmp3 = (tmp1.toInt(), tmp2.toInt());
    i0.dartFree(tmp0, const i2.WasmI32(16), const i2.WasmI32(8));
    return tmp3;
  }
}

late i3.Run _unnamedExport14;

final class TuiSpikeImports {
  const TuiSpikeImports._();

  i1.Tty get termTty => const _Imported$0();
  i3.Environment get cliEnvironment => const _Imported$12();
  i3.Exit get cliExit => const _Imported$13();
  i3.Stdin get cliStdin => const _Imported$16();
  i3.Stdout get cliStdout => const _Imported$17();
  i3.Stderr get cliStderr => const _Imported$18();
  i3.TerminalStdin get cliTerminalStdin => const _Imported$21();
  i3.TerminalStdout get cliTerminalStdout => const _Imported$22();
  i3.TerminalStderr get cliTerminalStderr => const _Imported$23();
  i5.MonotonicClock get clocksMonotonicClock => const _Imported$2();
  i5.SystemClock get clocksSystemClock => const _Imported$3();
  i6.Types get filesystemTypes => const _Imported$5();
  i6.Preopens get filesystemPreopens => const _Imported$6();
  i7.Types get socketsTypes => const _Imported$7();
  i7.IpNameLookup get socketsIpNameLookup => const _Imported$8();
  i8.Random get randomRandom => const _Imported$9();
  i8.Insecure get randomInsecure => const _Imported$10();
  i8.InsecureSeed get randomInsecureSeed => const _Imported$11();
}

@i9.RecordUse()
void tuiSpikeComponent(i3.Run Function(TuiSpikeImports) defineComponent) {
  final res = defineComponent(const TuiSpikeImports._());
  _unnamedExport14 = res;
}

@pragma('wasm:export', r'component_0')
i2.WasmI32 _component_0() {
  final asyncExitCode = i0.spawnTask(
    run: () async {
      final tmp0 = await _unnamedExport14.run();
      i2.WasmI32 tmp1;
      switch (tmp0) {
        case i0.OkResult(:final value):
          tmp1 = const i2.WasmI32(0);

        case i0.ErrorResult(:final value):
          tmp1 = const i2.WasmI32(1);
      }
      _component_0taskReturn(tmp1);
    },
    debugName: 'run',
  );
  return asyncExitCode.toWasmI32();
}

@pragma('wasm:import', 'component._component_0taskReturn')
external i2.WasmVoid _component_0taskReturn(i2.WasmI32 p0);
