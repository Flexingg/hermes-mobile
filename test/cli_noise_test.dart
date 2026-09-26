import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/core/util/cli_noise.dart';

/// The exact reply from the screenshot: Hermes' CLI banner, streamed into the
/// transcript as if the assistant had said it.
const screenshotReply = '''
Session 20260926_115626_c2787f found but has no messages. Starting fresh.
🔗 attaching 1 image(s) natively (model supports vision):
ac095b29_scaled_f3138f07-172d-4995-b35a-382046529d496367632180177757070.jpg
Resume this session with:
 hermes --resume 20260926_115626_c2787f
 hermes -c "Assistant"
Title:    Assistant
Duration: 19s
Messages: 2 (1 user, 0 tool calls)
''';

void main() {
  group('isPlumbingLine', () {
    test('recognises the lines that leaked into the Assistant screenshot', () {
      for (final line in [
        'Session 20260926_115626_c2787f found but has no messages. Starting fresh.',
        '🔗 attaching 1 image(s) natively (model supports vision):',
        'Resume this session with:',
        ' hermes --resume 20260926_115626_c2787f',
        ' hermes -c "Assistant"',
        'Title:    Assistant',
        'Duration: 19s',
        'Messages: 2 (1 user, 0 tool calls)',
        'Session: 20260926_115626_c2787f',
        'Query: what did I eat today',
        'Initializing agent...',
        'Assistant · 19s',
      ]) {
        expect(isPlumbingLine(line), isTrue, reason: line);
      }
    });

    test('leaves the agent\'s actual words alone', () {
      for (final line in [
        'You have 1,310 kcal left today.',
        'The session I looked at had 12 messages.',
        '- Title: a heading in markdown',
        'Duration is not something I can change.',
        '',
        '   ',
      ]) {
        expect(isPlumbingLine(line), isFalse, reason: line);
      }
    });

    test('strips ANSI colour codes before deciding', () {
      expect(isPlumbingLine('\x1b[36mSession: abc\x1b[0m'), isTrue);
    });
  });

  group('stripPlumbing', () {
    test('removes the banner and keeps nothing but the answer', () {
      final cleaned = stripPlumbing('Here is what I found.\n$screenshotReply');
      expect(cleaned, 'Here is what I found.');
      expect(cleaned.contains('Resume this session'), isFalse);
    });

    test('a normal reply is untouched', () {
      const reply = 'Two things:\n\n1. Fasting\n2. Sleep';
      expect(stripPlumbing(reply), reply);
    });

    test('plumbingLines names what was dropped', () {
      final dropped = plumbingLines(screenshotReply);
      expect(dropped, contains('Title:    Assistant'));
      expect(dropped.length, 9);
    });
  });

  group('parseSessionMeta', () {
    test('pulls the session facts out of the banner', () {
      final meta = parseSessionMeta(screenshotReply);
      expect(meta['sessionId'], '20260926_115626_c2787f');
      expect(meta['title'], 'Assistant');
      expect(meta['duration'], '19s');
      expect(meta['messages'], '2 (1 user, 0 tool calls)');
      expect(meta['resumeCommand'], 'hermes --resume 20260926_115626_c2787f');
      expect(meta['note'], contains('started fresh'));
    });

    test('a reply with no banner yields nothing to show', () {
      expect(parseSessionMeta('Just an answer.'), isEmpty);
    });
  });
}
