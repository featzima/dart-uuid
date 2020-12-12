library uuid;

import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:convert/convert.dart' show hex;
import 'package:crypto/crypto.dart' show sha1;

import 'uuid_util.dart';

class Uuid extends UnmodifiableUint8ListView {
  Uuid.fromBytes(Uint8List list) : super(list);

  /// Create an an UUID with all 0s, effectively equivalent to NAMESPACE_NIL
  factory Uuid.empty() => Uuid.fromBytes(Uint8List(16));

  factory Uuid.fromString(String input) {
    assert(input != null);

    final Uint8List bytes = Uint8List(16);
    input = input.toLowerCase();

    final RegExp regex = RegExp('[0-9a-f]{2}');
    final List<Match> matches = regex.allMatches(input).toList();
    // assert(matches.length >= 16);

    int i = 0;
    for (Match match in matches.take(16)) {
      final String hexString = input.substring(match.start, match.end);
      bytes[i] = hex.decode(hexString)[0];
      i++;
    }
    return Uuid.fromBytes(bytes);
  }

  /// Generates a time-based version 1 UUID
  ///
  /// By default it will generate a string based off current time.
  ///
  /// @todo explain options
  ///
  /// http://tools.ietf.org/html/rfc4122.html#section-4.2.2
  factory Uuid.fromTime({
    int? mSecs,
    int? nSecs,
    final int? clockSequence,
    Uint8List? node,
  }) {
    final Uint8List bytes = Uint8List(16);

    int clockSeq = clockSequence ?? _clockSeq;

    // UUID timestamps are 100 nano-second units since the Gregorian epoch,
    // (1582-10-15 00:00). Time is handled internally as 'msecs' (integer
    // milliseconds) and 'nsecs' (100-nanoseconds offset from msecs) since unix
    // epoch, 1970-01-01 00:00.
    mSecs ??= DateTime.now().millisecondsSinceEpoch;

    // Per 4.2.1.2, use count of uuid's generated during the current clock
    // cycle to simulate higher resolution clock
    nSecs ??= _lastNSecs + 1;

    // Time since last uuid creation (in msecs)
    final int dt = (mSecs - _lastMSecs) * 10000 + (nSecs - _lastNSecs);

    // Per 4.2.1.2, Bump clockseq on clock regression
    if (dt < 0 && clockSequence == null) {
      clockSeq = clockSeq + 1 & 0x3fff;
    }

    // Reset nsecs if clock regresses (clockseq) or we've moved onto a new
    // time interval
    if ((dt < 0 || mSecs > _lastMSecs) && nSecs == null) {
      nSecs = 0;
    }

    // Per 4.2.1.2 Throw error if too many uuids are requested
    if (nSecs >= 10000) {
      throw Exception('uuid.fromTime(): Can\'t create more than 10M uuids/sec');
    }

    _lastMSecs = mSecs;
    _lastNSecs = nSecs;
    _clockSeq = clockSeq;

    // Per 4.1.4 - Convert from unix epoch to Gregorian epoch
    mSecs += 12219292800000;

    // time Low
    final int timeLow = ((mSecs & 0xfffffff) * 10000 + nSecs) % 0x100000000;
    bytes[0] = timeLow >> 8 * 3 & 0xff;
    bytes[1] = timeLow >> 8 * 2 & 0xff;
    bytes[2] = timeLow >> 8 * 1 & 0xff;
    bytes[3] = timeLow >> 8 * 0 & 0xff;

    // time mid
    final int timeMidHigh = (mSecs ~/ 0x100000000 * 10000) & 0xfffffff;
    bytes[4] = timeMidHigh >> 8 * 1 & 0xff;
    bytes[5] = timeMidHigh >> 8 * 0 & 0xff;

    // time high and version
    bytes[6] = timeMidHigh >> 8 * 3 & 0xf | 0x10; // include version
    bytes[7] = timeMidHigh >> 8 * 2 & 0xff;

    // clockSeq high and reserved (Per 4.2.2 - include variant)
    bytes[8] = clockSeq >> 8 * 1 | 0x80;

    // clockSeq low
    bytes[9] = clockSeq >> 8 * 0 & 0xff;

    // node
    node ??= _nodeId;
    for (int n = 0; n < 6; n++) {
      bytes[10 + n] = node[n];
    }

    return Uuid.fromBytes(bytes);
  }

  /// Generates a RNG version 4 UUID
  ///
  /// By default it will generate a string based off mathRNG.
  /// If you wish to have crypto-strong RNG, pass in UuidUtil.cryptoRNG.
  ///
  /// http://tools.ietf.org/html/rfc4122.html#section-4.4
  factory Uuid.randomUuid({
    Uint8List? random,
  }) {
    // Use provided values over RNG
    random ??= UuidUtil.mathRNG();

    // per 4.4, set bits for version and clockSeq high and reserved
    random[6] = (random[6] & 0x0f) | 0x40;
    random[8] = (random[8] & 0x3f) | 0x80;
    return Uuid.fromBytes(random);
  }

  /// Generates a namspace & name-based version 5 UUID
  ///
  /// By default it will generate a string based on a provided uuid namespace and
  /// name, and will return a string.
  ///
  /// The first argument is an options map that takes various configuration
  /// options detailed in the readme.
  ///
  /// http://tools.ietf.org/html/rfc4122.html#section-4.4
  factory Uuid.fromName(
    // @non-nullable
    String name, {
    String? namespace,

    /// Check if user wants a random namespace generated by fromName() or a NIL namespace.
    bool randomNamespace = true,
  }) {
    // Use provided namespace, or use whatever is decided by options.
    // If randomNamespace is true, generate UUIDv4, else use NIL
    namespace ??=
        randomNamespace ? Uuid.randomUuid().toString() : NAMESPACE_NIL;

    // Convert namespace UUID to Byte List
    final Uint8List bytes = Uuid.fromString(namespace);

    // Convert name to a list of bytes
    final Uint8List nameBytes = Uint8List.fromList(name.codeUnits);

    // Generate SHA1 using namespace concatenated with name
    final Uint8List hashBytes =
        Uint8List.fromList(sha1.convert(bytes + nameBytes).bytes);

    // per 4.4, set bits for version and clockSeq high and reserved
    hashBytes[6] = (hashBytes[6] & 0x0f) | 0x50;
    hashBytes[8] = (hashBytes[8] & 0x3f) | 0x80;

    return Uuid.fromBytes(hashBytes);
  }

  // final Uint8List _list;

  @override
  bool operator ==(dynamic other) =>
      other is Uuid && _equality.equals(other, this);

  @override
  int get hashCode => _equality.hash(this);

  // RFC4122 provided namespaces for v3 and v5 namespace based UUIDs
  static const String NAMESPACE_DNS = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';
  static const String NAMESPACE_URL = '6ba7b811-9dad-11d1-80b4-00c04fd430c8';
  static const String NAMESPACE_OID = '6ba7b812-9dad-11d1-80b4-00c04fd430c8';
  static const String NAMESPACE_X500 = '6ba7b814-9dad-11d1-80b4-00c04fd430c8';
  static const String NAMESPACE_NIL = '00000000-0000-0000-0000-000000000000';

  static const ListEquality<int> _equality = ListEquality<int>();

// Sets initial seedBytes, node, and clock seq based on cryptoRNG.
  static final Uint8List _seedBytes = UuidUtil.cryptoRNG();

  static int _lastMSecs = 0;
  static int _lastNSecs = 0;
  // Per 4.2.2, randomize (14 bit) clockseq
  static int _clockSeq = (_seedBytes[6] << 8 | _seedBytes[7]) & 0x3ffff;

// Per 4.5, create a 48-bit node id (47 random bits + multicast bit = 1)
  static final Uint8List _nodeId = Uint8List.fromList(<int>[
    _seedBytes[0] | 0x01,
    _seedBytes[1],
    _seedBytes[2],
    _seedBytes[3],
    _seedBytes[4],
    _seedBytes[5]
  ]);

  // @todo implement this
  bool get isFromTime {
    return true;
  }

  int get millisecondsSinceEpoch {
    return (this[0] << 8 * 3) +
        (this[1] << 8 * 2) +
        (this[2] << 8 * 1) +
        (this[3] << 8 * 0);
  }

  int get clockSequence {
    return (this[8] << 8) + this[9];
  }

  /// outputs a proper UUID string.
  @override
  String toString() {
    return <List<int>>[
      sublist(0, 4),
      sublist(4, 6),
      sublist(6, 8),
      sublist(8, 10),
      sublist(10, 16),
    ].map((List<int> e) => hex.encode(e)).join('-');
  }
}
