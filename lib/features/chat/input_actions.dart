import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../../data/app_repository.dart';
import '../../data/models.dart';

/// Input actions shared by the chat composer and the floating assistant bar.
///
/// Both surfaces must behave the same way — on-device speech recognition that
/// only ever produces text, and a picked photo that goes through
/// [AppRepository.uploadAttachment] — so the logic lives here once instead of
/// being forked into each widget.

/// Tap-to-talk speech recognition. Recognition runs on the device through the
/// platform recognizer; only the transcript is handed back, no audio is kept
/// or uploaded.
class VoiceInputController extends ChangeNotifier {
  stt.SpeechToText? _speech;
  bool _listening = false;
  bool _disposed = false;

  bool get listening => _listening;

  void _setListening(bool value) {
    if (_listening == value || _disposed) return;
    _listening = value;
    notifyListeners();
  }

  /// Starts listening, or stops if already listening. [onWords] receives the
  /// running transcript. Returns false when speech recognition is unavailable
  /// (no recognizer, or the microphone permission was not granted).
  Future<bool> toggle(void Function(String words) onWords) async {
    _speech ??= stt.SpeechToText();
    if (_listening) {
      await _speech!.stop();
      _setListening(false);
      return true;
    }
    final available = await _speech!.initialize(
        onStatus: (s) {
          if (s == 'done' || s == 'notListening') _setListening(false);
        },
        onError: (_) => _setListening(false));
    if (!available) return false;
    _setListening(true);
    await _speech!.listen(
      onResult: (r) {
        final w = r.recognizedWords;
        if (w.isNotEmpty) onWords(w);
      },
      listenOptions: stt.SpeechListenOptions(
        localeId: 'en_US',
        listenFor: const Duration(seconds: 20),
      ),
    );
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    _speech?.stop();
    super.dispose();
  }
}

/// A local file the user picked, ready to be uploaded to the bridge.
class LocalUpload {
  final String localPath;
  final String name;
  final String mimeType;
  const LocalUpload({
    required this.localPath,
    required this.name,
    required this.mimeType,
  });
}

/// Asks [picker] for a photo from [source]. Null when the user backs out.
Future<LocalUpload?> pickImage(ImagePicker picker, ImageSource source) async {
  final picked = await picker.pickImage(source: source, maxWidth: 2048);
  if (picked == null) return null;
  return LocalUpload(
      localPath: picked.path,
      name: p.basename(picked.path),
      mimeType: 'image/jpeg');
}

/// Uploads a picked file so the agent can use it.
Future<Attachment> uploadPicked(AppRepository repo, LocalUpload file) =>
    repo.uploadAttachment(
        localPath: file.localPath, name: file.name, mimeType: file.mimeType);

/// Takes a photo and uploads it. Null when the user cancels the camera.
Future<Attachment?> captureAndUpload(AppRepository repo,
    {ImagePicker? picker}) async {
  final file = await pickImage(picker ?? ImagePicker(), ImageSource.camera);
  if (file == null) return null;
  return uploadPicked(repo, file);
}

/// Best-effort MIME type from a file name, for files that come from the
/// generic file picker (which doesn't report one).
String guessMime(String name) {
  final ext = p.extension(name).toLowerCase();
  const m = <String, String>{
    '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
    '.gif': 'image/gif', '.webp': 'image/webp',
    '.pdf': 'application/pdf', '.txt': 'text/plain', '.md': 'text/markdown',
    '.json': 'application/json', '.csv': 'text/csv',
    '.doc': 'application/msword', '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    '.xls': 'application/vnd.ms-excel', '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    '.zip': 'application/zip', '.apk': 'application/vnd.android.package-archive',
  };
  return m[ext] ?? 'application/octet-stream';
}
