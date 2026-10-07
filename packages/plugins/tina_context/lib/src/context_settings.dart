import 'package:tina_settings/tina_settings.dart';

const defaultContextBudgetTokens = 32000;
const defaultContextResponseReserveTokens = 2048;

final contextBudgetSetting = SettingDefinition<int>(
    id: 'tina/context/budget_tokens',
    label: 'Working context budget',
    description:
        'Total working-context token budget, including reserved response space. Usage reminders guide file edits; overflow recovery is not yet implemented.',
    defaultValue: defaultContextBudgetTokens,
    kind: SettingKind.integer,
    minimum: 1,
    applyAt: ApplyAt.nextRequest);

final contextResponseReserveSetting = SettingDefinition<int>(
    id: 'tina/context/response_reserve_tokens',
    label: 'Context response reserve',
    description:
        'Space reserved within the context budget for the next response; must be smaller than the budget. Does not change the provider output limit.',
    defaultValue: defaultContextResponseReserveTokens,
    kind: SettingKind.integer,
    minimum: 0,
    applyAt: ApplyAt.nextRequest);
