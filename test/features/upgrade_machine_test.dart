import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openhd350b/features/firmware/upgrade_machine.dart';
import 'package:openhd350b/features/firmware/vm_upgrade.dart';

/// A scripted HD 350BT that speaks the VM-Upgrade protocol, so the whole
/// state machine runs off-hardware. It reassembles the image it receives and
/// records whether it committed / aborted.
class FakeUpgradeDevice implements UpgradeTransport {
  FakeUpgradeDevice({
    required this.imageLength,
    this.chunk = 20,
    this.batch = 1 << 20,
    this.validationDelays = 0,
    this.failValidation = false,
    this.deviceBattery = 90,
    this.startAtPostReboot = false,
    this.errorAtByte,
  }) {
    resume = startAtPostReboot ? ResumePoint.postReboot : ResumePoint.start;
  }

  final int imageLength;
  final int chunk;
  final int batch; // bytes the device requests per DATA_BYTES_REQ
  final int validationDelays;
  final bool failValidation;
  final int? deviceBattery;
  final bool startAtPostReboot;
  final int? errorAtByte;

  final received = BytesBuilder();
  int resume = ResumePoint.start;
  int _outstanding = 0;
  int _validationCalls = 0;
  bool committed = false;
  bool aborted = false;
  bool rebootRequested = false;
  final List<int> syncFileIds = [];

  final _events = StreamController<VmPdu>.broadcast();
  Completer<void>? _reboot;
  bool _rebootPending = false;

  @override
  Stream<VmPdu> get events => _events.stream;
  @override
  int get maxChunkBytes => chunk;
  @override
  Future<int?> deviceBatteryPercent() async => deviceBattery;
  @override
  Future<void> enable() async {}
  @override
  Future<void> registerEvents() async {}
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}

  @override
  Future<void> awaitReconnect() {
    if (_rebootPending) {
      _rebootPending = false;
      return Future<void>.value();
    }
    _reboot = Completer<void>();
    return _reboot!.future;
  }

  void _emit(VmPdu p) => scheduleMicrotask(() {
        if (!_events.isClosed) _events.add(p);
      });

  void _requestBatch() {
    final remaining = imageLength - received.length;
    if (remaining <= 0) return;
    _outstanding = remaining < batch ? remaining : batch;
    final p = Uint8List(8);
    ByteData.sublistView(p)
      ..setUint32(0, _outstanding)
      ..setUint32(4, 0);
    _emit(VmPdu(UpOp.dataBytesReq, p));
  }

  @override
  Future<void> sendControl(VmPdu pdu) async {
    switch (pdu.opcode) {
      case UpOp.syncReq:
        syncFileIds.add(
            ByteData.sublistView(pdu.payload).getUint32(0));
        _emit(VmPdu(UpOp.syncCfm,
            Uint8List.fromList([resume, 0x12, 0x34, 0x56, 0x78, 1])));
      case UpOp.startReq:
        _emit(VmPdu(UpOp.startCfm, Uint8List.fromList([0, 0x00, 0x64])));
      case UpOp.startDataReq:
        _requestBatch();
      case UpOp.data:
        final flag = pdu.payload[0];
        received.add(pdu.payload.sublist(1));
        _outstanding -= pdu.payload.length - 1;
        if (errorAtByte != null && received.length >= errorAtByte!) {
          _emit(VmPdu(UpOp.errorInd, Uint8List.fromList([0x00, 0x05])));
          return;
        }
        if (flag == 1) {
          // all data received; device will answer validation next
        } else if (_outstanding <= 0) {
          _requestBatch();
        }
      case UpOp.isValidationDoneReq:
        if (failValidation) {
          _emit(VmPdu(UpOp.errorInd, Uint8List.fromList([0x00, 0x11])));
          return;
        }
        final more = _validationCalls < validationDelays;
        _validationCalls++;
        _emit(VmPdu(UpOp.isValidationDoneCfm,
            more ? Uint8List.fromList([0x00, 0x32]) : Uint8List(2)));
        if (!more) _emit(VmPdu(UpOp.transferCompleteInd));
      case UpOp.transferCompleteRes:
        rebootRequested = true;
        resume = ResumePoint.postReboot;
        if (_reboot != null && !_reboot!.isCompleted) {
          _reboot!.complete();
        } else {
          _rebootPending = true;
        }
      case UpOp.proceedToCommit:
        _emit(VmPdu(UpOp.commitReq));
      case UpOp.commitCfm:
        committed = true;
        _emit(VmPdu(UpOp.completeInd));
      case UpOp.abortReq:
        aborted = true;
    }
  }

  Future<void> close() => _events.close();
}

Uint8List _image(int n) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 7 + 3) & 0xFF));

void main() {
  group('VmPdu codec', () {
    test('encodes opcode + BE16 length + payload', () {
      final p = VmPdu.syncReq(0x12345678).encode();
      expect(p.sublist(0, 3), [0x13, 0x00, 0x04]);
      expect(p.sublist(3), [0x12, 0x34, 0x56, 0x78]);
    });

    test('data packet sets the last-packet flag', () {
      final d = VmPdu.data(1, Uint8List.fromList([0xAA, 0xBB]));
      expect(d.encode(), [0x04, 0x00, 0x03, 1, 0xAA, 0xBB]);
    });

    test('round-trips and parses fields', () {
      final cfm = VmPdu.decode([0x14, 0, 6, 3, 0x12, 0x34, 0x56, 0x78, 1])!;
      expect(cfm.opcode, UpOp.syncCfm);
      expect(cfm.syncResumePoint, 3); // POST_REBOOT
      final req = VmPdu.decode(
          [0x03, 0, 8, 0, 0, 0x04, 0, 0, 0, 0, 0])!;
      expect(req.dataBytesReq!.numBytes, 0x400);
    });

    test('rejects truncated PDUs', () {
      expect(VmPdu.decode([0x13, 0x00]), isNull);
      expect(VmPdu.decode([0x13, 0x00, 0x04, 0x12]), isNull);
    });
  });

  group('UpgradeMachine happy path', () {
    test('flashes, reassembles the exact image, and commits', () async {
      final img = _image(4096);
      final dev = FakeUpgradeDevice(imageLength: img.length, chunk: 20);
      final m = UpgradeMachine(
          transport: dev, image: img, phoneBatteryPercent: () async => 80);
      final ok = await m.run();
      expect(ok, isTrue);
      expect(dev.committed, isTrue);
      expect(dev.aborted, isFalse);
      expect(dev.received.toBytes(), img); // byte-exact
      expect(dev.syncFileIds.first, upgradeFileId);
      await m.dispose();
      await dev.close();
    });

    test('works when the device requests data in several batches', () async {
      final img = _image(10000);
      final dev = FakeUpgradeDevice(imageLength: img.length, chunk: 33, batch: 777);
      final m = UpgradeMachine(
          transport: dev, image: img, phoneBatteryPercent: () async => 80);
      expect(await m.run(), isTrue);
      expect(dev.received.toBytes(), img);
      await m.dispose();
      await dev.close();
    });

    test('polls validation while the device reports a delay', () async {
      final img = _image(512);
      final dev = FakeUpgradeDevice(
          imageLength: img.length, chunk: 64, validationDelays: 3);
      final m = UpgradeMachine(
          transport: dev, image: img, phoneBatteryPercent: () async => 80);
      expect(await m.run(), isTrue);
      expect(dev.committed, isTrue);
      await m.dispose();
      await dev.close();
    });
  });

  group('UpgradeMachine safety', () {
    test('refuses when the phone battery is low', () async {
      final img = _image(256);
      final dev = FakeUpgradeDevice(imageLength: img.length);
      final m = UpgradeMachine(
          transport: dev, image: img, phoneBatteryPercent: () async => 10);
      expect(await m.run(), isFalse);
      expect(dev.received.length, 0); // nothing sent
      await m.dispose();
      await dev.close();
    });

    test('refuses when the headphone battery is low', () async {
      final img = _image(256);
      final dev = FakeUpgradeDevice(imageLength: img.length, deviceBattery: 5);
      final m = UpgradeMachine(
          transport: dev, image: img, phoneBatteryPercent: () async => 90);
      expect(await m.run(), isFalse);
      await m.dispose();
      await dev.close();
    });

    test('dry run stops before any image data and aborts', () async {
      final img = _image(2048);
      final dev = FakeUpgradeDevice(imageLength: img.length);
      final m = UpgradeMachine(
          transport: dev,
          image: img,
          phoneBatteryPercent: () async => 90,
          dryRun: true);
      final ok = await m.run();
      expect(ok, isFalse); // dry run returns not-success
      expect(dev.received.length, 0); // no firmware bytes written
      expect(dev.aborted, isTrue);
      await m.dispose();
      await dev.close();
    });

    test('validation failure aborts (device rolls back)', () async {
      final img = _image(512);
      final dev = FakeUpgradeDevice(
          imageLength: img.length, chunk: 64, failValidation: true);
      final m = UpgradeMachine(
          transport: dev, image: img, phoneBatteryPercent: () async => 80);
      expect(await m.run(), isFalse);
      expect(dev.aborted, isTrue);
      expect(dev.committed, isFalse);
      await m.dispose();
      await dev.close();
    });

    test('a device error mid-transfer aborts', () async {
      final img = _image(4096);
      final dev = FakeUpgradeDevice(
          imageLength: img.length, chunk: 32, errorAtByte: 1000);
      final m = UpgradeMachine(
          transport: dev, image: img, phoneBatteryPercent: () async => 80);
      expect(await m.run(), isFalse);
      expect(dev.aborted, isTrue);
      await m.dispose();
      await dev.close();
    });

    test('resumes straight to commit when the device is post-reboot', () async {
      final img = _image(512);
      final dev = FakeUpgradeDevice(
          imageLength: img.length, startAtPostReboot: true);
      final m = UpgradeMachine(
          transport: dev, image: img, phoneBatteryPercent: () async => 80);
      expect(await m.run(), isTrue);
      expect(dev.committed, isTrue);
      expect(dev.received.length, 0); // no data re-sent
      await m.dispose();
      await dev.close();
    });
  });
}
