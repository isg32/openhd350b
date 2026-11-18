import 'dart:async';

import 'package:flutter/foundation.dart';

import 'vm_upgrade.dart';

/// The transport the [UpgradeMachine] drives. The real implementation wraps the
/// GAIA client; tests use a fake device. Keeping it abstract means the whole
/// state machine is exercised off-hardware.
abstract interface class UpgradeTransport {
  Future<void> enable(); // Upgrade_Enable (0x0494/0x0202)
  Future<void> registerEvents(); // 0x000A/0x4001 event 0x12
  Future<void> connect(); // 0x000A/0x0640
  Future<void> disconnect(); // 0x000A/0x0641
  Future<void> sendControl(VmPdu pdu); // 0x000A/0x0642

  /// Decoded VM-Upgrade PDUs from the device.
  Stream<VmPdu> get events;

  /// Image bytes carried per DATA packet (transport payload minus headers).
  int get maxChunkBytes;

  /// Device battery %, or null if unknown.
  Future<int?> deviceBatteryPercent();

  /// After the device reboots: wait, reconnect, re-enable/register.
  Future<void> awaitReconnect();
}

enum UpgradePhase {
  preconditions,
  connecting,
  syncing,
  starting,
  transferring,
  validating,
  rebooting,
  committing,
  done,
  aborted,
  failed,
}

@immutable
class UpgradeProgress {
  const UpgradeProgress(this.phase, {this.percent = 0, this.message});
  final UpgradePhase phase;
  final double percent; // 0..1 during transfer
  final String? message;
}

class UpgradeError implements Exception {
  UpgradeError(this.message);
  final String message;
  @override
  String toString() => 'UpgradeError: $message';
}

/// Drives a full VM-Upgrade. Every wait has a timeout; any unexpected state
/// sends ABORT and fails, so the device rolls back rather than being left in
/// an unknown state.
class UpgradeMachine {
  UpgradeMachine({
    required this.transport,
    required this.image,
    required this.phoneBatteryPercent,
    this.minBatteryPercent = 20,
    this.dryRun = false,
    this.fileId = upgradeFileId,
  });

  final UpgradeTransport transport;
  final Uint8List image;
  final Future<int?> Function() phoneBatteryPercent;
  final int minBatteryPercent;

  /// Runs the full handshake up to START, then aborts without sending any
  /// image data — a safe on-device test that never writes firmware.
  final bool dryRun;
  final int fileId;

  final _progress = StreamController<UpgradeProgress>.broadcast();
  Stream<UpgradeProgress> get progress => _progress.stream;

  StreamSubscription<VmPdu>? _sub;
  // A buffered queue + single pending waiter, so a reply that arrives before
  // the machine starts waiting is never lost (no broadcast-stream race).
  final _buffer = <VmPdu>[];
  (int, Completer<VmPdu>)? _waiter;
  UpgradeError? _pendingError;
  var _dataOffset = 0;
  var _aborted = false;
  var _started = false;

  void _onPdu(VmPdu pdu) {
    final w0 = _waiter;
    debugPrint(
      '[upgrade] << opcode=0x${pdu.opcode.toRadixString(16)} '
      'len=${pdu.payload.length} '
      '${w0 != null ? "waiting=0x${w0.$1.toRadixString(16)}" : "no-waiter"}'
      '${w0 != null && w0.$1 != pdu.opcode && pdu.opcode != UpOp.errorInd ? " -> BUFFERED" : ""}',
    );
    if (pdu.opcode == UpOp.errorInd) {
      final err = UpgradeError(
        'device error 0x${pdu.errorCode.toRadixString(16)}',
      );
      final w = _waiter;
      if (w != null && !w.$2.isCompleted) {
        _waiter = null;
        w.$2.completeError(err);
      } else {
        _pendingError = err;
      }
      return;
    }
    final w = _waiter;
    if (w != null && w.$1 == pdu.opcode && !w.$2.isCompleted) {
      _waiter = null;
      w.$2.complete(pdu);
    } else {
      _buffer.add(pdu);
    }
  }

  void _emit(UpgradePhase p, {double percent = 0, String? message}) {
    debugPrint(
      '[upgrade] phase=${p.name}'
      '${percent > 0 ? ' ${(percent * 100).toStringAsFixed(1)}%' : ''}'
      '${message != null ? ' ($message)' : ''}',
    );
    if (!_progress.isClosed) {
      _progress.add(UpgradeProgress(p, percent: percent, message: message));
    }
  }

  /// Waits for one PDU with [opcode]. Checks the buffer first, then waits.
  /// A buffered/arriving ERROR_IND fails fast. Times out.
  Future<VmPdu> _await(
    int opcode, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    if (_pendingError != null) {
      final e = _pendingError!;
      _pendingError = null;
      throw e;
    }
    final i = _buffer.indexWhere((p) => p.opcode == opcode);
    if (i >= 0) return Future.value(_buffer.removeAt(i));
    final completer = Completer<VmPdu>();
    _waiter = (opcode, completer);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiter = null;
        throw UpgradeError(
          'timed out waiting for opcode 0x${opcode.toRadixString(16)}',
        );
      },
    );
  }

  /// Runs the upgrade. Returns true on success, false if it was aborted/failed
  /// or a dry run (the device rolls back / nothing was written).
  Future<bool> run() async {
    _sub = transport.events.listen(_onPdu);
    try {
      // A dry run writes nothing and takes seconds, so the battery guard
      // (which protects the ~20-minute real flash) doesn't apply.
      if (!dryRun) await _checkBatteries();
      _emit(UpgradePhase.connecting);
      await transport.registerEvents();
      // Connect and enable are best-effort: the device may answer "already
      // connected / not needed" (status 6 / 1). What actually gates the
      // upgrade is SYNC + START below, so a non-zero ack here is not fatal.
      for (final step in [
        ('connect', transport.connect),
        ('enable', transport.enable),
      ]) {
        try {
          await step.$2();
        } catch (e) {
          debugPrint(
            '[upgrade] ${step.$1} (best-effort) non-OK, continuing: $e',
          );
        }
      }
      _started = true; // past here, an abort has something to abort
      await _drive();
      if (_aborted) return false;
      _emit(UpgradePhase.done);
      return true;
    } on UpgradeError catch (e) {
      debugPrint('[upgrade] $e');
      await _abort(e.message);
      return false;
    } catch (e) {
      debugPrint('[upgrade] unexpected: $e');
      await _abort('$e');
      return false;
    } finally {
      await _sub?.cancel();
    }
  }

  Future<void> _checkBatteries() async {
    _emit(UpgradePhase.preconditions, message: 'Checking battery');
    final phone = await phoneBatteryPercent();
    if (phone != null && phone < minBatteryPercent) {
      throw UpgradeError('Phone battery $phone% is below $minBatteryPercent%');
    }
    final device = await transport.deviceBatteryPercent();
    if (device != null && device < minBatteryPercent) {
      throw UpgradeError(
        'Headphone battery $device% is below $minBatteryPercent%',
      );
    }
  }

  /// The SYNC-driven loop: SYNC tells us where the device wants to continue.
  Future<void> _drive() async {
    for (var guard = 0; guard < 6; guard++) {
      _emit(UpgradePhase.syncing);
      await transport.sendControl(VmPdu.syncReq(fileId));
      final syncCfm = await _await(UpOp.syncCfm);
      final resume = syncCfm.syncResumePoint;
      debugPrint('[upgrade] SYNC_CFM resumePoint=$resume');

      _emit(UpgradePhase.starting);
      await transport.sendControl(VmPdu.startReq());
      final startCfm = await _await(UpOp.startCfm);
      debugPrint('[upgrade] START_CFM status=${startCfm.startStatus}');
      if (startCfm.startStatus != 0) {
        throw UpgradeError('START refused (status ${startCfm.startStatus})');
      }

      if (dryRun) {
        _emit(UpgradePhase.aborted, message: 'Dry run: stopped before data');
        await _abort('dry run');
        return;
      }

      switch (resume) {
        case ResumePoint.start:
          await _transferData();
          await _validate();
          await _transferComplete();
          // device reboots; reconnect and loop back to SYNC
          _emit(UpgradePhase.rebooting);
          await transport.awaitReconnect();
          continue;
        case ResumePoint.preValidate:
          await _validate();
          await _transferComplete();
          _emit(UpgradePhase.rebooting);
          await transport.awaitReconnect();
          continue;
        case ResumePoint.preReboot:
          await _transferComplete();
          _emit(UpgradePhase.rebooting);
          await transport.awaitReconnect();
          continue;
        case ResumePoint.postReboot:
          await _commit();
          return;
        case ResumePoint.postCommit:
          return;
        default:
          throw UpgradeError('unknown resume point $resume');
      }
    }
    throw UpgradeError('too many sync cycles');
  }

  Future<void> _transferData() async {
    _dataOffset = 0;
    _emit(UpgradePhase.transferring, percent: 0);
    await transport.sendControl(VmPdu.startDataReq());
    var lastLoggedPct = -1;
    while (_dataOffset < image.length) {
      // The device paces the transfer by requesting bytes; it can pause to
      // write flash, so give it room before timing out.
      final req = (await _await(UpOp.dataBytesReq,
              timeout: const Duration(seconds: 60)))
          .dataBytesReq;
      if (req == null) throw UpgradeError('bad DATA_BYTES_REQ');
      debugPrint('[upgrade] DATA_BYTES_REQ numBytes=${req.numBytes} '
          'offset=${req.offset} at dataOffset=$_dataOffset');
      // Relative offset adjustment (resume / retransmit); usually 0.
      if (req.offset != 0) {
        _dataOffset = (_dataOffset + req.offset <= image.length)
            ? _dataOffset + req.offset
            : 0;
      }
      // Fulfil the whole request in maxChunk-sized packets, matching the
      // official app's `remainingBytesToSend` recursion. NOTE: this cannot
      // complete over BLE on the HD 350BT — the device caps the ATT MTU at 64
      // and rejects long writes, so a request larger than one packet (e.g. the
      // 268-byte request after the header) must be fragmented, and the device's
      // BLE VM-Upgrade path stalls on that. Firmware flashing needs an
      // RFCOMM/SPP transport (how the official app does it). See handover.md.
      var want = req.numBytes;
      while (want > 0 && _dataOffset < image.length) {
        final take = [
          want,
          transport.maxChunkBytes,
          image.length - _dataOffset,
        ].reduce((a, b) => a < b ? a : b);
        final chunk = Uint8List.sublistView(
          image,
          _dataOffset,
          _dataOffset + take,
        );
        final last = _dataOffset + take >= image.length;
        await transport.sendControl(VmPdu.data(last ? 1 : 0, chunk));
        _dataOffset += take;
        want -= take;
        final pct = _dataOffset / image.length;
        final whole = (pct * 100).floor();
        if (whole > lastLoggedPct) {
          lastLoggedPct = whole;
          _emit(UpgradePhase.transferring, percent: pct);
        }
        if (last) return;
      }
    }
  }

  Future<void> _validate() async {
    _emit(UpgradePhase.validating);
    for (var i = 0; i < 600; i++) {
      await transport.sendControl(VmPdu.isValidationDoneReq());
      final cfm = await _await(
        UpOp.isValidationDoneCfm,
        timeout: const Duration(seconds: 30),
      );
      final delay = cfm.validationDelayMs;
      if (delay <= 0) return; // validation finished
      await Future<void>.delayed(Duration(milliseconds: delay.clamp(50, 5000)));
    }
    throw UpgradeError('validation did not finish');
  }

  Future<void> _transferComplete() async {
    // The device signals it's done; we tell it to proceed (action 0 = reboot).
    await _await(
      UpOp.transferCompleteInd,
      timeout: const Duration(seconds: 30),
    );
    await transport.sendControl(VmPdu.transferCompleteRes(0));
  }

  Future<void> _commit() async {
    _emit(UpgradePhase.committing);
    await transport.sendControl(VmPdu.proceedToCommit(0));
    await _await(UpOp.commitReq, timeout: const Duration(seconds: 30));
    await transport.sendControl(VmPdu.commitCfm(0));
    await _await(UpOp.completeInd, timeout: const Duration(seconds: 30));
  }

  Future<void> _abort(String reason) async {
    if (_aborted) return;
    _aborted = true;
    _emit(UpgradePhase.failed, message: reason);
    // Only abort if the upgrade actually started; otherwise there is nothing
    // in progress and ABORT would just hit the device in the wrong state.
    if (!_started) return;
    try {
      await transport.sendControl(VmPdu.abortReq());
    } catch (_) {
      // Already disconnected; the device rolls back on its own.
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _progress.close();
  }
}
