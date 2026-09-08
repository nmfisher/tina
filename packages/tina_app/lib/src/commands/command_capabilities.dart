import 'dart:async';
import 'dart:io';

import 'package:tina_engine/tina_engine.dart';

import 'package:tina_app/src/session/conversation.dart';
import 'package:tina_app/src/session/session_manager.dart';
import 'package:tina_app/src/summaries/summary_index.dart';

abstract interface class UsageCapabilities {
  Conversation get active;
  SpendLedger? get spendLedger;
}

abstract interface class UpdateCapabilities {
  Conversation get active;
  Future<bool> Function(String prompt)? get confirm;
}

abstract interface class FrontendCapabilities {
  Conversation get active;
  Future<void> Function()? get openSettings;
  Future<void> Function()? get openPrompts;
  Future<void> Function()? get openSpawn;
  Future<void> Function()? get openBranch;
  Future<void> Function()? get openModelPicker;
  Future<void> Function(String path)? get openImage;
  Future<void> Function(int index)? get openToolOutput;
  Future<void> Function()? get detachTmux;
}

abstract interface class SessionsCapabilities {
  Conversation get active;
  SessionManager get sessionManager;
  SessionStore? get sessionStore;
  void Function()? get onSessionsChanged;
  Future<void> Function()? get openSessionPicker;
  Future<void> newSession({String? providerId, String? model});
  void switchSession(String id);
  Future<bool> resumeIntoActive(String id);
}

abstract interface class HistoryCapabilities {
  Conversation get active;
  int get autoCompactThreshold;
  set autoCompactThreshold(int value);
  int get autoCompactPreserveRecent;
}

abstract interface class PermissionsCapabilities {
  Conversation get active;
  void Function(PermissionMode mode)? get setPermissionMode;
}

abstract interface class IndexCapabilities {
  Conversation get active;
  SummaryIndex? get summaryIndex;
  Future<bool> Function(String prompt)? get confirm;
  SpendLedger? get spendLedger;
  Future<void> Function(
    Conversation conv,
    List<String>? dirs, {
    bool repartition,
  })?
  get runBackgroundIndex;
  Future<void> Function(Conversation conv)? get runBackgroundEnvironment;
}

abstract interface class DispatchCapabilities {
  Conversation get active;
  Map<String, FutureOr<void> Function()> get commandHooks;
}

abstract interface class WorkflowCapabilities {
  Conversation get active;
  Directory? get workflowsDir;
  String? get defaultWorkflow;
  Future<void> Function(String name)? get openWorkflowViewer;
  Future<void> Function({String? name, bool isNew})? get openWorkflowEditor;
}
