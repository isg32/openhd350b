import 'dart:typed_data';

/// 3-band equalizer math for the HD 350BT, ported verbatim from Smart Control
/// 4.7.0 (`Eq3Band` + `EqKnobValuesCoder` in bundle.js). The HD 350 does not
/// use the 5-band path — it falls back to this 3-band bass/mid/treble model.
///
/// Sliders are bass, mid, treble in dB, each clipped to [minGain, maxGain].
/// Applying the EQ sends the shelf-filter parameters via `Sound_SetCustomEQ`
/// (`0x021B`) and stores a compact form in the two EQ knobs
/// (`Sound_SetCustomEQKnob`, index 0 = X, 1 = Y).
class Hd350EqParams {
  const Hd350EqParams({
    this.minGain = -6,
    this.maxGain = 6,
    this.gainLimit = 4,
    this.bassBoost = 5,
    this.bassBoostFrequency = 150,
    this.lowerMidFrequency = 280,
    this.upperMidFrequency = 1600,
  });

  final double minGain;
  final double maxGain;
  final double gainLimit;

  /// dB added to the bass band when bass-boost is on.
  final double bassBoost;
  final int bassBoostFrequency;
  final int lowerMidFrequency;
  final int upperMidFrequency;
}

/// The three UI bands, matching the official app's labels/centre frequencies.
const eqBandLabels = ['Bass', 'Mid', 'Treble'];
const eqBandFrequencies = [50, 1000, 8000];

/// Encoded X/Y knob values the device stores for an EQ setting.
class EqKnobValues {
  const EqKnobValues(this.x, this.y);
  final int x;
  final int y;
}

class Hd350EqEngine {
  const Hd350EqEngine([this.params = const Hd350EqParams()]);
  final Hd350EqParams params;

  // Bit masks from EqKnobValuesCoder.
  static const _maskNewStorage = 0x4000; // 16384
  static const _maskOldClassic = 0xFF00; // 65280
  static const _maskClassicEq = 0x2000; // 8192
  static const _maskBassBoost = 0x1000; // 4096
  static const _maskPeakFilter = 0x0800; // 2048

  List<double> clip(List<double> gains) => gains
      .map((g) => g.clamp(params.minGain, params.maxGain).toDouble())
      .toList();

  /// JS `Math.trunc` — truncate toward zero.
  int _trunc(num v) => v.toInt();

  /// JS 2-decimal rounding (`parseFloat(v.toFixed(2))`).
  double _fixed2(double v) => (v * 100).round() / 100;

  /// Centres the three gains on their mean, then pulls everything down so the
  /// loudest band never exceeds [Hd350EqParams.gainLimit] (headroom guard).
  List<double> smooth(List<double> gains) {
    var b = gains[0], m = gains[1], t = gains[2];
    final mean = (b + m + t) / 3;
    b -= mean;
    m -= mean;
    t -= mean;
    final over =
        [b, m, t, params.gainLimit].reduce((a, c) => a > c ? a : c) -
        params.gainLimit;
    return [b - over, m - over, t - over];
  }

  /// Builds the `Sound_SetCustomEQ` (0x021B) parameter array for the given
  /// bands. Pass [bassBoost] to apply the bass-boost offset + low-shelf
  /// frequency, exactly as the app does inside `send()`.
  List<int> customEqParams(List<double> bands, {bool bassBoost = false}) {
    var gains = [...bands];
    if (bassBoost) gains[0] += params.bassBoost;
    gains = smooth(gains);
    final b = gains[0], m = gains[1], t = gains[2];

    // `425 === trunc(100*mid)` → the device would convert 4.25 to 0xff; the
    // app nudges it to 4.24.
    var master = m;
    if (_trunc(100 * master) == 425) master = 4.24;

    final lowFreq = bassBoost
        ? params.bassBoostFrequency
        : params.lowerMidFrequency;
    return [
      9,
      257,
      _trunc(60 * master),
      272,
      10,
      273,
      _trunc(3 * lowFreq),
      274,
      _trunc(60 * (b - m)),
      275,
      2896,
      288,
      11,
      289,
      _trunc(3 * params.upperMidFrequency),
      290,
      _trunc(60 * (t - m)),
      291,
      2896,
      0,
    ];
  }

  /// Encodes bands into the stored X/Y knob values (`EqKnobValuesCoder`).
  EqKnobValues encodeKnobs(
    List<double> bands, {
    bool bassBoost = false,
    bool peakFilter = false,
  }) {
    final r = params.maxGain;
    final s = bands.map(_fixed2).toList();
    final x =
        (_trunc(s[0] / r * 127) & 0xFF) |
        ((_trunc(s[1] / r * 127) & 0xFF) << 8);
    var y = _trunc(s[2] / r * 127) & 0xFF;
    y |= _maskNewStorage;
    if (bassBoost) y |= _maskBassBoost;
    if (peakFilter) y |= _maskPeakFilter;
    return EqKnobValues(x & 0xFFFF, y & 0xFFFF);
  }

  /// Decodes stored X/Y knob values back into bands + bass-boost flag. Returns
  /// null when the device holds a legacy/unconfigured value (the app then
  /// resets to neutral).
  ({List<double> bands, bool bassBoost})? decodeKnobs(int x, int y) {
    if ((y & _maskOldClassic) == _maskOldClassic ||
        (y & _maskNewStorage) != _maskNewStorage) {
      return null; // old storage → caller resets to neutral
    }
    var yy = y & ~_maskNewStorage;
    if ((yy & _maskClassicEq) == _maskClassicEq) yy &= ~_maskClassicEq;
    final bassBoost = (yy & _maskBassBoost) == _maskBassBoost;
    if (bassBoost) yy &= ~_maskBassBoost;
    if ((yy & _maskPeakFilter) == _maskPeakFilter) yy &= ~_maskPeakFilter;

    double band(int raw) {
      final signed = raw > 128 ? raw - 256 : raw;
      return _fixed2(signed / 127 * params.maxGain);
    }

    return (
      bands: [band(x & 0xFF), band((x >> 8) & 0xFF), band(yy & 0xFF)],
      bassBoost: bassBoost,
    );
  }

  /// Packs a UINT16 parameter array big-endian for a GAIA v2 payload.
  static Uint8List packU16(List<int> values) {
    final out = Uint8List(values.length * 2);
    final view = ByteData.sublistView(out);
    for (var i = 0; i < values.length; i++) {
      view.setUint16(i * 2, values[i] & 0xFFFF);
    }
    return out;
  }

  /// Payload for a `Sound_SetCustomEQKnob` write: UINT16 index, UINT16 value.
  static Uint8List knobPayload(int index, int value) => packU16([index, value]);
}
