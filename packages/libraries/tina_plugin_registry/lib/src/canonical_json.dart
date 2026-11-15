/// Canonical JSON encoding: object keys sorted lexicographically
/// recursively, `,`/`:` separators with no whitespace, UTF-8, integers
/// plain. This is exactly the byte format the Rust publisher signs.
import 'dart:convert';

String canonicalJson(Object? value) {
  final out = StringBuffer();
  _write(value, out);
  return out.toString();
}

void _write(Object? value, StringBuffer out) {
  switch (value) {
    case null:
      out.write('null');
    case bool b:
      out.write(b ? 'true' : 'false');
    case num n:
      out.write(_number(n));
    case String s:
      out.write(json.encode(s));
    case List items:
      out.write('[');
      for (var i = 0; i < items.length; i++) {
        if (i > 0) out.write(',');
        _write(items[i], out);
      }
      out.write(']');
    case Map map:
      final keys = map.keys.map((k) => k.toString()).toList()..sort();
      out.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) out.write(',');
        out.write(json.encode(keys[i]));
        out.write(':');
        _write(map[keys[i]], out);
      }
      out.write('}');
    default:
      throw ArgumentError('unsupported canonical JSON value: $value');
  }
}

String _number(num n) {
  if (n is int) return n.toString();
  if (n is double) {
    if (n == n.truncateToDouble()) return n.toInt().toString();
    return n.toString();
  }
  return n.toString();
}
