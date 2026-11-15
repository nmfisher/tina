import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'command_approval_store.dart' show resolveHostExecutable;
import 'process_runner.dart';
import 'sandbox_home.dart';

/// An exact invocation, including interpreter arguments or the entire shell
/// body. This never infers permission for other scripts or command prefixes.
final class CommandExactPlan {
  CommandExactPlan._(this.executable, this.arguments, this.identity);
  final String executable, identity;
  final List<String> arguments;

  static CommandExactPlan? parse(ProcessRequest request,
      {required String workspace,
      String? searchPath,
      String? sandboxHomeRoot}) {
    try {
      final executable = resolveHostExecutable(request,
          workspace: workspace, searchPath: searchPath);
      final environment = request.environment;
      final keys = environment?.keys.toList()?..sort();
      final identity = sha256
          .convert(utf8.encode(jsonEncode([
            executable,
            request.arguments,
            canonicalSandboxPath(request.workingDirectory ?? workspace),
            if (keys == null)
              null
            else
              {
                for (final key in keys)
                  key: sandboxHomeRoot != null &&
                          {'HOME', 'TMPDIR'}.contains(key) &&
                          sandboxPathUnder(environment![key]!, sandboxHomeRoot)
                      ? '$sandboxHomeRoot/<private-$key>'
                      : environment![key],
              },
            request.stdin,
          ])))
          .toString();
      return CommandExactPlan._(
          executable, List.unmodifiable(request.arguments), identity);
    } on FileSystemException {
      return null;
    }
  }
}
