import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openhd350b/core/gaia/gaia_frame.dart';
import 'package:openhd350b/core/hex.dart';

void main() {
  group('GaiaV2Codec — real HD 350BT bytes (fw 5.8.0)', () {
    const codec = GaiaV2Codec();

    test('encodes a command', () {
      expect(toHex(codec.encodeCommand(0x000A, 0x0302)), '00 0A 03 02');
      expect(
        toHex(codec.encodeCommand(0x000A, 0x4001, Uint8List.fromList([5]))),
        '00 0A 40 01 05',
      );
    });

    test('decodes GetApiVersion ack', () {
      final m = codec.decode(fromHex('000A 8300 00 010205'))!;
      expect(m.type, GaiaPacketType.response);
      expect(m.vendorId, 0x000A);
      expect(m.commandId, 0x0300);
      expect(m.status, 0);
      expect(m.payload, [1, 2, 5]);
    });

    test('decodes GetBatteryLevel ack (millivolts)', () {
      final m = codec.decode(fromHex('000A 8302 00 103E'))!;
      expect((m.payload[0] << 8) | m.payload[1], 4158);
    });

    test('decodes GetApplicationVersion ack', () {
      final m = codec.decode(
        fromHex('000A 8304 00 0001000A0160FFFF0000000000353830'),
      )!;
      expect(
        String.fromCharCodes(m.payload.sublist(m.payload.length - 3)),
        '580',
      );
    });

    test('non-zero status is an error', () {
      final m = codec.decode(fromHex('000A 8300 01'))!;
      expect(m.type, GaiaPacketType.error);
      expect(m.status, 1);
    });

    test('event notification', () {
      final m = codec.decode(fromHex('000A 4003 07 2A'))!;
      expect(m.type, GaiaPacketType.notification);
      expect(m.payload, [7, 0x2A]);
    });

    test('request and ack share a key', () {
      final req = codec.decode(codec.encodeCommand(0x000A, 0x0302))!;
      final ack = codec.decode(fromHex('000A 8302 00 103E'))!;
      expect(req.key, ack.key);
    });

    test('rejects malformed input', () {
      expect(codec.decode([0, 0x0A, 0x83]), isNull);
      expect(codec.decode(fromHex('000A 8302')), isNull); // ack w/o status
      expect(() => codec.encodeCommand(0, 0x8000), throwsRangeError);
    });
  });

  group('GaiaV3Codec', () {
    const codec = GaiaV3Codec();

    test('packs feature/type/command into the header', () {
      final id = GaiaV3Codec.combine(0x03, 0x05);
      // desc = 3<<9 | 0<<7 | 5 = 0x0605
      expect(
        toHex(codec.encodeCommand(0x001D, id, Uint8List.fromList([0xAA]))),
        '00 1D 06 05 AA',
      );
    });

    test('round-trips each packet type', () {
      final id = GaiaV3Codec.combine(0x7F, 0x7F);
      for (final t in GaiaPacketType.values) {
        final m = codec.decode(
          codec.encode(0x1234, id, t, Uint8List.fromList([9])),
        )!;
        expect(m.type, t);
        expect(m.commandId, id);
      }
    });

    test('error packets expose status', () {
      final m = codec.decode(fromHex('001D 0180 05'))!;
      expect(m.type, GaiaPacketType.error);
      expect(m.status, 5);
    });
  });

  test('max payload accounts for ATT and GAIA headers', () {
    expect(const GaiaV2Codec().maxPayloadForMtu(64), 57);
  });

  group('hex', () {
    test('accepts common separators and 0x prefixes', () {
      expect(fromHex('0x00, 0x1d'), [0x00, 0x1D]);
      expect(fromHex('00:1D-06 05'), [0, 0x1D, 6, 5]);
    });
    test('rejects bad input', () {
      expect(() => fromHex('abc'), throwsFormatException);
      expect(() => fromHex('zz'), throwsFormatException);
    });
  });
}
