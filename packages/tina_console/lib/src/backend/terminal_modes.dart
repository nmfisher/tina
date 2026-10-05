/// Disable button, drag and motion tracking, then both coordinate encodings
/// used by notcurses. Emit each mode separately for terminal compatibility.
const disableMouseReporting = '\x1b[?1000l\x1b[?1002l\x1b[?1003l'
    '\x1b[?1006l\x1b[?1016l';
