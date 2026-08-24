import 'dart:async';
import 'dart:convert';

import 'input_event.dart';

/// State machine that decodes raw terminal bytes into [InputEvent]s.
///
/// Handles UTF-8 accumulation, ESC/CSI/SS3 sequence parsing, and single-byte
/// control code recognition. When [escapeTimeout] is set, a standalone ESC
/// byte that receives no following byte within the timeout produces an
/// [EscapeKey] delivered via the [onTimeout] callback — this allows the parser
/// to disambiguate "user pressed Escape" from "ESC is the start of a
/// multi-byte sequence".
///
/// When [macosOptionAsMeta] is true, macOS Option+letter characters (e.g. ƒ
/// for Option+F) are mapped back to [AltKey] events, so menus work without
/// requiring the user to enable "Use Option as Meta" in their terminal.
///
/// No I/O — feed bytes in, get events out.
class InputParser {
  final Duration? _escapeTimeout;
  final void Function(InputEvent)? _onTimeout;
  final bool macosOptionAsMeta;
  Timer? _escTimer;

  final List<int> _escBuf = [];
  final List<int> _utf8Pending = [];

  /// True between a `ESC[200~` start marker and its `ESC[201~` end marker.
  /// While collecting, bytes route into [_pasteBuf] instead of being decoded
  /// as keystrokes — so a paste's embedded newlines/tabs/controls are
  /// preserved verbatim rather than interpreted as Enter/Tab/etc.
  bool _inPaste = false;
  final List<int> _pasteBuf = [];

  /// True when a CSI sequence exceeded the buffer limit without a final byte.
  /// Bytes are consumed and discarded until a CSI final byte (0x40–0x7e)
  /// arrives. Without this, long terminal query responses (DA2, XTVERSION)
  /// overflow the buffer and subsequent bytes leak as visible characters.
  bool _discardingCsi = false;

  /// True while discarding an OSC sequence (`ESC]` … terminator). Terminal
  /// query replies (e.g. the OSC 11 background-color response) carry no input
  /// semantics and must not reach the editor — without this, `ESC]` falls
  /// through as `AltKey(']')` and the payload bytes render as visible junk.
  bool _discardingOsc = false;

  /// Set when an `ESC` is seen mid-OSC: it may be the lead byte of the ST
  /// terminator (`ESC \`); the next byte decides.
  bool _oscSawEsc = false;

  /// True while collecting a sequence that began `ESC ESC` — the first ESC is
  /// the Alt modifier (macOS Terminal.app sends Alt+Arrow as `ESC ESC [ D`,
  /// an ESC-prefixed CSI, rather than xterm's `ESC [ 1;3 D`). When the
  /// sequence completes, its [ArrowKey] gets `hasAlt` set.
  bool _altPrefix = false;

  /// macOS Option key produces special Unicode characters instead of the
  /// ESC+letter sequence. This table maps those code points back to the
  /// lowercase letter the user intended, so [AltKey] events fire correctly.
  /// Dead-key combinations (Option+E/I/N/U/`) are excluded — they don't
  /// produce a character immediately and can't be mapped.
  static const _macosOptionMap = <int, int>{
    0x00E5: 0x61, // å → a
    0x222B: 0x62, // ∫ → b
    0x00E7: 0x63, // ç → c
    0x2202: 0x64, // ∂ → d
    0x0192: 0x66, // ƒ → f
    0x00A9: 0x67, // © → g
    0x02D9: 0x68, // ˙ → h
    0x2206: 0x6A, // ∆ → j
    0x00AC: 0x6C, // ¬ → l
    0x00B5: 0x6D, // µ → m
    0x00F8: 0x6F, // ø → o
    0x03C0: 0x70, // π → p
    0x0153: 0x71, // œ → q
    0x00AE: 0x72, // ® → r
    0x00DF: 0x73, // ß → s
    0x2020: 0x74, // † → t
    0x221A: 0x76, // √ → v
    0x2211: 0x77, // ∑ → w
    0x2248: 0x78, // ≈ → x
    0x00A5: 0x79, // ¥ → y
    0x03A9: 0x7A, // Ω → z
  };

  InputParser({
    Duration? escapeTimeout,
    void Function(InputEvent)? onTimeout,
    this.macosOptionAsMeta = false,
  })  : _escapeTimeout = escapeTimeout,
        _onTimeout = onTimeout;

  /// Feed a single raw byte. Returns `null` when more bytes are needed
  /// (mid-escape or mid-UTF-8), or a fully decoded [InputEvent].
  InputEvent? feed(int b) {
    // Any new byte cancels a pending ESC timeout — the ESC was part of a
    // multi-byte sequence, not standalone.
    _escTimer?.cancel();
    _escTimer = null;

    // Mid-OSC discard: consume bytes until the terminator (BEL or ST).
    // An ESC mid-sequence might be the lead byte of the ST terminator
    // (`ESC \`); flag it and let the next byte decide. Everything else is
    // swallowed so terminal query replies (OSC 11, etc.) never reach the
    // editor as visible characters.
    if (_discardingOsc) {
      if (_oscSawEsc) {
        _oscSawEsc = false;
        if (b == 0x5c) {
          // ST (ESC \) — terminator found.
          _discardingOsc = false;
        }
        // Any byte after a lone ESC that isn't '\' keeps discarding; the
        // ESC is dropped (it's inside the OSC payload).
        return null;
      }
      if (b == 0x07) {
        // BEL terminator.
        _discardingOsc = false;
        return null;
      }
      if (b == 0x1b) {
        _oscSawEsc = true;
        return null;
      }
      return null;
    }

    // A previous CSI sequence overflowed — swallow bytes until the final
    // byte (0x40–0x7e) arrives, then resume normal parsing. This prevents
    // long terminal query responses (DA2, XTVERSION, palette) from leaking
    // as visible characters in the editor.
    if (_discardingCsi) {
      if (b >= 0x40 && b <= 0x7e) {
        _discardingCsi = false;
        _escBuf.clear();
      }
      return null;
    }

    // Collecting a bracketed paste: route every byte into [_pasteBuf] (this
    // runs *before* the ESC/CSI machinery so the end marker's leading ESC
    // stays in the buffer and isn't hijacked as a standalone escape). When the
    // trailing `ESC[201~` appears, emit one [PasteInput] with the full text.
    if (_inPaste) {
      _pasteBuf.add(b);
      if (_pasteBuf.length >= 6 && _isPasteEndSuffix()) {
        _pasteBuf.length -= 6;
        _inPaste = false;
        final text = utf8.decode(_pasteBuf, allowMalformed: true);
        _pasteBuf.clear();
        return PasteInput(text);
      }
      return null;
    }

    if (_escBuf.isNotEmpty) {
      _escBuf.add(b);
      if (_tryFinishEscape()) {
        final result = _pendingEvent;
        _pendingEvent = null;
        _escBuf.clear();
        return _applyAltPrefix(result);
      }
      return null;
    }
    if (_utf8Pending.isNotEmpty) {
      _utf8Pending.add(b);
      return _tryDecodePending();
    }
    if (b == 0x1b) {
      _escBuf.add(b);
      // Start timeout — if no following byte arrives, this is standalone ESC.
      if (_escapeTimeout != null && _onTimeout != null) {
        _escTimer = Timer(_escapeTimeout!, _onEscTimeout);
      }
      return null;
    }
    if (b == 0x17) return ControlKey(ControlCode.ctrlW);
    if (b == 0x07) return ControlKey(ControlCode.ctrlG);
    if (b == 0x03) return ControlKey(ControlCode.ctrlC);
    if (b == 0x04) return ControlKey(ControlCode.ctrlD);
    if (b == 0x0d || b == 0x0a) return ControlKey(ControlCode.enter);
    if (b == 0x09) return ControlKey(ControlCode.tab);
    if (b == 0x7f || b == 0x08) return ControlKey(ControlCode.backspace);
    if (b == 0x0c) return ControlKey(ControlCode.ctrlL);
    if (b == 0x13) return ControlKey(ControlCode.ctrlS);
    if (b == 0x0f) return ControlKey(ControlCode.ctrlO);
    if (b == 0x12) return ControlKey(ControlCode.ctrlR);
    if (b == 0x01) return EditingKey(EditingAction.home);
    if (b == 0x05) return EditingKey(EditingAction.end);
    if (b == 0x0b) return EditingKey(EditingAction.killToEnd);
    if (b == 0x15) return EditingKey(EditingAction.killToStart);
    if (b < 0x20) return null;
    if (b < 0x80) return CharInput(String.fromCharCode(b));
    _utf8Pending.add(b);
    return null;
  }

  /// Called when the ESC timeout fires — no following byte arrived, so the
  /// ESC was standalone. Produces [EscapeKey] via the [onTimeout] callback.
  void _onEscTimeout() {
    _escTimer = null;
    _escBuf.clear();
    _altPrefix = false;
    _onTimeout!(EscapeKey());
  }

  /// Reset all internal state.
  void reset() {
    _escTimer?.cancel();
    _escTimer = null;
    _escBuf.clear();
    _utf8Pending.clear();
    _pendingEvent = null;
    _discardingCsi = false;
    _discardingOsc = false;
    _oscSawEsc = false;
    _altPrefix = false;
    _inPaste = false;
    _pasteBuf.clear();
  }

  /// Release resources (cancel timers).
  void dispose() {
    _escTimer?.cancel();
    _escTimer = null;
  }

  /// Whether a multi-byte sequence is in progress.
  bool get isMidSequence =>
      _escBuf.isNotEmpty ||
      _utf8Pending.isNotEmpty ||
      _inPaste ||
      _discardingOsc;

  InputEvent? _pendingEvent;

  /// Whether the last six bytes of [_pasteBuf] are `ESC[201~` — the bracketed
  /// paste end marker. The start marker (`ESC[200~`) sets [_inPaste]; while
  /// collecting, the end marker's bytes accumulate at the tail of the buffer
  /// and are detected here so the preceding text becomes the [PasteInput].
  bool _isPasteEndSuffix() {
    final n = _pasteBuf.length;
    return _pasteBuf[n - 6] == 0x1b &&
        _pasteBuf[n - 5] == 0x5b &&
        _pasteBuf[n - 4] == 0x32 &&
        _pasteBuf[n - 3] == 0x30 &&
        _pasteBuf[n - 2] == 0x31 &&
        _pasteBuf[n - 1] == 0x7e;
  }

  /// Try to decode pending UTF-8 bytes.
  InputEvent? _tryDecodePending() {
    try {
      final s = utf8.decode(_utf8Pending);
      _utf8Pending.clear();
      if (macosOptionAsMeta && s.length == 1) {
        final cp = s.codeUnitAt(0);
        final letter = _macosOptionMap[cp];
        if (letter != null) return AltKey(letter);
      }
      return CharInput(s);
    } catch (_) {
      if (_utf8Pending.length > 4) _utf8Pending.clear();
      return null;
    }
  }

  /// Check whether [_escBuf] contains a complete escape sequence.
  /// Sets [_pendingEvent] on completion.
  bool _tryFinishEscape() {
    if (_escBuf.length < 2) return false;
    final second = _escBuf[1];
    if (second == 0x5b || second == 0x4f) {
      // CSI or SS3 sequence.
      if (_escBuf.length == 2) return false;
      final last = _escBuf.last;
      if (last >= 0x40 && last <= 0x7e) {
        _dispatchCsi(second, _escBuf.sublist(2));
        return true;
      }
      if (_escBuf.length > 8) {
        // Overlong CSI — terminal query responses (DA2, XTVERSION, palette)
        // can be 14–100+ bytes. Instead of aborting and leaking the remaining
        // bytes as visible characters, swallow until a CSI final byte arrives.
        _discardingCsi = true;
        _pendingEvent = null;
        return true;
      }
      return false;
    }
    if (second == 0x1b) {
      // ESC ESC <sequence> — the first ESC is the Alt modifier. Drop it, flag
      // the modifier, and keep collecting the sequence that follows (a CSI/SS3
      // arrow, typically — macOS Terminal.app sends Alt+Arrow this way). The
      // escape timer restarts so a lone double-ESC still resolves via timeout.
      _escBuf.removeAt(0);
      _altPrefix = true;
      if (_escapeTimeout != null && _onTimeout != null) {
        _escTimer?.cancel();
        _escTimer = Timer(_escapeTimeout!, _onEscTimeout);
      }
      return false;
    }
    if (second == 0x5d) {
      // OSC introducer (ESC]). Terminal query replies (OSC 11 background
      // color, OSC 8 hyperlinks, etc.) carry no input semantics and their
      // payloads would otherwise render as visible junk. Enter the discard
      // state and swallow everything up to the terminator (BEL or ST), which
      // is handled byte-by-byte in [feed].
      _discardingOsc = true;
      _oscSawEsc = false;
      _pendingEvent = null;
      return true;
    }
    // Two-byte escape that isn't CSI/SS3.
    // If the second byte is a printable ASCII character, this is Alt+letter.
    if (second >= 0x20 && second < 0x7f) {
      final lower =
          (second >= 0x41 && second <= 0x5a) ? second + 0x20 : second;
      _pendingEvent = AltKey(lower);
    } else if (second == 0x7f) {
      // Alt+Backspace (ESC followed by DEL).
      _pendingEvent = EditingKey(EditingAction.deleteWordBackward);
    }
    return true;
  }

  /// Stamp `hasAlt` onto a completed sequence's [ArrowKey] when it was
  /// ESC-prefixed (`ESC ESC [ D`), then clear the flag. Non-arrow results
  /// (and nulls) just clear it — they have no modifier to carry.
  InputEvent? _applyAltPrefix(InputEvent? event) {
    final alt = _altPrefix;
    _altPrefix = false;
    if (alt && event is ArrowKey && !event.hasAlt) {
      return ArrowKey(event.direction,
          hasCtrl: event.hasCtrl, hasAlt: true);
    }
    return event;
  }

  /// Map a complete CSI/SS3 sequence to an [InputEvent].
  void _dispatchCsi(int introducer, List<int> rest) {
    if (rest.isEmpty) return;
    final last = rest.last;
    final params = rest.sublist(0, rest.length - 1);
    if (introducer == 0x5b) {
      if (params.isEmpty) {
        switch (last) {
          case 0x41:
            _pendingEvent = ArrowKey(ArrowDirection.up);
            return;
          case 0x42:
            _pendingEvent = ArrowKey(ArrowDirection.down);
            return;
          case 0x43:
            _pendingEvent = ArrowKey(ArrowDirection.right);
            return;
          case 0x44:
            _pendingEvent = ArrowKey(ArrowDirection.left);
            return;
          case 0x5a:
            // CSI Z — backtab (Shift+Tab). A distinct key from plain Tab
            // (0x09): apps bind it as a reverse-cycle modifier. Routed to
            // the editor's onBackTab hook; the editor itself binds nothing.
            _pendingEvent = ControlKey(ControlCode.backtab);
            return;
          case 0x48:
            _pendingEvent = EditingKey(EditingAction.home);
            return;
          case 0x46:
            _pendingEvent = EditingKey(EditingAction.end);
            return;
        }
      }
      // CSI 1;<mod>{A,B,C,D} — modified arrow. Modifier byte encodes bits
      // (shift=1, alt=2, ctrl=4) offset by 1: 5=Ctrl, 6=Shift+Ctrl,
      // 7=Alt+Ctrl, 8=all. FocusManager only cares about hasCtrl; other
      // modifiers pass through as a plain arrow so downstream editors
      // still work.
      if (last == 0x41 || last == 0x42 || last == 0x43 || last == 0x44) {
        final s = String.fromCharCodes(params);
        final semi = s.indexOf(';');
        if (semi > 0) {
          final mod = int.tryParse(s.substring(semi + 1)) ?? 0;
          final flags = mod > 0 ? mod - 1 : 0;
          final direction = switch (last) {
            0x41 => ArrowDirection.up,
            0x42 => ArrowDirection.down,
            0x43 => ArrowDirection.right,
            _ => ArrowDirection.left,
          };
          _pendingEvent = ArrowKey(direction,
              hasCtrl: (flags & 4) != 0, hasAlt: (flags & 2) != 0);
          return;
        }
      }
      if (last == 0x7e) {
        final code = String.fromCharCodes(params);
        switch (code) {
          // Bracketed paste start marker: begin collecting the pasted bytes
          // into [_pasteBuf]. The content is emitted as a single [PasteInput]
          // when the end marker arrives (handled in [feed] under [_inPaste]).
          case '200':
            _inPaste = true;
            _pasteBuf.clear();
            _utf8Pending.clear();
            _pendingEvent = null;
            return;
          // Bracketed paste end marker. Normally [_inPaste] is true and the
          // end marker never reaches here — it's stripped in [feed] before
          // CSI parsing. A stray end marker (no matching start) is consumed
          // harmlessly.
          case '201':
            _inPaste = false;
            _pasteBuf.clear();
            _pendingEvent = null;
            return;
          case '3':
            _pendingEvent = EditingKey(EditingAction.delete);
            return;
          case '1':
          case '7':
            _pendingEvent = EditingKey(EditingAction.home);
            return;
          case '4':
          case '8':
            _pendingEvent = EditingKey(EditingAction.end);
            return;
          // F5–F12 via CSI ~ sequences.
          case '15':
            _pendingEvent = FunctionKey(FunctionKeyCode.f5);
            return;
          case '17':
            _pendingEvent = FunctionKey(FunctionKeyCode.f6);
            return;
          case '18':
            _pendingEvent = FunctionKey(FunctionKeyCode.f7);
            return;
          case '19':
            _pendingEvent = FunctionKey(FunctionKeyCode.f8);
            return;
          case '20':
            _pendingEvent = FunctionKey(FunctionKeyCode.f9);
            return;
          case '21':
            _pendingEvent = FunctionKey(FunctionKeyCode.f10);
            return;
          case '23':
            _pendingEvent = FunctionKey(FunctionKeyCode.f11);
            return;
          case '24':
            _pendingEvent = FunctionKey(FunctionKeyCode.f12);
            return;
          // Page Up / Page Down via CSI ~ sequences.
          case '5':
            _pendingEvent = ArrowKey(ArrowDirection.pageUp);
            return;
          case '6':
            _pendingEvent = ArrowKey(ArrowDirection.pageDown);
            return;
        }
      }
    } else if (introducer == 0x4f) {
      switch (last) {
        case 0x48:
          _pendingEvent = EditingKey(EditingAction.home);
          return;
        case 0x46:
          _pendingEvent = EditingKey(EditingAction.end);
          return;
        // F1–F4 via SS3 + P/Q/R/S.
        case 0x50:
          _pendingEvent = FunctionKey(FunctionKeyCode.f1);
          return;
        case 0x51:
          _pendingEvent = FunctionKey(FunctionKeyCode.f2);
          return;
        case 0x52:
          _pendingEvent = FunctionKey(FunctionKeyCode.f3);
          return;
        case 0x53:
          _pendingEvent = FunctionKey(FunctionKeyCode.f4);
          return;
      }
    }
  }
}
