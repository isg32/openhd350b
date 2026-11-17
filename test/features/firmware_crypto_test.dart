import 'package:flutter_test/flutter_test.dart';
import 'package:openhd350b/core/hex.dart';
import 'package:openhd350b/features/firmware/firmware_crypto.dart';

void main() {
  // Golden vector: the first 48 bytes of the real HD 350BT 5.8.0 package
  // (HD350BT_firmware_v580_DFU.bin.zip.enc) and its AES-256-CTR plaintext,
  // which is a ZIP ("PK\x03\x04") naming the firmware image. CTR is a stream
  // cipher, so decrypting a prefix yields the correct prefix.
  const encHex =
      '7a2a112923ac6fc42ba62124c9634eeb31fd8400a33a9080'
      'bfd70acb556f13df20622fb45c021ef5962d862eef5c5f34';
  const decHex =
      '504b0304140008080800c3444e55000000000000000000000000'
      '1d000000484433353042545f6669726d776172655f76';

  test('decrypts the real HD 350BT package prefix to a ZIP header', () {
    final out = FirmwareCrypto.decrypt(fromHex(encHex));
    expect(toHex(out.sublist(0, decHex.length ~/ 2)), toHex(fromHex(decHex)));
    // sanity: starts with the PK zip magic
    expect(out.sublist(0, 4), [0x50, 0x4B, 0x03, 0x04]);
  });

  test('round-trips (CTR is symmetric)', () {
    final enc = fromHex(encHex);
    final dec = FirmwareCrypto.decrypt(enc);
    final reEnc = FirmwareCrypto.decrypt(dec);
    expect(reEnc, enc);
  });
}
