import 'package:logging/logging.dart';

/// Forensic log for safety denials: sandbox violations, denylist hits, fanout
/// rejections, and action-cap trips. Writes to the `tina.audit` logger, which
/// shares the app-wide file sink (`~/.tina/tina.log`) set up in
/// `lib/logging.dart` — so denials land in one persistent, tail-able place.
///
/// Every denial in the codebase routes through [auditDenial] so forensics sees
/// the whole safety surface. The detail passed in is *redacted* before logging:
/// a denied `curl` with an embedded token, or a path to `~/.ssh/id_rsa`, must
/// not persist secrets to the log file.

final _auditLog = Logger('tina.audit');

/// Hard-coded categories. Kept small and explicit — this isn't a free-form
/// event bus, just the kinds of safety trip we audit.
const String auditSandbox = 'sandbox';
const String auditDenylist = 'denylist';
const String auditFanout = 'fanout';
const String auditAction = 'action';

/// Log a safety denial. [kind] is one of the `audit*` constants; [detail] is the
/// blocked command/path/fanout count — it is redacted before being written, so
/// callers can pass the raw value without sanitizing it themselves.
void auditDenial({required String kind, required String detail}) {
  _auditLog.info('$kind: ${redact(detail)}');
}

/// Best-effort secret scrubber for denial detail. Not cryptographic — just meant
/// to keep obviously-sensitive tokens and key paths out of a plaintext log an
/// adversary (or a future log shipper) might read.
///
/// Rules, applied in order:
/// - URL query values and `userinfo@` are redacted (exfil URLs carry secrets in
///   the query string, e.g. `https://evil/?t=<token>`).
/// - Sensitive path segments (`.ssh`, `.aws`, `id_rsa`, ...) are replaced.
/// - Long opaque tokens (20+ char hex/base64 runs) are collapsed.
/// - The whole thing is truncated so a giant blocked command can't bloat the log.
String redact(String detail) {
  var s = detail;

  // URL query values: ?k=&k= and #frag.
  s = s.replaceAllMapped(
    RegExp(r'([?&][A-Za-z0-9_.-]+=)([^&\s]*)'),
    (m) => '${m[1]}<redacted>',
  );
  // userinfo in urls: //user:pass@host
  s = s.replaceAllMapped(
    RegExp(r':\/\/[^/\s]+@'),
    (m) => '://<redacted>@',
  );

  // Sensitive path segments.
  for (final seg in _sensitiveSegments) {
    s = s.replaceAll(seg, '<redacted>');
  }

  // Long opaque tokens (keys, bearer tokens, hex digests) — 20+ word chars of
  // hex/base64-ish alphabet with no whitespace.
  s = s.replaceAllMapped(
    RegExp(r'[A-Za-z0-9+\/=]{20,}'),
    (m) {
      final t = m[0]!;
      // Leave short-ish tokens and obvious non-secrets alone; only collapse
      // runs that look like a credential (mostly hex or base64, not English).
      final nonLetter = t.replaceAll(RegExp(r'[A-Za-z]'), '').length;
      return nonLetter / t.length > 0.5 ? '<redacted>' : t;
    },
  );

  // Truncate.
  const max = 200;
  if (s.length > max) s = '${s.substring(0, max)}...(${s.length - max} more)';
  return s;
}

final List<RegExp> _sensitiveSegments = [
  RegExp(r'/\.ssh/', caseSensitive: false),
  RegExp(r'/\.aws/', caseSensitive: false),
  RegExp(r'/\.tina/', caseSensitive: false),
  RegExp(r'/\.env', caseSensitive: false),
  RegExp(r'/\.gnupg/', caseSensitive: false),
  RegExp(r'\bid_rsa\b', caseSensitive: false),
  RegExp(r'\bid_ed25519\b', caseSensitive: false),
  RegExp(r'\.pem\b', caseSensitive: false),
  RegExp(r'\.p12\b', caseSensitive: false),
  RegExp(r'\bcredentials\b', caseSensitive: false),
  RegExp(r'\bsecret', caseSensitive: false),
];
