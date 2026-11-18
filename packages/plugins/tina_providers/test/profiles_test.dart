// The profiles module's resolution helpers: which name is active
// (launch override > session-scope switch > config key) and which value
// a leg resolves to (current leg setting > active profile's leg > the
// caller's leg-specific fallback).
//
// Run: dart test
library;

import 'package:test/test.dart';
import 'package:tina_providers/tina_providers.dart';
import 'package:tina_settings/tina_settings.dart';

void main() {
  const work = ModelProfile(
    name: 'work',
    main: ModelLeg(provider: 'provA', model: 'qwen-3'),
    subagent: ModelLeg(provider: 'provB', model: 'glm-5.3'),
    approver: ModelLeg(model: 'haiku-3'),
  );

  test('effectiveProfileName: launch override wins without being stored',
      () {
    final settings = ScopedSettings(
        catalog: SettingCatalog(), backend: MemorySettingsBackend());
    expect(
        effectiveProfileName(
            launchProfile: 'budget',
            settings: settings,
            configProfile: 'work'),
        'budget');
    expect(settings.layer(SettingScope.session), isEmpty,
        reason: 'a launch override is never persisted');
  });

  test('effectiveProfileName: a session switch outranks the config key',
      () {
    final backend = MemorySettingsBackend();
    final settings = ScopedSettings(
        catalog: SettingCatalog()..register(activeProfileSetting),
        backend: backend);
    settings.set(activeProfileSetting, 'budget', SettingScope.session);
    expect(
        effectiveProfileName(
            settings: settings, configProfile: 'work'),
        'budget');
  });

  test('effectiveProfileName: falls back to the config key', () {
    expect(effectiveProfileName(configProfile: 'work'), 'work');
    expect(effectiveProfileName(configProfile: 'work'),
        isNot('default'));
  });

  test('effectiveProfileLeg: the current leg setting outranks the profile',
      () {
    final settings = ScopedSettings(
        catalog: SettingCatalog()..register(profileSubagentModelSetting),
        backend: MemorySettingsBackend());
    settings.set(profileSubagentModelSetting, 'provA/qwen-3',
        SettingScope.session);
    expect(
        effectiveProfileLeg(profileSubagentModelSetting, settings, work,
            ProfileLeg.subagent,
            sessionProvider: 'provA'),
        'provA/qwen-3',
        reason: 'the legs are the truth; profiles are presets');
  });

  test('effectiveProfileLeg: the profile leg supplies provider inheritance',
      () {
    expect(
        effectiveProfileLeg(
            profileSubagentModelSetting, null, work, ProfileLeg.subagent,
            sessionProvider: 'provA'),
        'provB/glm-5.3');
    expect(
        effectiveProfileLeg(
            profileApproverModelSetting, null, work, ProfileLeg.approver,
            sessionProvider: 'provA'),
        'provA/haiku-3',
        reason: 'a leg without a provider inherits the session provider');
  });

  test('effectiveProfileLeg: null when neither setting nor profile set it',
      () {
    const budget = ModelProfile(name: 'budget', main: null);
    expect(
        effectiveProfileLeg(
            profileSubagentModelSetting, null, budget, ProfileLeg.subagent),
        isNull,
        reason: 'subagent falls back to the parent\'s current model');
    expect(
        effectiveProfileLeg(
            profileApproverModelSetting, null, budget, ProfileLeg.approver),
        isNull,
        reason: 'approver falls back to the legacy classifier chain');
  });

  test('effectiveProfileLeg: a whitespace setting value reads as unset', () {
    final settings = ScopedSettings(
        catalog: SettingCatalog()..register(profileSubagentModelSetting),
        backend: MemorySettingsBackend());
    settings.set(profileSubagentModelSetting, '  ', SettingScope.session);
    expect(
        effectiveProfileLeg(profileSubagentModelSetting, settings, work,
            ProfileLeg.subagent,
            sessionProvider: 'provA'),
        'provB/glm-5.3');
  });
}
