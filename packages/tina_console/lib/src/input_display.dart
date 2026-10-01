/// Project real input onto a single terminal row. The source text is retained
/// for submission; pasted terminal controls must never move the screen cursor.
String inputDisplayText(String text) => text
    .replaceAll(RegExp(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\|$)'), '')
    .replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*(?:[@-~]|$)'), '')
    .replaceAll(RegExp(r'\x1b.'), '')
    .replaceAll(RegExp(r'[\r\n\t]'), ' ')
    .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), '');
