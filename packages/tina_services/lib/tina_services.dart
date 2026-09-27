/// tina_services — the shared contracts between plugins and the front
/// end: one locator ([Services]), one terminal seam ([Terminal]), and the
/// command registry ([Commands]) a front end reads to present slash
/// commands its own way.
library;

export 'src/commands.dart';
export 'src/services.dart';
export 'src/terminal.dart';
