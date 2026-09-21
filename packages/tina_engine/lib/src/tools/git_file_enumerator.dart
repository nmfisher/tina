import 'package:file_tree/file_tree.dart' as tree;
import 'process_runner.dart';

export 'package:file_tree/file_tree.dart'
    show GitFileListing, GitListingStatus, FileEnumerationException;

/// Compatibility adapter: processes still use the engine's tracked runner.
class GitFileEnumerator extends tree.GitFileEnumerator {
  static const arguments = tree.GitFileEnumerator.arguments;
  GitFileEnumerator({
    required ProcessRunner processes,
    super.maxFiles,
    super.maxOutputBytes,
    super.maxPathBytes,
    super.timeout,
    super.exitTimeout,
  }) : super(
            start: (root, args) =>
                processes.start('git', args, workingDirectory: root));
}
