// Spike for tin-v6tq: dump what a terminal-reply burst decodes to at the
// Dart pump layer. Runs the same notcurses init tina uses, subscribes to the
// input pump, and writes one line per PumpedInput (id, modifiers, decoded
// text) to a log file — the pane itself is owned by notcurses, so the log is
// the observation surface. Two hazards the shape works around: writes are
// synchronous (an IOSink's async flush interleaved with writeln from the pump
// listener throws "StreamSink is bound to a stream"), and the wait must be
// async — dart:io sleep() blocks the isolate, so no NativeCallable.listener
// notification is ever delivered and the pump looks silent.
//
// Usage (in a tmux pane, after the usual reply injection):
//   dart run tool/reply_decode_spike.dart <out-log> [seconds]
// Then, mid-run: tool/tmux_inject_replies.sh <session>
import 'dart:io';

import 'package:dart_notcurses/dart_notcurses.dart' as nc;

String decode(int id, int mods) {
  final b = StringBuffer();
  if (id >= 0x20 && id < 0x7f) {
    b.write('printable=${String.fromCharCode(id)}');
  } else if (id > 0x7f && id < 0x110000) {
    b.write('unicode=${String.fromCharCode(id)} (U+${id.toRadixString(16)})');
  } else {
    b.write('ctrl/synth=0x${id.toRadixString(16)}');
  }
  if (mods != 0) b.write(' mods=$mods');
  return b.toString();
}

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args[0] : '/tmp/reply_spike.log';
  final seconds = args.length > 1 ? int.parse(args[1]) : 25;
  final log = File(path).openSync(mode: FileMode.write);
  void rec(String s) => log.writeStringSync('$s\n');
  final ncv = nc.NotCurses(nc.CursesOptions(
    loglevel: nc.LogLevel.silent,
    flags: nc.OptionFlags.suppressBanners,
  ));
  if (ncv.notInitialized) {
    stderr.writeln('notcurses init failed');
    exit(1);
  }
  final pump = ncv.startInputPump();
  var n = 0;
  final t0 = DateTime.now();
  pump.events.listen((e) {
    n++;
    final ms = DateTime.now().difference(t0).inMilliseconds;
    rec('$ms\tid=${e.id}\tmods=${e.modifiers}\t${decode(e.id, e.modifiers)}');
  });
  rec('=== spike up, listening (pid=$pid) ===');
  final plane = ncv.stdplane();
  plane.putStrYX(0, 0, 'reply spike running');
  ncv.render();
  await Future<void>.delayed(Duration(seconds: seconds));
  pump.stop();
  rec('=== done: $n events ===');
  log.closeSync();
  ncv.stop();
  exit(0);
}
