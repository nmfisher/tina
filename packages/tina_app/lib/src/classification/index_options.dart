enum LanguageMethod { jev, extensions }

class IndexOptions {
  static const defaultMethod = LanguageMethod.extensions;
  static const usage = 'Usage: /index [jev|extensions] [status|refresh]';
  final LanguageMethod method;
  final String mode;
  const IndexOptions({this.method = defaultMethod, this.mode = ''});

  factory IndexOptions.parse(String arguments) {
    LanguageMethod? method;
    String? mode;
    for (final token
        in arguments.split(RegExp(r'\s+')).where((s) => s.isNotEmpty)) {
      switch (token) {
        case 'jev':
        case 'extensions':
          if (method != null) throw ArgumentError(usage);
          method = LanguageMethod.values.byName(token);
        case 'status':
        case 'refresh':
          if (mode != null) throw ArgumentError(usage);
          mode = token;
        default:
          throw ArgumentError(usage);
      }
    }
    return IndexOptions(method: method ?? defaultMethod, mode: mode ?? '');
  }
}
