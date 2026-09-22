import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

// The choice table is the one place that says what an approval row offers, what
// each key means, and how long the answer lasts. These pin all three flavours.

void main() {
  PermissionPrompt bashPrompt() =>
      PermissionPrompt('bash', const {'command': 'dart test'});

  PermissionPrompt sandboxPrompt() => PermissionPrompt(
        'bash',
        const {'command': 'dart test'},
        sandboxAccess:
            SandboxAccessRequest(['/sdk/cache'], 'launcher metadata'),
      );

  PermissionPrompt outsidePrompt() => PermissionPrompt(
        'write',
        const {'filePath': '/p/a.dart'},
        outsideSandbox: true,
      );

  group('an ordinary prompt offers decisions and regex review', () {
    test('keys, meanings and scopes', () {
      final choices = bashPrompt().choices;
      expect([for (final c in choices) c.key], ['y', 'n', 'a', 'd', 'r']);
      expect([
        for (final c in choices) c.label
      ], [
        'allow once',
        'deny once',
        'allow always',
        'deny always',
        'rewrite to safe regular expression'
      ]);

      final byKey = {for (final c in choices) c.key: c};
      expect(byKey['y']!.decision, PermissionDecision.allow);
      expect(byKey['y']!.remember, isFalse);
      expect(byKey['n']!.decision, PermissionDecision.deny);
      expect(byKey['n']!.remember, isFalse);
      expect(byKey['a']!.decision, PermissionDecision.allow);
      expect(byKey['a']!.remember, isTrue);
      expect(byKey['d']!.decision, PermissionDecision.deny);
      expect(byKey['d']!.remember, isTrue);
      for (final key in ['y', 'n', 'a', 'd']) {
        expect(
            byKey[key]!.scope,
            key == 'a' || key == 'd'
                ? GrantScope.conversation
                : GrantScope.call,
            reason: 'only the remembering answers outlive the call');
      }
    });

    test('the response carries the decision, the rule and the scope', () {
      final always = bashPrompt().choiceForKey('a')!.response;
      expect(always.decision, PermissionDecision.allow);
      expect(always.remember, isTrue);
      expect(always.scope, GrantScope.conversation);

      final denyOnce = bashPrompt().choiceForKey('N')!.response;
      expect(denyOnce.decision, PermissionDecision.deny,
          reason: 'keys answer case-insensitively');
      expect(denyOnce.remember, isFalse);
      expect(denyOnce.scope, GrantScope.call);
    });

    test('the note names the rule and the scope a/d will remember', () {
      final note = bashPrompt().alwaysScopeNote;
      expect(note, contains('[a]/[d]'));
      expect(note, contains('"dart test"'));
      expect(note, contains('this conversation, until tina exits'));
    });
  });

  group('a sandbox-access prompt denies on the key it advertises', () {
    test('offers once, directories, deny — and no deny-always', () {
      final choices = sandboxPrompt().choices;
      expect([for (final c in choices) c.key], ['y', 'a', 'n']);
      expect([for (final c in choices) c.label],
          ['allow once', 'session directories', 'deny']);
      expect(sandboxPrompt().choiceForKey('d'), isNull,
          reason:
              'the row used to advertise `[d] deny` while d did nothing; the '
              'table is what the row and the keys both read now');
      expect(sandboxPrompt().choiceForKey('a')!.scope,
          GrantScope.sessionDirectories);
      expect(sandboxPrompt().choiceForKey('n')!.response.remember, isFalse,
          reason: 'denying the request must not remember anything');
    });

    test('its own description already states the scope, so no note', () {
      expect(sandboxPrompt().alwaysScopeNote, isEmpty);
    });
  });

  group('an outside-sandbox prompt', () {
    test('offers run-once, session and deny — never deny-always', () {
      final choices = outsidePrompt().choices;
      expect([for (final c in choices) c.key], ['y', 'a', 'd']);
      expect(outsidePrompt().choiceForKey('n'), isNull);
      final deny = outsidePrompt().choiceForKey('d')!.response;
      expect(deny.decision, PermissionDecision.deny);
      expect(deny.remember, isFalse,
          reason: 'ordinary always-rules must not authorize this escalation');
      expect(deny.scope, GrantScope.call);
      expect(
          outsidePrompt().choiceForKey('a')!.scope, GrantScope.sessionOutside);
    });

    test('its own description already states the scope, so no note', () {
      expect(outsidePrompt().alwaysScopeNote, isEmpty);
    });
  });

  group('the outside-sandbox description states what it adds', () {
    PermissionPrompt outside({bool networkIsolated = false}) =>
        PermissionPrompt(
          'bash',
          const {'command': 'ssh host'},
          outsideSandbox: true,
          sandboxNetworkIsolated: networkIsolated,
          retryExplanation: 'Read-only file system while writing ~/.ssh.',
        );

    test('it names write confinement, not "filesystem and network access"', () {
      final text = outside().accessDescription;
      expect(text, contains('confines what this command can write'));
      expect(text, contains('anywhere your account can'));
      expect(text, isNot(contains('filesystem and network access')),
          reason: 'the sandboxed command could already read and (by default) '
              'reach the network; only writes were confined');
    });

    test('it mentions the network only when the sandbox was blocking it', () {
      expect(outside().accessDescription, isNot(contains('network')));
      expect(outside(networkIsolated: true).accessDescription,
          contains('blocking its network access'));
    });

    test('it still carries the failure explanation and the once/session choice',
        () {
      final text = outside().accessDescription;
      expect(text, contains('Read-only file system'));
      expect(text, contains('nothing is saved to disk'));
      expect(text, contains('this retry only'));
    });
  });

  group('the row is built from the choices', () {
    test('every offered key and label appears', () {
      for (final prompt in [bashPrompt(), sandboxPrompt(), outsidePrompt()]) {
        final row = prompt.approvalOptionsText;
        for (final choice in prompt.choices) {
          expect(row, contains('[${choice.key}]'));
          expect(row, contains(choice.label));
        }
        expect(prompt.approvalRow, contains(row));
      }
    });

    test('rewrite requires review and cannot approve directly', () {
      final rewrite = bashPrompt().choiceForKey('r')!;
      expect(rewrite.action, ApprovalAction.rewriteRegex);
      expect(() => rewrite.response, throwsStateError);
      expect(sandboxPrompt().choiceForKey('r'), isNull);
      expect(outsidePrompt().choiceForKey('r'), isNull);
    });
  });
}
