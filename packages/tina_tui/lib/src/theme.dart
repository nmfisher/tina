import 'package:tina_console/tina_console.dart';

/// Merge explicit color overrides over the selected shipped variant.
Theme resolveTheme(Map<String, dynamic> values) {
  final base = switch (values['variant']) {
    'light' => const Theme.light(),
    'dark' => const Theme.dark(),
    _ => const Theme.defaults(),
  };
  Map<String, dynamic> merge(Map<String, dynamic> a, Map<String, dynamic> b) =>
      {
        ...a,
        for (final e in b.entries)
          if (e.key != 'variant')
            e.key: e.value is Map && a[e.key] is Map
                ? merge(Map<String, dynamic>.from(a[e.key] as Map),
                    Map<String, dynamic>.from(e.value as Map))
                : e.value,
      };
  return Theme.fromMap(merge(base.toMap(), values));
}
