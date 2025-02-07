// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.8

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:process/process.dart';

import 'application_package.dart';
import 'base/common.dart';
import 'base/file_system.dart';
import 'base/io.dart';
import 'base/logger.dart';
import 'base/os.dart';
import 'build_info.dart';
import 'convert.dart';
import 'devfs.dart';
import 'device.dart';
import 'device_port_forwarder.dart';
import 'protocol_discovery.dart';

/// A partial implementation of Device for desktop-class devices to inherit
/// from, containing implementations that are common to all desktop devices.
abstract class DesktopDevice extends Device {
  DesktopDevice(String identifier, {
      @required PlatformType platformType,
      @required bool ephemeral,
      @required Logger logger,
      @required ProcessManager processManager,
      @required FileSystem fileSystem,
      @required OperatingSystemUtils operatingSystemUtils,
    }) : _logger = logger,
         _processManager = processManager,
         _fileSystem = fileSystem,
         _operatingSystemUtils = operatingSystemUtils,
         super(
          identifier,
          category: Category.desktop,
          platformType: platformType,
          ephemeral: ephemeral,
        );

  final Logger _logger;
  final ProcessManager _processManager;
  final FileSystem _fileSystem;
  final OperatingSystemUtils _operatingSystemUtils;
  final Set<Process> _runningProcesses = <Process>{};
  final DesktopLogReader _deviceLogReader = DesktopLogReader();

  @override
  DevFSWriter createDevFSWriter(covariant ApplicationPackage app, String userIdentifier) {
    return LocalDevFSWriter(fileSystem: _fileSystem);
  }

  // Since the host and target devices are the same, no work needs to be done
  // to install the application.
  @override
  Future<bool> isAppInstalled(
    ApplicationPackage app, {
    String userIdentifier,
  }) async => true;

  // Since the host and target devices are the same, no work needs to be done
  // to install the application.
  @override
  Future<bool> isLatestBuildInstalled(ApplicationPackage app) async => true;

  // Since the host and target devices are the same, no work needs to be done
  // to install the application.
  @override
  Future<bool> installApp(
    ApplicationPackage app, {
    String userIdentifier,
  }) async => true;

  // Since the host and target devices are the same, no work needs to be done
  // to uninstall the application.
  @override
  Future<bool> uninstallApp(
    ApplicationPackage app, {
    String userIdentifier,
  }) async => true;

  @override
  Future<bool> get isLocalEmulator async => false;

  @override
  Future<String> get emulatorId async => null;

  @override
  DevicePortForwarder get portForwarder => const NoOpDevicePortForwarder();

  @override
  Future<String> get sdkNameAndVersion async => _operatingSystemUtils.name;

  @override
  bool supportsRuntimeMode(BuildMode buildMode) => buildMode != BuildMode.jitRelease;

  @override
  DeviceLogReader getLogReader({
    ApplicationPackage app,
    bool includePastLogs = false,
  }) {
    assert(!includePastLogs, 'Past log reading not supported on desktop.');
    return _deviceLogReader;
  }

  @override
  void clearLogs() {}

  @override
  Future<LaunchResult> startApp(
    ApplicationPackage package, {
    String mainPath,
    String route,
    @required DebuggingOptions debuggingOptions,
    Map<String, dynamic> platformArgs = const <String, dynamic>{},
    bool prebuiltApplication = false,
    bool ipv6 = false,
    String userIdentifier,
  }) async {
    if (!prebuiltApplication) {
      await buildForDevice(
        package,
        buildInfo: debuggingOptions.buildInfo,
        mainPath: mainPath,
      );
    }

    // Ensure that the executable is locatable.
    final BuildMode buildMode = debuggingOptions?.buildInfo?.mode;
    final bool traceStartup = platformArgs['trace-startup'] as bool ?? false;
    final String executable = executablePathForDevice(package, buildMode);
    if (executable == null) {
      _logger.printError('Unable to find executable to run');
      return LaunchResult.failed();
    }

    final Process process = await _processManager.start(
      <String>[
        executable,
        ...?debuggingOptions?.dartEntrypointArgs,
      ],
      environment: _computeEnvironment(debuggingOptions, traceStartup, route),
    );
    _runningProcesses.add(process);
    unawaited(process.exitCode.then((_) => _runningProcesses.remove(process)));

    _deviceLogReader.initializeProcess(process);
    if (debuggingOptions?.buildInfo?.isRelease == true) {
      return LaunchResult.succeeded();
    }
    final ProtocolDiscovery observatoryDiscovery = ProtocolDiscovery.observatory(_deviceLogReader,
      devicePort: debuggingOptions?.deviceVmServicePort,
      hostPort: debuggingOptions?.hostVmServicePort,
      ipv6: ipv6,
      logger: _logger,
    );
    try {
      final Uri observatoryUri = await observatoryDiscovery.uri;
      if (observatoryUri != null) {
        onAttached(package, buildMode, process);
        return LaunchResult.succeeded(observatoryUri: observatoryUri);
      }
      _logger.printError(
        'Error waiting for a debug connection: '
        'The log reader stopped unexpectedly.',
      );
    } on Exception catch (error) {
      _logger.printError('Error waiting for a debug connection: $error');
    } finally {
      await observatoryDiscovery.cancel();
    }
    return LaunchResult.failed();
  }

  @override
  Future<bool> stopApp(
    ApplicationPackage app, {
    String userIdentifier,
  }) async {
    bool succeeded = true;
    // Walk a copy of _runningProcesses, since the exit handler removes from the
    // set.
    for (final Process process in Set<Process>.of(_runningProcesses)) {
      succeeded &= _processManager.killPid(process.pid);
    }
    return succeeded;
  }

  @override
  Future<void> dispose() async {
    await portForwarder?.dispose();
  }

  /// Builds the current project for this device, with the given options.
  Future<void> buildForDevice(
    ApplicationPackage package, {
    String mainPath,
    BuildInfo buildInfo,
  });

  /// Returns the path to the executable to run for [package] on this device for
  /// the given [buildMode].
  String executablePathForDevice(ApplicationPackage package, BuildMode buildMode);

  /// Called after a process is attached, allowing any device-specific extra
  /// steps to be run.
  void onAttached(ApplicationPackage package, BuildMode buildMode, Process process) {}

  /// Computes a set of environment variables used to pass debugging information
  /// to the engine without interfering with application level command line
  /// arguments.
  ///
  /// The format of the environment variables is:
  ///   * FLUTTER_ENGINE_SWITCHES to the number of switches.
  ///   * FLUTTER_ENGINE_SWITCH_<N> (indexing from 1) to the individual switches.
  Map<String, String> _computeEnvironment(DebuggingOptions debuggingOptions, bool traceStartup, String route) {
    int flags = 0;
    final Map<String, String> environment = <String, String>{};

    void addFlag(String value) {
      flags += 1;
      environment['FLUTTER_ENGINE_SWITCH_$flags'] = value;
    }
    void finish() {
      environment['FLUTTER_ENGINE_SWITCHES'] = flags.toString();
    }

    addFlag('enable-dart-profiling=true');
    addFlag('enable-background-compilation=true');

    if (traceStartup) {
      addFlag('trace-startup=true');
    }
    if (route != null) {
      addFlag('route=$route');
    }
    if (debuggingOptions.enableSoftwareRendering) {
      addFlag('enable-software-rendering=true');
    }
    if (debuggingOptions.skiaDeterministicRendering) {
      addFlag('skia-deterministic-rendering=true');
    }
    if (debuggingOptions.traceSkia) {
      addFlag('trace-skia=true');
    }
    if (debuggingOptions.traceAllowlist != null) {
      addFlag('trace-allowlist=${debuggingOptions.traceAllowlist}');
    }
    if (debuggingOptions.traceSkiaAllowlist != null) {
      addFlag('trace-skia-allowlist=${debuggingOptions.traceSkiaAllowlist}');
    }
    if (debuggingOptions.traceSystrace) {
      addFlag('trace-systrace=true');
    }
    if (debuggingOptions.endlessTraceBuffer) {
      addFlag('endless-trace-buffer=true');
    }
    if (debuggingOptions.dumpSkpOnShaderCompilation) {
      addFlag('dump-skp-on-shader-compilation=true');
    }
    if (debuggingOptions.cacheSkSL) {
      addFlag('cache-sksl=true');
    }
    if (debuggingOptions.purgePersistentCache) {
      addFlag('purge-persistent-cache=true');
    }
    // Options only supported when there is a VM Service connection between the
    // tool and the device, usually in debug or profile mode.
    if (debuggingOptions.debuggingEnabled) {
      if (debuggingOptions.deviceVmServicePort != null) {
        addFlag('observatory-port=${debuggingOptions.deviceVmServicePort}');
      }
      if (debuggingOptions.buildInfo.isDebug) {
        addFlag('enable-checked-mode=true');
        addFlag('verify-entry-points=true');
      }
      if (debuggingOptions.startPaused) {
        addFlag('start-paused=true');
      }
      if (debuggingOptions.disableServiceAuthCodes) {
        addFlag('disable-service-auth-codes=true');
      }
      final String dartVmFlags = computeDartVmFlags(debuggingOptions);
      if (dartVmFlags.isNotEmpty) {
        addFlag('dart-flags=$dartVmFlags');
      }
      if (debuggingOptions.useTestFonts) {
        addFlag('use-test-fonts=true');
      }
      if (debuggingOptions.verboseSystemLogs) {
        addFlag('verbose-logging=true');
      }
    }
    finish();
    return environment;
  }
}

/// A log reader for desktop applications that delegates to a [Process] stdout
/// and stderr streams.
class DesktopLogReader extends DeviceLogReader {
  final StreamController<List<int>> _inputController = StreamController<List<int>>.broadcast();

  /// Begin listening to the stdout and stderr streams of the provided [process].
  void initializeProcess(Process process) {
    final StreamSubscription<List<int>> stdoutSub = process.stdout.listen(
      _inputController.add,
    );
    final StreamSubscription<List<int>> stderrSub = process.stderr.listen(
      _inputController.add,
    );
    process.exitCode.whenComplete(() async {
      // Wait for output to be fully processed.
      await Future.wait<void>(<Future<void>>[
        stdoutSub.asFuture<void>(),
        stderrSub.asFuture<void>(),
      ]);
      // The streams as futures have already completed, so waiting for the
      // potentially async stream cancellation to complete likely has no
      // benefit.
      unawaited(stdoutSub.cancel());
      unawaited(stderrSub.cancel());
      await _inputController.close();
    });
  }

  @override
  Stream<String> get logLines {
    return _inputController.stream
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  }

  @override
  String get name => 'desktop';

  @override
  void dispose() {
    // Nothing to dispose.
  }
}
