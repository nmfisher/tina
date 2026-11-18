import 'package:tina_host/tina_host.dart';

const modelOption = CliOption('model',
    description:
        'Override the model for this run; resume otherwise restores its saved model.',
    valueName: 'PROVIDER/MODEL');
const profileOption = CliOption('profile',
    description:
        'Run under this model profile for this launch (default: the config\'s profile key).',
    valueName: 'NAME');
const modelsOption = CliOption('models',
    description: 'List available models without starting a session.',
    value: CliValue.optional,
    valueName: 'PROVIDER');
const providersCli = PluginCli(options: [modelOption, modelsOption, profileOption]);
