/// tin-q4vz probe: what does ncplane_resize(0,0,0,0,0,0,h,w) do to a child
/// plane's absolute origin? Run in a tmux pane (needs a tty).
library;

import 'package:dart_notcurses/dart_notcurses.dart' as nc;

void main() {
  final n = nc.NotCurses(nc.CursesOptions(
    loglevel: nc.LogLevel.silent,
    flags: nc.OptionFlags.suppressBanners,
  ));
  final std = n.stdplane();
  final child = std.create(nc.PlaneOptions(
      y: 1, x: 1, rows: 38, cols: 76, name: 'probe'))!;
  print('before resize: absYX=${child.absYX()} dims=${child.dimy()}x${child.dimx()}');
  child.resize(0, 0, 0, 0, 0, 0, 38, 118);
  print('after  resize: absYX=${child.absYX()} dims=${child.dimy()}x${child.dimx()}');
  child.resize(0, 0, 0, 0, 0, 0, 37, 118);
  print('after  resize2: absYX=${child.absYX()} dims=${child.dimy()}x${child.dimx()}');
  child.moveYX(1, 1);
  print('after  moveYX(1,1): absYX=${child.absYX()}');
  n.stop();
}
