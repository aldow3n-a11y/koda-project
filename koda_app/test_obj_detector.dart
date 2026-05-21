import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';

void main() {
  final options = ObjectDetectorOptions(
    mode: DetectionMode.stream,
    classifyObjects: false,
    multipleObjects: false,
  );
  final detector = ObjectDetector(options: options);
  print(detector);
}
