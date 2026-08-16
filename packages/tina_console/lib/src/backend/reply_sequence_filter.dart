/// Prototype filter for tin-v6tq — NOT yet wired into [NotcursesInputBackend].
///
/// Drops *terminal reply sequences* (OSC/CSI/DCS/APC payloads arriving as key
/// events) from a pump-level key stream, so a late or re-delivered capability
/// reply does not paste into the editor as text.
///
/// ## Why this is possible at the event layer
///
/// The tin-v6tq ticket recorded that a content-based filter was "not
/// implementable at this layer: a reply's printable bytes are
/// indistinguishable from typing". Capturing what the pump actually delivers
/// (tool/reply_decode_spike.dart, 2026-08-16) disproves that: notcurses' input
/// automaton has no rule for OSC replies *after* init, so it emits the leading
/// `ESC` as a standalone key event and decodes the rest of the reply as
/// ordinary printable characters. Measured, in one run:
///
///  - a re-injected reply bundle: **4837 events over 198 ms** (max inter-event
///    gap 3 ms), 267 of them `ESC`, every reply starting `ESC` + `]`/`[`;
///  - a genuine 5400-byte bracketed paste: 5400 events over 18 ms with **zero
///    `ESC` events** (notcurses consumes the `ESC[200~`/`ESC[201~` markers);
///  - typing: isolated events, gaps of seconds.
///
/// So "reply" is distinguishable from both typing and pasting by two
/// independent signals: an `ESC` immediately followed by a sequence
/// introducer, arriving at burst rate.
///
/// ## Termination matters
///
/// Each introducer class ends differently, and getting this wrong is not
/// cosmetic — an early prototype that only ended a reply on `BEL` or `ESC \`
/// never closed on the CSI replies (which end in a final byte, e.g. the
/// `t` of `ESC[8;40;120t`) and then swallowed the rest of the session,
/// including the next real paste:
///
///  - **OSC** (`ESC ]`): `BEL` (0x07) or `ST` (`ESC \`).
///  - **CSI** (`ESC [`): parameter/intermediate bytes 0x20–0x3F, then one
///    final byte 0x40–0x7E.
///  - **DCS / APC / PM / SOS** (`ESC P` `ESC _` `ESC ^` `ESC X`): `ST` only.
///
/// ## False positives
///
///  - **Typing `ESC` then `]`**: requires the two keys within
///    [introducerWindow] (5 ms). Not physically producible by hand.
///  - **A genuine paste**: contains no `ESC` events at all (see above), so it
///    cannot match. A paste of text that *itself* contains literal reply
///    sequences (e.g. pasting a captured typescript) would have those runs
///    dropped — noted as an accepted trade-off on the ticket, since injecting
///    raw control sequences into the editor is unwanted either way.
///  - **An undecoded CSI key** (`ESC [ A`, an arrow): if notcurses ever failed
///    to decode a real key it would surface as `ESC` + `[` + `A` and be
///    swallowed here (`A` is a valid CSI final byte). Mitigated by
///    [_abortOnControlKey]: any non-printable event inside a reply stops the
///    swallow and is delivered, so a user's Enter/Tab/Backspace is never eaten.
///
/// Pure and time-parameterized (no I/O, no notcurses dependency), so it is
/// unit-testable directly. Single-threaded; callers must serialize
/// [add]/[flush].
class ReplySequenceFilter {
  /// How long after an `ESC` the next event may arrive and still be read as a
  /// sequence introducer. Measured reply gaps are ≤3 ms; a human pressing two
  /// keys is ≥50 ms apart, so 5 ms sits between them.
  final Duration introducerWindow;

  /// A single reply longer than this is abandoned and the remainder delivered
  /// as ordinary input. Guards against swallowing the whole keyboard after a
  /// pathological unterminated sequence.
  final int maxReplyLength;

  ReplySequenceFilter({
    this.introducerWindow = const Duration(milliseconds: 5),
    this.maxReplyLength = 8192,
  });

  int _state = _idle;
  int _heldEscAt = 0;
  int _replyLength = 0;
  late int _class;

  static const int _idle = 0;
  static const int _afterEsc = 1;
  static const int _inReply = 2;
  static const int _inReplyAfterEsc = 3;

  // Reply classes, keyed by the byte that follows ESC.
  static const int _osc = 0x5d; // ]
  static const int _csi = 0x5b; // [
  static const int _dcs = 0x50; // P
  static const int _apc = 0x5f; // _
  static const int _pm = 0x5e; // ^
  static const int _sos = 0x58; // X

  /// Feed one key event (a notcurses key id) stamped at [monotonicMicros].
  /// Returns the events to emit now — empty while a candidate reply is being
  /// examined or swallowed, the input itself when it is not part of a reply.
  List<int> add(int id, int monotonicMicros) {
    switch (_state) {
      case _idle:
        if (id == _esc) {
          _heldEscAt = monotonicMicros;
          _state = _afterEsc;
          return const [];
        }
        return [id];

      case _afterEsc:
        if (monotonicMicros - _heldEscAt > introducerWindow.inMicroseconds) {
          // ESC stood alone for longer than any reply introducer could take:
          // it was a real Escape, and this event is unrelated.
          _state = _idle;
          return [_esc, id];
        }
        final cls = _classOf(id);
        if (cls != 0) {
          _class = cls;
          _replyLength = 0;
          _state = _inReply;
          return const [];
        }
        _state = _idle;
        return [_esc, id];

      case _inReply:
        _replyLength++;
        if (_replyLength > maxReplyLength) {
          _state = _idle;
          return [id];
        }
        switch (_class) {
          case _osc:
            if (id == _bel) {
              _state = _idle;
              return const [];
            }
            if (id == _esc) {
              _heldEscAt = monotonicMicros;
              _state = _inReplyAfterEsc;
              return const [];
            }
          case _csi:
            // ESC inside a CSI is not a terminator: deliver the abort below.
            if (id == _esc) break;
            // Parameter/intermediate bytes keep the reply open…
            if (id >= 0x20 && id <= 0x3f) return const [];
            // …and a final byte (0x40–0x7E) closes it.
            if (id >= 0x40 && id <= 0x7e) {
              _state = _idle;
              return const [];
            }
          default: // DCS / APC / PM / SOS — ST only.
            if (id == _esc) {
              _heldEscAt = monotonicMicros;
              _state = _inReplyAfterEsc;
              return const [];
            }
        }
        if (_abortOnControlKey(id)) {
          _state = _idle;
          return [id];
        }
        return const [];

      case _inReplyAfterEsc:
        // The ESC held here is the ST opener (`ESC \`), except in CSI where an
        // ESC mid-reply means the reply is over — a new sequence may start.
        if (id == _backslash) {
          _state = _idle;
          return const [];
        }
        if (id == _esc) {
          return const []; // Two ESCs in a row; keep waiting.
        }
        final cls = _classOf(id);
        if (cls != 0 && _class != _csi) {
          // A new sequence began before the old one terminated.
          _class = cls;
          _replyLength = 0;
          _state = _inReply;
          return const [];
        }
        if (_abortOnControlKey(id)) {
          _state = _idle;
          return [id];
        }
        _state = _idle;
        return [id];

      default:
        _state = _idle;
        return [id];
    }
  }

  /// Release anything still held once the stream goes quiet. Only an `ESC`
  /// awaiting an introducer can be outstanding; a reply in progress has
  /// already been swallowed.
  List<int> flush() {
    if (_state == _afterEsc) {
      _state = _idle;
      return [_esc];
    }
    _state = _idle;
    return const [];
  }

  /// The reply class for [id], or 0 when it is not a sequence introducer.
  int _classOf(int id) {
    switch (id) {
      case _osc:
      case _csi:
      case _dcs:
      case _apc:
      case _pm:
      case _sos:
        return id;
      default:
        return 0;
    }
  }

  /// A non-printable, non-terminator event inside a reply means this is not a
  /// reply after all — deliver it rather than swallow a real key press.
  bool _abortOnControlKey(int id) =>
      (id < 0x20 && id != _bel) || id == 0x7f || id >= 0x110000;

  static const int _esc = 0x1b;
  static const int _bel = 0x07;
  static const int _backslash = 0x5c;
}
