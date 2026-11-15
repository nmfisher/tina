// ignore_for_file: type=warning
import r'package:wasm_components/wasm_components.dart' as i0;

import r'tina_term.dart' as i1;

// ignore: import_internal_library
import r'dart:_wasm' as i2;

import r'tina_layout.dart' as i3;
import r'tina_http.dart' as i4;

import r'dart:typed_data' as i5;

import r'tina_plugin_host.dart' as i6;
import r'tina_policy.dart' as i7;
import r'tina_process.dart' as i8;
import r'wasi_cli.dart' as i9;
import r'wasi_clocks.dart' as i10;
import r'wasi_filesystem.dart' as i11;
import r'wasi_sockets.dart' as i12;
import r'wasi_random.dart' as i13;

import r'package:meta/meta.dart' as i14;

@pragma("wasm:import", r"component._import0")
external i2.WasmVoid _import0(i2.WasmI32 p0);

final class _Imported$35 implements i1.Tty {
  const _Imported$35();
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
external i2.WasmVoid _import1(i2.WasmI32 p0, i2.WasmI32 p1);

final class _Imported$36 implements i1.Crash {
  const _Imported$36();
  @override
  void fail({required String message}) {
    final tmp0 = i0.AllocatedString.allocateUtf16(message);
    _import1(tmp0.ptr, tmp0.packedLength);
    tmp0.free();
  }
}

final class _Imported$2 implements i3.Types {
  const _Imported$2();
}

@pragma("wasm:import", r"component._import2")
external i2.WasmVoid _import2(i2.WasmI32 p0);
@pragma("wasm:import", r"component._import3")
external i2.WasmVoid _import3(
  i2.WasmI32 p0,
  i2.WasmI32 p1,
  i2.WasmI32 p2,
  i2.WasmI32 p3,
  i2.WasmI32 p4,
  i2.WasmI32 p5,
  i2.WasmI32 p6,
  i2.WasmI32 p7,
  i2.WasmF64 p8,
  i2.WasmI32 p9,
);

final class _Imported$4 implements i3.Bridge {
  const _Imported$4();
  @override
  i0.Option<({String id, String version, String description})> describe() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(28));
    _import2(tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Option<({String id, String version, String description})> tmp9;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 8);
      final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
      final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);
      final tmp6 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 20);
      final tmp7 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 24);
      final tmp8 = (
        id: i0.AllocatedString.read(tmp2, tmp3),
        version: i0.AllocatedString.read(tmp4, tmp5),
        description: i0.AllocatedString.read(tmp6, tmp7),
      );

      tmp9 = .some(tmp8);
    } else {
      tmp9 = .none;
    }

    i0.dartFree(tmp0, const i2.WasmI32(28), const i2.WasmI32(4));
    return tmp9;
  }

  @override
  i0.Result<
    ({
      int columns,
      int rows,
      ({double rowsPerUnit}) metrics,
      List<({String id, ({int col, int row, int width, int height}) rect})>
      rects,
      List<double> columnTrackSizes,
      List<double> rowTrackSizes,
      List<({String id, String reason})> dropped,
      double overflowUnitsX,
      double overflowUnitsY,
      double trailingGapUnitsX,
      double trailingGapUnitsY,
    }),
    i3.BridgeFallback
  >
  solve({
    required ({
      List<
        ({
          i3.TypesTrackKind kind,
          double sizeUnits,
          double weight,
          double minUnits,
          i0.Option<double> maxUnits,
        })
      >
      columns,
      List<
        ({
          i3.TypesTrackKind kind,
          double sizeUnits,
          double weight,
          double minUnits,
          i0.Option<double> maxUnits,
        })
      >
      rows,
      List<
        ({
          String id,
          ({i0.Option<int> start, int span}) column,
          ({i0.Option<int> start, int span}) row,
          double minWidthUnits,
          double minHeightUnits,
          i0.Option<double> maxWidthUnits,
          i0.Option<double> maxHeightUnits,
          i0.Option<double> aspectHint,
          int priority,
        })
      >
      items,
    })
    spec,
    required int columns,
    required int rows,
    required ({double rowsPerUnit}) metrics,
  }) {
    final tmp1 = i2.WasmI32.fromInt(48 * spec.columns.length);
    final tmp2 = i0.mallocAligned(const i2.WasmI32(8), tmp1);
    var tmp3 = tmp2;
    for (final element in spec.columns) {
      final elementPtr = tmp3;
      i0.memory.storeInt8(
        elementPtr.toIntUnsigned(),
        element.kind.index.toWasmI32(),
        offset: 0,
      );
      i0.memory.storeFloat64(
        elementPtr.toIntUnsigned(),
        i2.WasmF64.fromDouble(element.sizeUnits),
        offset: 8,
      );
      i0.memory.storeFloat64(
        elementPtr.toIntUnsigned(),
        i2.WasmF64.fromDouble(element.weight),
        offset: 16,
      );
      i0.memory.storeFloat64(
        elementPtr.toIntUnsigned(),
        i2.WasmF64.fromDouble(element.minUnits),
        offset: 24,
      );
      final tmp0 = element.maxUnits;
      if (tmp0.hasValue) {
        final value = tmp0.requireValue();
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 32,
        );
        i0.memory.storeFloat64(
          elementPtr.toIntUnsigned(),
          i2.WasmF64.fromDouble(value),
          offset: 40,
        );
      } else {
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 32,
        );
      }

      tmp3 += const i2.WasmI32(48);
    }

    final tmp5 = i2.WasmI32.fromInt(48 * spec.rows.length);
    final tmp6 = i0.mallocAligned(const i2.WasmI32(8), tmp5);
    var tmp7 = tmp6;
    for (final element in spec.rows) {
      final elementPtr = tmp7;
      i0.memory.storeInt8(
        elementPtr.toIntUnsigned(),
        element.kind.index.toWasmI32(),
        offset: 0,
      );
      i0.memory.storeFloat64(
        elementPtr.toIntUnsigned(),
        i2.WasmF64.fromDouble(element.sizeUnits),
        offset: 8,
      );
      i0.memory.storeFloat64(
        elementPtr.toIntUnsigned(),
        i2.WasmF64.fromDouble(element.weight),
        offset: 16,
      );
      i0.memory.storeFloat64(
        elementPtr.toIntUnsigned(),
        i2.WasmF64.fromDouble(element.minUnits),
        offset: 24,
      );
      final tmp4 = element.maxUnits;
      if (tmp4.hasValue) {
        final value = tmp4.requireValue();
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 32,
        );
        i0.memory.storeFloat64(
          elementPtr.toIntUnsigned(),
          i2.WasmF64.fromDouble(value),
          offset: 40,
        );
      } else {
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 32,
        );
      }

      tmp7 += const i2.WasmI32(48);
    }

    final tmp17 = <void Function()>[];

    final tmp14 = i2.WasmI32.fromInt(104 * spec.items.length);
    final tmp15 = i0.mallocAligned(const i2.WasmI32(8), tmp14);
    var tmp16 = tmp15;
    for (final element in spec.items) {
      final elementPtr = tmp16;
      final tmp8 = i0.AllocatedString.allocateUtf16(element.id);
      i0.memory.storeInt32(
        elementPtr.toIntUnsigned(),
        tmp8.packedLength,
        offset: 4,
      );
      i0.memory.storeInt32(elementPtr.toIntUnsigned(), tmp8.ptr, offset: 0);
      final tmp9 = element.column.start;
      if (tmp9.hasValue) {
        final value = tmp9.requireValue();
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 8,
        );
        i0.memory.storeInt32(
          elementPtr.toIntUnsigned(),
          i2.WasmI32.fromInt(value),
          offset: 12,
        );
      } else {
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 8,
        );
      }
      i0.memory.storeInt32(
        elementPtr.toIntUnsigned(),
        i2.WasmI32.fromInt(element.column.span),
        offset: 16,
      );
      final tmp10 = element.row.start;
      if (tmp10.hasValue) {
        final value = tmp10.requireValue();
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 20,
        );
        i0.memory.storeInt32(
          elementPtr.toIntUnsigned(),
          i2.WasmI32.fromInt(value),
          offset: 24,
        );
      } else {
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 20,
        );
      }
      i0.memory.storeInt32(
        elementPtr.toIntUnsigned(),
        i2.WasmI32.fromInt(element.row.span),
        offset: 28,
      );
      i0.memory.storeFloat64(
        elementPtr.toIntUnsigned(),
        i2.WasmF64.fromDouble(element.minWidthUnits),
        offset: 32,
      );
      i0.memory.storeFloat64(
        elementPtr.toIntUnsigned(),
        i2.WasmF64.fromDouble(element.minHeightUnits),
        offset: 40,
      );
      final tmp11 = element.maxWidthUnits;
      if (tmp11.hasValue) {
        final value = tmp11.requireValue();
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 48,
        );
        i0.memory.storeFloat64(
          elementPtr.toIntUnsigned(),
          i2.WasmF64.fromDouble(value),
          offset: 56,
        );
      } else {
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 48,
        );
      }
      final tmp12 = element.maxHeightUnits;
      if (tmp12.hasValue) {
        final value = tmp12.requireValue();
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 64,
        );
        i0.memory.storeFloat64(
          elementPtr.toIntUnsigned(),
          i2.WasmF64.fromDouble(value),
          offset: 72,
        );
      } else {
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 64,
        );
      }
      final tmp13 = element.aspectHint;
      if (tmp13.hasValue) {
        final value = tmp13.requireValue();
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 80,
        );
        i0.memory.storeFloat64(
          elementPtr.toIntUnsigned(),
          i2.WasmF64.fromDouble(value),
          offset: 88,
        );
      } else {
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 80,
        );
      }
      i0.memory.storeInt32(
        elementPtr.toIntUnsigned(),
        i2.WasmI32.fromInt(element.priority),
        offset: 96,
      );

      tmp16 += const i2.WasmI32(104);
      tmp17.add(() {
        tmp8.free();
      });
    }

    var tmp18 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(88));
    _import3(
      tmp2,
      i2.WasmI32.fromInt(spec.columns.length),
      tmp6,
      i2.WasmI32.fromInt(spec.rows.length),
      tmp15,
      i2.WasmI32.fromInt(spec.items.length),
      i2.WasmI32.fromInt(columns),
      i2.WasmI32.fromInt(rows),
      i2.WasmF64.fromDouble(metrics.rowsPerUnit),
      tmp18,
    );
    final tmp19 = i0.memory.loadUint8(tmp18.toIntUnsigned(), offset: 0);
    final i0.Result<
      ({
        int columns,
        int rows,
        ({double rowsPerUnit}) metrics,
        List<({String id, ({int col, int row, int width, int height}) rect})>
        rects,
        List<double> columnTrackSizes,
        List<double> rowTrackSizes,
        List<({String id, String reason})> dropped,
        double overflowUnitsX,
        double overflowUnitsY,
        double trailingGapUnitsX,
        double trailingGapUnitsY,
      }),
      i3.BridgeFallback
    >
    tmp66;
    if (tmp19.toBool()) {
      final tmp60 = i0.memory.loadUint8(tmp18.toIntUnsigned(), offset: 8);
      final i3.BridgeFallback tmp65;
      switch (tmp60.toIntUnsigned()) {
        case 0:
          tmp65 = i3.BridgeFallbackNoPlugin();
        case 1:
          final tmp61 = i0.memory.loadInt32(tmp18.toIntUnsigned(), offset: 12);
          final tmp62 = i0.memory.loadInt32(tmp18.toIntUnsigned(), offset: 16);

          tmp65 = i3.BridgeFallbackPluginError(
            i0.AllocatedString.read(tmp61, tmp62),
          );
        case 2:
          final tmp63 = i0.memory.loadInt32(tmp18.toIntUnsigned(), offset: 12);
          final tmp64 = i0.memory.loadInt32(tmp18.toIntUnsigned(), offset: 16);

          tmp65 = i3.BridgeFallbackPluginTimeout(
            i0.AllocatedString.read(tmp63, tmp64),
          );

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp66 = .error(tmp65);
    } else {
      final tmp20 = i0.memory.loadInt32(tmp18.toIntUnsigned(), offset: 8);
      final tmp21 = i0.memory.loadInt32(tmp18.toIntUnsigned(), offset: 12);
      final tmp22 = i0.memory.loadFloat64(tmp18.toIntUnsigned(), offset: 16);
      final tmp23 = (rowsPerUnit: tmp22.toDouble());
      final tmp24 = i0.memory.loadInt32(tmp18.toIntUnsigned(), offset: 24);
      final tmp25 = i0.memory.loadInt32(tmp18.toIntUnsigned(), offset: 28);

      final tmp35 = tmp24.toIntUnsigned();
      final tmp34 = List.generate(tmp25.toIntUnsigned(), growable: false, (i) {
        final elementPtr = i2.WasmI32.fromInt(tmp35 + i * 24);
        final tmp26 = i0.memory.loadInt32(
          elementPtr.toIntUnsigned(),
          offset: 0,
        );
        final tmp27 = i0.memory.loadInt32(
          elementPtr.toIntUnsigned(),
          offset: 4,
        );
        final tmp28 = i0.memory.loadInt32(
          elementPtr.toIntUnsigned(),
          offset: 8,
        );
        final tmp29 = i0.memory.loadInt32(
          elementPtr.toIntUnsigned(),
          offset: 12,
        );
        final tmp30 = i0.memory.loadInt32(
          elementPtr.toIntUnsigned(),
          offset: 16,
        );
        final tmp31 = i0.memory.loadInt32(
          elementPtr.toIntUnsigned(),
          offset: 20,
        );
        final tmp32 = (
          col: tmp28.toIntSigned(),
          row: tmp29.toIntSigned(),
          width: tmp30.toIntSigned(),
          height: tmp31.toIntSigned(),
        );
        final tmp33 = (id: i0.AllocatedString.read(tmp26, tmp27), rect: tmp32);

        return tmp33;
      });

      final tmp36 = i0.memory.loadInt32(tmp18.toIntUnsigned(), offset: 32);
      final tmp37 = i0.memory.loadInt32(tmp18.toIntUnsigned(), offset: 36);

      final tmp40 = tmp36.toIntUnsigned();
      final tmp39 = List.generate(tmp37.toIntUnsigned(), growable: false, (i) {
        final elementPtr = i2.WasmI32.fromInt(tmp40 + i * 8);
        final tmp38 = i0.memory.loadFloat64(
          elementPtr.toIntUnsigned(),
          offset: 0,
        );

        return tmp38.toDouble();
      });

      final tmp41 = i0.memory.loadInt32(tmp18.toIntUnsigned(), offset: 40);
      final tmp42 = i0.memory.loadInt32(tmp18.toIntUnsigned(), offset: 44);

      final tmp45 = tmp41.toIntUnsigned();
      final tmp44 = List.generate(tmp42.toIntUnsigned(), growable: false, (i) {
        final elementPtr = i2.WasmI32.fromInt(tmp45 + i * 8);
        final tmp43 = i0.memory.loadFloat64(
          elementPtr.toIntUnsigned(),
          offset: 0,
        );

        return tmp43.toDouble();
      });

      final tmp46 = i0.memory.loadInt32(tmp18.toIntUnsigned(), offset: 48);
      final tmp47 = i0.memory.loadInt32(tmp18.toIntUnsigned(), offset: 52);

      final tmp54 = tmp46.toIntUnsigned();
      final tmp53 = List.generate(tmp47.toIntUnsigned(), growable: false, (i) {
        final elementPtr = i2.WasmI32.fromInt(tmp54 + i * 16);
        final tmp48 = i0.memory.loadInt32(
          elementPtr.toIntUnsigned(),
          offset: 0,
        );
        final tmp49 = i0.memory.loadInt32(
          elementPtr.toIntUnsigned(),
          offset: 4,
        );
        final tmp50 = i0.memory.loadInt32(
          elementPtr.toIntUnsigned(),
          offset: 8,
        );
        final tmp51 = i0.memory.loadInt32(
          elementPtr.toIntUnsigned(),
          offset: 12,
        );
        final tmp52 = (
          id: i0.AllocatedString.read(tmp48, tmp49),
          reason: i0.AllocatedString.read(tmp50, tmp51),
        );

        return tmp52;
      });

      final tmp55 = i0.memory.loadFloat64(tmp18.toIntUnsigned(), offset: 56);
      final tmp56 = i0.memory.loadFloat64(tmp18.toIntUnsigned(), offset: 64);
      final tmp57 = i0.memory.loadFloat64(tmp18.toIntUnsigned(), offset: 72);
      final tmp58 = i0.memory.loadFloat64(tmp18.toIntUnsigned(), offset: 80);
      final tmp59 = (
        columns: tmp20.toIntUnsigned(),
        rows: tmp21.toIntUnsigned(),
        metrics: tmp23,
        rects: tmp34,
        columnTrackSizes: tmp39,
        rowTrackSizes: tmp44,
        dropped: tmp53,
        overflowUnitsX: tmp55.toDouble(),
        overflowUnitsY: tmp56.toDouble(),
        trailingGapUnitsX: tmp57.toDouble(),
        trailingGapUnitsY: tmp58.toDouble(),
      );

      tmp66 = .ok(tmp59);
    }

    i0.dartFree(tmp2, tmp1, const i2.WasmI32(8));
    i0.dartFree(tmp6, tmp5, const i2.WasmI32(8));
    for (final f in tmp17) {
      f();
    }
    i0.dartFree(tmp15, tmp14, const i2.WasmI32(8));
    i0.dartFree(tmp18, const i2.WasmI32(88), const i2.WasmI32(8));
    return tmp66;
  }
}

final class _Imported$0 implements i4.Types {
  const _Imported$0();
}

@pragma('wasm:import', 'component.stream8.new')
external i2.WasmI64 _streamNew8();
@pragma('wasm:import', 'component.stream8.read')
external i2.WasmI32 _streamRead8(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream8.write')
external i2.WasmI32 _streamWrite8(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream8.drop-readable')
external i2.WasmVoid _streamDropReadable8(i2.WasmI32 stream);
@pragma('wasm:import', 'component.stream8.drop-writable')
external i2.WasmVoid _streamDropWritable8(i2.WasmI32 stream);

final class _Vtable8 implements i0.StreamVtable<i5.Uint8List> {
  const _Vtable8();

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
  void writeToBuffer(int address, i5.Uint8List elements) {
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
  i5.Uint8List readFromBuffer(int address, int count) {
    final typedList = i5.Uint8List(count);
    for (var i = 0; i < count; i++) {
      final ptr = i2.WasmI32.fromInt(address + i * 1);
      final tmp0 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 0);

      typedList[i] = tmp0.toIntUnsigned();
    }
    return typedList;
  }

  @override
  int newStream() => _streamNew8().toInt();
  @override
  void dropReadable(int stream) {
    _streamDropReadable8(i2.WasmI32.fromInt(stream));
  }

  @override
  void dropWritable(int stream) {
    _streamDropWritable8(i2.WasmI32.fromInt(stream));
  }

  @override
  int read(int stream, int ptr, int n) {
    return _streamRead8(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }

  @override
  int write(int stream, int ptr, int n) {
    return _streamWrite8(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }
}

@pragma('wasm:import', 'component.future10.new')
external i2.WasmI64 _futureNew10();
@pragma('wasm:import', 'component.future10.write')
external i2.WasmI32 _futureWrite10(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future10.read')
external i2.WasmI32 _futureRead10(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future10.drop-readable')
external i2.WasmVoid _futureDropReadable10(i2.WasmI32 future);
@pragma('wasm:import', 'component.future10.drop-writable')
external i2.WasmVoid _futureDropWritable10(i2.WasmI32 future);

final class _Vtable10
    implements i0.FutureVtable<i0.Result<void, i4.TypesError>> {
  const _Vtable10();

  @override
  int newFuture() => _futureNew10().toInt();

  @override
  int read(int future, int buffer) {
    return _futureRead10(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  int write(int future, int buffer) {
    return _futureWrite10(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  void dropRead(int future) {
    _futureDropReadable10(i2.WasmI32.fromInt(future));
  }

  @override
  void dropWrite(int future) {
    _futureDropWritable10(i2.WasmI32.fromInt(future));
  }

  @override
  int allocateBuffer() {
    return i0
        .mallocAligned(const i2.WasmI32(4), const i2.WasmI32(16))
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
              final tmp2 = i0.memory.loadInt32(ptr.toIntUnsigned(), offset: 8);
              final tmp3 = i0.memory.loadInt32(ptr.toIntUnsigned(), offset: 12);
              i0.AllocatedString(tmp2, tmp3).free();
              break;
          }
          break;
      }
    }
    i0.dartFree(address.toWasmI32(), const i2.WasmI32(16), const i2.WasmI32(4));
  }

  @override
  void store(int address, i0.Result<void, i4.TypesError> value) {
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
          case i4.TypesErrorMessage(payload: final value):
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(0),
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
        }
    }
  }

  @override
  i0.Result<void, i4.TypesError> load(int address) {
    final wasmAddress = i2.WasmI32.fromInt(address);

    final tmp0 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 0);
    final i0.Result<void, i4.TypesError> tmp5;
    if (tmp0.toBool()) {
      final tmp1 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 4);
      final i4.TypesError tmp4;
      switch (tmp1.toIntUnsigned()) {
        case 0:
          final tmp2 = i0.memory.loadInt32(
            wasmAddress.toIntUnsigned(),
            offset: 8,
          );
          final tmp3 = i0.memory.loadInt32(
            wasmAddress.toIntUnsigned(),
            offset: 12,
          );

          tmp4 = i4.TypesErrorMessage(i0.AllocatedString.read(tmp2, tmp3));

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp5 = .error(tmp4);
    } else {
      tmp5 = .ok(null);
    }

    return tmp5;
  }
}

@pragma("wasm:import", r"component._import14")
external i2.WasmI32 _import14(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import15")
external i2.WasmI32 _import15(i2.WasmI64 p0, i2.WasmI32 p1, i2.WasmI32 p2);

final class _Imported$1 implements i4.Client {
  const _Imported$1();
  @override
  Future<i0.Result<i4.TypesOutcome, i4.TypesError>> send({
    required ({
      String method,
      String url,
      List<(String, String)> headers,
      i0.Option<List<int>> body,
    })
    req,
  }) async {
    final tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(36));
    final tmp1 = i0.AllocatedString.allocateUtf16(req.method);
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      tmp1.packedLength,
      offset: 4,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      tmp1.ptr,
      offset: 0,
    );
    final tmp2 = i0.AllocatedString.allocateUtf16(req.url);
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      tmp2.packedLength,
      offset: 12,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      tmp2.ptr,
      offset: 8,
    );

    final tmp5 = i2.WasmI32.fromInt(16 * req.headers.length);
    final tmp6 = i0.mallocAligned(const i2.WasmI32(4), tmp5);
    var tmp7 = tmp6;
    for (final element in req.headers) {
      final elementPtr = tmp7;
      final tmp3 = i0.AllocatedString.allocateUtf16(element.$1);
      i0.memory.storeInt32(
        elementPtr.toIntUnsigned(),
        tmp3.packedLength,
        offset: 4,
      );
      i0.memory.storeInt32(elementPtr.toIntUnsigned(), tmp3.ptr, offset: 0);
      final tmp4 = i0.AllocatedString.allocateUtf16(element.$2);
      i0.memory.storeInt32(
        elementPtr.toIntUnsigned(),
        tmp4.packedLength,
        offset: 12,
      );
      i0.memory.storeInt32(elementPtr.toIntUnsigned(), tmp4.ptr, offset: 8);

      tmp7 += const i2.WasmI32(16);
    }

    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      i2.WasmI32.fromInt(req.headers.length),
      offset: 20,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      tmp6,
      offset: 16,
    );
    final tmp11 = req.body;
    if (tmp11.hasValue) {
      final value = tmp11.requireValue();
      i0.memory.storeInt8(
        (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
        const i2.WasmI32(1),
        offset: 24,
      );

      final tmp8 = i2.WasmI32.fromInt(1 * value.length);
      final tmp9 = i0.mallocAligned(const i2.WasmI32(1), tmp8);
      var tmp10 = tmp9;
      for (final element in value) {
        final elementPtr = tmp10;
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          i2.WasmI32.uint8FromInt(element),
          offset: 0,
        );

        tmp10 += const i2.WasmI32(1);
      }

      i0.memory.storeInt32(
        (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
        i2.WasmI32.fromInt(value.length),
        offset: 32,
      );
      i0.memory.storeInt32(
        (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
        tmp9,
        offset: 28,
      );
    } else {
      i0.memory.storeInt8(
        (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
        const i2.WasmI32(0),
        offset: 24,
      );
    }
    var tmp12 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(40));
    await i0.createSubtask(_import14(tmp0, tmp12)).completion;
    final tmp13 = i0.memory.loadUint8(tmp12.toIntUnsigned(), offset: 0);
    final i0.Result<i4.TypesOutcome, i4.TypesError> tmp44;
    if (tmp13.toBool()) {
      final tmp40 = i0.memory.loadUint8(tmp12.toIntUnsigned(), offset: 8);
      final i4.TypesError tmp43;
      switch (tmp40.toIntUnsigned()) {
        case 0:
          final tmp41 = i0.memory.loadInt32(tmp12.toIntUnsigned(), offset: 12);
          final tmp42 = i0.memory.loadInt32(tmp12.toIntUnsigned(), offset: 16);

          tmp43 = i4.TypesErrorMessage(i0.AllocatedString.read(tmp41, tmp42));

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp44 = .error(tmp43);
    } else {
      final tmp14 = i0.memory.loadUint8(tmp12.toIntUnsigned(), offset: 8);
      final i4.TypesOutcome tmp39;
      switch (tmp14.toIntUnsigned()) {
        case 0:
          final tmp15 = i0.memory.loadUint16(tmp12.toIntUnsigned(), offset: 16);
          final tmp16 = i0.memory.loadInt32(tmp12.toIntUnsigned(), offset: 20);
          final tmp17 = i0.memory.loadInt32(tmp12.toIntUnsigned(), offset: 24);

          final tmp24 = tmp16.toIntUnsigned();
          final tmp23 = List.generate(tmp17.toIntUnsigned(), growable: false, (
            i,
          ) {
            final elementPtr = i2.WasmI32.fromInt(tmp24 + i * 16);
            final tmp18 = i0.memory.loadInt32(
              elementPtr.toIntUnsigned(),
              offset: 0,
            );
            final tmp19 = i0.memory.loadInt32(
              elementPtr.toIntUnsigned(),
              offset: 4,
            );
            final tmp20 = i0.memory.loadInt32(
              elementPtr.toIntUnsigned(),
              offset: 8,
            );
            final tmp21 = i0.memory.loadInt32(
              elementPtr.toIntUnsigned(),
              offset: 12,
            );
            final tmp22 = (
              i0.AllocatedString.read(tmp18, tmp19),
              i0.AllocatedString.read(tmp20, tmp21),
            );

            return tmp22;
          });

          final tmp25 = (status: tmp15.toIntUnsigned(), headers: tmp23);
          final tmp26 = i0.memory.loadInt32(tmp12.toIntUnsigned(), offset: 28);
          final tmp27 = i0.ReadableStream(
            tmp26.toIntUnsigned(),
            const _Vtable8(),
          );
          final tmp28 = i0.memory.loadInt32(tmp12.toIntUnsigned(), offset: 32);
          final tmp29 = i0.readFuture(const _Vtable10(), tmp28.toIntUnsigned());
          final tmp30 = (head: tmp25, body: tmp27, delivered: tmp29);

          tmp39 = i4.TypesOutcomeSent(tmp30);
        case 1:
          final tmp31 = i0.memory.loadInt64(tmp12.toIntUnsigned(), offset: 16);
          final tmp32 = i0.memory.loadInt32(tmp12.toIntUnsigned(), offset: 24);
          final tmp33 = i0.memory.loadInt32(tmp12.toIntUnsigned(), offset: 28);
          final tmp34 = i0.memory.loadInt32(tmp12.toIntUnsigned(), offset: 32);
          final tmp35 = i0.memory.loadInt32(tmp12.toIntUnsigned(), offset: 36);
          final tmp36 = (
            id: tmp31.toInt(),
            url: i0.AllocatedString.read(tmp32, tmp33),
            reason: i0.AllocatedString.read(tmp34, tmp35),
          );

          tmp39 = i4.TypesOutcomeApproval(tmp36);
        case 2:
          final tmp37 = i0.memory.loadInt32(tmp12.toIntUnsigned(), offset: 16);
          final tmp38 = i0.memory.loadInt32(tmp12.toIntUnsigned(), offset: 20);

          tmp39 = i4.TypesOutcomeDenied(i0.AllocatedString.read(tmp37, tmp38));

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp44 = .ok(tmp39);
    }

    i0.dartFree(tmp0, const i2.WasmI32(36), const i2.WasmI32(4));
    i0.dartFree(tmp12, const i2.WasmI32(40), const i2.WasmI32(8));
    return tmp44;
  }

  @override
  Future<i0.Result<i4.TypesOutcome, i4.TypesError>> respond({
    required int approval,
    required bool allow,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(40));
    await i0
        .createSubtask(
          _import15(
            i2.WasmI64.fromInt(approval),
            i2.WasmI32.fromBool(allow),
            tmp0,
          ),
        )
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i4.TypesOutcome, i4.TypesError> tmp32;
    if (tmp1.toBool()) {
      final tmp28 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i4.TypesError tmp31;
      switch (tmp28.toIntUnsigned()) {
        case 0:
          final tmp29 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
          final tmp30 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

          tmp31 = i4.TypesErrorMessage(i0.AllocatedString.read(tmp29, tmp30));

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp32 = .error(tmp31);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i4.TypesOutcome tmp27;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          final tmp3 = i0.memory.loadUint16(tmp0.toIntUnsigned(), offset: 16);
          final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 20);
          final tmp5 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 24);

          final tmp12 = tmp4.toIntUnsigned();
          final tmp11 = List.generate(tmp5.toIntUnsigned(), growable: false, (
            i,
          ) {
            final elementPtr = i2.WasmI32.fromInt(tmp12 + i * 16);
            final tmp6 = i0.memory.loadInt32(
              elementPtr.toIntUnsigned(),
              offset: 0,
            );
            final tmp7 = i0.memory.loadInt32(
              elementPtr.toIntUnsigned(),
              offset: 4,
            );
            final tmp8 = i0.memory.loadInt32(
              elementPtr.toIntUnsigned(),
              offset: 8,
            );
            final tmp9 = i0.memory.loadInt32(
              elementPtr.toIntUnsigned(),
              offset: 12,
            );
            final tmp10 = (
              i0.AllocatedString.read(tmp6, tmp7),
              i0.AllocatedString.read(tmp8, tmp9),
            );

            return tmp10;
          });

          final tmp13 = (status: tmp3.toIntUnsigned(), headers: tmp11);
          final tmp14 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 28);
          final tmp15 = i0.ReadableStream(
            tmp14.toIntUnsigned(),
            const _Vtable8(),
          );
          final tmp16 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 32);
          final tmp17 = i0.readFuture(const _Vtable10(), tmp16.toIntUnsigned());
          final tmp18 = (head: tmp13, body: tmp15, delivered: tmp17);

          tmp27 = i4.TypesOutcomeSent(tmp18);
        case 1:
          final tmp19 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 16);
          final tmp20 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 24);
          final tmp21 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 28);
          final tmp22 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 32);
          final tmp23 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 36);
          final tmp24 = (
            id: tmp19.toInt(),
            url: i0.AllocatedString.read(tmp20, tmp21),
            reason: i0.AllocatedString.read(tmp22, tmp23),
          );

          tmp27 = i4.TypesOutcomeApproval(tmp24);
        case 2:
          final tmp25 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);
          final tmp26 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 20);

          tmp27 = i4.TypesOutcomeDenied(i0.AllocatedString.read(tmp25, tmp26));

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp32 = .ok(tmp27);
    }

    i0.dartFree(tmp0, const i2.WasmI32(40), const i2.WasmI32(8));
    return tmp32;
  }
}

@pragma("wasm:import", r"component._import16")
external i2.WasmVoid _import16(i2.WasmI32 p0);
@pragma("wasm:import", r"component._import17")
external i2.WasmI32 _import17(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import18")
external i2.WasmVoid _import18(i2.WasmI32 p0, i2.WasmI32 p1, i2.WasmI32 p2);

final class _Imported$5 implements i6.Session {
  const _Imported$5();
  @override
  i0.Result<String, i6.SessionError> open() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(12));
    _import16(tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<String, i6.SessionError> tmp6;
    if (tmp1.toBool()) {
      final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i6.SessionError tmp5;
      switch (tmp4.toIntUnsigned()) {
        case 0:
          tmp5 = i6.SessionErrorDenied();
        case 1:
          tmp5 = i6.SessionErrorUnavailable();
        case 2:
          tmp5 = i6.SessionErrorFailed();

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp6 = .error(tmp5);
    } else {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 8);

      tmp6 = .ok(i0.AllocatedString.read(tmp2, tmp3));
    }

    i0.dartFree(tmp0, const i2.WasmI32(12), const i2.WasmI32(4));
    return tmp6;
  }

  @override
  Future<i0.Result<String, i6.SessionError>> onPrompt({
    required String lease,
    required String sessionId,
    required String model,
  }) async {
    final tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(24));
    final tmp1 = i0.AllocatedString.allocateUtf16(lease);
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      tmp1.packedLength,
      offset: 4,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      tmp1.ptr,
      offset: 0,
    );
    final tmp2 = i0.AllocatedString.allocateUtf16(sessionId);
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(8)).toIntUnsigned(),
      tmp2.packedLength,
      offset: 4,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(8)).toIntUnsigned(),
      tmp2.ptr,
      offset: 0,
    );
    final tmp3 = i0.AllocatedString.allocateUtf16(model);
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(16)).toIntUnsigned(),
      tmp3.packedLength,
      offset: 4,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(16)).toIntUnsigned(),
      tmp3.ptr,
      offset: 0,
    );
    var tmp4 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(12));
    await i0.createSubtask(_import17(tmp0, tmp4)).completion;
    final tmp5 = i0.memory.loadUint8(tmp4.toIntUnsigned(), offset: 0);
    final i0.Result<String, i6.SessionError> tmp10;
    if (tmp5.toBool()) {
      final tmp8 = i0.memory.loadUint8(tmp4.toIntUnsigned(), offset: 4);
      final i6.SessionError tmp9;
      switch (tmp8.toIntUnsigned()) {
        case 0:
          tmp9 = i6.SessionErrorDenied();
        case 1:
          tmp9 = i6.SessionErrorUnavailable();
        case 2:
          tmp9 = i6.SessionErrorFailed();

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp10 = .error(tmp9);
    } else {
      final tmp6 = i0.memory.loadInt32(tmp4.toIntUnsigned(), offset: 4);
      final tmp7 = i0.memory.loadInt32(tmp4.toIntUnsigned(), offset: 8);

      tmp10 = .ok(i0.AllocatedString.read(tmp6, tmp7));
    }

    i0.dartFree(tmp0, const i2.WasmI32(24), const i2.WasmI32(4));
    i0.dartFree(tmp4, const i2.WasmI32(12), const i2.WasmI32(4));
    return tmp10;
  }

  @override
  i0.Result<void, i6.SessionError> close({required String lease}) {
    final tmp0 = i0.AllocatedString.allocateUtf16(lease);
    var tmp1 = i0.mallocAligned(const i2.WasmI32(1), const i2.WasmI32(2));
    _import18(tmp0.ptr, tmp0.packedLength, tmp1);
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<void, i6.SessionError> tmp5;
    if (tmp2.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 1);
      final i6.SessionError tmp4;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp4 = i6.SessionErrorDenied();
        case 1:
          tmp4 = i6.SessionErrorUnavailable();
        case 2:
          tmp4 = i6.SessionErrorFailed();

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp5 = .error(tmp4);
    } else {
      tmp5 = .ok(null);
    }

    tmp0.free();
    i0.dartFree(tmp1, const i2.WasmI32(2), const i2.WasmI32(1));
    return tmp5;
  }
}

final class _Imported$6 implements i7.Types {
  const _Imported$6();
}

@pragma("wasm:import", r"component._import19")
external i2.WasmI32 _import19(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import20")
external i2.WasmVoid _import20(i2.WasmI32 p0);

final class _Imported$7 implements i7.Policy {
  const _Imported$7();
  @override
  Future<i0.Result<void, String>> widen({
    required i7.TypesCapabilityEntry entry,
  }) async {
    final tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(28));
    switch (entry) {
      case i7.TypesCapabilityEntryDirectory(payload: final value):
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 0,
        );
        final tmp1 = i0.AllocatedString.allocateUtf16(value.path);
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp1.packedLength,
          offset: 8,
        );
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp1.ptr,
          offset: 4,
        );
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          value.access.index.toWasmI32(),
          offset: 12,
        );
        final tmp2 = i0.AllocatedString.allocateUtf16(value.origin);
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp2.packedLength,
          offset: 20,
        );
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp2.ptr,
          offset: 16,
        );

      case i7.TypesCapabilityEntryDomain(payload: final value):
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 0,
        );
        final tmp3 = i0.AllocatedString.allocateUtf16(value.domain);
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp3.packedLength,
          offset: 8,
        );
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp3.ptr,
          offset: 4,
        );
        final tmp4 = i0.AllocatedString.allocateUtf16(value.origin);
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp4.packedLength,
          offset: 16,
        );
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp4.ptr,
          offset: 12,
        );

      case i7.TypesCapabilityEntryCommand(payload: final value):
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          const i2.WasmI32(2),
          offset: 0,
        );
        final tmp5 = i0.AllocatedString.allocateUtf16(value.pattern);
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp5.packedLength,
          offset: 8,
        );
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp5.ptr,
          offset: 4,
        );
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          value.verdict.index.toWasmI32(),
          offset: 12,
        );
        final tmp6 = i0.AllocatedString.allocateUtf16(value.origin);
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp6.packedLength,
          offset: 20,
        );
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp6.ptr,
          offset: 16,
        );

      case i7.TypesCapabilityEntryPlugin(payload: final value):
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          const i2.WasmI32(3),
          offset: 0,
        );
        final tmp7 = i0.AllocatedString.allocateUtf16(value.plugin);
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp7.packedLength,
          offset: 8,
        );
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp7.ptr,
          offset: 4,
        );

        final tmp9 = i2.WasmI32.fromInt(8 * value.grants.length);
        final tmp10 = i0.mallocAligned(const i2.WasmI32(4), tmp9);
        var tmp11 = tmp10;
        for (final element in value.grants) {
          final elementPtr = tmp11;
          final tmp8 = i0.AllocatedString.allocateUtf16(element);
          i0.memory.storeInt32(
            elementPtr.toIntUnsigned(),
            tmp8.packedLength,
            offset: 4,
          );
          i0.memory.storeInt32(elementPtr.toIntUnsigned(), tmp8.ptr, offset: 0);

          tmp11 += const i2.WasmI32(8);
        }

        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          i2.WasmI32.fromInt(value.grants.length),
          offset: 16,
        );
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp10,
          offset: 12,
        );
        final tmp12 = i0.AllocatedString.allocateUtf16(value.origin);
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp12.packedLength,
          offset: 24,
        );
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp12.ptr,
          offset: 20,
        );

      case i7.TypesCapabilityEntryProtected(payload: final value):
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          const i2.WasmI32(4),
          offset: 0,
        );
        final tmp13 = i0.AllocatedString.allocateUtf16(value);
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp13.packedLength,
          offset: 8,
        );
        i0.memory.storeInt32(
          (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
          tmp13.ptr,
          offset: 4,
        );
    }
    var tmp14 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(12));
    await i0.createSubtask(_import19(tmp0, tmp14)).completion;
    final tmp15 = i0.memory.loadUint8(tmp14.toIntUnsigned(), offset: 0);
    final i0.Result<void, String> tmp18;
    if (tmp15.toBool()) {
      final tmp16 = i0.memory.loadInt32(tmp14.toIntUnsigned(), offset: 4);
      final tmp17 = i0.memory.loadInt32(tmp14.toIntUnsigned(), offset: 8);

      tmp18 = .error(i0.AllocatedString.read(tmp16, tmp17));
    } else {
      tmp18 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(28), const i2.WasmI32(4));
    i0.dartFree(tmp14, const i2.WasmI32(12), const i2.WasmI32(4));
    return tmp18;
  }

  @override
  ({
    String mode,
    List<i7.TypesCapabilityEntry> entries,
    List<String> protectedPaths,
  })
  snapshot() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(24));
    _import20(tmp0);
    final tmp1 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
    final tmp3 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 8);
    final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);

    final tmp38 = tmp3.toIntUnsigned();
    final tmp37 = List.generate(tmp4.toIntUnsigned(), growable: false, (i) {
      final elementPtr = i2.WasmI32.fromInt(tmp38 + i * 28);
      final tmp5 = i0.memory.loadUint8(elementPtr.toIntUnsigned(), offset: 0);
      final i7.TypesCapabilityEntry tmp36;
      switch (tmp5.toIntUnsigned()) {
        case 0:
          final tmp6 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 4,
          );
          final tmp7 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 8,
          );
          final tmp8 = i0.memory.loadUint8(
            elementPtr.toIntUnsigned(),
            offset: 12,
          );
          final tmp9 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 16,
          );
          final tmp10 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 20,
          );
          final tmp11 = (
            path: i0.AllocatedString.read(tmp6, tmp7),
            access: i7.TypesDirectoryAccess.values[tmp8.toIntUnsigned()],
            origin: i0.AllocatedString.read(tmp9, tmp10),
          );

          tmp36 = i7.TypesCapabilityEntryDirectory(tmp11);
        case 1:
          final tmp12 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 4,
          );
          final tmp13 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 8,
          );
          final tmp14 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 12,
          );
          final tmp15 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 16,
          );
          final tmp16 = (
            domain: i0.AllocatedString.read(tmp12, tmp13),
            origin: i0.AllocatedString.read(tmp14, tmp15),
          );

          tmp36 = i7.TypesCapabilityEntryDomain(tmp16);
        case 2:
          final tmp17 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 4,
          );
          final tmp18 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 8,
          );
          final tmp19 = i0.memory.loadUint8(
            elementPtr.toIntUnsigned(),
            offset: 12,
          );
          final tmp20 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 16,
          );
          final tmp21 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 20,
          );
          final tmp22 = (
            pattern: i0.AllocatedString.read(tmp17, tmp18),
            verdict: i7.TypesVerdict.values[tmp19.toIntUnsigned()],
            origin: i0.AllocatedString.read(tmp20, tmp21),
          );

          tmp36 = i7.TypesCapabilityEntryCommand(tmp22);
        case 3:
          final tmp23 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 4,
          );
          final tmp24 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 8,
          );
          final tmp25 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 12,
          );
          final tmp26 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 16,
          );

          final tmp30 = tmp25.toIntUnsigned();
          final tmp29 = List.generate(tmp26.toIntUnsigned(), growable: false, (
            i,
          ) {
            final elementPtr = i2.WasmI32.fromInt(tmp30 + i * 8);
            final tmp27 = i0.memory.loadInt32(
              elementPtr.toIntUnsigned(),
              offset: 0,
            );
            final tmp28 = i0.memory.loadInt32(
              elementPtr.toIntUnsigned(),
              offset: 4,
            );

            return i0.AllocatedString.read(tmp27, tmp28);
          });

          final tmp31 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 20,
          );
          final tmp32 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 24,
          );
          final tmp33 = (
            plugin: i0.AllocatedString.read(tmp23, tmp24),
            grants: tmp29,
            origin: i0.AllocatedString.read(tmp31, tmp32),
          );

          tmp36 = i7.TypesCapabilityEntryPlugin(tmp33);
        case 4:
          final tmp34 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 4,
          );
          final tmp35 = i0.memory.loadInt32(
            elementPtr.toIntUnsigned(),
            offset: 8,
          );

          tmp36 = i7.TypesCapabilityEntryProtected(
            i0.AllocatedString.read(tmp34, tmp35),
          );

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      return tmp36;
    });

    final tmp39 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);
    final tmp40 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 20);

    final tmp44 = tmp39.toIntUnsigned();
    final tmp43 = List.generate(tmp40.toIntUnsigned(), growable: false, (i) {
      final elementPtr = i2.WasmI32.fromInt(tmp44 + i * 8);
      final tmp41 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 0);
      final tmp42 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 4);

      return i0.AllocatedString.read(tmp41, tmp42);
    });

    final tmp45 = (
      mode: i0.AllocatedString.read(tmp1, tmp2),
      entries: tmp37,
      protectedPaths: tmp43,
    );
    i0.dartFree(tmp0, const i2.WasmI32(24), const i2.WasmI32(4));
    return tmp45;
  }
}

final class _Imported$33 implements i8.Types {
  const _Imported$33();
}

@pragma('wasm:import', 'component.stream187.new')
external i2.WasmI64 _streamNew187();
@pragma('wasm:import', 'component.stream187.read')
external i2.WasmI32 _streamRead187(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream187.write')
external i2.WasmI32 _streamWrite187(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream187.drop-readable')
external i2.WasmVoid _streamDropReadable187(i2.WasmI32 stream);
@pragma('wasm:import', 'component.stream187.drop-writable')
external i2.WasmVoid _streamDropWritable187(i2.WasmI32 stream);

final class _Vtable187 implements i0.StreamVtable<i5.Uint8List> {
  const _Vtable187();

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
  void writeToBuffer(int address, i5.Uint8List elements) {
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
  i5.Uint8List readFromBuffer(int address, int count) {
    final typedList = i5.Uint8List(count);
    for (var i = 0; i < count; i++) {
      final ptr = i2.WasmI32.fromInt(address + i * 1);
      final tmp0 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 0);

      typedList[i] = tmp0.toIntUnsigned();
    }
    return typedList;
  }

  @override
  int newStream() => _streamNew187().toInt();
  @override
  void dropReadable(int stream) {
    _streamDropReadable187(i2.WasmI32.fromInt(stream));
  }

  @override
  void dropWritable(int stream) {
    _streamDropWritable187(i2.WasmI32.fromInt(stream));
  }

  @override
  int read(int stream, int ptr, int n) {
    return _streamRead187(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }

  @override
  int write(int stream, int ptr, int n) {
    return _streamWrite187(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }
}

@pragma("wasm:import", r"component._import26")
external i2.WasmI32 _import26(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import27")
external i2.WasmI32 _import27(i2.WasmI64 p0, i2.WasmI32 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import28")
external i2.WasmI32 _import28(i2.WasmI64 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import29")
external i2.WasmI32 _import29(i2.WasmI64 p0, i2.WasmI32 p1);

final class _Imported$34 implements i8.Process {
  const _Imported$34();
  @override
  Future<i0.Result<i8.TypesOutcome, i8.TypesError>> spawn({
    required ({
      List<String> argv,
      i0.Option<String> cwd,
      List<(String, String)> env,
      i0.Option<List<int>> stdin,
      i0.Option<({List<({String pattern, i8.TypesVerdict verdict})> rules})>
      profile,
    })
    req,
  }) async {
    final tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(52));

    final tmp2 = i2.WasmI32.fromInt(8 * req.argv.length);
    final tmp3 = i0.mallocAligned(const i2.WasmI32(4), tmp2);
    var tmp4 = tmp3;
    for (final element in req.argv) {
      final elementPtr = tmp4;
      final tmp1 = i0.AllocatedString.allocateUtf16(element);
      i0.memory.storeInt32(
        elementPtr.toIntUnsigned(),
        tmp1.packedLength,
        offset: 4,
      );
      i0.memory.storeInt32(elementPtr.toIntUnsigned(), tmp1.ptr, offset: 0);

      tmp4 += const i2.WasmI32(8);
    }

    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      i2.WasmI32.fromInt(req.argv.length),
      offset: 4,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      tmp3,
      offset: 0,
    );
    final tmp6 = req.cwd;
    if (tmp6.hasValue) {
      final value = tmp6.requireValue();
      i0.memory.storeInt8(
        (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
        const i2.WasmI32(1),
        offset: 8,
      );
      final tmp5 = i0.AllocatedString.allocateUtf16(value);
      i0.memory.storeInt32(
        (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
        tmp5.packedLength,
        offset: 16,
      );
      i0.memory.storeInt32(
        (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
        tmp5.ptr,
        offset: 12,
      );
    } else {
      i0.memory.storeInt8(
        (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
        const i2.WasmI32(0),
        offset: 8,
      );
    }

    final tmp9 = i2.WasmI32.fromInt(16 * req.env.length);
    final tmp10 = i0.mallocAligned(const i2.WasmI32(4), tmp9);
    var tmp11 = tmp10;
    for (final element in req.env) {
      final elementPtr = tmp11;
      final tmp7 = i0.AllocatedString.allocateUtf16(element.$1);
      i0.memory.storeInt32(
        elementPtr.toIntUnsigned(),
        tmp7.packedLength,
        offset: 4,
      );
      i0.memory.storeInt32(elementPtr.toIntUnsigned(), tmp7.ptr, offset: 0);
      final tmp8 = i0.AllocatedString.allocateUtf16(element.$2);
      i0.memory.storeInt32(
        elementPtr.toIntUnsigned(),
        tmp8.packedLength,
        offset: 12,
      );
      i0.memory.storeInt32(elementPtr.toIntUnsigned(), tmp8.ptr, offset: 8);

      tmp11 += const i2.WasmI32(16);
    }

    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      i2.WasmI32.fromInt(req.env.length),
      offset: 24,
    );
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      tmp10,
      offset: 20,
    );
    final tmp15 = req.stdin;
    if (tmp15.hasValue) {
      final value = tmp15.requireValue();
      i0.memory.storeInt8(
        (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
        const i2.WasmI32(1),
        offset: 28,
      );

      final tmp12 = i2.WasmI32.fromInt(1 * value.length);
      final tmp13 = i0.mallocAligned(const i2.WasmI32(1), tmp12);
      var tmp14 = tmp13;
      for (final element in value) {
        final elementPtr = tmp14;
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          i2.WasmI32.uint8FromInt(element),
          offset: 0,
        );

        tmp14 += const i2.WasmI32(1);
      }

      i0.memory.storeInt32(
        (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
        i2.WasmI32.fromInt(value.length),
        offset: 36,
      );
      i0.memory.storeInt32(
        (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
        tmp13,
        offset: 32,
      );
    } else {
      i0.memory.storeInt8(
        (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
        const i2.WasmI32(0),
        offset: 28,
      );
    }
    final tmp20 = req.profile;
    if (tmp20.hasValue) {
      final value = tmp20.requireValue();
      i0.memory.storeInt8(
        (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
        const i2.WasmI32(1),
        offset: 40,
      );

      final tmp17 = i2.WasmI32.fromInt(12 * value.rules.length);
      final tmp18 = i0.mallocAligned(const i2.WasmI32(4), tmp17);
      var tmp19 = tmp18;
      for (final element in value.rules) {
        final elementPtr = tmp19;
        final tmp16 = i0.AllocatedString.allocateUtf16(element.pattern);
        i0.memory.storeInt32(
          elementPtr.toIntUnsigned(),
          tmp16.packedLength,
          offset: 4,
        );
        i0.memory.storeInt32(elementPtr.toIntUnsigned(), tmp16.ptr, offset: 0);
        i0.memory.storeInt8(
          elementPtr.toIntUnsigned(),
          element.verdict.index.toWasmI32(),
          offset: 8,
        );

        tmp19 += const i2.WasmI32(12);
      }

      i0.memory.storeInt32(
        (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
        i2.WasmI32.fromInt(value.rules.length),
        offset: 48,
      );
      i0.memory.storeInt32(
        (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
        tmp18,
        offset: 44,
      );
    } else {
      i0.memory.storeInt8(
        (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
        const i2.WasmI32(0),
        offset: 40,
      );
    }
    var tmp21 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(40));
    await i0.createSubtask(_import26(tmp0, tmp21)).completion;
    final tmp22 = i0.memory.loadUint8(tmp21.toIntUnsigned(), offset: 0);
    final i0.Result<i8.TypesOutcome, i8.TypesError> tmp43;
    if (tmp22.toBool()) {
      final tmp39 = i0.memory.loadUint8(tmp21.toIntUnsigned(), offset: 8);
      final i8.TypesError tmp42;
      switch (tmp39.toIntUnsigned()) {
        case 0:
          final tmp40 = i0.memory.loadInt32(tmp21.toIntUnsigned(), offset: 12);
          final tmp41 = i0.memory.loadInt32(tmp21.toIntUnsigned(), offset: 16);

          tmp42 = i8.TypesErrorMessage(i0.AllocatedString.read(tmp40, tmp41));

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp43 = .error(tmp42);
    } else {
      final tmp23 = i0.memory.loadUint8(tmp21.toIntUnsigned(), offset: 8);
      final i8.TypesOutcome tmp38;
      switch (tmp23.toIntUnsigned()) {
        case 0:
          final tmp24 = i0.memory.loadInt64(tmp21.toIntUnsigned(), offset: 16);
          final tmp25 = i0.memory.loadInt32(tmp21.toIntUnsigned(), offset: 24);
          final tmp26 = i0.ReadableStream(
            tmp25.toIntUnsigned(),
            const _Vtable187(),
          );
          final tmp27 = i0.memory.loadInt32(tmp21.toIntUnsigned(), offset: 28);
          final tmp28 = i0.ReadableStream(
            tmp27.toIntUnsigned(),
            const _Vtable187(),
          );
          final tmp29 = (id: tmp24.toInt(), stdout: tmp26, stderr: tmp28);

          tmp38 = i8.TypesOutcomeStarted(tmp29);
        case 1:
          final tmp30 = i0.memory.loadInt64(tmp21.toIntUnsigned(), offset: 16);
          final tmp31 = i0.memory.loadInt32(tmp21.toIntUnsigned(), offset: 24);
          final tmp32 = i0.memory.loadInt32(tmp21.toIntUnsigned(), offset: 28);
          final tmp33 = i0.memory.loadInt32(tmp21.toIntUnsigned(), offset: 32);
          final tmp34 = i0.memory.loadInt32(tmp21.toIntUnsigned(), offset: 36);
          final tmp35 = (
            id: tmp30.toInt(),
            command: i0.AllocatedString.read(tmp31, tmp32),
            reason: i0.AllocatedString.read(tmp33, tmp34),
          );

          tmp38 = i8.TypesOutcomeApproval(tmp35);
        case 2:
          final tmp36 = i0.memory.loadInt32(tmp21.toIntUnsigned(), offset: 16);
          final tmp37 = i0.memory.loadInt32(tmp21.toIntUnsigned(), offset: 20);

          tmp38 = i8.TypesOutcomeDenied(i0.AllocatedString.read(tmp36, tmp37));

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp43 = .ok(tmp38);
    }

    i0.dartFree(tmp0, const i2.WasmI32(52), const i2.WasmI32(4));
    i0.dartFree(tmp21, const i2.WasmI32(40), const i2.WasmI32(8));
    return tmp43;
  }

  @override
  Future<i0.Result<i8.TypesOutcome, i8.TypesError>> respond({
    required int approval,
    required bool allow,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(40));
    await i0
        .createSubtask(
          _import27(
            i2.WasmI64.fromInt(approval),
            i2.WasmI32.fromBool(allow),
            tmp0,
          ),
        )
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i8.TypesOutcome, i8.TypesError> tmp22;
    if (tmp1.toBool()) {
      final tmp18 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i8.TypesError tmp21;
      switch (tmp18.toIntUnsigned()) {
        case 0:
          final tmp19 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);
          final tmp20 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);

          tmp21 = i8.TypesErrorMessage(i0.AllocatedString.read(tmp19, tmp20));

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp22 = .error(tmp21);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i8.TypesOutcome tmp17;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          final tmp3 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 16);
          final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 24);
          final tmp5 = i0.ReadableStream(
            tmp4.toIntUnsigned(),
            const _Vtable187(),
          );
          final tmp6 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 28);
          final tmp7 = i0.ReadableStream(
            tmp6.toIntUnsigned(),
            const _Vtable187(),
          );
          final tmp8 = (id: tmp3.toInt(), stdout: tmp5, stderr: tmp7);

          tmp17 = i8.TypesOutcomeStarted(tmp8);
        case 1:
          final tmp9 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 16);
          final tmp10 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 24);
          final tmp11 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 28);
          final tmp12 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 32);
          final tmp13 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 36);
          final tmp14 = (
            id: tmp9.toInt(),
            command: i0.AllocatedString.read(tmp10, tmp11),
            reason: i0.AllocatedString.read(tmp12, tmp13),
          );

          tmp17 = i8.TypesOutcomeApproval(tmp14);
        case 2:
          final tmp15 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 16);
          final tmp16 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 20);

          tmp17 = i8.TypesOutcomeDenied(i0.AllocatedString.read(tmp15, tmp16));

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp22 = .ok(tmp17);
    }

    i0.dartFree(tmp0, const i2.WasmI32(40), const i2.WasmI32(8));
    return tmp22;
  }

  @override
  Future<i0.Result<i8.TypesExit, i8.TypesError>> wait({required int id}) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(16));
    await i0.createSubtask(_import28(i2.WasmI64.fromInt(id), tmp0)).completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i8.TypesExit, i8.TypesError> tmp10;
    if (tmp1.toBool()) {
      final tmp6 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i8.TypesError tmp9;
      switch (tmp6.toIntUnsigned()) {
        case 0:
          final tmp7 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 8);
          final tmp8 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);

          tmp9 = i8.TypesErrorMessage(i0.AllocatedString.read(tmp7, tmp8));

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp10 = .error(tmp9);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i8.TypesExit tmp5;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          final tmp3 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 8);

          tmp5 = i8.TypesExitCode(tmp3.toIntUnsigned());
        case 1:
          final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 8);

          tmp5 = i8.TypesExitSignal(tmp4.toIntUnsigned());

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp10 = .ok(tmp5);
    }

    i0.dartFree(tmp0, const i2.WasmI32(16), const i2.WasmI32(4));
    return tmp10;
  }

  @override
  Future<i0.Result<void, i8.TypesError>> kill({required int id}) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(16));
    await i0.createSubtask(_import29(i2.WasmI64.fromInt(id), tmp0)).completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i8.TypesError> tmp6;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i8.TypesError tmp5;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          final tmp3 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 8);
          final tmp4 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 12);

          tmp5 = i8.TypesErrorMessage(i0.AllocatedString.read(tmp3, tmp4));

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp6 = .error(tmp5);
    } else {
      tmp6 = .ok(null);
    }

    i0.dartFree(tmp0, const i2.WasmI32(16), const i2.WasmI32(4));
    return tmp6;
  }
}

@pragma("wasm:import", r"component._import30")
external i2.WasmVoid _import30(i2.WasmI32 p0);
@pragma("wasm:import", r"component._import31")
external i2.WasmVoid _import31(i2.WasmI32 p0);
@pragma("wasm:import", r"component._import32")
external i2.WasmVoid _import32(i2.WasmI32 p0);

final class _Imported$19 implements i9.Environment {
  const _Imported$19();
  @override
  List<(String, String)> getEnvironment() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import30(tmp0);
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
    _import31(tmp0);
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
    _import32(tmp0);
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

@pragma("wasm:import", r"component._import33")
external i2.WasmVoid _import33(i2.WasmI32 p0);
@pragma("wasm:import", r"component._import34")
external i2.WasmVoid _import34(i2.WasmI32 p0);

final class _Imported$20 implements i9.Exit {
  const _Imported$20();
  @override
  void exit({required i0.Result<void, void> status}) {
    i2.WasmI32 tmp0;
    switch (status) {
      case i0.OkResult(:final value):
        tmp0 = const i2.WasmI32(0);

      case i0.ErrorResult(:final value):
        tmp0 = const i2.WasmI32(1);
    }
    _import33(tmp0);
  }

  @override
  void exitWithCode({required int statusCode}) {
    _import34(i2.WasmI32.uint8FromInt(statusCode));
  }
}

final class _Imported$22 implements i9.Types {
  const _Imported$22();
}

@pragma('wasm:import', 'component.stream154.new')
external i2.WasmI64 _streamNew154();
@pragma('wasm:import', 'component.stream154.read')
external i2.WasmI32 _streamRead154(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream154.write')
external i2.WasmI32 _streamWrite154(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream154.drop-readable')
external i2.WasmVoid _streamDropReadable154(i2.WasmI32 stream);
@pragma('wasm:import', 'component.stream154.drop-writable')
external i2.WasmVoid _streamDropWritable154(i2.WasmI32 stream);

final class _Vtable154 implements i0.StreamVtable<i5.Uint8List> {
  const _Vtable154();

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
  void writeToBuffer(int address, i5.Uint8List elements) {
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
  i5.Uint8List readFromBuffer(int address, int count) {
    final typedList = i5.Uint8List(count);
    for (var i = 0; i < count; i++) {
      final ptr = i2.WasmI32.fromInt(address + i * 1);
      final tmp0 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 0);

      typedList[i] = tmp0.toIntUnsigned();
    }
    return typedList;
  }

  @override
  int newStream() => _streamNew154().toInt();
  @override
  void dropReadable(int stream) {
    _streamDropReadable154(i2.WasmI32.fromInt(stream));
  }

  @override
  void dropWritable(int stream) {
    _streamDropWritable154(i2.WasmI32.fromInt(stream));
  }

  @override
  int read(int stream, int ptr, int n) {
    return _streamRead154(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }

  @override
  int write(int stream, int ptr, int n) {
    return _streamWrite154(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }
}

@pragma('wasm:import', 'component.future156.new')
external i2.WasmI64 _futureNew156();
@pragma('wasm:import', 'component.future156.write')
external i2.WasmI32 _futureWrite156(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future156.read')
external i2.WasmI32 _futureRead156(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future156.drop-readable')
external i2.WasmVoid _futureDropReadable156(i2.WasmI32 future);
@pragma('wasm:import', 'component.future156.drop-writable')
external i2.WasmVoid _futureDropWritable156(i2.WasmI32 future);

final class _Vtable156
    implements i0.FutureVtable<i0.Result<void, i9.TypesErrorCode>> {
  const _Vtable156();

  @override
  int newFuture() => _futureNew156().toInt();

  @override
  int read(int future, int buffer) {
    return _futureRead156(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  int write(int future, int buffer) {
    return _futureWrite156(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  void dropRead(int future) {
    _futureDropReadable156(i2.WasmI32.fromInt(future));
  }

  @override
  void dropWrite(int future) {
    _futureDropWritable156(i2.WasmI32.fromInt(future));
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
  void store(int address, i0.Result<void, i9.TypesErrorCode> value) {
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
  i0.Result<void, i9.TypesErrorCode> load(int address) {
    final wasmAddress = i2.WasmI32.fromInt(address);

    final tmp0 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 0);
    final i0.Result<void, i9.TypesErrorCode> tmp2;
    if (tmp0.toBool()) {
      final tmp1 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 1);

      tmp2 = .error(i9.TypesErrorCode.values[tmp1.toIntUnsigned()]);
    } else {
      tmp2 = .ok(null);
    }

    return tmp2;
  }
}

@pragma("wasm:import", r"component._import45")
external i2.WasmVoid _import45(i2.WasmI32 p0);

final class _Imported$23 implements i9.Stdin {
  const _Imported$23();
  @override
  (Stream<i5.Uint8List>, Future<i0.Result<void, i9.TypesErrorCode>>)
  readViaStream() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import45(tmp0);
    final tmp1 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.ReadableStream(tmp1.toIntUnsigned(), const _Vtable154());
    final tmp3 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
    final tmp4 = i0.readFuture(const _Vtable156(), tmp3.toIntUnsigned());
    final tmp5 = (tmp2, tmp4);
    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp5;
  }
}

@pragma('wasm:import', 'component.future160.new')
external i2.WasmI64 _futureNew160();
@pragma('wasm:import', 'component.future160.write')
external i2.WasmI32 _futureWrite160(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future160.read')
external i2.WasmI32 _futureRead160(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future160.drop-readable')
external i2.WasmVoid _futureDropReadable160(i2.WasmI32 future);
@pragma('wasm:import', 'component.future160.drop-writable')
external i2.WasmVoid _futureDropWritable160(i2.WasmI32 future);

final class _Vtable160
    implements i0.FutureVtable<i0.Result<void, i9.TypesErrorCode>> {
  const _Vtable160();

  @override
  int newFuture() => _futureNew160().toInt();

  @override
  int read(int future, int buffer) {
    return _futureRead160(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  int write(int future, int buffer) {
    return _futureWrite160(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  void dropRead(int future) {
    _futureDropReadable160(i2.WasmI32.fromInt(future));
  }

  @override
  void dropWrite(int future) {
    _futureDropWritable160(i2.WasmI32.fromInt(future));
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
  void store(int address, i0.Result<void, i9.TypesErrorCode> value) {
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
  i0.Result<void, i9.TypesErrorCode> load(int address) {
    final wasmAddress = i2.WasmI32.fromInt(address);

    final tmp0 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 0);
    final i0.Result<void, i9.TypesErrorCode> tmp2;
    if (tmp0.toBool()) {
      final tmp1 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 1);

      tmp2 = .error(i9.TypesErrorCode.values[tmp1.toIntUnsigned()]);
    } else {
      tmp2 = .ok(null);
    }

    return tmp2;
  }
}

@pragma("wasm:import", r"component._import51")
external i2.WasmI32 _import51(i2.WasmI32 p0);

final class _Imported$24 implements i9.Stdout {
  const _Imported$24();
  @override
  Future<i0.Result<void, i9.TypesErrorCode>> writeViaStream({
    required Stream<i5.Uint8List> data,
  }) {
    final tmp0 = i0.newReadableStream(const _Vtable154(), data).toWasmI32();
    final tmp1 = _import51(tmp0);
    final tmp2 = i0.readFuture(const _Vtable160(), tmp1.toIntUnsigned());
    return tmp2;
  }
}

@pragma('wasm:import', 'component.future163.new')
external i2.WasmI64 _futureNew163();
@pragma('wasm:import', 'component.future163.write')
external i2.WasmI32 _futureWrite163(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future163.read')
external i2.WasmI32 _futureRead163(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future163.drop-readable')
external i2.WasmVoid _futureDropReadable163(i2.WasmI32 future);
@pragma('wasm:import', 'component.future163.drop-writable')
external i2.WasmVoid _futureDropWritable163(i2.WasmI32 future);

final class _Vtable163
    implements i0.FutureVtable<i0.Result<void, i9.TypesErrorCode>> {
  const _Vtable163();

  @override
  int newFuture() => _futureNew163().toInt();

  @override
  int read(int future, int buffer) {
    return _futureRead163(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  int write(int future, int buffer) {
    return _futureWrite163(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  void dropRead(int future) {
    _futureDropReadable163(i2.WasmI32.fromInt(future));
  }

  @override
  void dropWrite(int future) {
    _futureDropWritable163(i2.WasmI32.fromInt(future));
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
  void store(int address, i0.Result<void, i9.TypesErrorCode> value) {
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
  i0.Result<void, i9.TypesErrorCode> load(int address) {
    final wasmAddress = i2.WasmI32.fromInt(address);

    final tmp0 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 0);
    final i0.Result<void, i9.TypesErrorCode> tmp2;
    if (tmp0.toBool()) {
      final tmp1 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 1);

      tmp2 = .error(i9.TypesErrorCode.values[tmp1.toIntUnsigned()]);
    } else {
      tmp2 = .ok(null);
    }

    return tmp2;
  }
}

@pragma("wasm:import", r"component._import57")
external i2.WasmI32 _import57(i2.WasmI32 p0);

final class _Imported$25 implements i9.Stderr {
  const _Imported$25();
  @override
  Future<i0.Result<void, i9.TypesErrorCode>> writeViaStream({
    required Stream<i5.Uint8List> data,
  }) {
    final tmp0 = i0.newReadableStream(const _Vtable154(), data).toWasmI32();
    final tmp1 = _import57(tmp0);
    final tmp2 = i0.readFuture(const _Vtable163(), tmp1.toIntUnsigned());
    return tmp2;
  }
}

final class _Imported$26 implements i9.TerminalInput {
  const _Imported$26();
}

final class _Imported$27 implements i9.TerminalOutput {
  const _Imported$27();
}

@pragma('wasm:import', r'component._drop$166')
external i2.WasmVoid _drop$166Raw(i2.WasmI32 handle);

void _drop$166(int handle) {
  _drop$166Raw(i2.WasmI32.fromInt(handle));
}

@pragma("wasm:import", r"component._import58")
external i2.WasmVoid _import58(i2.WasmI32 p0);

final class _Imported$28 implements i9.TerminalStdin {
  const _Imported$28();
  @override
  i0.Option<i0.Owned<i9.TerminalInputTerminalInput>> getTerminalStdin() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import58(tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Option<i0.Owned<i9.TerminalInputTerminalInput>> tmp4;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i0.Owned<i9.TerminalInputTerminalInput>(
        tmp2.toIntUnsigned(),
        _drop$166,
      );
      tmp4 = .some(tmp3);
    } else {
      tmp4 = .none;
    }

    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp4;
  }
}

@pragma('wasm:import', r'component._drop$169')
external i2.WasmVoid _drop$169Raw(i2.WasmI32 handle);

void _drop$169(int handle) {
  _drop$169Raw(i2.WasmI32.fromInt(handle));
}

@pragma("wasm:import", r"component._import60")
external i2.WasmVoid _import60(i2.WasmI32 p0);

final class _Imported$29 implements i9.TerminalStdout {
  const _Imported$29();
  @override
  i0.Option<i0.Owned<i9.TerminalOutputTerminalOutput>> getTerminalStdout() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import60(tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Option<i0.Owned<i9.TerminalOutputTerminalOutput>> tmp4;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i0.Owned<i9.TerminalOutputTerminalOutput>(
        tmp2.toIntUnsigned(),
        _drop$169,
      );
      tmp4 = .some(tmp3);
    } else {
      tmp4 = .none;
    }

    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp4;
  }
}

@pragma('wasm:import', r'component._drop$172')
external i2.WasmVoid _drop$172Raw(i2.WasmI32 handle);

void _drop$172(int handle) {
  _drop$172Raw(i2.WasmI32.fromInt(handle));
}

@pragma("wasm:import", r"component._import62")
external i2.WasmVoid _import62(i2.WasmI32 p0);

final class _Imported$30 implements i9.TerminalStderr {
  const _Imported$30();
  @override
  i0.Option<i0.Owned<i9.TerminalOutputTerminalOutput>> getTerminalStderr() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import62(tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Option<i0.Owned<i9.TerminalOutputTerminalOutput>> tmp4;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i0.Owned<i9.TerminalOutputTerminalOutput>(
        tmp2.toIntUnsigned(),
        _drop$172,
      );
      tmp4 = .some(tmp3);
    } else {
      tmp4 = .none;
    }

    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp4;
  }
}

final class _Imported$8 implements i10.Types {
  const _Imported$8();
}

@pragma("wasm:import", r"component._import64")
external i2.WasmI64 _import64();
@pragma("wasm:import", r"component._import65")
external i2.WasmI64 _import65();
@pragma("wasm:import", r"component._import66")
external i2.WasmI32 _import66(i2.WasmI64 p0);
@pragma("wasm:import", r"component._import67")
external i2.WasmI32 _import67(i2.WasmI64 p0);

final class _Imported$9 implements i10.MonotonicClock {
  const _Imported$9();
  @override
  int now() {
    final tmp0 = _import64();
    return tmp0.toInt();
  }

  @override
  int getResolution() {
    final tmp0 = _import65();
    return tmp0.toInt();
  }

  @override
  Future<void> waitUntil({required int when}) async {
    await i0.createSubtask(_import66(i2.WasmI64.fromInt(when))).completion;
  }

  @override
  Future<void> waitFor({required int howLong}) async {
    await i0.createSubtask(_import67(i2.WasmI64.fromInt(howLong))).completion;
  }
}

@pragma("wasm:import", r"component._import68")
external i2.WasmVoid _import68(i2.WasmI32 p0);
@pragma("wasm:import", r"component._import69")
external i2.WasmI64 _import69();

final class _Imported$10 implements i10.SystemClock {
  const _Imported$10();
  @override
  ({int seconds, int nanoseconds}) now() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(16));
    _import68(tmp0);
    final tmp1 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 8);
    final tmp3 = (seconds: tmp1.toInt(), nanoseconds: tmp2.toIntUnsigned());
    i0.dartFree(tmp0, const i2.WasmI32(16), const i2.WasmI32(8));
    return tmp3;
  }

  @override
  int getResolution() {
    final tmp0 = _import69();
    return tmp0.toInt();
  }
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

final class _Vtable90 implements i0.StreamVtable<i5.Uint8List> {
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
  void writeToBuffer(int address, i5.Uint8List elements) {
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
  i5.Uint8List readFromBuffer(int address, int count) {
    final typedList = i5.Uint8List(count);
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
    implements i0.FutureVtable<i0.Result<void, i11.TypesErrorCode>> {
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
  void store(int address, i0.Result<void, i11.TypesErrorCode> value) {
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
          case i11.TypesErrorCodeAccess():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(0),
              offset: 4,
            );

          case i11.TypesErrorCodeAlready():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(1),
              offset: 4,
            );

          case i11.TypesErrorCodeBadDescriptor():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(2),
              offset: 4,
            );

          case i11.TypesErrorCodeBusy():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(3),
              offset: 4,
            );

          case i11.TypesErrorCodeDeadlock():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(4),
              offset: 4,
            );

          case i11.TypesErrorCodeQuota():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(5),
              offset: 4,
            );

          case i11.TypesErrorCodeExist():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(6),
              offset: 4,
            );

          case i11.TypesErrorCodeFileTooLarge():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(7),
              offset: 4,
            );

          case i11.TypesErrorCodeIllegalByteSequence():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(8),
              offset: 4,
            );

          case i11.TypesErrorCodeInProgress():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(9),
              offset: 4,
            );

          case i11.TypesErrorCodeInterrupted():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(10),
              offset: 4,
            );

          case i11.TypesErrorCodeInvalid():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(11),
              offset: 4,
            );

          case i11.TypesErrorCodeIo():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(12),
              offset: 4,
            );

          case i11.TypesErrorCodeIsDirectory():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(13),
              offset: 4,
            );

          case i11.TypesErrorCodeLoop():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(14),
              offset: 4,
            );

          case i11.TypesErrorCodeTooManyLinks():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(15),
              offset: 4,
            );

          case i11.TypesErrorCodeMessageSize():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(16),
              offset: 4,
            );

          case i11.TypesErrorCodeNameTooLong():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(17),
              offset: 4,
            );

          case i11.TypesErrorCodeNoDevice():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(18),
              offset: 4,
            );

          case i11.TypesErrorCodeNoEntry():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(19),
              offset: 4,
            );

          case i11.TypesErrorCodeNoLock():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(20),
              offset: 4,
            );

          case i11.TypesErrorCodeInsufficientMemory():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(21),
              offset: 4,
            );

          case i11.TypesErrorCodeInsufficientSpace():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(22),
              offset: 4,
            );

          case i11.TypesErrorCodeNotDirectory():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(23),
              offset: 4,
            );

          case i11.TypesErrorCodeNotEmpty():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(24),
              offset: 4,
            );

          case i11.TypesErrorCodeNotRecoverable():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(25),
              offset: 4,
            );

          case i11.TypesErrorCodeUnsupported():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(26),
              offset: 4,
            );

          case i11.TypesErrorCodeNoTty():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(27),
              offset: 4,
            );

          case i11.TypesErrorCodeNoSuchDevice():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(28),
              offset: 4,
            );

          case i11.TypesErrorCodeOverflow():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(29),
              offset: 4,
            );

          case i11.TypesErrorCodeNotPermitted():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(30),
              offset: 4,
            );

          case i11.TypesErrorCodePipe():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(31),
              offset: 4,
            );

          case i11.TypesErrorCodeReadOnly():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(32),
              offset: 4,
            );

          case i11.TypesErrorCodeInvalidSeek():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(33),
              offset: 4,
            );

          case i11.TypesErrorCodeTextFileBusy():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(34),
              offset: 4,
            );

          case i11.TypesErrorCodeCrossDevice():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(35),
              offset: 4,
            );

          case i11.TypesErrorCodeOther(payload: final value):
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
  i0.Result<void, i11.TypesErrorCode> load(int address) {
    final wasmAddress = i2.WasmI32.fromInt(address);

    final tmp0 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 0);
    final i0.Result<void, i11.TypesErrorCode> tmp7;
    if (tmp0.toBool()) {
      final tmp1 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp6;
      switch (tmp1.toIntUnsigned()) {
        case 0:
          tmp6 = i11.TypesErrorCodeAccess();
        case 1:
          tmp6 = i11.TypesErrorCodeAlready();
        case 2:
          tmp6 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp6 = i11.TypesErrorCodeBusy();
        case 4:
          tmp6 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp6 = i11.TypesErrorCodeQuota();
        case 6:
          tmp6 = i11.TypesErrorCodeExist();
        case 7:
          tmp6 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp6 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp6 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp6 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp6 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp6 = i11.TypesErrorCodeIo();
        case 13:
          tmp6 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp6 = i11.TypesErrorCodeLoop();
        case 15:
          tmp6 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp6 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp6 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp6 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp6 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp6 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp6 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp6 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp6 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp6 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp6 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp6 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp6 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp6 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp6 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp6 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp6 = i11.TypesErrorCodePipe();
        case 32:
          tmp6 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp6 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp6 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp6 = i11.TypesErrorCodeCrossDevice();
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

          tmp6 = i11.TypesErrorCodeOther(tmp5);

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

@pragma('wasm:import', 'component.stream96.new')
external i2.WasmI64 _streamNew96();
@pragma('wasm:import', 'component.stream96.read')
external i2.WasmI32 _streamRead96(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream96.write')
external i2.WasmI32 _streamWrite96(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream96.drop-readable')
external i2.WasmVoid _streamDropReadable96(i2.WasmI32 stream);
@pragma('wasm:import', 'component.stream96.drop-writable')
external i2.WasmVoid _streamDropWritable96(i2.WasmI32 stream);

final class _Vtable96
    implements
        i0.StreamVtable<List<({i11.TypesDescriptorType type, String name})>> {
  const _Vtable96();

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
    List<({i11.TypesDescriptorType type, String name})> elements,
  ) {
    for (final (i, element) in elements.indexed) {
      final wasmAddress = i2.WasmI32.fromInt(address + i);

      switch (element.type) {
        case i11.TypesDescriptorTypeBlockDevice():
          i0.memory.storeInt8(
            wasmAddress.toIntUnsigned(),
            const i2.WasmI32(0),
            offset: 0,
          );

        case i11.TypesDescriptorTypeCharacterDevice():
          i0.memory.storeInt8(
            wasmAddress.toIntUnsigned(),
            const i2.WasmI32(1),
            offset: 0,
          );

        case i11.TypesDescriptorTypeDirectory():
          i0.memory.storeInt8(
            wasmAddress.toIntUnsigned(),
            const i2.WasmI32(2),
            offset: 0,
          );

        case i11.TypesDescriptorTypeFifo():
          i0.memory.storeInt8(
            wasmAddress.toIntUnsigned(),
            const i2.WasmI32(3),
            offset: 0,
          );

        case i11.TypesDescriptorTypeSymbolicLink():
          i0.memory.storeInt8(
            wasmAddress.toIntUnsigned(),
            const i2.WasmI32(4),
            offset: 0,
          );

        case i11.TypesDescriptorTypeRegularFile():
          i0.memory.storeInt8(
            wasmAddress.toIntUnsigned(),
            const i2.WasmI32(5),
            offset: 0,
          );

        case i11.TypesDescriptorTypeSocket():
          i0.memory.storeInt8(
            wasmAddress.toIntUnsigned(),
            const i2.WasmI32(6),
            offset: 0,
          );

        case i11.TypesDescriptorTypeOther(payload: final value):
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
  List<({i11.TypesDescriptorType type, String name})> readFromBuffer(
    int address,
    int count,
  ) {
    return List.generate(count, (i) {
      final ptr = i2.WasmI32.fromInt(address + i * 24);
      final tmp0 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 0);
      final i11.TypesDescriptorType tmp5;
      switch (tmp0.toIntUnsigned()) {
        case 0:
          tmp5 = i11.TypesDescriptorTypeBlockDevice();
        case 1:
          tmp5 = i11.TypesDescriptorTypeCharacterDevice();
        case 2:
          tmp5 = i11.TypesDescriptorTypeDirectory();
        case 3:
          tmp5 = i11.TypesDescriptorTypeFifo();
        case 4:
          tmp5 = i11.TypesDescriptorTypeSymbolicLink();
        case 5:
          tmp5 = i11.TypesDescriptorTypeRegularFile();
        case 6:
          tmp5 = i11.TypesDescriptorTypeSocket();
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

          tmp5 = i11.TypesDescriptorTypeOther(tmp4);

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
  int newStream() => _streamNew96().toInt();
  @override
  void dropReadable(int stream) {
    _streamDropReadable96(i2.WasmI32.fromInt(stream));
  }

  @override
  void dropWritable(int stream) {
    _streamDropWritable96(i2.WasmI32.fromInt(stream));
  }

  @override
  int read(int stream, int ptr, int n) {
    return _streamRead96(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }

  @override
  int write(int stream, int ptr, int n) {
    return _streamWrite96(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }
}

@pragma("wasm:import", r"component._import85")
external i2.WasmVoid _import85(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import86")
external i2.WasmI32 _import86(i2.WasmI32 p0, i2.WasmI32 p1, i2.WasmI64 p2);
@pragma("wasm:import", r"component._import87")
external i2.WasmI32 _import87(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import88")
external i2.WasmI32 _import88(
  i2.WasmI32 p0,
  i2.WasmI64 p1,
  i2.WasmI64 p2,
  i2.WasmI32 p3,
  i2.WasmI32 p4,
);
@pragma("wasm:import", r"component._import89")
external i2.WasmI32 _import89(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import90")
external i2.WasmI32 _import90(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import91")
external i2.WasmI32 _import91(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import92")
external i2.WasmI32 _import92(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import93")
external i2.WasmI32 _import93(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import94")
external i2.WasmVoid _import94(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import95")
external i2.WasmI32 _import95(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import96")
external i2.WasmI32 _import96(
  i2.WasmI32 p0,
  i2.WasmI32 p1,
  i2.WasmI32 p2,
  i2.WasmI32 p3,
);
@pragma("wasm:import", r"component._import97")
external i2.WasmI32 _import97(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import98")
external i2.WasmI32 _import98(
  i2.WasmI32 p0,
  i2.WasmI32 p1,
  i2.WasmI32 p2,
  i2.WasmI32 p3,
  i2.WasmI32 p4,
);
@pragma("wasm:import", r"component._import99")
external i2.WasmI32 _import99(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import100")
external i2.WasmI32 _import100(i2.WasmI32 p0, i2.WasmI32 p1);

@pragma('wasm:import', r'component._drop$88')
external i2.WasmVoid _drop$88Raw(i2.WasmI32 handle);

void _drop$88(int handle) {
  _drop$88Raw(i2.WasmI32.fromInt(handle));
}

@pragma("wasm:import", r"component._import101")
external i2.WasmI32 _import101(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import103")
external i2.WasmI32 _import103(
  i2.WasmI32 p0,
  i2.WasmI32 p1,
  i2.WasmI32 p2,
  i2.WasmI32 p3,
);
@pragma("wasm:import", r"component._import104")
external i2.WasmI32 _import104(
  i2.WasmI32 p0,
  i2.WasmI32 p1,
  i2.WasmI32 p2,
  i2.WasmI32 p3,
);
@pragma("wasm:import", r"component._import105")
external i2.WasmI32 _import105(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import106")
external i2.WasmI32 _import106(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import107")
external i2.WasmI32 _import107(
  i2.WasmI32 p0,
  i2.WasmI32 p1,
  i2.WasmI32 p2,
  i2.WasmI32 p3,
);
@pragma("wasm:import", r"component._import108")
external i2.WasmI32 _import108(i2.WasmI32 p0, i2.WasmI32 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import109")
external i2.WasmI32 _import109(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import110")
external i2.WasmI32 _import110(
  i2.WasmI32 p0,
  i2.WasmI32 p1,
  i2.WasmI32 p2,
  i2.WasmI32 p3,
  i2.WasmI32 p4,
);

final class _Imported$12 implements i11.Types {
  const _Imported$12();
  @override
  (Stream<i5.Uint8List>, Future<i0.Result<void, i11.TypesErrorCode>>)
  methodDescriptorReadViaStream({
    required i0.Borrowed<i11.TypesDescriptor> self,
    required int offset,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import85(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI64.fromInt(offset),
      tmp0,
    );
    final tmp1 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.ReadableStream(tmp1.toIntUnsigned(), const _Vtable90());
    final tmp3 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
    final tmp4 = i0.readFuture(const _Vtable92(), tmp3.toIntUnsigned());
    final tmp5 = (tmp2, tmp4);
    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp5;
  }

  @override
  Future<i0.Result<void, i11.TypesErrorCode>> methodDescriptorWriteViaStream({
    required i0.Borrowed<i11.TypesDescriptor> self,
    required Stream<i5.Uint8List> data,
    required int offset,
  }) {
    final tmp0 = i0.newReadableStream(const _Vtable90(), data).toWasmI32();
    final tmp1 = _import86(
      i2.WasmI32.fromInt(self.handle),
      tmp0,
      i2.WasmI64.fromInt(offset),
    );
    final tmp2 = i0.readFuture(const _Vtable92(), tmp1.toIntUnsigned());
    return tmp2;
  }

  @override
  Future<i0.Result<void, i11.TypesErrorCode>> methodDescriptorAppendViaStream({
    required i0.Borrowed<i11.TypesDescriptor> self,
    required Stream<i5.Uint8List> data,
  }) {
    final tmp0 = i0.newReadableStream(const _Vtable90(), data).toWasmI32();
    final tmp1 = _import87(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp2 = i0.readFuture(const _Vtable92(), tmp1.toIntUnsigned());
    return tmp2;
  }

  @override
  Future<i0.Result<void, i11.TypesErrorCode>> methodDescriptorAdvise({
    required i0.Borrowed<i11.TypesDescriptor> self,
    required int offset,
    required int length,
    required i11.TypesAdvice advice,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(
          _import88(
            i2.WasmI32.fromInt(self.handle),
            i2.WasmI64.fromInt(offset),
            i2.WasmI64.fromInt(length),
            advice.index.toWasmI32(),
            tmp0,
          ),
        )
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i11.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i11.TypesErrorCodeAccess();
        case 1:
          tmp7 = i11.TypesErrorCodeAlready();
        case 2:
          tmp7 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp7 = i11.TypesErrorCodeBusy();
        case 4:
          tmp7 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp7 = i11.TypesErrorCodeQuota();
        case 6:
          tmp7 = i11.TypesErrorCodeExist();
        case 7:
          tmp7 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp7 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp7 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp7 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp7 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp7 = i11.TypesErrorCodeIo();
        case 13:
          tmp7 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp7 = i11.TypesErrorCodeLoop();
        case 15:
          tmp7 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp7 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp7 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp7 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp7 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp7 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp7 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp7 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp7 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp7 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp7 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp7 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp7 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp7 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp7 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp7 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp7 = i11.TypesErrorCodePipe();
        case 32:
          tmp7 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp7 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp7 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp7 = i11.TypesErrorCodeCrossDevice();
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

          tmp7 = i11.TypesErrorCodeOther(tmp6);

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
  Future<i0.Result<void, i11.TypesErrorCode>> methodDescriptorSyncData({
    required i0.Borrowed<i11.TypesDescriptor> self,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(_import89(i2.WasmI32.fromInt(self.handle), tmp0))
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i11.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i11.TypesErrorCodeAccess();
        case 1:
          tmp7 = i11.TypesErrorCodeAlready();
        case 2:
          tmp7 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp7 = i11.TypesErrorCodeBusy();
        case 4:
          tmp7 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp7 = i11.TypesErrorCodeQuota();
        case 6:
          tmp7 = i11.TypesErrorCodeExist();
        case 7:
          tmp7 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp7 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp7 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp7 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp7 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp7 = i11.TypesErrorCodeIo();
        case 13:
          tmp7 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp7 = i11.TypesErrorCodeLoop();
        case 15:
          tmp7 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp7 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp7 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp7 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp7 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp7 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp7 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp7 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp7 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp7 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp7 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp7 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp7 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp7 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp7 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp7 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp7 = i11.TypesErrorCodePipe();
        case 32:
          tmp7 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp7 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp7 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp7 = i11.TypesErrorCodeCrossDevice();
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

          tmp7 = i11.TypesErrorCodeOther(tmp6);

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
  Future<i0.Result<i11.TypesDescriptorFlags, i11.TypesErrorCode>>
  methodDescriptorGetFlags({
    required i0.Borrowed<i11.TypesDescriptor> self,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(_import90(i2.WasmI32.fromInt(self.handle), tmp0))
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i11.TypesDescriptorFlags, i11.TypesErrorCode> tmp10;
    if (tmp1.toBool()) {
      final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp9;
      switch (tmp4.toIntUnsigned()) {
        case 0:
          tmp9 = i11.TypesErrorCodeAccess();
        case 1:
          tmp9 = i11.TypesErrorCodeAlready();
        case 2:
          tmp9 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp9 = i11.TypesErrorCodeBusy();
        case 4:
          tmp9 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp9 = i11.TypesErrorCodeQuota();
        case 6:
          tmp9 = i11.TypesErrorCodeExist();
        case 7:
          tmp9 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp9 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp9 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp9 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp9 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp9 = i11.TypesErrorCodeIo();
        case 13:
          tmp9 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp9 = i11.TypesErrorCodeLoop();
        case 15:
          tmp9 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp9 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp9 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp9 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp9 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp9 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp9 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp9 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp9 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp9 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp9 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp9 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp9 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp9 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp9 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp9 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp9 = i11.TypesErrorCodePipe();
        case 32:
          tmp9 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp9 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp9 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp9 = i11.TypesErrorCodeCrossDevice();
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

          tmp9 = i11.TypesErrorCodeOther(tmp8);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp10 = .error(tmp9);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i11.TypesDescriptorFlags(tmp2.toIntUnsigned());

      tmp10 = .ok(tmp3);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp10;
  }

  @override
  Future<i0.Result<i11.TypesDescriptorType, i11.TypesErrorCode>>
  methodDescriptorGetType({
    required i0.Borrowed<i11.TypesDescriptor> self,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(_import91(i2.WasmI32.fromInt(self.handle), tmp0))
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i11.TypesDescriptorType, i11.TypesErrorCode> tmp14;
    if (tmp1.toBool()) {
      final tmp8 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp13;
      switch (tmp8.toIntUnsigned()) {
        case 0:
          tmp13 = i11.TypesErrorCodeAccess();
        case 1:
          tmp13 = i11.TypesErrorCodeAlready();
        case 2:
          tmp13 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp13 = i11.TypesErrorCodeBusy();
        case 4:
          tmp13 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp13 = i11.TypesErrorCodeQuota();
        case 6:
          tmp13 = i11.TypesErrorCodeExist();
        case 7:
          tmp13 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp13 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp13 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp13 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp13 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp13 = i11.TypesErrorCodeIo();
        case 13:
          tmp13 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp13 = i11.TypesErrorCodeLoop();
        case 15:
          tmp13 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp13 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp13 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp13 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp13 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp13 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp13 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp13 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp13 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp13 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp13 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp13 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp13 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp13 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp13 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp13 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp13 = i11.TypesErrorCodePipe();
        case 32:
          tmp13 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp13 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp13 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp13 = i11.TypesErrorCodeCrossDevice();
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

          tmp13 = i11.TypesErrorCodeOther(tmp12);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp14 = .error(tmp13);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i11.TypesDescriptorType tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i11.TypesDescriptorTypeBlockDevice();
        case 1:
          tmp7 = i11.TypesDescriptorTypeCharacterDevice();
        case 2:
          tmp7 = i11.TypesDescriptorTypeDirectory();
        case 3:
          tmp7 = i11.TypesDescriptorTypeFifo();
        case 4:
          tmp7 = i11.TypesDescriptorTypeSymbolicLink();
        case 5:
          tmp7 = i11.TypesDescriptorTypeRegularFile();
        case 6:
          tmp7 = i11.TypesDescriptorTypeSocket();
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

          tmp7 = i11.TypesDescriptorTypeOther(tmp6);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp14 = .ok(tmp7);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp14;
  }

  @override
  Future<i0.Result<void, i11.TypesErrorCode>> methodDescriptorSetSize({
    required i0.Borrowed<i11.TypesDescriptor> self,
    required int size,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(
          _import92(
            i2.WasmI32.fromInt(self.handle),
            i2.WasmI64.fromInt(size),
            tmp0,
          ),
        )
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i11.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i11.TypesErrorCodeAccess();
        case 1:
          tmp7 = i11.TypesErrorCodeAlready();
        case 2:
          tmp7 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp7 = i11.TypesErrorCodeBusy();
        case 4:
          tmp7 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp7 = i11.TypesErrorCodeQuota();
        case 6:
          tmp7 = i11.TypesErrorCodeExist();
        case 7:
          tmp7 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp7 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp7 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp7 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp7 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp7 = i11.TypesErrorCodeIo();
        case 13:
          tmp7 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp7 = i11.TypesErrorCodeLoop();
        case 15:
          tmp7 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp7 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp7 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp7 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp7 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp7 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp7 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp7 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp7 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp7 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp7 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp7 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp7 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp7 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp7 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp7 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp7 = i11.TypesErrorCodePipe();
        case 32:
          tmp7 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp7 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp7 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp7 = i11.TypesErrorCodeCrossDevice();
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

          tmp7 = i11.TypesErrorCodeOther(tmp6);

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
  Future<i0.Result<void, i11.TypesErrorCode>> methodDescriptorSetTimes({
    required i0.Borrowed<i11.TypesDescriptor> self,
    required i11.TypesNewTimestamp dataAccessTimestamp,
    required i11.TypesNewTimestamp dataModificationTimestamp,
  }) async {
    final tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(56));
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      i2.WasmI32.fromInt(self.handle),
      offset: 0,
    );
    switch (dataAccessTimestamp) {
      case i11.TypesNewTimestampNoChange():
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(8)).toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 0,
        );

      case i11.TypesNewTimestampNow():
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(8)).toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 0,
        );

      case i11.TypesNewTimestampTimestamp(payload: final value):
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
      case i11.TypesNewTimestampNoChange():
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(32)).toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 0,
        );

      case i11.TypesNewTimestampNow():
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(32)).toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 0,
        );

      case i11.TypesNewTimestampTimestamp(payload: final value):
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
    await i0.createSubtask(_import93(tmp0, tmp1)).completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<void, i11.TypesErrorCode> tmp9;
    if (tmp2.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i11.TypesErrorCodeAccess();
        case 1:
          tmp8 = i11.TypesErrorCodeAlready();
        case 2:
          tmp8 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp8 = i11.TypesErrorCodeBusy();
        case 4:
          tmp8 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp8 = i11.TypesErrorCodeQuota();
        case 6:
          tmp8 = i11.TypesErrorCodeExist();
        case 7:
          tmp8 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp8 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp8 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp8 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp8 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp8 = i11.TypesErrorCodeIo();
        case 13:
          tmp8 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp8 = i11.TypesErrorCodeLoop();
        case 15:
          tmp8 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp8 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp8 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp8 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp8 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp8 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp8 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp8 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp8 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp8 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp8 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp8 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp8 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp8 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp8 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp8 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp8 = i11.TypesErrorCodePipe();
        case 32:
          tmp8 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp8 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp8 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp8 = i11.TypesErrorCodeCrossDevice();
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

          tmp8 = i11.TypesErrorCodeOther(tmp7);

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
    Stream<List<({i11.TypesDescriptorType type, String name})>>,
    Future<i0.Result<void, i11.TypesErrorCode>>,
  )
  methodDescriptorReadDirectory({
    required i0.Borrowed<i11.TypesDescriptor> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import94(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.ReadableStream(tmp1.toIntUnsigned(), const _Vtable96());
    final tmp3 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
    final tmp4 = i0.readFuture(const _Vtable92(), tmp3.toIntUnsigned());
    final tmp5 = (tmp2, tmp4);
    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp5;
  }

  @override
  Future<i0.Result<void, i11.TypesErrorCode>> methodDescriptorSync({
    required i0.Borrowed<i11.TypesDescriptor> self,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(_import95(i2.WasmI32.fromInt(self.handle), tmp0))
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i11.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i11.TypesErrorCodeAccess();
        case 1:
          tmp7 = i11.TypesErrorCodeAlready();
        case 2:
          tmp7 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp7 = i11.TypesErrorCodeBusy();
        case 4:
          tmp7 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp7 = i11.TypesErrorCodeQuota();
        case 6:
          tmp7 = i11.TypesErrorCodeExist();
        case 7:
          tmp7 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp7 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp7 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp7 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp7 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp7 = i11.TypesErrorCodeIo();
        case 13:
          tmp7 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp7 = i11.TypesErrorCodeLoop();
        case 15:
          tmp7 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp7 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp7 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp7 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp7 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp7 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp7 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp7 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp7 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp7 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp7 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp7 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp7 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp7 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp7 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp7 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp7 = i11.TypesErrorCodePipe();
        case 32:
          tmp7 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp7 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp7 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp7 = i11.TypesErrorCodeCrossDevice();
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

          tmp7 = i11.TypesErrorCodeOther(tmp6);

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
  Future<i0.Result<void, i11.TypesErrorCode>>
  methodDescriptorCreateDirectoryAt({
    required i0.Borrowed<i11.TypesDescriptor> self,
    required String path,
  }) async {
    final tmp0 = i0.AllocatedString.allocateUtf16(path);
    var tmp1 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(
          _import96(
            i2.WasmI32.fromInt(self.handle),
            tmp0.ptr,
            tmp0.packedLength,
            tmp1,
          ),
        )
        .completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<void, i11.TypesErrorCode> tmp9;
    if (tmp2.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i11.TypesErrorCodeAccess();
        case 1:
          tmp8 = i11.TypesErrorCodeAlready();
        case 2:
          tmp8 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp8 = i11.TypesErrorCodeBusy();
        case 4:
          tmp8 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp8 = i11.TypesErrorCodeQuota();
        case 6:
          tmp8 = i11.TypesErrorCodeExist();
        case 7:
          tmp8 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp8 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp8 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp8 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp8 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp8 = i11.TypesErrorCodeIo();
        case 13:
          tmp8 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp8 = i11.TypesErrorCodeLoop();
        case 15:
          tmp8 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp8 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp8 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp8 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp8 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp8 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp8 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp8 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp8 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp8 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp8 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp8 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp8 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp8 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp8 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp8 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp8 = i11.TypesErrorCodePipe();
        case 32:
          tmp8 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp8 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp8 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp8 = i11.TypesErrorCodeCrossDevice();
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

          tmp8 = i11.TypesErrorCodeOther(tmp7);

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
        i11.TypesDescriptorType type,
        int linkCount,
        int size,
        i0.Option<({int seconds, int nanoseconds})> dataAccessTimestamp,
        i0.Option<({int seconds, int nanoseconds})> dataModificationTimestamp,
        i0.Option<({int seconds, int nanoseconds})> statusChangeTimestamp,
      }),
      i11.TypesErrorCode
    >
  >
  methodDescriptorStat({required i0.Borrowed<i11.TypesDescriptor> self}) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(112));
    await i0
        .createSubtask(_import97(i2.WasmI32.fromInt(self.handle), tmp0))
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<
      ({
        i11.TypesDescriptorType type,
        int linkCount,
        int size,
        i0.Option<({int seconds, int nanoseconds})> dataAccessTimestamp,
        i0.Option<({int seconds, int nanoseconds})> dataModificationTimestamp,
        i0.Option<({int seconds, int nanoseconds})> statusChangeTimestamp,
      }),
      i11.TypesErrorCode
    >
    tmp32;
    if (tmp1.toBool()) {
      final tmp26 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i11.TypesErrorCode tmp31;
      switch (tmp26.toIntUnsigned()) {
        case 0:
          tmp31 = i11.TypesErrorCodeAccess();
        case 1:
          tmp31 = i11.TypesErrorCodeAlready();
        case 2:
          tmp31 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp31 = i11.TypesErrorCodeBusy();
        case 4:
          tmp31 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp31 = i11.TypesErrorCodeQuota();
        case 6:
          tmp31 = i11.TypesErrorCodeExist();
        case 7:
          tmp31 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp31 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp31 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp31 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp31 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp31 = i11.TypesErrorCodeIo();
        case 13:
          tmp31 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp31 = i11.TypesErrorCodeLoop();
        case 15:
          tmp31 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp31 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp31 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp31 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp31 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp31 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp31 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp31 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp31 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp31 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp31 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp31 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp31 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp31 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp31 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp31 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp31 = i11.TypesErrorCodePipe();
        case 32:
          tmp31 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp31 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp31 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp31 = i11.TypesErrorCodeCrossDevice();
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

          tmp31 = i11.TypesErrorCodeOther(tmp30);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp32 = .error(tmp31);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i11.TypesDescriptorType tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i11.TypesDescriptorTypeBlockDevice();
        case 1:
          tmp7 = i11.TypesDescriptorTypeCharacterDevice();
        case 2:
          tmp7 = i11.TypesDescriptorTypeDirectory();
        case 3:
          tmp7 = i11.TypesDescriptorTypeFifo();
        case 4:
          tmp7 = i11.TypesDescriptorTypeSymbolicLink();
        case 5:
          tmp7 = i11.TypesDescriptorTypeRegularFile();
        case 6:
          tmp7 = i11.TypesDescriptorTypeSocket();
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

          tmp7 = i11.TypesDescriptorTypeOther(tmp6);

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
        i11.TypesDescriptorType type,
        int linkCount,
        int size,
        i0.Option<({int seconds, int nanoseconds})> dataAccessTimestamp,
        i0.Option<({int seconds, int nanoseconds})> dataModificationTimestamp,
        i0.Option<({int seconds, int nanoseconds})> statusChangeTimestamp,
      }),
      i11.TypesErrorCode
    >
  >
  methodDescriptorStatAt({
    required i0.Borrowed<i11.TypesDescriptor> self,
    required i11.TypesPathFlags pathFlags,
    required String path,
  }) async {
    final tmp0 = i0.AllocatedString.allocateUtf16(path);
    var tmp1 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(112));
    await i0
        .createSubtask(
          _import98(
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
        i11.TypesDescriptorType type,
        int linkCount,
        int size,
        i0.Option<({int seconds, int nanoseconds})> dataAccessTimestamp,
        i0.Option<({int seconds, int nanoseconds})> dataModificationTimestamp,
        i0.Option<({int seconds, int nanoseconds})> statusChangeTimestamp,
      }),
      i11.TypesErrorCode
    >
    tmp33;
    if (tmp2.toBool()) {
      final tmp27 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 8);
      final i11.TypesErrorCode tmp32;
      switch (tmp27.toIntUnsigned()) {
        case 0:
          tmp32 = i11.TypesErrorCodeAccess();
        case 1:
          tmp32 = i11.TypesErrorCodeAlready();
        case 2:
          tmp32 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp32 = i11.TypesErrorCodeBusy();
        case 4:
          tmp32 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp32 = i11.TypesErrorCodeQuota();
        case 6:
          tmp32 = i11.TypesErrorCodeExist();
        case 7:
          tmp32 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp32 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp32 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp32 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp32 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp32 = i11.TypesErrorCodeIo();
        case 13:
          tmp32 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp32 = i11.TypesErrorCodeLoop();
        case 15:
          tmp32 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp32 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp32 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp32 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp32 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp32 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp32 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp32 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp32 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp32 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp32 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp32 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp32 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp32 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp32 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp32 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp32 = i11.TypesErrorCodePipe();
        case 32:
          tmp32 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp32 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp32 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp32 = i11.TypesErrorCodeCrossDevice();
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

          tmp32 = i11.TypesErrorCodeOther(tmp31);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp33 = .error(tmp32);
    } else {
      final tmp3 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 8);
      final i11.TypesDescriptorType tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i11.TypesDescriptorTypeBlockDevice();
        case 1:
          tmp8 = i11.TypesDescriptorTypeCharacterDevice();
        case 2:
          tmp8 = i11.TypesDescriptorTypeDirectory();
        case 3:
          tmp8 = i11.TypesDescriptorTypeFifo();
        case 4:
          tmp8 = i11.TypesDescriptorTypeSymbolicLink();
        case 5:
          tmp8 = i11.TypesDescriptorTypeRegularFile();
        case 6:
          tmp8 = i11.TypesDescriptorTypeSocket();
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

          tmp8 = i11.TypesDescriptorTypeOther(tmp7);

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
  Future<i0.Result<void, i11.TypesErrorCode>> methodDescriptorSetTimesAt({
    required i0.Borrowed<i11.TypesDescriptor> self,
    required i11.TypesPathFlags pathFlags,
    required String path,
    required i11.TypesNewTimestamp dataAccessTimestamp,
    required i11.TypesNewTimestamp dataModificationTimestamp,
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
      case i11.TypesNewTimestampNoChange():
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(16)).toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 0,
        );

      case i11.TypesNewTimestampNow():
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(16)).toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 0,
        );

      case i11.TypesNewTimestampTimestamp(payload: final value):
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
      case i11.TypesNewTimestampNoChange():
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(40)).toIntUnsigned(),
          const i2.WasmI32(0),
          offset: 0,
        );

      case i11.TypesNewTimestampNow():
        i0.memory.storeInt8(
          (tmp0 + const i2.WasmI32(40)).toIntUnsigned(),
          const i2.WasmI32(1),
          offset: 0,
        );

      case i11.TypesNewTimestampTimestamp(payload: final value):
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
    await i0.createSubtask(_import99(tmp0, tmp2)).completion;
    final tmp3 = i0.memory.loadUint8(tmp2.toIntUnsigned(), offset: 0);
    final i0.Result<void, i11.TypesErrorCode> tmp10;
    if (tmp3.toBool()) {
      final tmp4 = i0.memory.loadUint8(tmp2.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp9;
      switch (tmp4.toIntUnsigned()) {
        case 0:
          tmp9 = i11.TypesErrorCodeAccess();
        case 1:
          tmp9 = i11.TypesErrorCodeAlready();
        case 2:
          tmp9 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp9 = i11.TypesErrorCodeBusy();
        case 4:
          tmp9 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp9 = i11.TypesErrorCodeQuota();
        case 6:
          tmp9 = i11.TypesErrorCodeExist();
        case 7:
          tmp9 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp9 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp9 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp9 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp9 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp9 = i11.TypesErrorCodeIo();
        case 13:
          tmp9 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp9 = i11.TypesErrorCodeLoop();
        case 15:
          tmp9 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp9 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp9 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp9 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp9 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp9 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp9 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp9 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp9 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp9 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp9 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp9 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp9 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp9 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp9 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp9 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp9 = i11.TypesErrorCodePipe();
        case 32:
          tmp9 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp9 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp9 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp9 = i11.TypesErrorCodeCrossDevice();
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

          tmp9 = i11.TypesErrorCodeOther(tmp8);

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
  Future<i0.Result<void, i11.TypesErrorCode>> methodDescriptorLinkAt({
    required i0.Borrowed<i11.TypesDescriptor> self,
    required i11.TypesPathFlags oldPathFlags,
    required String oldPath,
    required i0.Borrowed<i11.TypesDescriptor> newDescriptor,
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
    await i0.createSubtask(_import100(tmp0, tmp3)).completion;
    final tmp4 = i0.memory.loadUint8(tmp3.toIntUnsigned(), offset: 0);
    final i0.Result<void, i11.TypesErrorCode> tmp11;
    if (tmp4.toBool()) {
      final tmp5 = i0.memory.loadUint8(tmp3.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp10;
      switch (tmp5.toIntUnsigned()) {
        case 0:
          tmp10 = i11.TypesErrorCodeAccess();
        case 1:
          tmp10 = i11.TypesErrorCodeAlready();
        case 2:
          tmp10 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp10 = i11.TypesErrorCodeBusy();
        case 4:
          tmp10 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp10 = i11.TypesErrorCodeQuota();
        case 6:
          tmp10 = i11.TypesErrorCodeExist();
        case 7:
          tmp10 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp10 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp10 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp10 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp10 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp10 = i11.TypesErrorCodeIo();
        case 13:
          tmp10 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp10 = i11.TypesErrorCodeLoop();
        case 15:
          tmp10 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp10 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp10 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp10 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp10 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp10 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp10 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp10 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp10 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp10 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp10 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp10 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp10 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp10 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp10 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp10 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp10 = i11.TypesErrorCodePipe();
        case 32:
          tmp10 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp10 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp10 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp10 = i11.TypesErrorCodeCrossDevice();
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

          tmp10 = i11.TypesErrorCodeOther(tmp9);

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
  Future<i0.Result<i0.Owned<i11.TypesDescriptor>, i11.TypesErrorCode>>
  methodDescriptorOpenAt({
    required i0.Borrowed<i11.TypesDescriptor> self,
    required i11.TypesPathFlags pathFlags,
    required String path,
    required i11.TypesOpenFlags openFlags,
    required i11.TypesDescriptorFlags flags,
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
    await i0.createSubtask(_import101(tmp0, tmp2)).completion;
    final tmp3 = i0.memory.loadUint8(tmp2.toIntUnsigned(), offset: 0);
    final i0.Result<i0.Owned<i11.TypesDescriptor>, i11.TypesErrorCode> tmp12;
    if (tmp3.toBool()) {
      final tmp6 = i0.memory.loadUint8(tmp2.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp11;
      switch (tmp6.toIntUnsigned()) {
        case 0:
          tmp11 = i11.TypesErrorCodeAccess();
        case 1:
          tmp11 = i11.TypesErrorCodeAlready();
        case 2:
          tmp11 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp11 = i11.TypesErrorCodeBusy();
        case 4:
          tmp11 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp11 = i11.TypesErrorCodeQuota();
        case 6:
          tmp11 = i11.TypesErrorCodeExist();
        case 7:
          tmp11 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp11 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp11 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp11 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp11 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp11 = i11.TypesErrorCodeIo();
        case 13:
          tmp11 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp11 = i11.TypesErrorCodeLoop();
        case 15:
          tmp11 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp11 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp11 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp11 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp11 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp11 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp11 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp11 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp11 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp11 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp11 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp11 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp11 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp11 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp11 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp11 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp11 = i11.TypesErrorCodePipe();
        case 32:
          tmp11 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp11 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp11 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp11 = i11.TypesErrorCodeCrossDevice();
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

          tmp11 = i11.TypesErrorCodeOther(tmp10);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp12 = .error(tmp11);
    } else {
      final tmp4 = i0.memory.loadInt32(tmp2.toIntUnsigned(), offset: 4);
      final tmp5 = i0.Owned<i11.TypesDescriptor>(
        tmp4.toIntUnsigned(),
        _drop$88,
      );
      tmp12 = .ok(tmp5);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    i0.dartFree(tmp2, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp12;
  }

  @override
  Future<i0.Result<String, i11.TypesErrorCode>> methodDescriptorReadlinkAt({
    required i0.Borrowed<i11.TypesDescriptor> self,
    required String path,
  }) async {
    final tmp0 = i0.AllocatedString.allocateUtf16(path);
    var tmp1 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(
          _import103(
            i2.WasmI32.fromInt(self.handle),
            tmp0.ptr,
            tmp0.packedLength,
            tmp1,
          ),
        )
        .completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<String, i11.TypesErrorCode> tmp11;
    if (tmp2.toBool()) {
      final tmp5 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp10;
      switch (tmp5.toIntUnsigned()) {
        case 0:
          tmp10 = i11.TypesErrorCodeAccess();
        case 1:
          tmp10 = i11.TypesErrorCodeAlready();
        case 2:
          tmp10 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp10 = i11.TypesErrorCodeBusy();
        case 4:
          tmp10 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp10 = i11.TypesErrorCodeQuota();
        case 6:
          tmp10 = i11.TypesErrorCodeExist();
        case 7:
          tmp10 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp10 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp10 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp10 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp10 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp10 = i11.TypesErrorCodeIo();
        case 13:
          tmp10 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp10 = i11.TypesErrorCodeLoop();
        case 15:
          tmp10 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp10 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp10 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp10 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp10 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp10 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp10 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp10 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp10 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp10 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp10 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp10 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp10 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp10 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp10 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp10 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp10 = i11.TypesErrorCodePipe();
        case 32:
          tmp10 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp10 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp10 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp10 = i11.TypesErrorCodeCrossDevice();
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

          tmp10 = i11.TypesErrorCodeOther(tmp9);

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
  Future<i0.Result<void, i11.TypesErrorCode>>
  methodDescriptorRemoveDirectoryAt({
    required i0.Borrowed<i11.TypesDescriptor> self,
    required String path,
  }) async {
    final tmp0 = i0.AllocatedString.allocateUtf16(path);
    var tmp1 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(
          _import104(
            i2.WasmI32.fromInt(self.handle),
            tmp0.ptr,
            tmp0.packedLength,
            tmp1,
          ),
        )
        .completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<void, i11.TypesErrorCode> tmp9;
    if (tmp2.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i11.TypesErrorCodeAccess();
        case 1:
          tmp8 = i11.TypesErrorCodeAlready();
        case 2:
          tmp8 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp8 = i11.TypesErrorCodeBusy();
        case 4:
          tmp8 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp8 = i11.TypesErrorCodeQuota();
        case 6:
          tmp8 = i11.TypesErrorCodeExist();
        case 7:
          tmp8 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp8 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp8 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp8 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp8 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp8 = i11.TypesErrorCodeIo();
        case 13:
          tmp8 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp8 = i11.TypesErrorCodeLoop();
        case 15:
          tmp8 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp8 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp8 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp8 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp8 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp8 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp8 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp8 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp8 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp8 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp8 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp8 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp8 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp8 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp8 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp8 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp8 = i11.TypesErrorCodePipe();
        case 32:
          tmp8 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp8 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp8 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp8 = i11.TypesErrorCodeCrossDevice();
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

          tmp8 = i11.TypesErrorCodeOther(tmp7);

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
  Future<i0.Result<void, i11.TypesErrorCode>> methodDescriptorRenameAt({
    required i0.Borrowed<i11.TypesDescriptor> self,
    required String oldPath,
    required i0.Borrowed<i11.TypesDescriptor> newDescriptor,
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
    await i0.createSubtask(_import105(tmp0, tmp3)).completion;
    final tmp4 = i0.memory.loadUint8(tmp3.toIntUnsigned(), offset: 0);
    final i0.Result<void, i11.TypesErrorCode> tmp11;
    if (tmp4.toBool()) {
      final tmp5 = i0.memory.loadUint8(tmp3.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp10;
      switch (tmp5.toIntUnsigned()) {
        case 0:
          tmp10 = i11.TypesErrorCodeAccess();
        case 1:
          tmp10 = i11.TypesErrorCodeAlready();
        case 2:
          tmp10 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp10 = i11.TypesErrorCodeBusy();
        case 4:
          tmp10 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp10 = i11.TypesErrorCodeQuota();
        case 6:
          tmp10 = i11.TypesErrorCodeExist();
        case 7:
          tmp10 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp10 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp10 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp10 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp10 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp10 = i11.TypesErrorCodeIo();
        case 13:
          tmp10 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp10 = i11.TypesErrorCodeLoop();
        case 15:
          tmp10 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp10 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp10 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp10 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp10 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp10 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp10 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp10 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp10 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp10 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp10 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp10 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp10 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp10 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp10 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp10 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp10 = i11.TypesErrorCodePipe();
        case 32:
          tmp10 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp10 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp10 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp10 = i11.TypesErrorCodeCrossDevice();
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

          tmp10 = i11.TypesErrorCodeOther(tmp9);

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
  Future<i0.Result<void, i11.TypesErrorCode>> methodDescriptorSymlinkAt({
    required i0.Borrowed<i11.TypesDescriptor> self,
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
    await i0.createSubtask(_import106(tmp0, tmp3)).completion;
    final tmp4 = i0.memory.loadUint8(tmp3.toIntUnsigned(), offset: 0);
    final i0.Result<void, i11.TypesErrorCode> tmp11;
    if (tmp4.toBool()) {
      final tmp5 = i0.memory.loadUint8(tmp3.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp10;
      switch (tmp5.toIntUnsigned()) {
        case 0:
          tmp10 = i11.TypesErrorCodeAccess();
        case 1:
          tmp10 = i11.TypesErrorCodeAlready();
        case 2:
          tmp10 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp10 = i11.TypesErrorCodeBusy();
        case 4:
          tmp10 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp10 = i11.TypesErrorCodeQuota();
        case 6:
          tmp10 = i11.TypesErrorCodeExist();
        case 7:
          tmp10 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp10 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp10 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp10 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp10 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp10 = i11.TypesErrorCodeIo();
        case 13:
          tmp10 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp10 = i11.TypesErrorCodeLoop();
        case 15:
          tmp10 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp10 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp10 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp10 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp10 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp10 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp10 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp10 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp10 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp10 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp10 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp10 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp10 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp10 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp10 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp10 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp10 = i11.TypesErrorCodePipe();
        case 32:
          tmp10 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp10 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp10 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp10 = i11.TypesErrorCodeCrossDevice();
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

          tmp10 = i11.TypesErrorCodeOther(tmp9);

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
  Future<i0.Result<void, i11.TypesErrorCode>> methodDescriptorUnlinkFileAt({
    required i0.Borrowed<i11.TypesDescriptor> self,
    required String path,
  }) async {
    final tmp0 = i0.AllocatedString.allocateUtf16(path);
    var tmp1 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(
          _import107(
            i2.WasmI32.fromInt(self.handle),
            tmp0.ptr,
            tmp0.packedLength,
            tmp1,
          ),
        )
        .completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<void, i11.TypesErrorCode> tmp9;
    if (tmp2.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 4);
      final i11.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i11.TypesErrorCodeAccess();
        case 1:
          tmp8 = i11.TypesErrorCodeAlready();
        case 2:
          tmp8 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp8 = i11.TypesErrorCodeBusy();
        case 4:
          tmp8 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp8 = i11.TypesErrorCodeQuota();
        case 6:
          tmp8 = i11.TypesErrorCodeExist();
        case 7:
          tmp8 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp8 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp8 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp8 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp8 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp8 = i11.TypesErrorCodeIo();
        case 13:
          tmp8 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp8 = i11.TypesErrorCodeLoop();
        case 15:
          tmp8 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp8 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp8 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp8 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp8 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp8 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp8 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp8 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp8 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp8 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp8 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp8 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp8 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp8 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp8 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp8 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp8 = i11.TypesErrorCodePipe();
        case 32:
          tmp8 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp8 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp8 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp8 = i11.TypesErrorCodeCrossDevice();
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

          tmp8 = i11.TypesErrorCodeOther(tmp7);

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
    required i0.Borrowed<i11.TypesDescriptor> self,
    required i0.Borrowed<i11.TypesDescriptor> other,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(1), const i2.WasmI32(1));
    await i0
        .createSubtask(
          _import108(
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
  Future<i0.Result<({int lower, int upper}), i11.TypesErrorCode>>
  methodDescriptorMetadataHash({
    required i0.Borrowed<i11.TypesDescriptor> self,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(24));
    await i0
        .createSubtask(_import109(i2.WasmI32.fromInt(self.handle), tmp0))
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<({int lower, int upper}), i11.TypesErrorCode> tmp11;
    if (tmp1.toBool()) {
      final tmp5 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i11.TypesErrorCode tmp10;
      switch (tmp5.toIntUnsigned()) {
        case 0:
          tmp10 = i11.TypesErrorCodeAccess();
        case 1:
          tmp10 = i11.TypesErrorCodeAlready();
        case 2:
          tmp10 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp10 = i11.TypesErrorCodeBusy();
        case 4:
          tmp10 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp10 = i11.TypesErrorCodeQuota();
        case 6:
          tmp10 = i11.TypesErrorCodeExist();
        case 7:
          tmp10 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp10 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp10 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp10 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp10 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp10 = i11.TypesErrorCodeIo();
        case 13:
          tmp10 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp10 = i11.TypesErrorCodeLoop();
        case 15:
          tmp10 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp10 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp10 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp10 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp10 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp10 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp10 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp10 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp10 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp10 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp10 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp10 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp10 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp10 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp10 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp10 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp10 = i11.TypesErrorCodePipe();
        case 32:
          tmp10 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp10 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp10 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp10 = i11.TypesErrorCodeCrossDevice();
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

          tmp10 = i11.TypesErrorCodeOther(tmp9);

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
  Future<i0.Result<({int lower, int upper}), i11.TypesErrorCode>>
  methodDescriptorMetadataHashAt({
    required i0.Borrowed<i11.TypesDescriptor> self,
    required i11.TypesPathFlags pathFlags,
    required String path,
  }) async {
    final tmp0 = i0.AllocatedString.allocateUtf16(path);
    var tmp1 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(24));
    await i0
        .createSubtask(
          _import110(
            i2.WasmI32.fromInt(self.handle),
            pathFlags.toWasmI32(),
            tmp0.ptr,
            tmp0.packedLength,
            tmp1,
          ),
        )
        .completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<({int lower, int upper}), i11.TypesErrorCode> tmp12;
    if (tmp2.toBool()) {
      final tmp6 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 8);
      final i11.TypesErrorCode tmp11;
      switch (tmp6.toIntUnsigned()) {
        case 0:
          tmp11 = i11.TypesErrorCodeAccess();
        case 1:
          tmp11 = i11.TypesErrorCodeAlready();
        case 2:
          tmp11 = i11.TypesErrorCodeBadDescriptor();
        case 3:
          tmp11 = i11.TypesErrorCodeBusy();
        case 4:
          tmp11 = i11.TypesErrorCodeDeadlock();
        case 5:
          tmp11 = i11.TypesErrorCodeQuota();
        case 6:
          tmp11 = i11.TypesErrorCodeExist();
        case 7:
          tmp11 = i11.TypesErrorCodeFileTooLarge();
        case 8:
          tmp11 = i11.TypesErrorCodeIllegalByteSequence();
        case 9:
          tmp11 = i11.TypesErrorCodeInProgress();
        case 10:
          tmp11 = i11.TypesErrorCodeInterrupted();
        case 11:
          tmp11 = i11.TypesErrorCodeInvalid();
        case 12:
          tmp11 = i11.TypesErrorCodeIo();
        case 13:
          tmp11 = i11.TypesErrorCodeIsDirectory();
        case 14:
          tmp11 = i11.TypesErrorCodeLoop();
        case 15:
          tmp11 = i11.TypesErrorCodeTooManyLinks();
        case 16:
          tmp11 = i11.TypesErrorCodeMessageSize();
        case 17:
          tmp11 = i11.TypesErrorCodeNameTooLong();
        case 18:
          tmp11 = i11.TypesErrorCodeNoDevice();
        case 19:
          tmp11 = i11.TypesErrorCodeNoEntry();
        case 20:
          tmp11 = i11.TypesErrorCodeNoLock();
        case 21:
          tmp11 = i11.TypesErrorCodeInsufficientMemory();
        case 22:
          tmp11 = i11.TypesErrorCodeInsufficientSpace();
        case 23:
          tmp11 = i11.TypesErrorCodeNotDirectory();
        case 24:
          tmp11 = i11.TypesErrorCodeNotEmpty();
        case 25:
          tmp11 = i11.TypesErrorCodeNotRecoverable();
        case 26:
          tmp11 = i11.TypesErrorCodeUnsupported();
        case 27:
          tmp11 = i11.TypesErrorCodeNoTty();
        case 28:
          tmp11 = i11.TypesErrorCodeNoSuchDevice();
        case 29:
          tmp11 = i11.TypesErrorCodeOverflow();
        case 30:
          tmp11 = i11.TypesErrorCodeNotPermitted();
        case 31:
          tmp11 = i11.TypesErrorCodePipe();
        case 32:
          tmp11 = i11.TypesErrorCodeReadOnly();
        case 33:
          tmp11 = i11.TypesErrorCodeInvalidSeek();
        case 34:
          tmp11 = i11.TypesErrorCodeTextFileBusy();
        case 35:
          tmp11 = i11.TypesErrorCodeCrossDevice();
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

          tmp11 = i11.TypesErrorCodeOther(tmp10);

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

@pragma('wasm:import', r'component._drop$103')
external i2.WasmVoid _drop$103Raw(i2.WasmI32 handle);

void _drop$103(int handle) {
  _drop$103Raw(i2.WasmI32.fromInt(handle));
}

@pragma("wasm:import", r"component._import111")
external i2.WasmVoid _import111(i2.WasmI32 p0);

final class _Imported$13 implements i11.Preopens {
  const _Imported$13();
  @override
  List<(i0.Owned<i11.TypesDescriptor>, String)> getDirectories() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import111(tmp0);
    final tmp1 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);

    final tmp9 = tmp1.toIntUnsigned();
    final tmp8 = List.generate(tmp2.toIntUnsigned(), growable: false, (i) {
      final elementPtr = i2.WasmI32.fromInt(tmp9 + i * 12);
      final tmp3 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 0);
      final tmp4 = i0.Owned<i11.TypesDescriptor>(
        tmp3.toIntUnsigned(),
        _drop$103,
      );
      final tmp5 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 4);
      final tmp6 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 8);
      final tmp7 = (tmp4, i0.AllocatedString.read(tmp5, tmp6));

      return tmp7;
    });

    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp8;
  }
}

@pragma('wasm:import', r'component._drop$117')
external i2.WasmVoid _drop$117Raw(i2.WasmI32 handle);

void _drop$117(int handle) {
  _drop$117Raw(i2.WasmI32.fromInt(handle));
}

@pragma('wasm:import', 'component.stream123.new')
external i2.WasmI64 _streamNew123();
@pragma('wasm:import', 'component.stream123.read')
external i2.WasmI32 _streamRead123(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream123.write')
external i2.WasmI32 _streamWrite123(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream123.drop-readable')
external i2.WasmVoid _streamDropReadable123(i2.WasmI32 stream);
@pragma('wasm:import', 'component.stream123.drop-writable')
external i2.WasmVoid _streamDropWritable123(i2.WasmI32 stream);

final class _Vtable123
    implements i0.StreamVtable<List<i0.Owned<i12.TypesTcpSocket>>> {
  const _Vtable123();

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
      final tmp1 = i0.Owned<i12.TypesTcpSocket>(
        tmp0.toIntUnsigned(),
        _drop$117,
      );
      tmp1.drop();
    }

    i0.dartFree(
      address.toWasmI32(),
      (totalSize * 4).toWasmI32(),
      const i2.WasmI32(4),
    );
  }

  @override
  void writeToBuffer(int address, List<i0.Owned<i12.TypesTcpSocket>> elements) {
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
  List<i0.Owned<i12.TypesTcpSocket>> readFromBuffer(int address, int count) {
    return List.generate(count, (i) {
      final ptr = i2.WasmI32.fromInt(address + i * 4);
      final tmp0 = i0.memory.loadInt32(ptr.toIntUnsigned(), offset: 0);
      final tmp1 = i0.Owned<i12.TypesTcpSocket>(
        tmp0.toIntUnsigned(),
        _drop$117,
      );
      return tmp1;
    });
  }

  @override
  int newStream() => _streamNew123().toInt();
  @override
  void dropReadable(int stream) {
    _streamDropReadable123(i2.WasmI32.fromInt(stream));
  }

  @override
  void dropWritable(int stream) {
    _streamDropWritable123(i2.WasmI32.fromInt(stream));
  }

  @override
  int read(int stream, int ptr, int n) {
    return _streamRead123(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }

  @override
  int write(int stream, int ptr, int n) {
    return _streamWrite123(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }
}

@pragma('wasm:import', 'component.stream125.new')
external i2.WasmI64 _streamNew125();
@pragma('wasm:import', 'component.stream125.read')
external i2.WasmI32 _streamRead125(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream125.write')
external i2.WasmI32 _streamWrite125(
  i2.WasmI32 stream,
  i2.WasmI32 ptr,
  i2.WasmI32 n,
);
@pragma('wasm:import', 'component.stream125.drop-readable')
external i2.WasmVoid _streamDropReadable125(i2.WasmI32 stream);
@pragma('wasm:import', 'component.stream125.drop-writable')
external i2.WasmVoid _streamDropWritable125(i2.WasmI32 stream);

final class _Vtable125 implements i0.StreamVtable<i5.Uint8List> {
  const _Vtable125();

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
  void writeToBuffer(int address, i5.Uint8List elements) {
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
  i5.Uint8List readFromBuffer(int address, int count) {
    final typedList = i5.Uint8List(count);
    for (var i = 0; i < count; i++) {
      final ptr = i2.WasmI32.fromInt(address + i * 1);
      final tmp0 = i0.memory.loadUint8(ptr.toIntUnsigned(), offset: 0);

      typedList[i] = tmp0.toIntUnsigned();
    }
    return typedList;
  }

  @override
  int newStream() => _streamNew125().toInt();
  @override
  void dropReadable(int stream) {
    _streamDropReadable125(i2.WasmI32.fromInt(stream));
  }

  @override
  void dropWritable(int stream) {
    _streamDropWritable125(i2.WasmI32.fromInt(stream));
  }

  @override
  int read(int stream, int ptr, int n) {
    return _streamRead125(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }

  @override
  int write(int stream, int ptr, int n) {
    return _streamWrite125(
      i2.WasmI32.fromInt(stream),
      i2.WasmI32.fromInt(ptr),
      i2.WasmI32.fromInt(n),
    ).toIntUnsigned();
  }
}

@pragma('wasm:import', 'component.future126.new')
external i2.WasmI64 _futureNew126();
@pragma('wasm:import', 'component.future126.write')
external i2.WasmI32 _futureWrite126(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future126.read')
external i2.WasmI32 _futureRead126(i2.WasmI32 future, i2.WasmI32 ptr);
@pragma('wasm:import', 'component.future126.drop-readable')
external i2.WasmVoid _futureDropReadable126(i2.WasmI32 future);
@pragma('wasm:import', 'component.future126.drop-writable')
external i2.WasmVoid _futureDropWritable126(i2.WasmI32 future);

final class _Vtable126
    implements i0.FutureVtable<i0.Result<void, i12.TypesErrorCode>> {
  const _Vtable126();

  @override
  int newFuture() => _futureNew126().toInt();

  @override
  int read(int future, int buffer) {
    return _futureRead126(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  int write(int future, int buffer) {
    return _futureWrite126(
      i2.WasmI32.fromInt(future),
      i2.WasmI32.fromInt(buffer),
    ).toIntUnsigned();
  }

  @override
  void dropRead(int future) {
    _futureDropReadable126(i2.WasmI32.fromInt(future));
  }

  @override
  void dropWrite(int future) {
    _futureDropWritable126(i2.WasmI32.fromInt(future));
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
  void store(int address, i0.Result<void, i12.TypesErrorCode> value) {
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
          case i12.TypesErrorCodeAccessDenied():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(0),
              offset: 4,
            );

          case i12.TypesErrorCodeNotSupported():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(1),
              offset: 4,
            );

          case i12.TypesErrorCodeInvalidArgument():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(2),
              offset: 4,
            );

          case i12.TypesErrorCodeOutOfMemory():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(3),
              offset: 4,
            );

          case i12.TypesErrorCodeTimeout():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(4),
              offset: 4,
            );

          case i12.TypesErrorCodeInvalidState():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(5),
              offset: 4,
            );

          case i12.TypesErrorCodeAddressNotBindable():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(6),
              offset: 4,
            );

          case i12.TypesErrorCodeAddressInUse():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(7),
              offset: 4,
            );

          case i12.TypesErrorCodeRemoteUnreachable():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(8),
              offset: 4,
            );

          case i12.TypesErrorCodeConnectionRefused():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(9),
              offset: 4,
            );

          case i12.TypesErrorCodeConnectionBroken():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(10),
              offset: 4,
            );

          case i12.TypesErrorCodeConnectionReset():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(11),
              offset: 4,
            );

          case i12.TypesErrorCodeConnectionAborted():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(12),
              offset: 4,
            );

          case i12.TypesErrorCodeDatagramTooLarge():
            i0.memory.storeInt8(
              wasmAddress.toIntUnsigned(),
              const i2.WasmI32(13),
              offset: 4,
            );

          case i12.TypesErrorCodeOther(payload: final value):
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
  i0.Result<void, i12.TypesErrorCode> load(int address) {
    final wasmAddress = i2.WasmI32.fromInt(address);

    final tmp0 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 0);
    final i0.Result<void, i12.TypesErrorCode> tmp7;
    if (tmp0.toBool()) {
      final tmp1 = i0.memory.loadUint8(wasmAddress.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp6;
      switch (tmp1.toIntUnsigned()) {
        case 0:
          tmp6 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp6 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp6 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp6 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp6 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp6 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp6 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp6 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp6 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp6 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp6 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp6 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp6 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp6 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp6 = i12.TypesErrorCodeOther(tmp5);

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

@pragma("wasm:import", r"component._import129")
external i2.WasmVoid _import129(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import130")
external i2.WasmVoid _import130(
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
@pragma("wasm:import", r"component._import131")
external i2.WasmI32 _import131(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import132")
external i2.WasmVoid _import132(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import133")
external i2.WasmI32 _import133(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import134")
external i2.WasmVoid _import134(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import135")
external i2.WasmVoid _import135(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import136")
external i2.WasmVoid _import136(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import137")
external i2.WasmI32 _import137(i2.WasmI32 p0);
@pragma("wasm:import", r"component._import138")
external i2.WasmI32 _import138(i2.WasmI32 p0);
@pragma("wasm:import", r"component._import139")
external i2.WasmVoid _import139(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import140")
external i2.WasmVoid _import140(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import141")
external i2.WasmVoid _import141(i2.WasmI32 p0, i2.WasmI32 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import142")
external i2.WasmVoid _import142(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import143")
external i2.WasmVoid _import143(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import144")
external i2.WasmVoid _import144(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import145")
external i2.WasmVoid _import145(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import146")
external i2.WasmVoid _import146(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import147")
external i2.WasmVoid _import147(i2.WasmI32 p0, i2.WasmI32 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import148")
external i2.WasmVoid _import148(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import149")
external i2.WasmVoid _import149(i2.WasmI32 p0, i2.WasmI32 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import150")
external i2.WasmVoid _import150(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import151")
external i2.WasmVoid _import151(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import152")
external i2.WasmVoid _import152(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import153")
external i2.WasmVoid _import153(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);

@pragma('wasm:import', r'component._drop$118')
external i2.WasmVoid _drop$118Raw(i2.WasmI32 handle);

void _drop$118(int handle) {
  _drop$118Raw(i2.WasmI32.fromInt(handle));
}

@pragma("wasm:import", r"component._import154")
external i2.WasmVoid _import154(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import156")
external i2.WasmVoid _import156(
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
@pragma("wasm:import", r"component._import157")
external i2.WasmVoid _import157(
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
@pragma("wasm:import", r"component._import158")
external i2.WasmVoid _import158(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import159")
external i2.WasmI32 _import159(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import160")
external i2.WasmI32 _import160(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import161")
external i2.WasmVoid _import161(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import162")
external i2.WasmVoid _import162(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import163")
external i2.WasmI32 _import163(i2.WasmI32 p0);
@pragma("wasm:import", r"component._import164")
external i2.WasmVoid _import164(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import165")
external i2.WasmVoid _import165(i2.WasmI32 p0, i2.WasmI32 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import166")
external i2.WasmVoid _import166(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import167")
external i2.WasmVoid _import167(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);
@pragma("wasm:import", r"component._import168")
external i2.WasmVoid _import168(i2.WasmI32 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import169")
external i2.WasmVoid _import169(i2.WasmI32 p0, i2.WasmI64 p1, i2.WasmI32 p2);

final class _Imported$14 implements i12.Types {
  const _Imported$14();
  @override
  i0.Result<i0.Owned<i12.TypesTcpSocket>, i12.TypesErrorCode>
  staticTcpSocketCreate({required i12.TypesIpAddressFamily addressFamily}) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import129(addressFamily.index.toWasmI32(), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i0.Owned<i12.TypesTcpSocket>, i12.TypesErrorCode> tmp10;
    if (tmp1.toBool()) {
      final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp9;
      switch (tmp4.toIntUnsigned()) {
        case 0:
          tmp9 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp9 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp9 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp9 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp9 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp9 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp9 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp9 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp9 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp9 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp9 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp9 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp9 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp9 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp9 = i12.TypesErrorCodeOther(tmp8);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp10 = .error(tmp9);
    } else {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i0.Owned<i12.TypesTcpSocket>(
        tmp2.toIntUnsigned(),
        _drop$117,
      );
      tmp10 = .ok(tmp3);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp10;
  }

  @override
  i0.Result<void, i12.TypesErrorCode> methodTcpSocketBind({
    required i0.Borrowed<i12.TypesTcpSocket> self,
    required i12.TypesIpSocketAddress localAddress,
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
      case i12.TypesIpSocketAddressIpv4(payload: final value):
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

      case i12.TypesIpSocketAddressIpv6(payload: final value):
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
    _import130(
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
    final i0.Result<void, i12.TypesErrorCode> tmp20;
    if (tmp13.toBool()) {
      final tmp14 = i0.memory.loadUint8(tmp12.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp19;
      switch (tmp14.toIntUnsigned()) {
        case 0:
          tmp19 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp19 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp19 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp19 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp19 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp19 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp19 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp19 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp19 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp19 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp19 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp19 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp19 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp19 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp19 = i12.TypesErrorCodeOther(tmp18);

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
  Future<i0.Result<void, i12.TypesErrorCode>> methodTcpSocketConnect({
    required i0.Borrowed<i12.TypesTcpSocket> self,
    required i12.TypesIpSocketAddress remoteAddress,
  }) async {
    final tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(36));
    i0.memory.storeInt32(
      (tmp0 + const i2.WasmI32(0)).toIntUnsigned(),
      i2.WasmI32.fromInt(self.handle),
      offset: 0,
    );
    switch (remoteAddress) {
      case i12.TypesIpSocketAddressIpv4(payload: final value):
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

      case i12.TypesIpSocketAddressIpv6(payload: final value):
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
    await i0.createSubtask(_import131(tmp0, tmp1)).completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<void, i12.TypesErrorCode> tmp9;
    if (tmp2.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp8 = i12.TypesErrorCodeOther(tmp7);

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
  i0.Result<Stream<List<i0.Owned<i12.TypesTcpSocket>>>, i12.TypesErrorCode>
  methodTcpSocketListen({required i0.Borrowed<i12.TypesTcpSocket> self}) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import132(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<
      Stream<List<i0.Owned<i12.TypesTcpSocket>>>,
      i12.TypesErrorCode
    >
    tmp10;
    if (tmp1.toBool()) {
      final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp9;
      switch (tmp4.toIntUnsigned()) {
        case 0:
          tmp9 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp9 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp9 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp9 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp9 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp9 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp9 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp9 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp9 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp9 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp9 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp9 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp9 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp9 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp9 = i12.TypesErrorCodeOther(tmp8);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp10 = .error(tmp9);
    } else {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i0.ReadableStream(tmp2.toIntUnsigned(), const _Vtable123());

      tmp10 = .ok(tmp3);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp10;
  }

  @override
  Future<i0.Result<void, i12.TypesErrorCode>> methodTcpSocketSend({
    required i0.Borrowed<i12.TypesTcpSocket> self,
    required Stream<i5.Uint8List> data,
  }) {
    final tmp0 = i0.newReadableStream(const _Vtable125(), data).toWasmI32();
    final tmp1 = _import133(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp2 = i0.readFuture(const _Vtable126(), tmp1.toIntUnsigned());
    return tmp2;
  }

  @override
  (Stream<i5.Uint8List>, Future<i0.Result<void, i12.TypesErrorCode>>)
  methodTcpSocketReceive({required i0.Borrowed<i12.TypesTcpSocket> self}) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import134(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.ReadableStream(tmp1.toIntUnsigned(), const _Vtable125());
    final tmp3 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
    final tmp4 = i0.readFuture(const _Vtable126(), tmp3.toIntUnsigned());
    final tmp5 = (tmp2, tmp4);
    i0.dartFree(tmp0, const i2.WasmI32(8), const i2.WasmI32(4));
    return tmp5;
  }

  @override
  i0.Result<i12.TypesIpSocketAddress, i12.TypesErrorCode>
  methodTcpSocketGetLocalAddress({
    required i0.Borrowed<i12.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(36));
    _import135(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i12.TypesIpSocketAddress, i12.TypesErrorCode> tmp30;
    if (tmp1.toBool()) {
      final tmp24 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp29;
      switch (tmp24.toIntUnsigned()) {
        case 0:
          tmp29 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp29 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp29 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp29 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp29 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp29 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp29 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp29 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp29 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp29 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp29 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp29 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp29 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp29 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp29 = i12.TypesErrorCodeOther(tmp28);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp30 = .error(tmp29);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesIpSocketAddress tmp23;
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

          tmp23 = i12.TypesIpSocketAddressIpv4(tmp9);
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

          tmp23 = i12.TypesIpSocketAddressIpv6(tmp22);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp30 = .ok(tmp23);
    }

    i0.dartFree(tmp0, const i2.WasmI32(36), const i2.WasmI32(4));
    return tmp30;
  }

  @override
  i0.Result<i12.TypesIpSocketAddress, i12.TypesErrorCode>
  methodTcpSocketGetRemoteAddress({
    required i0.Borrowed<i12.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(36));
    _import136(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i12.TypesIpSocketAddress, i12.TypesErrorCode> tmp30;
    if (tmp1.toBool()) {
      final tmp24 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp29;
      switch (tmp24.toIntUnsigned()) {
        case 0:
          tmp29 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp29 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp29 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp29 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp29 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp29 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp29 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp29 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp29 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp29 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp29 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp29 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp29 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp29 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp29 = i12.TypesErrorCodeOther(tmp28);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp30 = .error(tmp29);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesIpSocketAddress tmp23;
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

          tmp23 = i12.TypesIpSocketAddressIpv4(tmp9);
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

          tmp23 = i12.TypesIpSocketAddressIpv6(tmp22);

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
    required i0.Borrowed<i12.TypesTcpSocket> self,
  }) {
    final tmp0 = _import137(i2.WasmI32.fromInt(self.handle));
    return tmp0.toBool();
  }

  @override
  i12.TypesIpAddressFamily methodTcpSocketGetAddressFamily({
    required i0.Borrowed<i12.TypesTcpSocket> self,
  }) {
    final tmp0 = _import138(i2.WasmI32.fromInt(self.handle));
    return i12.TypesIpAddressFamily.values[tmp0.toIntUnsigned()];
  }

  @override
  i0.Result<void, i12.TypesErrorCode> methodTcpSocketSetListenBacklogSize({
    required i0.Borrowed<i12.TypesTcpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import139(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI64.fromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i12.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp7 = i12.TypesErrorCodeOther(tmp6);

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
  i0.Result<bool, i12.TypesErrorCode> methodTcpSocketGetKeepAliveEnabled({
    required i0.Borrowed<i12.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import140(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<bool, i12.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp8 = i12.TypesErrorCodeOther(tmp7);

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
  i0.Result<void, i12.TypesErrorCode> methodTcpSocketSetKeepAliveEnabled({
    required i0.Borrowed<i12.TypesTcpSocket> self,
    required bool value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import141(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI32.fromBool(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i12.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp7 = i12.TypesErrorCodeOther(tmp6);

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
  i0.Result<int, i12.TypesErrorCode> methodTcpSocketGetKeepAliveIdleTime({
    required i0.Borrowed<i12.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(24));
    _import142(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i12.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i12.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp8 = i12.TypesErrorCodeOther(tmp7);

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
  i0.Result<void, i12.TypesErrorCode> methodTcpSocketSetKeepAliveIdleTime({
    required i0.Borrowed<i12.TypesTcpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import143(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI64.fromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i12.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp7 = i12.TypesErrorCodeOther(tmp6);

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
  i0.Result<int, i12.TypesErrorCode> methodTcpSocketGetKeepAliveInterval({
    required i0.Borrowed<i12.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(24));
    _import144(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i12.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i12.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp8 = i12.TypesErrorCodeOther(tmp7);

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
  i0.Result<void, i12.TypesErrorCode> methodTcpSocketSetKeepAliveInterval({
    required i0.Borrowed<i12.TypesTcpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import145(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI64.fromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i12.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp7 = i12.TypesErrorCodeOther(tmp6);

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
  i0.Result<int, i12.TypesErrorCode> methodTcpSocketGetKeepAliveCount({
    required i0.Borrowed<i12.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import146(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i12.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp8 = i12.TypesErrorCodeOther(tmp7);

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
  i0.Result<void, i12.TypesErrorCode> methodTcpSocketSetKeepAliveCount({
    required i0.Borrowed<i12.TypesTcpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import147(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI32.fromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i12.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp7 = i12.TypesErrorCodeOther(tmp6);

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
  i0.Result<int, i12.TypesErrorCode> methodTcpSocketGetHopLimit({
    required i0.Borrowed<i12.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import148(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i12.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp8 = i12.TypesErrorCodeOther(tmp7);

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
  i0.Result<void, i12.TypesErrorCode> methodTcpSocketSetHopLimit({
    required i0.Borrowed<i12.TypesTcpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import149(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI32.uint8FromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i12.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp7 = i12.TypesErrorCodeOther(tmp6);

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
  i0.Result<int, i12.TypesErrorCode> methodTcpSocketGetReceiveBufferSize({
    required i0.Borrowed<i12.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(24));
    _import150(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i12.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i12.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp8 = i12.TypesErrorCodeOther(tmp7);

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
  i0.Result<void, i12.TypesErrorCode> methodTcpSocketSetReceiveBufferSize({
    required i0.Borrowed<i12.TypesTcpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import151(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI64.fromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i12.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp7 = i12.TypesErrorCodeOther(tmp6);

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
  i0.Result<int, i12.TypesErrorCode> methodTcpSocketGetSendBufferSize({
    required i0.Borrowed<i12.TypesTcpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(24));
    _import152(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i12.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i12.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp8 = i12.TypesErrorCodeOther(tmp7);

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
  i0.Result<void, i12.TypesErrorCode> methodTcpSocketSetSendBufferSize({
    required i0.Borrowed<i12.TypesTcpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import153(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI64.fromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i12.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp7 = i12.TypesErrorCodeOther(tmp6);

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
  i0.Result<i0.Owned<i12.TypesUdpSocket>, i12.TypesErrorCode>
  staticUdpSocketCreate({required i12.TypesIpAddressFamily addressFamily}) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import154(addressFamily.index.toWasmI32(), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i0.Owned<i12.TypesUdpSocket>, i12.TypesErrorCode> tmp10;
    if (tmp1.toBool()) {
      final tmp4 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp9;
      switch (tmp4.toIntUnsigned()) {
        case 0:
          tmp9 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp9 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp9 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp9 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp9 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp9 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp9 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp9 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp9 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp9 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp9 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp9 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp9 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp9 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp9 = i12.TypesErrorCodeOther(tmp8);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp10 = .error(tmp9);
    } else {
      final tmp2 = i0.memory.loadInt32(tmp0.toIntUnsigned(), offset: 4);
      final tmp3 = i0.Owned<i12.TypesUdpSocket>(
        tmp2.toIntUnsigned(),
        _drop$118,
      );
      tmp10 = .ok(tmp3);
    }

    i0.dartFree(tmp0, const i2.WasmI32(20), const i2.WasmI32(4));
    return tmp10;
  }

  @override
  i0.Result<void, i12.TypesErrorCode> methodUdpSocketBind({
    required i0.Borrowed<i12.TypesUdpSocket> self,
    required i12.TypesIpSocketAddress localAddress,
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
      case i12.TypesIpSocketAddressIpv4(payload: final value):
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

      case i12.TypesIpSocketAddressIpv6(payload: final value):
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
    _import156(
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
    final i0.Result<void, i12.TypesErrorCode> tmp20;
    if (tmp13.toBool()) {
      final tmp14 = i0.memory.loadUint8(tmp12.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp19;
      switch (tmp14.toIntUnsigned()) {
        case 0:
          tmp19 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp19 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp19 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp19 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp19 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp19 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp19 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp19 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp19 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp19 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp19 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp19 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp19 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp19 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp19 = i12.TypesErrorCodeOther(tmp18);

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
  i0.Result<void, i12.TypesErrorCode> methodUdpSocketConnect({
    required i0.Borrowed<i12.TypesUdpSocket> self,
    required i12.TypesIpSocketAddress remoteAddress,
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
      case i12.TypesIpSocketAddressIpv4(payload: final value):
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

      case i12.TypesIpSocketAddressIpv6(payload: final value):
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
    _import157(
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
    final i0.Result<void, i12.TypesErrorCode> tmp20;
    if (tmp13.toBool()) {
      final tmp14 = i0.memory.loadUint8(tmp12.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp19;
      switch (tmp14.toIntUnsigned()) {
        case 0:
          tmp19 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp19 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp19 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp19 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp19 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp19 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp19 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp19 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp19 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp19 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp19 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp19 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp19 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp19 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp19 = i12.TypesErrorCodeOther(tmp18);

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
  i0.Result<void, i12.TypesErrorCode> methodUdpSocketDisconnect({
    required i0.Borrowed<i12.TypesUdpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import158(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i12.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp7 = i12.TypesErrorCodeOther(tmp6);

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
  Future<i0.Result<void, i12.TypesErrorCode>> methodUdpSocketSend({
    required i0.Borrowed<i12.TypesUdpSocket> self,
    required List<int> data,
    required i0.Option<i12.TypesIpSocketAddress> remoteAddress,
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
        case i12.TypesIpSocketAddressIpv4(payload: final value):
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

        case i12.TypesIpSocketAddressIpv6(payload: final value):
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
    await i0.createSubtask(_import159(tmp0, tmp5)).completion;
    final tmp6 = i0.memory.loadUint8(tmp5.toIntUnsigned(), offset: 0);
    final i0.Result<void, i12.TypesErrorCode> tmp13;
    if (tmp6.toBool()) {
      final tmp7 = i0.memory.loadUint8(tmp5.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp12;
      switch (tmp7.toIntUnsigned()) {
        case 0:
          tmp12 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp12 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp12 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp12 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp12 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp12 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp12 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp12 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp12 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp12 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp12 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp12 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp12 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp12 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp12 = i12.TypesErrorCodeOther(tmp11);

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
  Future<i0.Result<(List<int>, i12.TypesIpSocketAddress), i12.TypesErrorCode>>
  methodUdpSocketReceive({
    required i0.Borrowed<i12.TypesUdpSocket> self,
  }) async {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(44));
    await i0
        .createSubtask(_import160(i2.WasmI32.fromInt(self.handle), tmp0))
        .completion;
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<(List<int>, i12.TypesIpSocketAddress), i12.TypesErrorCode>
    tmp36;
    if (tmp1.toBool()) {
      final tmp30 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp35;
      switch (tmp30.toIntUnsigned()) {
        case 0:
          tmp35 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp35 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp35 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp35 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp35 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp35 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp35 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp35 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp35 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp35 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp35 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp35 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp35 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp35 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp35 = i12.TypesErrorCodeOther(tmp34);

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
      final i12.TypesIpSocketAddress tmp28;
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

          tmp28 = i12.TypesIpSocketAddressIpv4(tmp14);
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

          tmp28 = i12.TypesIpSocketAddressIpv6(tmp27);

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
  i0.Result<i12.TypesIpSocketAddress, i12.TypesErrorCode>
  methodUdpSocketGetLocalAddress({
    required i0.Borrowed<i12.TypesUdpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(36));
    _import161(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i12.TypesIpSocketAddress, i12.TypesErrorCode> tmp30;
    if (tmp1.toBool()) {
      final tmp24 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp29;
      switch (tmp24.toIntUnsigned()) {
        case 0:
          tmp29 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp29 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp29 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp29 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp29 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp29 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp29 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp29 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp29 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp29 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp29 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp29 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp29 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp29 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp29 = i12.TypesErrorCodeOther(tmp28);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp30 = .error(tmp29);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesIpSocketAddress tmp23;
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

          tmp23 = i12.TypesIpSocketAddressIpv4(tmp9);
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

          tmp23 = i12.TypesIpSocketAddressIpv6(tmp22);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp30 = .ok(tmp23);
    }

    i0.dartFree(tmp0, const i2.WasmI32(36), const i2.WasmI32(4));
    return tmp30;
  }

  @override
  i0.Result<i12.TypesIpSocketAddress, i12.TypesErrorCode>
  methodUdpSocketGetRemoteAddress({
    required i0.Borrowed<i12.TypesUdpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(36));
    _import162(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<i12.TypesIpSocketAddress, i12.TypesErrorCode> tmp30;
    if (tmp1.toBool()) {
      final tmp24 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp29;
      switch (tmp24.toIntUnsigned()) {
        case 0:
          tmp29 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp29 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp29 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp29 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp29 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp29 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp29 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp29 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp29 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp29 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp29 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp29 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp29 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp29 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp29 = i12.TypesErrorCodeOther(tmp28);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp30 = .error(tmp29);
    } else {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesIpSocketAddress tmp23;
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

          tmp23 = i12.TypesIpSocketAddressIpv4(tmp9);
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

          tmp23 = i12.TypesIpSocketAddressIpv6(tmp22);

        default:
          throw ArgumentError('Invalid discrimant value for variant');
      }

      tmp30 = .ok(tmp23);
    }

    i0.dartFree(tmp0, const i2.WasmI32(36), const i2.WasmI32(4));
    return tmp30;
  }

  @override
  i12.TypesIpAddressFamily methodUdpSocketGetAddressFamily({
    required i0.Borrowed<i12.TypesUdpSocket> self,
  }) {
    final tmp0 = _import163(i2.WasmI32.fromInt(self.handle));
    return i12.TypesIpAddressFamily.values[tmp0.toIntUnsigned()];
  }

  @override
  i0.Result<int, i12.TypesErrorCode> methodUdpSocketGetUnicastHopLimit({
    required i0.Borrowed<i12.TypesUdpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import164(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i12.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp8 = i12.TypesErrorCodeOther(tmp7);

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
  i0.Result<void, i12.TypesErrorCode> methodUdpSocketSetUnicastHopLimit({
    required i0.Borrowed<i12.TypesUdpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import165(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI32.uint8FromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i12.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp7 = i12.TypesErrorCodeOther(tmp6);

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
  i0.Result<int, i12.TypesErrorCode> methodUdpSocketGetReceiveBufferSize({
    required i0.Borrowed<i12.TypesUdpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(24));
    _import166(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i12.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i12.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp8 = i12.TypesErrorCodeOther(tmp7);

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
  i0.Result<void, i12.TypesErrorCode> methodUdpSocketSetReceiveBufferSize({
    required i0.Borrowed<i12.TypesUdpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import167(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI64.fromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i12.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp7 = i12.TypesErrorCodeOther(tmp6);

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
  i0.Result<int, i12.TypesErrorCode> methodUdpSocketGetSendBufferSize({
    required i0.Borrowed<i12.TypesUdpSocket> self,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(24));
    _import168(i2.WasmI32.fromInt(self.handle), tmp0);
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<int, i12.TypesErrorCode> tmp9;
    if (tmp1.toBool()) {
      final tmp3 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 8);
      final i12.TypesErrorCode tmp8;
      switch (tmp3.toIntUnsigned()) {
        case 0:
          tmp8 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp8 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp8 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp8 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp8 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp8 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp8 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp8 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp8 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp8 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp8 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp8 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp8 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp8 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp8 = i12.TypesErrorCodeOther(tmp7);

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
  i0.Result<void, i12.TypesErrorCode> methodUdpSocketSetSendBufferSize({
    required i0.Borrowed<i12.TypesUdpSocket> self,
    required int value,
  }) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    _import169(
      i2.WasmI32.fromInt(self.handle),
      i2.WasmI64.fromInt(value),
      tmp0,
    );
    final tmp1 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 0);
    final i0.Result<void, i12.TypesErrorCode> tmp8;
    if (tmp1.toBool()) {
      final tmp2 = i0.memory.loadUint8(tmp0.toIntUnsigned(), offset: 4);
      final i12.TypesErrorCode tmp7;
      switch (tmp2.toIntUnsigned()) {
        case 0:
          tmp7 = i12.TypesErrorCodeAccessDenied();
        case 1:
          tmp7 = i12.TypesErrorCodeNotSupported();
        case 2:
          tmp7 = i12.TypesErrorCodeInvalidArgument();
        case 3:
          tmp7 = i12.TypesErrorCodeOutOfMemory();
        case 4:
          tmp7 = i12.TypesErrorCodeTimeout();
        case 5:
          tmp7 = i12.TypesErrorCodeInvalidState();
        case 6:
          tmp7 = i12.TypesErrorCodeAddressNotBindable();
        case 7:
          tmp7 = i12.TypesErrorCodeAddressInUse();
        case 8:
          tmp7 = i12.TypesErrorCodeRemoteUnreachable();
        case 9:
          tmp7 = i12.TypesErrorCodeConnectionRefused();
        case 10:
          tmp7 = i12.TypesErrorCodeConnectionBroken();
        case 11:
          tmp7 = i12.TypesErrorCodeConnectionReset();
        case 12:
          tmp7 = i12.TypesErrorCodeConnectionAborted();
        case 13:
          tmp7 = i12.TypesErrorCodeDatagramTooLarge();
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

          tmp7 = i12.TypesErrorCodeOther(tmp6);

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

@pragma("wasm:import", r"component._import170")
external i2.WasmI32 _import170(i2.WasmI32 p0, i2.WasmI32 p1, i2.WasmI32 p2);

final class _Imported$15 implements i12.IpNameLookup {
  const _Imported$15();
  @override
  Future<i0.Result<List<i12.TypesIpAddress>, i12.IpNameLookupErrorCode>>
  resolveAddresses({required String name}) async {
    final tmp0 = i0.AllocatedString.allocateUtf16(name);
    var tmp1 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(20));
    await i0
        .createSubtask(_import170(tmp0.ptr, tmp0.packedLength, tmp1))
        .completion;
    final tmp2 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 0);
    final i0.Result<List<i12.TypesIpAddress>, i12.IpNameLookupErrorCode> tmp29;
    if (tmp2.toBool()) {
      final tmp23 = i0.memory.loadUint8(tmp1.toIntUnsigned(), offset: 4);
      final i12.IpNameLookupErrorCode tmp28;
      switch (tmp23.toIntUnsigned()) {
        case 0:
          tmp28 = i12.IpNameLookupErrorCodeAccessDenied();
        case 1:
          tmp28 = i12.IpNameLookupErrorCodeInvalidArgument();
        case 2:
          tmp28 = i12.IpNameLookupErrorCodeNameUnresolvable();
        case 3:
          tmp28 = i12.IpNameLookupErrorCodeTemporaryResolverFailure();
        case 4:
          tmp28 = i12.IpNameLookupErrorCodePermanentResolverFailure();
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

          tmp28 = i12.IpNameLookupErrorCodeOther(tmp27);

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
        final i12.TypesIpAddress tmp20;
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

            tmp20 = i12.TypesIpAddressIpv4(tmp10);
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

            tmp20 = i12.TypesIpAddressIpv6(tmp19);

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

@pragma("wasm:import", r"component._import171")
external i2.WasmVoid _import171(i2.WasmI64 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import172")
external i2.WasmI64 _import172();

final class _Imported$16 implements i13.Random {
  const _Imported$16();
  @override
  List<int> getRandomBytes({required int maxLen}) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import171(i2.WasmI64.fromInt(maxLen), tmp0);
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
    final tmp0 = _import172();
    return tmp0.toInt();
  }
}

@pragma("wasm:import", r"component._import173")
external i2.WasmVoid _import173(i2.WasmI64 p0, i2.WasmI32 p1);
@pragma("wasm:import", r"component._import174")
external i2.WasmI64 _import174();

final class _Imported$17 implements i13.Insecure {
  const _Imported$17();
  @override
  List<int> getInsecureRandomBytes({required int maxLen}) {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(4), const i2.WasmI32(8));
    _import173(i2.WasmI64.fromInt(maxLen), tmp0);
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
    final tmp0 = _import174();
    return tmp0.toInt();
  }
}

@pragma("wasm:import", r"component._import175")
external i2.WasmVoid _import175(i2.WasmI32 p0);

final class _Imported$18 implements i13.InsecureSeed {
  const _Imported$18();
  @override
  (int, int) getInsecureSeed() {
    var tmp0 = i0.mallocAligned(const i2.WasmI32(8), const i2.WasmI32(16));
    _import175(tmp0);
    final tmp1 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 0);
    final tmp2 = i0.memory.loadInt64(tmp0.toIntUnsigned(), offset: 8);
    final tmp3 = (tmp1.toInt(), tmp2.toInt());
    i0.dartFree(tmp0, const i2.WasmI32(16), const i2.WasmI32(8));
    return tmp3;
  }
}

late i9.Run _unnamedExport21;

final class TuiAppImports {
  const TuiAppImports._();

  i1.Tty get termTty => const _Imported$35();
  i1.Crash get termCrash => const _Imported$36();
  i3.Bridge get layoutBridge => const _Imported$4();
  i4.Client get httpClient => const _Imported$1();
  i6.Session get pluginHostSession => const _Imported$5();
  i7.Policy get policyPolicy => const _Imported$7();
  i8.Process get processProcess => const _Imported$34();
  i9.Environment get cliEnvironment => const _Imported$19();
  i9.Exit get cliExit => const _Imported$20();
  i9.Stdin get cliStdin => const _Imported$23();
  i9.Stdout get cliStdout => const _Imported$24();
  i9.Stderr get cliStderr => const _Imported$25();
  i9.TerminalStdin get cliTerminalStdin => const _Imported$28();
  i9.TerminalStdout get cliTerminalStdout => const _Imported$29();
  i9.TerminalStderr get cliTerminalStderr => const _Imported$30();
  i10.MonotonicClock get clocksMonotonicClock => const _Imported$9();
  i10.SystemClock get clocksSystemClock => const _Imported$10();
  i11.Types get filesystemTypes => const _Imported$12();
  i11.Preopens get filesystemPreopens => const _Imported$13();
  i12.Types get socketsTypes => const _Imported$14();
  i12.IpNameLookup get socketsIpNameLookup => const _Imported$15();
  i13.Random get randomRandom => const _Imported$16();
  i13.Insecure get randomInsecure => const _Imported$17();
  i13.InsecureSeed get randomInsecureSeed => const _Imported$18();
}

@i14.RecordUse()
void tuiAppComponent(i9.Run Function(TuiAppImports) defineComponent) {
  final res = defineComponent(const TuiAppImports._());
  _unnamedExport21 = res;
}

@pragma('wasm:export', r'component_0')
i2.WasmI32 _component_0() {
  final asyncExitCode = i0.spawnTask(
    run: () async {
      final tmp0 = await _unnamedExport21.run();
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
