import 'package:tina_host/tina_host.dart';

const noSandboxOption = CliOption('no-sandbox',
    description:
        'Disable OS filesystem and network confinement for this run. Approval checks and filtered child environments still apply.',
    value: CliValue.none);
const toolsCli = PluginCli(options: [noSandboxOption]);
