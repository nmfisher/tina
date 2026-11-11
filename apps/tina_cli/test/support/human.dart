import 'package:tina_approvals/tina_approvals.dart';

class TestHuman implements ApprovalRequester {
  TestHuman({this.allow = true});
  bool allow;
  int calls = 0;
  @override
  Future<ApprovalDecision> request({
    required String operation,
    required String target,
    required String reason,
    ApprovalKind kind = ApprovalKind.permission,
    Future<void>? whenCancelled,
    Map<String, Object?> details = const {},
    void Function(String)? onCommandPattern,
    void Function(List<DirectoryAccessGrant>)? onDirectoryGrants,
  }) async {
    calls++;
    return allow ? ApprovalDecision.allow : ApprovalDecision.deny;
  }
}
