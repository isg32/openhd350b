import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Decrypts a Sennheiser firmware `*.zip.enc` package.
///
/// The cipher and key are hardcoded in Smart Control 4.7.0, so the `.enc` is
/// only transport obfuscation — AES-256-CTR, key below, 128-bit counter whose
/// initial value is 5 (big-endian). Verified byte-for-byte against the real
/// HD 350BT 5.8.0 package. The decrypted image is still signed and validated
/// on-chip at install time; decrypting it lets you study it, not forge one.
class FirmwareCrypto {
  static final Uint8List _key = Uint8List.fromList([
    0xed, 0x3b, 0x78, 0xa4, 0x74, 0xc2, 0xac, 0xab, //
    0xb8, 0x12, 0x40, 0x7b, 0x97, 0x06, 0x56, 0x49,
    0xbf, 0x19, 0x0e, 0x3d, 0x75, 0x8e, 0x86, 0xf1,
    0x7b, 0x92, 0x0a, 0xa4, 0x1d, 0x8c, 0x27, 0x1e,
  ]);

  /// 128-bit big-endian counter block with initial value 5.
  static Uint8List _initialCounter() {
    final iv = Uint8List(16);
    iv[15] = 5;
    return iv;
  }

  static Uint8List decrypt(Uint8List enc) {
    final cipher = CTRStreamCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(_key), _initialCounter()));
    return cipher.process(enc);
  }
}
