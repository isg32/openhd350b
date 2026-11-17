import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openhd350b/core/gaia/gaia_client.dart';
import 'package:openhd350b/core/gaia/gaia_constants.dart';
import 'package:openhd350b/core/gaia/gaia_frame.dart';
import 'package:openhd350b/core/hex.dart';
import 'package:openhd350b/core/transport/fake_transport.dart';

/// Replays the replies a real HD 350BT (fw 5.8.0) gave on 2026-11-16.
List<Uint8List> hd350(Uint8List w) {
  const replies = {
    '00 0A 03 00': '000A830000010205',
    '00 0A 03 01': '000A830100D2',
    '00 0A 03 02': '000A830200103E',
    '00 0A 03 04': '000A8304000001000A0160FFFF0000000000353830',
  };
  final r = replies[toHex(w)];
  return r == null ? const [] : [fromHex(r)];
}

void main() {
  late FakeGaiaTransport transport;
  late GaiaClient client;

  setUp(() async {
    transport = FakeGaiaTransport(responder: hd350, mtu: 64);
    await transport.connect();
    client = GaiaClient(transport);
  });

  tearDown(() => client.dispose());

  test('reads API version from replayed HD 350BT', () async {
    final rsp = await client.send('V2_GetApiVersion');
    expect(rsp.payload, [1, 2, 5]);
    expect(transport.written.single, [0x00, 0x0A, 0x03, 0x00]);
  });

  test('reads battery millivolts and RSSI', () async {
    final batt = await client.send('V2_GetBatteryLevel');
    expect((batt.payload[0] << 8) | batt.payload[1], 4158);
    final rssi = await client.send('V2_GetCurrentRssi');
    expect(rssi.payload[0] - 256, -46);
  });

  test('matches concurrent requests to the right replies', () async {
    final results = await Future.wait([
      client.send('V2_GetBatteryLevel'),
      client.send('V2_GetApiVersion'),
    ]);
    expect(results[0].commandId, 0x0302);
    expect(results[1].commandId, 0x0300);
  });

  test('non-zero status throws GaiaErrorResponse', () async {
    transport.responder = (_) => [fromHex('000A 8300 01')];
    await expectLater(
      client.send('V2_GetApiVersion'),
      throwsA(
        isA<GaiaErrorResponse>().having((e) => e.message.status, 'status', 1),
      ),
    );
  });

  test('times out when the device stays silent', () async {
    transport.responder = (_) => const [];
    await expectLater(
      client.send(
        'V2_GetApiVersion',
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('refuses unresolved commands', () {
    expect(
      () => client.send('Battery_Percent'),
      throwsA(isA<UnsendableCommandException>()),
    );
    expect(transport.written, isEmpty);
  });

  test('refuses commands for the other protocol', () {
    expect(
      () => client.send('Core_GetApiVersion', allowCandidate: true),
      throwsA(isA<UnsendableCommandException>()),
    );
  });

  test('refuses candidates without allowCandidate', () {
    expect(
      () => client.send('V2_RegisterNotification'),
      throwsA(isA<UnsendableCommandException>()),
    );
  });

  test('refuses destructive commands until verified', () {
    expect(
      () => client.send('V2_VmUpgradeConnect', allowCandidate: true),
      throwsA(isA<UnsendableCommandException>()),
    );
    expect(
      () => client.send('Service_FactoryReset', allowCandidate: true),
      throwsA(isA<UnsendableCommandException>()),
    );
  });

  test('routes event notifications separately', () async {
    final next = client.notifications.first;
    transport.inject(fromHex('000A 4003 07 2A'));
    final n = await next;
    expect(n.payload, [7, 0x2A]);
  });

  test('logs both directions, including unparseable bytes', () async {
    final logged = <PduLogEntry>[];
    final sub = client.log.listen(logged.add);
    await client.send('V2_GetApiVersion');
    transport.inject(Uint8List.fromList([0x01]));
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(logged.map((e) => e.direction), [
      PduDirection.tx,
      PduDirection.rx,
      PduDirection.rx,
    ]);
    expect(logged.last.message, isNull);
  });

  test('v3 client uses v3 framing', () async {
    final t3 = FakeGaiaTransport(protocol: GaiaProtocol.v3);
    await t3.connect();
    final c3 = GaiaClient(t3);
    t3.responder = (w) => [
      const GaiaV3Codec().encode(
        0x001D,
        0x00,
        GaiaPacketType.response,
        Uint8List(1),
      ),
    ];
    await c3.send('Core_GetApiVersion', allowCandidate: true);
    expect(t3.written.single, [0x00, 0x1D, 0x00, 0x00]);
    await c3.dispose();
  });
}
