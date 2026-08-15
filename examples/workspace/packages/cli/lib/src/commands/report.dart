/// `track report` — print the summary statistics.
library;

import 'package:core/core.dart';
import 'package:reports/reports.dart';
import 'package:store/store.dart';

Future<int> reportCommand(JsonFileStore store, List<String> args) async {
  final summary = await SummaryReporter(store).summarize();
  print('total     ${summary.total}');
  print('open      ${summary.open}');
  print('completed ${summary.completed}');
  return 0;
}
