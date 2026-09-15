// Build hook: compiles the tina PTY shim into one dylib and declares it as the
// code asset `src/terminal/pty_shim.dart`.
//
// The shim is fully self-contained (libc only): no notcurses, no vendored
// third-party sources. Linux x64, Linux arm64, and macOS arm64 are supported
// from the same portable C; all PTY/termios/ioctl constants come from
// platform headers, so there are no per-OS constant tables here.
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final codeConfig = input.config.code;
    final targetOS = codeConfig.targetOS;
    if (targetOS != OS.linux && targetOS != OS.macOS) {
      // Windows/others: the package still builds and its non-terminal
      // features stay usable; the PTY backend simply has no native asset.
      // (PtyRunner.isSupported reports false there.)
      output.dependencies.add(input.packageRoot.resolve('hook/build.dart'));
      return;
    }

    final src = input.packageRoot.resolve('native/src/pty_shim.c');
    output.dependencies.add(src);
    output.dependencies.add(input.packageRoot.resolve('native/src/pty_shim.h'));

    final builder = CBuilder.library(
      name: 'tina_pty_shim',
      assetName: 'src/terminal/pty_shim.dart',
      sources: [src.toFilePath()],
      includes: [input.packageRoot.resolve('native/src').toFilePath()],
      flags: ['-D_GNU_SOURCE', '-O2'],
      language: Language.c,
    );
    await builder.run(input: input, output: output);
  });
}
