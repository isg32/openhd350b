import 'package:flutter_test/flutter_test.dart';
import 'package:opensennheiser/core/hex.dart';
import 'package:opensennheiser/features/equalizer/eq_engine.dart';

void main() {
  const eq = Hd350EqEngine();

  group('customEqParams', () {
    test('neutral bands give the known 0x021B array', () {
      // Hand-derived from Eq3Band.generateCommandParamsFromBandGains([0,0,0]).
      expect(eq.customEqParams([0, 0, 0]), [
        9, 257, 0, 272, 10, 273, 840, 274, 0, 275, 2896, //
        288, 11, 289, 4800, 290, 0, 291, 2896, 0,
      ]);
    });

    test('bass-boost switches the low-shelf frequency to 150 Hz', () {
      // index 6 is 3 * lowFreq: 3*280=840 off, 3*150=450 on.
      expect(eq.customEqParams([0, 0, 0])[6], 840);
      expect(eq.customEqParams([0, 0, 0], bassBoost: true)[6], 450);
    });

    test('shelf gains are relative to the mid band', () {
      // bands [3,0,-3] → smooth centres on mean 0, within gainLimit.
      final p = eq.customEqParams([3, 0, -3]);
      expect(p[8], 60 * (3 - 0)); // bass shelf (index 8): bass - mid = 180
      expect(
        p[16],
        60 * (-3 - 0),
      ); // treble shelf (index 16): treble - mid = -180
    });

    test('packs a negative shelf gain as two-complement big-endian u16', () {
      final p = eq.customEqParams([-6, 0, 0]); // bass far below mid
      expect(p[8], lessThan(0)); // bass shelf is negative
      // -360 & 0xFFFF = 0xFE98
      expect(toHex(Hd350EqEngine.packU16([p[8]])), 'FE 98');
    });
  });

  group('knob codec round-trips', () {
    test('neutral encodes to x=0, y=0x4000', () {
      final k = eq.encodeKnobs([0, 0, 0]);
      expect(k.x, 0);
      expect(k.y, 0x4000);
    });

    test('decode(encode(bands)) recovers the bands', () {
      for (final bands in [
        [0.0, 0.0, 0.0],
        [6.0, -6.0, 3.0],
        [-3.0, 1.5, 4.5],
      ]) {
        final k = eq.encodeKnobs(bands, bassBoost: false);
        final back = eq.decodeKnobs(k.x, k.y)!;
        for (var i = 0; i < 3; i++) {
          // within one quantisation step (maxGain/127 ≈ 0.047 dB)
          expect(
            (back.bands[i] - bands[i]).abs(),
            lessThan(0.1),
            reason: 'band $i of $bands',
          );
        }
      }
    });

    test('bass-boost flag survives encode/decode', () {
      final k = eq.encodeKnobs([2, 0, 0], bassBoost: true);
      expect(eq.decodeKnobs(k.x, k.y)!.bassBoost, isTrue);
    });

    test('legacy/unconfigured storage decodes to null', () {
      // y without the new-storage bit set.
      expect(eq.decodeKnobs(0, 0), isNull);
      expect(eq.decodeKnobs(0, 0xFF00), isNull);
    });
  });

  group('smooth', () {
    test('neutral stays neutral', () {
      expect(eq.smooth([0, 0, 0]), [0, 0, 0]);
    });
    test('pulls loudest band down to the gain limit', () {
      final out = eq.smooth([6, 6, 6]); // mean 6 → [0,0,0], none over limit
      expect(out, [0, 0, 0]);
    });
  });

  test('clip respects min/max gain', () {
    expect(const Hd350EqEngine().clip([-10, 0, 10]), [-6, 0, 6]);
  });
}
