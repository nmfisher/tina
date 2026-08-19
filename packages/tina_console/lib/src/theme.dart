/// Terminal color/theme definitions for the tina console UI.
///
/// Every visual element that currently hardcodes an ANSI SGR string is
/// represented here as a named field. The theme is carried by [Screen] and
/// read by regions/widgets, so callers can stop embedding escape codes in the
/// source. The backend contract stays unchanged: [TerminalBackend.colorize]
/// still takes a raw SGR parameter string, and the theme simply supplies
/// those strings.
class Theme {
  final ChatTheme chat;
  final BorderTheme border;
  final MenuTheme menu;
  final CompletionTheme completion;
  final DialogTheme dialog;
  final InfoPanelTheme infoPanel;
  final TextPanelTheme textPanel;
  final SpinnerTheme spinner;
  final LineEditorTheme lineEditor;
  final HostMessageTheme hostMessage;

  const Theme({
    this.chat = const ChatTheme(),
    this.border = const BorderTheme(),
    this.menu = const MenuTheme(),
    this.completion = const CompletionTheme(),
    this.dialog = const DialogTheme(),
    this.infoPanel = const InfoPanelTheme(),
    this.textPanel = const TextPanelTheme(),
    this.spinner = const SpinnerTheme(),
    this.lineEditor = const LineEditorTheme(),
    this.hostMessage = const HostMessageTheme(),
  });

  const Theme.defaults() : this();

  /// Tuned for light-background terminals (white/light default background).
  /// Bright-on-dark bars, standard ANSI colours, black agent text.
  const Theme.light()
      : chat = const ChatTheme.light(),
        border = const BorderTheme.light(),
        menu = const MenuTheme(),
        completion = const CompletionTheme(),
        dialog = const DialogTheme(),
        infoPanel = const InfoPanelTheme(),
        textPanel = const TextPanelTheme.light(),
        spinner = const SpinnerTheme(),
        lineEditor = const LineEditorTheme(),
        hostMessage = const HostMessageTheme.light();

  /// Tuned for dark-background terminals (black/dark default background).
  /// Dark-on-bright bars, bright ANSI colour variants, bright agent text.
  const Theme.dark()
      : chat = const ChatTheme.dark(),
        border = const BorderTheme.dark(),
        menu = const MenuTheme(),
        completion = const CompletionTheme(),
        dialog = const DialogTheme(),
        infoPanel = const InfoPanelTheme(),
        textPanel = const TextPanelTheme.dark(),
        spinner = const SpinnerTheme(),
        lineEditor = const LineEditorTheme(),
        hostMessage = const HostMessageTheme.dark();

  factory Theme.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const Theme.defaults();
    final cast = m.cast<String, dynamic>();
    return Theme(
      chat: ChatTheme.fromMap(_cast(cast['chat'])),
      border: BorderTheme.fromMap(_cast(cast['border'])),
      menu: MenuTheme.fromMap(_cast(cast['menu'])),
      completion: CompletionTheme.fromMap(_cast(cast['completion'])),
      dialog: DialogTheme.fromMap(_cast(cast['dialog'])),
      infoPanel: InfoPanelTheme.fromMap(_cast(cast['info_panel'])),
      textPanel: TextPanelTheme.fromMap(_cast(cast['text_panel'])),
      spinner: SpinnerTheme.fromMap(_cast(cast['spinner'])),
      lineEditor: LineEditorTheme.fromMap(_cast(cast['line_editor'])),
      hostMessage: HostMessageTheme.fromMap(_cast(cast['host_message'])),
    );
  }

  Map<String, dynamic> toMap() => {
        if (!chat.isDefault) 'chat': chat.toMap(),
        if (!border.isDefault) 'border': border.toMap(),
        if (!menu.isDefault) 'menu': menu.toMap(),
        if (!completion.isDefault) 'completion': completion.toMap(),
        if (!dialog.isDefault) 'dialog': dialog.toMap(),
        if (!infoPanel.isDefault) 'info_panel': infoPanel.toMap(),
        if (!textPanel.isDefault) 'text_panel': textPanel.toMap(),
        if (!spinner.isDefault) 'spinner': spinner.toMap(),
        if (!lineEditor.isDefault) 'line_editor': lineEditor.toMap(),
        if (!hostMessage.isDefault) 'host_message': hostMessage.toMap(),
      };
}

class ChatTheme {
  final String userBar;

  /// Style for user messages: a bullet line slightly lighter than agent
  /// prose (bold on top of the agent's code), replacing the old reverse-video
  /// bar.
  final String userText;
  final String agentText;
  final String dim;
  final String cyan;
  final String green;
  final String yellow;
  final String red;

  static const _default = ChatTheme();

  const ChatTheme({
    this.userBar = '7',
    this.userText = '1',
    this.agentText = '39',
    this.dim = '2',
    this.cyan = '36',
    this.green = '32',
    this.yellow = '33',
    this.red = '31',
  });

  /// Light-background variant: black agent text, black bar for user prompts,
  /// standard ANSI colour codes.
  const ChatTheme.light()
      : userBar = '97;40',
        userText = '1;30',
        agentText = '30',
        dim = '2',
        cyan = '36',
        green = '32',
        yellow = '33',
        red = '31';

  /// Dark-background variant: bright agent text, white bar for user prompts,
  /// bright ANSI colour codes for better contrast against the dark background.
  const ChatTheme.dark()
      : userBar = '30;47',
        userText = '1;97',
        agentText = '97',
        dim = '2',
        cyan = '96',
        green = '92',
        yellow = '93',
        red = '91';

  bool get isDefault =>
      userBar == _default.userBar &&
      userText == _default.userText &&
      agentText == _default.agentText &&
      dim == _default.dim &&
      cyan == _default.cyan &&
      green == _default.green &&
      yellow == _default.yellow &&
      red == _default.red;

  factory ChatTheme.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const ChatTheme();
    final cast = m.cast<String, dynamic>();
    return ChatTheme(
      userBar: _sgr(cast['user_bar'], _default.userBar),
      userText: _sgr(cast['user_text'], _default.userText),
      agentText: _sgr(cast['agent_text'], _default.agentText),
      dim: _sgr(cast['dim'], _default.dim),
      cyan: _sgr(cast['cyan'], _default.cyan),
      green: _sgr(cast['green'], _default.green),
      yellow: _sgr(cast['yellow'], _default.yellow),
      red: _sgr(cast['red'], _default.red),
    );
  }

  Map<String, dynamic> toMap() => {
        if (userBar != _default.userBar) 'user_bar': userBar,
        if (userText != _default.userText) 'user_text': userText,
        if (agentText != _default.agentText) 'agent_text': agentText,
        if (dim != _default.dim) 'dim': dim,
        if (cyan != _default.cyan) 'cyan': cyan,
        if (green != _default.green) 'green': green,
        if (yellow != _default.yellow) 'yellow': yellow,
        if (red != _default.red) 'red': red,
      };
}

class BorderTheme {
  final String focus;
  final String selection;
  final BusyBorderTheme busy;

  static const _default = BorderTheme();

  const BorderTheme({
    this.focus = '36',
    this.selection = '33',
    this.busy = const BusyBorderTheme(),
  });

  const BorderTheme.light() : this();

  const BorderTheme.dark()
      : focus = '96',
        selection = '93',
        busy = const BusyBorderTheme(); // default comet colours — visible on both

  bool get isDefault =>
      focus == _default.focus &&
      selection == _default.selection &&
      busy.isDefault;

  factory BorderTheme.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const BorderTheme();
    final cast = m.cast<String, dynamic>();
    return BorderTheme(
      focus: _sgr(cast['focus'], _default.focus),
      selection: _sgr(cast['selection'], _default.selection),
      busy: BusyBorderTheme.fromMap(_cast(cast['busy'])),
    );
  }

  Map<String, dynamic> toMap() => {
        if (focus != _default.focus) 'focus': focus,
        if (selection != _default.selection) 'selection': selection,
        if (!busy.isDefault) 'busy': busy.toMap(),
      };
}

class BusyBorderTheme {
  final String rail;
  final String head;
  final List<int> railRgb;
  final List<int> headRgb;
  final int tailLength;

  static const _default = BusyBorderTheme();

  const BusyBorderTheme({
    this.rail = '38;2;30;110;130',
    this.head = '1;38;2;175;255;255',
    this.railRgb = const [30, 110, 130],
    this.headRgb = const [175, 255, 255],
    this.tailLength = 7,
  });

  bool get isDefault =>
      rail == _default.rail &&
      head == _default.head &&
      _listEq(railRgb, _default.railRgb) &&
      _listEq(headRgb, _default.headRgb) &&
      tailLength == _default.tailLength;

  factory BusyBorderTheme.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const BusyBorderTheme();
    final cast = m.cast<String, dynamic>();
    final rail = _sgr(cast['rail'], _default.rail);
    final head = _sgr(cast['head'], _default.head);
    return BusyBorderTheme(
      rail: rail,
      head: head,
      railRgb: _rgb(cast['rail_rgb'], rail, _default.railRgb),
      headRgb: _rgb(cast['head_rgb'], head, _default.headRgb),
      tailLength: cast['tail_length'] as int? ?? _default.tailLength,
    );
  }

  Map<String, dynamic> toMap() => {
        if (rail != _default.rail) 'rail': rail,
        if (head != _default.head) 'head': head,
        if (!_listEq(railRgb, _default.railRgb)) 'rail_rgb': railRgb,
        if (!_listEq(headRgb, _default.headRgb)) 'head_rgb': headRgb,
        if (tailLength != _default.tailLength) 'tail_length': tailLength,
      };
}

class MenuTheme {
  final String barHighlight;
  final String barDim;
  final String dropdownSelected;
  final String dropdownDisabled;

  static const _default = MenuTheme();

  const MenuTheme({
    this.barHighlight = '7',
    this.barDim = '2',
    this.dropdownSelected = '7',
    this.dropdownDisabled = '2',
  });

  bool get isDefault =>
      barHighlight == _default.barHighlight &&
      barDim == _default.barDim &&
      dropdownSelected == _default.dropdownSelected &&
      dropdownDisabled == _default.dropdownDisabled;

  factory MenuTheme.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const MenuTheme();
    final cast = m.cast<String, dynamic>();
    return MenuTheme(
      barHighlight: _sgr(cast['bar_highlight'], _default.barHighlight),
      barDim: _sgr(cast['bar_dim'], _default.barDim),
      dropdownSelected: _sgr(cast['dropdown_selected'], _default.dropdownSelected),
      dropdownDisabled: _sgr(cast['dropdown_disabled'], _default.dropdownDisabled),
    );
  }

  Map<String, dynamic> toMap() => {
        if (barHighlight != _default.barHighlight) 'bar_highlight': barHighlight,
        if (barDim != _default.barDim) 'bar_dim': barDim,
        if (dropdownSelected != _default.dropdownSelected)
          'dropdown_selected': dropdownSelected,
        if (dropdownDisabled != _default.dropdownDisabled)
          'dropdown_disabled': dropdownDisabled,
      };
}

class CompletionTheme {
  final String dim;
  final String selected;

  static const _default = CompletionTheme();

  const CompletionTheme({
    this.dim = '2',
    this.selected = '7',
  });

  bool get isDefault => dim == _default.dim && selected == _default.selected;

  factory CompletionTheme.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const CompletionTheme();
    final cast = m.cast<String, dynamic>();
    return CompletionTheme(
      dim: _sgr(cast['dim'], _default.dim),
      selected: _sgr(cast['selected'], _default.selected),
    );
  }

  Map<String, dynamic> toMap() => {
        if (dim != _default.dim) 'dim': dim,
        if (selected != _default.selected) 'selected': selected,
      };
}

class DialogTheme {
  final String confirm;

  static const _default = DialogTheme();

  const DialogTheme({this.confirm = '7'});

  bool get isDefault => confirm == _default.confirm;

  factory DialogTheme.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const DialogTheme();
    final cast = m.cast<String, dynamic>();
    return DialogTheme(confirm: _sgr(cast['confirm'], _default.confirm));
  }

  Map<String, dynamic> toMap() => {
        if (confirm != _default.confirm) 'confirm': confirm,
      };
}

class InfoPanelTheme {
  final String dim;

  static const _default = InfoPanelTheme();

  const InfoPanelTheme({this.dim = '2'});

  bool get isDefault => dim == _default.dim;

  factory InfoPanelTheme.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const InfoPanelTheme();
    final cast = m.cast<String, dynamic>();
    return InfoPanelTheme(dim: _sgr(cast['dim'], _default.dim));
  }

  Map<String, dynamic> toMap() => {
        if (dim != _default.dim) 'dim': dim,
      };
}

class TextPanelTheme {
  final String focused;
  final String unfocused;

  static const _default = TextPanelTheme();

  const TextPanelTheme({
    this.focused = '36',
    this.unfocused = '2',
  });

  const TextPanelTheme.light() : this();

  const TextPanelTheme.dark()
      : focused = '96',
        unfocused = '2';

  bool get isDefault =>
      focused == _default.focused && unfocused == _default.unfocused;

  factory TextPanelTheme.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const TextPanelTheme();
    final cast = m.cast<String, dynamic>();
    return TextPanelTheme(
      focused: _sgr(cast['focused'], _default.focused),
      unfocused: _sgr(cast['unfocused'], _default.unfocused),
    );
  }

  Map<String, dynamic> toMap() => {
        if (focused != _default.focused) 'focused': focused,
        if (unfocused != _default.unfocused) 'unfocused': unfocused,
      };
}

class SpinnerTheme {
  final String dim;

  static const _default = SpinnerTheme();

  const SpinnerTheme({this.dim = '2'});

  bool get isDefault => dim == _default.dim;

  factory SpinnerTheme.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const SpinnerTheme();
    final cast = m.cast<String, dynamic>();
    return SpinnerTheme(dim: _sgr(cast['dim'], _default.dim));
  }

  Map<String, dynamic> toMap() => {
        if (dim != _default.dim) 'dim': dim,
      };
}

class LineEditorTheme {
  final String dim;

  static const _default = LineEditorTheme();

  const LineEditorTheme({this.dim = '2'});

  bool get isDefault => dim == _default.dim;

  factory LineEditorTheme.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const LineEditorTheme();
    final cast = m.cast<String, dynamic>();
    return LineEditorTheme(dim: _sgr(cast['dim'], _default.dim));
  }

  Map<String, dynamic> toMap() => {
        if (dim != _default.dim) 'dim': dim,
      };
}

class HostMessageTheme {
  /// No SGR for normal messages; null or empty means "passthrough".
  final String? normal;
  final String dim;
  final String user;
  final String warning;
  final String error;
  final String success;

  static const _default = HostMessageTheme();

  const HostMessageTheme({
    this.normal,
    this.dim = '2',
    this.user = '7',
    this.warning = '33',
    this.error = '31',
    this.success = '32',
  });

  const HostMessageTheme.light()
      : normal = null,
        dim = '2',
        user = '97;40',
        warning = '33',
        error = '31',
        success = '32';

  const HostMessageTheme.dark()
      : normal = null,
        dim = '2',
        user = '30;47',
        warning = '93',
        error = '91',
        success = '92';

  bool get isDefault =>
      (normal == null || normal!.isEmpty) &&
      dim == _default.dim &&
      user == _default.user &&
      warning == _default.warning &&
      error == _default.error &&
      success == _default.success;

  factory HostMessageTheme.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const HostMessageTheme();
    final cast = m.cast<String, dynamic>();
    String? normal;
    final rawNormal = cast['normal'];
    if (rawNormal is String && rawNormal.isNotEmpty) normal = rawNormal;
    return HostMessageTheme(
      normal: normal,
      dim: _sgr(cast['dim'], _default.dim),
      user: _sgr(cast['user'], _default.user),
      warning: _sgr(cast['warning'], _default.warning),
      error: _sgr(cast['error'], _default.error),
      success: _sgr(cast['success'], _default.success),
    );
  }

  Map<String, dynamic> toMap() => {
        if (normal != null && normal!.isNotEmpty) 'normal': normal,
        if (dim != _default.dim) 'dim': dim,
        if (user != _default.user) 'user': user,
        if (warning != _default.warning) 'warning': warning,
        if (error != _default.error) 'error': error,
        if (success != _default.success) 'success': success,
      };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Map<String, dynamic>? _cast(Object? value) {
  if (value is Map) return value.cast<String, dynamic>();
  return null;
}

String _sgr(Object? value, String defaultValue) {
  if (value is String) return value;
  return defaultValue;
}

List<int> _rgb(Object? explicit, String sgr, List<int> defaultValue) {
  final parsed = _parseRgbList(explicit);
  if (parsed != null) return parsed;
  return _parseRgbFromSgr(sgr) ?? defaultValue;
}

List<int>? _parseRgbList(Object? value) {
  if (value is List) {
    final ints = <int>[];
    for (final v in value) {
      if (v is int) {
        ints.add(v);
      } else if (v is String) {
        final n = int.tryParse(v);
        if (n == null) return null;
        ints.add(n);
      } else {
        return null;
      }
    }
    if (ints.length == 3) return ints;
  }
  return null;
}

/// Extracts the first truecolor foreground or background RGB triple found in
/// an SGR string of the form `38;2;r;g;b` or `48;2;r;g;b`.
List<int>? _parseRgbFromSgr(String sgr) {
  final parts = sgr.split(';');
  for (var i = 0; i + 4 < parts.length; i++) {
    if ((parts[i] == '38' || parts[i] == '48') && parts[i + 1] == '2') {
      final r = int.tryParse(parts[i + 2]);
      final g = int.tryParse(parts[i + 3]);
      final b = int.tryParse(parts[i + 4]);
      if (r != null && g != null && b != null) return [r, g, b];
    }
  }
  return null;
}

bool _listEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
