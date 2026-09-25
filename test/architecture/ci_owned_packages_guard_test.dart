import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Guard: every package listed in `ownedPackages`
/// (tool/architecture/policy.json) must have a CI job in
/// .github/workflows/ci.yml.
///
/// The pub-get list in ci.yml is generated from the policy, but the
/// per-package JOBS are hand-written on purpose: attractor and fuzzy_ranker
/// skip the submodule and the native linker steps so that the absence of
/// native terminal dependencies stays observable. So a package can join the
/// policy and reach the pub-get loop while its tests never run anywhere —
/// a silent failure. This test is the loud one.
///
/// A job "covers" a package when one of its steps runs with
/// `working-directory: packages/<name>`. The root package `tina` is covered
/// by the job that works at the repository root (`working-directory: .`).
/// Parsing the YAML (not scraping text) keeps comments and job names from
/// counting as coverage.
void main() {
  test('every owned package in the policy has a CI job', () async {
    // Other suites change cwd; package resolution is independent of that.
    // Anchor inside lib/ (pubspec.yaml is outside the package root and does
    // not resolve), then walk up: <root>/lib/config/x.dart -> repo root.
    final uri = await Isolate.resolvePackageUri(
      Uri.parse('package:tina/config/user_config.dart'),
    );
    final root = path.dirname(path.dirname(path.dirname(uri!.toFilePath())));

    final policyFile = File(path.join(root, 'tool/architecture/policy.json'));
    final policy =
        jsonDecode(policyFile.readAsStringSync()) as Map<String, dynamic>;
    final owned = (policy['ownedPackages'] as List).cast<String>();

    // If the policy loses its list (or the key is renamed), say so instead of
    // letting an empty list pass the test vacuously.
    expect(
      owned,
      isNotEmpty,
      reason:
          'tool/architecture/policy.json has no ownedPackages entries; '
          'the guard has nothing to check and would pass for the wrong reason.',
    );

    final ciFile = File(path.join(root, '.github/workflows/ci.yml'));
    final ci = loadYaml(ciFile.readAsStringSync()) as YamlMap;
    final jobs = ci['jobs'] as YamlMap;

    // package name -> job keys whose steps run in that package's directory.
    final coverage = <String, Set<String>>{};
    for (final jobKey in jobs.keys) {
      final job = jobs[jobKey] as YamlMap;
      final steps = job['steps'];
      if (steps is! YamlList) continue;
      for (final step in steps) {
        if (step is! Map) continue;
        final dir = step['working-directory'];
        if (dir is! String) continue;
        final package = RegExp(r'^packages/([^/]+)$').firstMatch(dir)?.group(1);
        if (package != null) {
          coverage.putIfAbsent(package, () => <String>{}).add(jobKey as String);
        } else if (dir == '.') {
          // The repository root job covers the root package `tina`.
          coverage.putIfAbsent('tina', () => <String>{}).add(jobKey as String);
        }
      }
    }

    final missing = owned.where((name) {
      final jobsFor = coverage[name];
      return jobsFor == null || jobsFor.isEmpty;
    }).toList();

    expect(
      missing,
      isEmpty,
      reason:
          'Owned packages with no CI job: $missing\n'
          'Their tests would never run on CI, and nothing else would notice. '
          'Add a job for each in .github/workflows/ci.yml — copy the shape of '
          'attractor or fuzzy_ranker for a terminal-free package, engine or '
          'console for one with native dependencies — or remove the package '
          'from ownedPackages in tool/architecture/policy.json. '
          'Coverage seen by this test: $coverage',
    );
  });
}
