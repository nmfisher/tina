import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:classification/category_store.dart';
import 'package:classification/utterance.dart';
import 'package:test/test.dart';
import 'adaptive_test.dart' show category;

void main() {
  late Directory directory;
  late String path;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('category-store-');
    path = '${directory.path}/classification/categories.json';
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'seeds without a write and restores definitions and counts across instances',
    () async {
      final first = FileInputCategoryStore(path);
      expect((await first.read()).first.categories, hasLength(2));
      expect(File(path).existsSync(), false);
      await first.learn('intent', category('greeting'));
      await first.record('intent', ['greeting', 'greeting', 'other']);
      final restored = (await FileInputCategoryStore(path).read()).first;
      expect(restored.categories, hasLength(3));
      expect(restored.category('greeting')!.selections, 1);
      expect(
        restored.category('greeting')!.question,
        'Is the input about greeting?',
      );
      expect(restored.otherSelections, 1);
      expect(
        directory
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => f.path),
        everyElement(isNot(endsWith('.tmp'))),
      );
    },
  );

  test(
    'concurrent sessions do not lose counts or duplicate learned labels',
    () async {
      final stores = [for (var i = 0; i < 8; i++) FileInputCategoryStore(path)];
      final learned = await Future.wait([
        for (var i = 0; i < stores.length; i++)
          stores[i].learn('intent', category('greeting$i', label: 'Greeting')),
      ]);
      expect(learned.map((c) => c!.id).toSet(), hasLength(1));
      final id = learned.first!.id;
      await Future.wait([
        for (var i = 0; i < 80; i++)
          stores[i % stores.length].record('intent', [id]),
      ]);
      final restored = (await stores.first.read()).first;
      expect(restored.categories, hasLength(3));
      expect(restored.category(id)!.selections, 80);
    },
  );

  test(
    'separate processes share the lock and preserve every selection',
    () async {
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:classification/utterance.dart'),
      );
      final fixture = File.fromUri(
        library!.resolve('../test/fixtures/category_writer.dart'),
      );
      // Direct Dart execution avoids package/native build hooks in the workers.
      final workers = await Future.wait([
        for (var i = 0; i < 3; i++)
          Process.run(Platform.resolvedExecutable, [
            '--packages=${Platform.packageConfig}',
            fixture.path,
            path,
            '25',
          ]),
      ]);
      for (final result in workers) {
        expect(result.exitCode, 0, reason: result.stderr.toString());
      }
      final restored = (await FileInputCategoryStore(path).read()).first;
      expect(restored.categories, hasLength(3));
      expect(restored.category('greeting')!.selections, 75);
      expect(restored.category('projectQuestion')!.selections, 75);
      expect(restored.otherSelections, 75);
    },
  );

  test(
    'a full catalog does not overwrite a category or admit the 255th',
    () async {
      final file = File(path)..parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'schema': 1,
          'questions': [
            CategoryQuestion(
              id: 'intent',
              question: 'Classify.',
              categories: [for (var i = 0; i < 254; i++) category('c$i')],
            ).toJson(),
            initialCategoryQuestions().last.toJson(),
          ],
        }),
      );
      final before = file.readAsStringSync();
      final store = FileInputCategoryStore(path);
      expect(await store.learn('intent', category('newCategory')), isNull);
      expect(file.readAsStringSync(), before);
      await expectLater(
        store.learn('intent', category('c0', label: 'different')),
        throwsFormatException,
      );
      expect(file.readAsStringSync(), before);
      await store.record('intent', ['other']);
      expect((await store.read()).first.otherSelections, 1);
    },
  );

  test(
    'invalid catalogs are reported and preserved, not silently reset',
    () async {
      final file = File(path)..parent.createSync(recursive: true);
      file.writeAsStringSync('{"schema":2,"questions":[]}');
      final store = FileInputCategoryStore(path);
      await expectLater(
        store.record('intent', ['projectQuestion']),
        throwsFormatException,
      );
      expect(file.readAsStringSync(), '{"schema":2,"questions":[]}');
      // Failure releases the mutex so a later repair can be read normally.
      file.deleteSync();
      expect((await store.read()).first.categories, hasLength(2));
    },
  );

  test('definitions reject reserved IDs and invalid persisted counters', () {
    expect(() => category('other'), throwsFormatException);
    expect(() => category('../bad'), throwsFormatException);
    expect(
      () => InputCategory(
        id: 'valid',
        label: 'label',
        description: 'desc',
        question: 'question?',
        selections: -1,
      ),
      throwsFormatException,
    );
    expect(
      () => CategoryQuestion(
        id: 'intent',
        question: 'Classify.',
        categories: [
          category('a', label: 'greeting'),
          category('b', label: ' Greeting '),
        ],
      ),
      throwsFormatException,
    );
  });
}
