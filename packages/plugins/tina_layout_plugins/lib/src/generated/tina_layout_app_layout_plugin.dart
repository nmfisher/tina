// ignore_for_file: type=warning
import r'package:wasm_components/wasm_components.dart' as i0;

import r'tina_layout.dart' as i1;

import r'package:meta/meta.dart' as i2;

// ignore: import_internal_library
import r'dart:_wasm' as i3;

final class _Imported$0 implements i1.Types {
  const _Imported$0();
}

late i1.Strategy _unnamedExport1;

final class LayoutPluginImports {
  const LayoutPluginImports._();
}

@i2.RecordUse()
void layoutPluginComponent(
  i1.Strategy Function(LayoutPluginImports) defineComponent,
) {
  final res = defineComponent(const LayoutPluginImports._());
  _unnamedExport1 = res;
}

@pragma('wasm:export', r'component_0')
i3.WasmI32 _component_0() {
  final tmp0 = _unnamedExport1.describe();
  var tmp1 = i0.mallocAligned(const i3.WasmI32(4), const i3.WasmI32(24));
  final tmp2 = i0.AllocatedString.allocateUtf16(tmp0.id);
  i0.memory.storeInt32(tmp1.toIntUnsigned(), tmp2.packedLength, offset: 4);
  i0.memory.storeInt32(tmp1.toIntUnsigned(), tmp2.ptr, offset: 0);
  final tmp3 = i0.AllocatedString.allocateUtf16(tmp0.version);
  i0.memory.storeInt32(tmp1.toIntUnsigned(), tmp3.packedLength, offset: 12);
  i0.memory.storeInt32(tmp1.toIntUnsigned(), tmp3.ptr, offset: 8);
  final tmp4 = i0.AllocatedString.allocateUtf16(tmp0.description);
  i0.memory.storeInt32(tmp1.toIntUnsigned(), tmp4.packedLength, offset: 20);
  i0.memory.storeInt32(tmp1.toIntUnsigned(), tmp4.ptr, offset: 16);
  return tmp1;
}

@pragma('wasm:export', r'component_0_postreturn')
i3.WasmVoid _component_0$postreturn(i3.WasmI32 p0) {
  final tmp0 = i0.memory.loadInt32(p0.toIntUnsigned(), offset: 0);
  final tmp1 = i0.memory.loadInt32(p0.toIntUnsigned(), offset: 4);
  i0.AllocatedString(tmp0, tmp1).free();
  final tmp2 = i0.memory.loadInt32(p0.toIntUnsigned(), offset: 8);
  final tmp3 = i0.memory.loadInt32(p0.toIntUnsigned(), offset: 12);
  i0.AllocatedString(tmp2, tmp3).free();
  final tmp4 = i0.memory.loadInt32(p0.toIntUnsigned(), offset: 16);
  final tmp5 = i0.memory.loadInt32(p0.toIntUnsigned(), offset: 20);
  i0.AllocatedString(tmp4, tmp5).free();
  i0.dartFree(p0, const i3.WasmI32(24), const i3.WasmI32(4));
  return i3.WasmVoid();
}

@pragma('wasm:export', r'component_1')
i3.WasmI32 _component_1(
  i3.WasmI32 p0,
  i3.WasmI32 p1,
  i3.WasmI32 p2,
  i3.WasmI32 p3,
  i3.WasmI32 p4,
  i3.WasmI32 p5,
  i3.WasmI32 p6,
  i3.WasmI32 p7,
  i3.WasmF64 p8,
) {
  final tmp9 = p0.toIntUnsigned();
  final tmp8 = List.generate(p1.toIntUnsigned(), growable: false, (i) {
    final elementPtr = i3.WasmI32.fromInt(tmp9 + i * 48);
    final tmp0 = i0.memory.loadUint8(elementPtr.toIntUnsigned(), offset: 0);
    final tmp1 = i0.memory.loadFloat64(elementPtr.toIntUnsigned(), offset: 8);
    final tmp2 = i0.memory.loadFloat64(elementPtr.toIntUnsigned(), offset: 16);
    final tmp3 = i0.memory.loadFloat64(elementPtr.toIntUnsigned(), offset: 24);
    final tmp4 = i0.memory.loadUint8(elementPtr.toIntUnsigned(), offset: 32);
    final i0.Option<double> tmp6;
    if (tmp4.toBool()) {
      final tmp5 = i0.memory.loadFloat64(
        elementPtr.toIntUnsigned(),
        offset: 40,
      );

      tmp6 = .some(tmp5.toDouble());
    } else {
      tmp6 = .none;
    }

    final tmp7 = (
      kind: i1.TypesTrackKind.values[tmp0.toIntUnsigned()],
      sizeUnits: tmp1.toDouble(),
      weight: tmp2.toDouble(),
      minUnits: tmp3.toDouble(),
      maxUnits: tmp6,
    );

    return tmp7;
  });

  final tmp19 = p2.toIntUnsigned();
  final tmp18 = List.generate(p3.toIntUnsigned(), growable: false, (i) {
    final elementPtr = i3.WasmI32.fromInt(tmp19 + i * 48);
    final tmp10 = i0.memory.loadUint8(elementPtr.toIntUnsigned(), offset: 0);
    final tmp11 = i0.memory.loadFloat64(elementPtr.toIntUnsigned(), offset: 8);
    final tmp12 = i0.memory.loadFloat64(elementPtr.toIntUnsigned(), offset: 16);
    final tmp13 = i0.memory.loadFloat64(elementPtr.toIntUnsigned(), offset: 24);
    final tmp14 = i0.memory.loadUint8(elementPtr.toIntUnsigned(), offset: 32);
    final i0.Option<double> tmp16;
    if (tmp14.toBool()) {
      final tmp15 = i0.memory.loadFloat64(
        elementPtr.toIntUnsigned(),
        offset: 40,
      );

      tmp16 = .some(tmp15.toDouble());
    } else {
      tmp16 = .none;
    }

    final tmp17 = (
      kind: i1.TypesTrackKind.values[tmp10.toIntUnsigned()],
      sizeUnits: tmp11.toDouble(),
      weight: tmp12.toDouble(),
      minUnits: tmp13.toDouble(),
      maxUnits: tmp16,
    );

    return tmp17;
  });

  final tmp46 = p4.toIntUnsigned();
  final tmp45 = List.generate(p5.toIntUnsigned(), growable: false, (i) {
    final elementPtr = i3.WasmI32.fromInt(tmp46 + i * 104);
    final tmp20 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 0);
    final tmp21 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 4);
    final tmp22 = i0.memory.loadUint8(elementPtr.toIntUnsigned(), offset: 8);
    final i0.Option<int> tmp24;
    if (tmp22.toBool()) {
      final tmp23 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 12);

      tmp24 = .some(tmp23.toIntUnsigned());
    } else {
      tmp24 = .none;
    }

    final tmp25 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 16);
    final tmp26 = (start: tmp24, span: tmp25.toIntUnsigned());
    final tmp27 = i0.memory.loadUint8(elementPtr.toIntUnsigned(), offset: 20);
    final i0.Option<int> tmp29;
    if (tmp27.toBool()) {
      final tmp28 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 24);

      tmp29 = .some(tmp28.toIntUnsigned());
    } else {
      tmp29 = .none;
    }

    final tmp30 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 28);
    final tmp31 = (start: tmp29, span: tmp30.toIntUnsigned());
    final tmp32 = i0.memory.loadFloat64(elementPtr.toIntUnsigned(), offset: 32);
    final tmp33 = i0.memory.loadFloat64(elementPtr.toIntUnsigned(), offset: 40);
    final tmp34 = i0.memory.loadUint8(elementPtr.toIntUnsigned(), offset: 48);
    final i0.Option<double> tmp36;
    if (tmp34.toBool()) {
      final tmp35 = i0.memory.loadFloat64(
        elementPtr.toIntUnsigned(),
        offset: 56,
      );

      tmp36 = .some(tmp35.toDouble());
    } else {
      tmp36 = .none;
    }

    final tmp37 = i0.memory.loadUint8(elementPtr.toIntUnsigned(), offset: 64);
    final i0.Option<double> tmp39;
    if (tmp37.toBool()) {
      final tmp38 = i0.memory.loadFloat64(
        elementPtr.toIntUnsigned(),
        offset: 72,
      );

      tmp39 = .some(tmp38.toDouble());
    } else {
      tmp39 = .none;
    }

    final tmp40 = i0.memory.loadUint8(elementPtr.toIntUnsigned(), offset: 80);
    final i0.Option<double> tmp42;
    if (tmp40.toBool()) {
      final tmp41 = i0.memory.loadFloat64(
        elementPtr.toIntUnsigned(),
        offset: 88,
      );

      tmp42 = .some(tmp41.toDouble());
    } else {
      tmp42 = .none;
    }

    final tmp43 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 96);
    final tmp44 = (
      id: i0.AllocatedString.read(tmp20, tmp21),
      column: tmp26,
      row: tmp31,
      minWidthUnits: tmp32.toDouble(),
      minHeightUnits: tmp33.toDouble(),
      maxWidthUnits: tmp36,
      maxHeightUnits: tmp39,
      aspectHint: tmp42,
      priority: tmp43.toIntSigned(),
    );

    return tmp44;
  });

  final tmp47 = (columns: tmp8, rows: tmp18, items: tmp45);
  final tmp48 = (rowsPerUnit: p8.toDouble());
  final tmp49 = _unnamedExport1.solve(
    spec: tmp47,
    columns: p6.toIntUnsigned(),
    rows: p7.toIntUnsigned(),
    metrics: tmp48,
  );
  var tmp50 = i0.mallocAligned(const i3.WasmI32(8), const i3.WasmI32(88));
  switch (tmp49) {
    case i0.OkResult(:final value):
      i0.memory.storeInt8(
        tmp50.toIntUnsigned(),
        const i3.WasmI32(0),
        offset: 0,
      );
      i0.memory.storeInt32(
        tmp50.toIntUnsigned(),
        i3.WasmI32.fromInt(value.columns),
        offset: 8,
      );
      i0.memory.storeInt32(
        tmp50.toIntUnsigned(),
        i3.WasmI32.fromInt(value.rows),
        offset: 12,
      );
      i0.memory.storeFloat64(
        tmp50.toIntUnsigned(),
        i3.WasmF64.fromDouble(value.metrics.rowsPerUnit),
        offset: 16,
      );

      final tmp52 = i3.WasmI32.fromInt(24 * value.rects.length);
      final tmp53 = i0.mallocAligned(const i3.WasmI32(4), tmp52);
      var tmp54 = tmp53;
      for (final element in value.rects) {
        final elementPtr = tmp54;
        final tmp51 = i0.AllocatedString.allocateUtf16(element.id);
        i0.memory.storeInt32(
          elementPtr.toIntUnsigned(),
          tmp51.packedLength,
          offset: 4,
        );
        i0.memory.storeInt32(elementPtr.toIntUnsigned(), tmp51.ptr, offset: 0);
        i0.memory.storeInt32(
          elementPtr.toIntUnsigned(),
          i3.WasmI32.fromInt(element.rect.col),
          offset: 8,
        );
        i0.memory.storeInt32(
          elementPtr.toIntUnsigned(),
          i3.WasmI32.fromInt(element.rect.row),
          offset: 12,
        );
        i0.memory.storeInt32(
          elementPtr.toIntUnsigned(),
          i3.WasmI32.fromInt(element.rect.width),
          offset: 16,
        );
        i0.memory.storeInt32(
          elementPtr.toIntUnsigned(),
          i3.WasmI32.fromInt(element.rect.height),
          offset: 20,
        );

        tmp54 += const i3.WasmI32(24);
      }

      i0.memory.storeInt32(
        tmp50.toIntUnsigned(),
        i3.WasmI32.fromInt(value.rects.length),
        offset: 28,
      );
      i0.memory.storeInt32(tmp50.toIntUnsigned(), tmp53, offset: 24);

      final tmp55 = i3.WasmI32.fromInt(8 * value.columnTrackSizes.length);
      final tmp56 = i0.mallocAligned(const i3.WasmI32(8), tmp55);
      var tmp57 = tmp56;
      for (final element in value.columnTrackSizes) {
        final elementPtr = tmp57;
        i0.memory.storeFloat64(
          elementPtr.toIntUnsigned(),
          i3.WasmF64.fromDouble(element),
          offset: 0,
        );

        tmp57 += const i3.WasmI32(8);
      }

      i0.memory.storeInt32(
        tmp50.toIntUnsigned(),
        i3.WasmI32.fromInt(value.columnTrackSizes.length),
        offset: 36,
      );
      i0.memory.storeInt32(tmp50.toIntUnsigned(), tmp56, offset: 32);

      final tmp58 = i3.WasmI32.fromInt(8 * value.rowTrackSizes.length);
      final tmp59 = i0.mallocAligned(const i3.WasmI32(8), tmp58);
      var tmp60 = tmp59;
      for (final element in value.rowTrackSizes) {
        final elementPtr = tmp60;
        i0.memory.storeFloat64(
          elementPtr.toIntUnsigned(),
          i3.WasmF64.fromDouble(element),
          offset: 0,
        );

        tmp60 += const i3.WasmI32(8);
      }

      i0.memory.storeInt32(
        tmp50.toIntUnsigned(),
        i3.WasmI32.fromInt(value.rowTrackSizes.length),
        offset: 44,
      );
      i0.memory.storeInt32(tmp50.toIntUnsigned(), tmp59, offset: 40);

      final tmp63 = i3.WasmI32.fromInt(16 * value.dropped.length);
      final tmp64 = i0.mallocAligned(const i3.WasmI32(4), tmp63);
      var tmp65 = tmp64;
      for (final element in value.dropped) {
        final elementPtr = tmp65;
        final tmp61 = i0.AllocatedString.allocateUtf16(element.id);
        i0.memory.storeInt32(
          elementPtr.toIntUnsigned(),
          tmp61.packedLength,
          offset: 4,
        );
        i0.memory.storeInt32(elementPtr.toIntUnsigned(), tmp61.ptr, offset: 0);
        final tmp62 = i0.AllocatedString.allocateUtf16(element.reason);
        i0.memory.storeInt32(
          elementPtr.toIntUnsigned(),
          tmp62.packedLength,
          offset: 12,
        );
        i0.memory.storeInt32(elementPtr.toIntUnsigned(), tmp62.ptr, offset: 8);

        tmp65 += const i3.WasmI32(16);
      }

      i0.memory.storeInt32(
        tmp50.toIntUnsigned(),
        i3.WasmI32.fromInt(value.dropped.length),
        offset: 52,
      );
      i0.memory.storeInt32(tmp50.toIntUnsigned(), tmp64, offset: 48);
      i0.memory.storeFloat64(
        tmp50.toIntUnsigned(),
        i3.WasmF64.fromDouble(value.overflowUnitsX),
        offset: 56,
      );
      i0.memory.storeFloat64(
        tmp50.toIntUnsigned(),
        i3.WasmF64.fromDouble(value.overflowUnitsY),
        offset: 64,
      );
      i0.memory.storeFloat64(
        tmp50.toIntUnsigned(),
        i3.WasmF64.fromDouble(value.trailingGapUnitsX),
        offset: 72,
      );
      i0.memory.storeFloat64(
        tmp50.toIntUnsigned(),
        i3.WasmF64.fromDouble(value.trailingGapUnitsY),
        offset: 80,
      );

    case i0.ErrorResult(:final value):
      i0.memory.storeInt8(
        tmp50.toIntUnsigned(),
        const i3.WasmI32(1),
        offset: 0,
      );
      final tmp66 = i0.AllocatedString.allocateUtf16(value);
      i0.memory.storeInt32(
        tmp50.toIntUnsigned(),
        tmp66.packedLength,
        offset: 12,
      );
      i0.memory.storeInt32(tmp50.toIntUnsigned(), tmp66.ptr, offset: 8);
  }
  return tmp50;
}

@pragma('wasm:export', r'component_1_postreturn')
i3.WasmVoid _component_1$postreturn(i3.WasmI32 p0) {
  final tmp0 = i0.memory.loadUint8(p0.toIntUnsigned(), offset: 0);
  switch (tmp0) {
    case 0:
      final tmp1 = i0.memory.loadInt32(p0.toIntUnsigned(), offset: 24);
      final tmp2 = i0.memory.loadInt32(p0.toIntUnsigned(), offset: 28);

      final tmp5 = tmp1.toIntUnsigned();
      for (var tmp6 = 0; tmp6 < tmp2.toIntUnsigned(); tmp6++) {
        final elementPtr = i3.WasmI32.fromInt(tmp5 + tmp6 * 24);
        final tmp3 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 0);
        final tmp4 = i0.memory.loadInt32(elementPtr.toIntUnsigned(), offset: 4);
        i0.AllocatedString(tmp3, tmp4).free();
      }
      i0.dartFree(
        tmp1,
        i3.WasmI32.fromInt(tmp2.toIntUnsigned() * 24),
        const i3.WasmI32(4),
      );

      final tmp7 = i0.memory.loadInt32(p0.toIntUnsigned(), offset: 32);
      final tmp8 = i0.memory.loadInt32(p0.toIntUnsigned(), offset: 36);

      final tmp9 = tmp7.toIntUnsigned();
      for (var tmp10 = 0; tmp10 < tmp8.toIntUnsigned(); tmp10++) {
        final elementPtr = i3.WasmI32.fromInt(tmp9 + tmp10 * 8);
      }
      i0.dartFree(
        tmp7,
        i3.WasmI32.fromInt(tmp8.toIntUnsigned() * 8),
        const i3.WasmI32(8),
      );

      final tmp11 = i0.memory.loadInt32(p0.toIntUnsigned(), offset: 40);
      final tmp12 = i0.memory.loadInt32(p0.toIntUnsigned(), offset: 44);

      final tmp13 = tmp11.toIntUnsigned();
      for (var tmp14 = 0; tmp14 < tmp12.toIntUnsigned(); tmp14++) {
        final elementPtr = i3.WasmI32.fromInt(tmp13 + tmp14 * 8);
      }
      i0.dartFree(
        tmp11,
        i3.WasmI32.fromInt(tmp12.toIntUnsigned() * 8),
        const i3.WasmI32(8),
      );

      final tmp15 = i0.memory.loadInt32(p0.toIntUnsigned(), offset: 48);
      final tmp16 = i0.memory.loadInt32(p0.toIntUnsigned(), offset: 52);

      final tmp21 = tmp15.toIntUnsigned();
      for (var tmp22 = 0; tmp22 < tmp16.toIntUnsigned(); tmp22++) {
        final elementPtr = i3.WasmI32.fromInt(tmp21 + tmp22 * 16);
        final tmp17 = i0.memory.loadInt32(
          elementPtr.toIntUnsigned(),
          offset: 0,
        );
        final tmp18 = i0.memory.loadInt32(
          elementPtr.toIntUnsigned(),
          offset: 4,
        );
        i0.AllocatedString(tmp17, tmp18).free();
        final tmp19 = i0.memory.loadInt32(
          elementPtr.toIntUnsigned(),
          offset: 8,
        );
        final tmp20 = i0.memory.loadInt32(
          elementPtr.toIntUnsigned(),
          offset: 12,
        );
        i0.AllocatedString(tmp19, tmp20).free();
      }
      i0.dartFree(
        tmp15,
        i3.WasmI32.fromInt(tmp16.toIntUnsigned() * 16),
        const i3.WasmI32(4),
      );

      break;
    case 1:
      final tmp23 = i0.memory.loadInt32(p0.toIntUnsigned(), offset: 8);
      final tmp24 = i0.memory.loadInt32(p0.toIntUnsigned(), offset: 12);
      i0.AllocatedString(tmp23, tmp24).free();
      break;
  }
  i0.dartFree(p0, const i3.WasmI32(88), const i3.WasmI32(8));
  return i3.WasmVoid();
}
