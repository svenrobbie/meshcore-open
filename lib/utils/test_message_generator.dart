import 'dart:math';
import 'dart:typed_data';

const int randomTestSenderNameLength = 16;
const int randomTestSenderNameMaxBytes = randomTestSenderNameLength;
const int randomTestMessageMaxBytes = 49;

const String _senderAlphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

/// Short Watch Dogs 2 lines used as synthetic test-message content.
const List<String> _dedSecQuotes = [
  'DedSec has given you the truth, do what you will.',
  'Wait, you want me to get you two coffee?',
  'We are DedSec.',
];

/// Selects a short Watch Dogs 2 quote for a synthetic test packet.
String randomTestMessage(Random random) {
  return _dedSecQuotes[random.nextInt(_dedSecQuotes.length)];
}

/// Generates a 16-character alphanumeric display name for group test packets.
/// Group text has no sender public key, so the sender is identified by this
/// text prefix.
String randomTestSenderName(Random random) {
  return List<String>.generate(
    randomTestSenderNameLength,
    (_) => _senderAlphabet[random.nextInt(_senderAlphabet.length)],
  ).join();
}

/// Replaces path bytes with random bytes while keeping the same length and
/// therefore the same hop count. An empty template stays a flood.
Uint8List randomTestPath(Uint8List template, Random random) {
  if (template.isEmpty) return Uint8List(0);
  return Uint8List.fromList(
    List<int>.generate(template.length, (_) => random.nextInt(256)),
  );
}
