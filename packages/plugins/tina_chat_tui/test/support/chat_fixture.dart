import 'package:test/test.dart';
import 'package:tina_chat/tina_chat.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';

final chatRuntimes = Expando<ChatPlugin>();
ChatView testChat(
    {required String model,
    int tokenCap = 0,
    int Function()? currentTokenCap,
    int Function()? sessionTokens,
    int Function()? sessionEstimatedTokens,
    bool showSessionId = true,
    bool Function()? terminalAlertsEnabled,
    DateTime Function()? now}) {
  final plugin = ChatPlugin(
      model: model,
      tokenCap: tokenCap,
      currentTokenCap: currentTokenCap,
      sessionTokens: sessionTokens,
      sessionEstimatedTokens: sessionEstimatedTokens,
      showSessionId: showSessionId,
      terminalAlertsEnabled: terminalAlertsEnabled);
  addTearDown(plugin.closeSession);
  final view = ChatView(plugin.observation, now: now);
  chatRuntimes[view] = plugin;
  return view;
}
