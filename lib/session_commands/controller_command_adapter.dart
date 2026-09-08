import 'dart:async';
import 'dart:io';

import 'package:tina_engine/tina_engine.dart';

import 'package:tina_app/tina_app.dart';

import '../session_controller.dart';

class ControllerCommandAdapter implements CommandContext {
  final SessionController controller;
  ControllerCommandAdapter(this.controller);
  @override
  Conversation get active => controller.active;
  @override
  SessionManager get sessionManager => controller.sessionManager;
  @override
  SessionStore? get sessionStore => controller.sessionStore;
  @override
  int get autoCompactThreshold => controller.autoCompactThreshold;
  @override
  set autoCompactThreshold(int value) =>
      controller.autoCompactThreshold = value;
  @override
  int get autoCompactPreserveRecent => controller.autoCompactPreserveRecent;
  @override
  Map<String, FutureOr<void> Function()> get commandHooks =>
      controller.commandHooks;
  @override
  void Function()? get onSessionsChanged => controller.onSessionsChanged;
  @override
  Future<void> Function()? get openSettings => controller.openSettings;
  @override
  Future<void> Function()? get openPrompts => controller.openPrompts;
  @override
  Future<void> Function()? get openSpawn => controller.openSpawn;
  @override
  Future<void> Function()? get openBranch => controller.openBranch;
  @override
  Future<void> Function()? get openModelPicker => controller.openModelPicker;
  @override
  Future<void> Function()? get openSessionPicker =>
      controller.openSessionPicker;
  @override
  void Function(PermissionMode mode)? get setPermissionMode =>
      controller.setPermissionMode;
  @override
  Future<void> Function(String path)? get openImage => controller.openImage;
  @override
  SummaryIndex? get summaryIndex => controller.summaryIndex;
  @override
  Future<bool> Function(String prompt)? get confirm => controller.confirm;
  @override
  Future<void> newSession({String? providerId, String? model}) =>
      controller.newSession(providerId: providerId, model: model);
  @override
  void switchSession(String id) => controller.switchSession(id);
  @override
  Future<bool> resumeIntoActive(String id) => controller.resumeIntoActive(id);
  @override
  Directory? get workflowsDir => controller.workflowsDir;
  @override
  String? get defaultWorkflow => controller.defaultWorkflow;
  @override
  Future<void> Function(String name)? get openWorkflowViewer =>
      controller.openWorkflowViewer;
  @override
  Future<void> Function(int index)? get openToolOutput =>
      controller.openToolOutput;
  @override
  SpendLedger? get spendLedger => controller.spendLedger;
  @override
  Future<void> Function(
    Conversation conv,
    List<String>? dirs, {
    bool repartition,
  })?
  get runBackgroundIndex => controller.runBackgroundIndex;
  @override
  Future<void> Function(Conversation conv)? get runBackgroundEnvironment =>
      controller.runBackgroundEnvironment;
  @override
  Future<void> Function({String? name, bool isNew})? get openWorkflowEditor =>
      controller.openWorkflowEditor;
  @override
  Future<void> Function()? get detachTmux => controller.detachTmux;
}
