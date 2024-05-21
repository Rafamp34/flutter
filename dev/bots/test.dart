// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Runs the tests for the flutter/flutter repository.
//
//
// By default, test output is filtered and only errors are shown. (If a
// particular test takes longer than _quietTimeout in utils.dart, the output is
// shown then also, in case something has hung.)
//
//  --verbose stops the output cleanup and just outputs everything verbatim.
//
//
// By default, errors are non-fatal; all tests are executed and the output
// ends with a summary of the errors that were detected.
//
// Exit code is 1 if there was an error.
//
//  --abort-on-error causes the script to exit immediately when hitting an error.
//
//
// By default, all tests are run. However, the tests support being split by
// shard and subshard. (Inspect the code to see what shards and subshards are
// supported.)
//
// If the CIRRUS_TASK_NAME environment variable exists, it is used to determine
// the shard and sub-shard, by parsing it in the form shard-subshard-platform,
// ignoring the platform.
//
// For local testing you can just set the SHARD and SUBSHARD environment
// variables. For example, to run all the framework tests you can just set
// SHARD=framework_tests. Some shards support named subshards, like
// SHARD=framework_tests SUBSHARD=widgets. Others support arbitrary numbered
// subsharding, like SHARD=build_tests SUBSHARD=1_2 (where 1_2 means "one of
// two" as in run the first half of the tests).
//
// So for example to run specifically the third subshard of the Web tests you
// would set SHARD=web_tests SUBSHARD=2 (it's zero-based).
//
// By default, where supported, tests within a shard are executed in a random
// order to (eventually) catch inter-test dependencies.
//
//  --test-randomize-ordering-seed=<n> sets the shuffle seed for reproducing runs.
//
//
// All other arguments are treated as arguments to pass to the flutter tool when
// running tests.

import 'dart:convert';
import 'dart:core' as system show print;
import 'dart:core' hide print;
import 'dart:io' as system show exit;
import 'dart:io' hide exit;
import 'dart:math' as math;
import 'package:path/path.dart' as path;
import 'run_command.dart';
import 'suite_runners/run_add_to_app_life_cycle_tests.dart';
import 'suite_runners/run_analyze_tests.dart';
import 'suite_runners/run_android_preview_integration_tool_tests.dart';
import 'suite_runners/run_customer_testing_tests.dart';
import 'suite_runners/run_docs_tests.dart';
import 'suite_runners/run_flutter_packages_tests.dart';
import 'suite_runners/run_framework_coverage_tests.dart';
import 'suite_runners/run_framework_tests.dart';
import 'suite_runners/run_fuchsia_precache.dart';
import 'suite_runners/run_realm_checker_tests.dart';
import 'suite_runners/run_skp_generator_tests.dart';
import 'suite_runners/run_test_harness_tests.dart';
import 'suite_runners/run_verify_binaries_codesigned_tests.dart';
import 'suite_runners/run_web_tests.dart';
import 'utils.dart';

typedef ShardRunner = Future<void> Function();

final Map<String, String> localEngineEnv = <String, String>{};
const String CIRRUS_TASK_NAME = 'CIRRUS_TASK_NAME';

Future<void> main(List<String> args) async {
  try {
    initialize(args);
    await runShardBasedOnEnvironment();
  } catch (error, stackTrace) {
    handleUnexpectedError(error, stackTrace);
    system.exit(255);
  }

  if (hasError) {
    reportErrorsAndExit('Test failed.');
  }
  reportSuccessAndExit('Test successful.');
}

void initialize(List<String> args) {
  printProgress('STARTING ANALYSIS');
  parseArguments(args);
  if (Platform.environment.containsKey(CIRRUS_TASK_NAME)) {
    printProgress('Running task: ${Platform.environment[CIRRUS_TASK_NAME]}');
  }
}

void parseArguments(List<String> args) {
  for (final String arg in args) {
    if (arg.startsWith('--local-engine=')) {
      localEngineEnv['FLUTTER_LOCAL_ENGINE'] = arg.substring('--local-engine='.length);
      flutterTestArgs.add(arg);
    } else if (arg.startsWith('--local-engine-host=')) {
      localEngineEnv['FLUTTER_LOCAL_ENGINE_HOST'] = arg.substring('--local-engine-host='.length);
      flutterTestArgs.add(arg);
    } else if (arg.startsWith('--local-engine-src-path=')) {
      localEngineEnv['FLUTTER_LOCAL_ENGINE_SRC_PATH'] = arg.substring('--local-engine-src-path='.length);
      flutterTestArgs.add(arg);
    } else if (arg.startsWith('--test-randomize-ordering-seed=')) {
      shuffleSeed = arg.substring('--test-randomize-ordering-seed='.length);
    } else if (arg == '--verbose') {
      print = (Object? message) => system.print(message);
    } else if (arg == '--abort-on-error') {
      onError = () => system.exit(1);
    } else {
      flutterTestArgs.add(arg);
    }
  }
}

Future<void> runShardBasedOnEnvironment() async {
  final WebTestsSuite webTestsSuite = WebTestsSuite(flutterTestArgs);
  await selectShard(<String, ShardRunner>{
    'add_to_app_life_cycle_tests': addToAppLifeCycleRunner,
    'build_tests': _runBuildTests,
    'framework_coverage': frameworkCoverageRunner,
    'framework_tests': frameworkTestsRunner,
    'tool_tests': _runToolTests,
    'web_tool_tests': _runWebToolTests,
    'tool_integration_tests': _runIntegrationToolTests,
    'android_preview_tool_integration_tests': androidPreviewIntegrationToolTestsRunner,
    'tool_host_cross_arch_tests': _runToolHostCrossArchTests,
    'web_tests': webTestsSuite.runWebHtmlUnitTests,
    'web_canvaskit_tests': webTestsSuite.runWebCanvasKitUnitTests,
    'web_skwasm_tests': webTestsSuite.runWebSkwasmUnitTests,
    'web_long_running_tests': webTestsSuite.webLongRunningTestsRunner,
    'flutter_plugins': flutterPackagesRunner,
    'skp_generator': skpGeneratorTestsRunner,
    'realm_checker': realmCheckerTestRunner,
    'customer_testing': customerTestingRunner,
    'analyze': analyzeRunner,
    'fuchsia_precache': fuchsiaPrecacheRunner,
    'snippets': _runSnippetsTests,
    'docs': docsRunner,
    'verify_binaries_codesigned': verifyCodesignedTestRunner,
    kTestHarnessShardName: testHarnessTestsRunner,
  });
}

void handleUnexpectedError(dynamic error, StackTrace stackTrace) {
  foundError(<String>[
    'UNEXPECTED ERROR!',
    error.toString(),
    ...stackTrace.toString().split('\n'),
    'The test.dart script should be corrected to catch this error and call foundError().',
    '${yellow}Some tests are likely to have been skipped.$reset',
  ]);
}

Future<void> _runBuildTests() async {
  final List<Directory> exampleDirectories = getExampleDirectories();
  final List<ShardRunner> tests = getBuildTests(exampleDirectories)..shuffle(math.Random(0));

  await runShardRunnerIndexOfTotalSubshard(tests);
}

List<Directory> getExampleDirectories() {
  final List<Directory> exampleDirectories = Directory(path.join(flutterRoot, 'examples')).listSync()
    .whereType<Directory>()
    .where((Directory dir) => path.basename(dir.path) != 'api')
    .toList();

  exampleDirectories.addAll([
    Directory(path.join(flutterRoot, 'packages', 'integration_test', 'example')),
    Directory(path.join(flutterRoot, 'dev', 'integration_tests', 'android_semantics_testing')),
    Directory(path.join(flutterRoot, 'dev', 'integration_tests', 'android_views')),
    Directory(path.join(flutterRoot, 'dev', 'integration_tests', 'channels')),
    Directory(path.join(flutterRoot, 'dev', 'integration_tests', 'hybrid_android_views')),
    Directory(path.join(flutterRoot, 'dev', 'integration_tests', 'flutter_gallery')),
    Directory(path.join(flutterRoot, 'dev', 'integration_tests', 'ios_platform_view_tests')),
    Directory(path.join(flutterRoot, 'dev', 'integration_tests', 'ios_app_with_extensions')),
    Directory(path.join(flutterRoot, 'dev', 'integration_tests', 'non_nullable')),
    Directory(path.join(flutterRoot, 'dev', 'integration_tests', 'platform_interaction')),
    Directory(path.join(flutterRoot, 'dev', 'integration_tests', 'spell_check')),
    Directory(path.join(flutterRoot, 'dev', 'integration_tests', 'ui')),
  ]);

  return exampleDirectories;
}

List<ShardRunner> getBuildTests(List<Directory> exampleDirectories) {
  final List<ShardRunner> tests = <ShardRunner>[
    for (final Directory exampleDirectory in exampleDirectories)
      () => _runExampleProjectBuildTests(exampleDirectory),
    () => _flutterBuildDart2js(path.join('dev', 'integration_tests', 'web'), path.join('lib', 'main.dart')),
    () => _flutterBuildDart2js(path.join('dev', 'integration_tests', 'web_compile_tests'), path.join('lib', 'dart_io_import.dart')),
    () => _flutterBuildDart2js(path.join('dev', 'integration_tests', 'web_compile_tests'), path.join('lib', 'background_isolate_binary_messenger.dart')),
    runForbiddenFromReleaseTests,
  ];

  return tests;
}

Future<void> _runExampleProjectBuildTests(Directory exampleDirectory) async {
  final String examplePath = path.relative(exampleDirectory.path, from: Directory.current.path);
  final bool verifyCaching = exampleDirectory.path.contains('flutter_gallery');

  await Future.wait([
    if (Directory(path.join(examplePath, 'android')).existsSync())
      _runAndroidBuildTests(examplePath, verifyCaching),
    if (Platform.isMacOS && Directory(path.join(examplePath, 'ios')).existsSync())
      _runIosBuildTests(examplePath, verifyCaching),
    if (Platform.isLinux && Directory(path.join(examplePath, 'linux')).existsSync())
      _runLinuxBuildTests(examplePath, verifyCaching),
    if (Platform.isMacOS && Directory(path.join(examplePath, 'macos')).existsSync())
      _runMacOsBuildTests(examplePath, verifyCaching),
    if (Platform.isWindows && Directory(path.join(examplePath, 'windows')).existsSync())
      _runWindowsBuildTests(examplePath, verifyCaching),
  ]);
}

Future<void> _runAndroidBuildTests(String examplePath, bool verifyCaching) async {
  await _flutterBuildApk(examplePath, release: false, verifyCaching: verifyCaching);
  await _flutterBuildApk(examplePath, release: true, verifyCaching: verifyCaching);
}

Future<void> _runIosBuildTests(String examplePath, bool verifyCaching) async {
  await _flutterBuildIpa(examplePath, release: false, verifyCaching: verifyCaching);
  await _flutterBuildIpa(examplePath, release: true, verifyCaching: verifyCaching);
}

Future<void> _runLinuxBuildTests(String examplePath, bool verifyCaching) async {
  await runCommand(flutter, <String>['config', '--enable-linux-desktop']);
  await _flutterBuildLinux(examplePath, verifyCaching: verifyCaching);
}

Future<void> _runMacOsBuildTests(String examplePath, bool verifyCaching) async {
  await runCommand(flutter, <String>['config', '--enable-macos-desktop']);
  await _flutterBuildMacOs(examplePath, verifyCaching: verifyCaching);
}

Future<void> _runWindowsBuildTests(String examplePath, bool verifyCaching) async {
  await runCommand(flutter, <String>['config', '--enable-windows-desktop']);
  await _flutterBuildWindows(examplePath, verifyCaching: verifyCaching);
}

Future<void> _runToolTests() async {
  await runCommand(dart, <String>['tool/test/all.dart']);
}

Future<void> _runWebToolTests() async {
  await runCommand(dart, <String>['tool/test/web_test.dart']);
}

Future<void> _runIntegrationToolTests() async {
  await runCommand(dart, <String>['tool/integration_tests/all.dart']);
}

Future<void> _runToolHostCrossArchTests() async {
  await runCommand(dart, <String>['tool/host_cross_arch_test.dart']);
}

Future<void> _runSnippetsTests() async {
  await runCommand(dart, <String>['dev/snippets/config_test.dart']);
}

Future<void> _flutterBuildDart2js(String target, String mainDartFilePath) async {
  await runCommand(
    flutter,
    <String>[
      'build',
      'web',
      '--target=$mainDartFilePath',
      '--release',
    ],
    workingDirectory: target,
  );
}

Future<void> _flutterBuildApk(String target, {required bool release, bool verifyCaching = false}) async {
  final String buildMode = release ? 'release' : 'debug';
  await runCommand(
    flutter,
    <String>[
      'build',
      'apk',
      '--$buildMode',
    ],
    workingDirectory: target,
  );
  if (verifyCaching) {
    await runCommand(
      flutter,
      <String>[
        'build',
        'apk',
        '--$buildMode',
        '--no-pub',
      ],
      workingDirectory: target,
    );
  }
}

Future<void> _flutterBuildIpa(String target, {required bool release, bool verifyCaching = false}) async {
  final String buildMode = release ? 'release' : 'debug';
  await runCommand(
    flutter,
    <String>[
      'build',
      'ipa',
      '--$buildMode',
    ],
    workingDirectory: target,
  );
  if (verifyCaching) {
    await runCommand(
      flutter,
      <String>[
        'build',
        'ipa',
        '--$buildMode',
        '--no-pub',
      ],
      workingDirectory: target,
    );
  }
}

Future<void> _flutterBuildLinux(String target, {bool verifyCaching = false}) async {
  await runCommand(
    flutter,
    <String>[
      'build',
      'linux',
      '--debug',
    ],
    workingDirectory: target,
  );
  if (verifyCaching) {
    await runCommand(
      flutter,
      <String>[
        'build',
        'linux',
        '--debug',
        '--no-pub',
      ],
      workingDirectory: target,
    );
  }
}

Future<void> _flutterBuildMacOs(String target, {bool verifyCaching = false}) async {
  await runCommand(
    flutter,
    <String>[
      'build',
      'macos',
      '--debug',
    ],
    workingDirectory: target,
  );
  if (verifyCaching) {
    await runCommand(
      flutter,
      <String>[
        'build',
        'macos',
        '--debug',
        '--no-pub',
      ],
      workingDirectory: target,
    );
  }
}

Future<void> _flutterBuildWindows(String target, {bool verifyCaching = false}) async {
  await runCommand(
    flutter,
    <String>[
      'build',
      'windows',
      '--debug',
    ],
    workingDirectory: target,
  );
  if (verifyCaching) {
    await runCommand(
      flutter,
      <String>[
        'build',
        'windows',
        '--debug',
        '--no-pub',
      ],
      workingDirectory: target,
    );
  }
}

void printProgress(String message) {
  print('$green+$reset $message');
}

void reportErrorsAndExit(String message) {
  print('$red-$reset $message');
  system.exit(1);
}

void reportSuccessAndExit(String message) {
  print('$green+$reset $message');
  system.exit(0);
}

void foundError(List<String> errorMessages) {
  for (final String error in errorMessages) {
    print('$red-$reset $error');
  }
  hasError = true;
  if (onError != null) {
    onError!();
  }
}
