import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import '../models/models.dart';

class ObjectTrackerService {
  ObjectDetector? _objectDetector;

  ObjectDetector _getDetector() {
    return _objectDetector ??= ObjectDetector(
      options: ObjectDetectorOptions(
        mode: DetectionMode.single,
        classifyObjects: false,
        multipleObjects: false,
      ),
    );
  }

  bool _isBusy = false;
  DateTime _lastProcessedTime = DateTime.now();

  Future<void> processFrame(
    CameraImage image,
    CameraDescription camera,
    void Function(ObjectTrackingData? data) onObjectDetected,
  ) async {
    // 1. Throttle: Only process at max 10 FPS (every 100ms) to keep S21 cool and conserve battery
    final now = DateTime.now();
    if (now.difference(_lastProcessedTime).inMilliseconds < 100) {
      return;
    }

    // 2. Lock guard: prevent concurrent processing if detection takes longer than frame interval
    if (_isBusy) return;
    _isBusy = true;
    _lastProcessedTime = now;

    try {
      final inputImage = _inputImageFromCameraImage(image, camera);
      if (inputImage == null) {
        _isBusy = false;
        return;
      }

      final objects = await _getDetector().processImage(inputImage);

      if (objects.isEmpty) {
        onObjectDetected(null);
      } else {
        // Track the first prominent object
        final obj = objects.first;
        
        final rotation = inputImage.metadata?.rotation ?? InputImageRotation.rotation0deg;
        final double imageWidth = inputImage.metadata?.size.width ?? image.width.toDouble();
        final double imageHeight = inputImage.metadata?.size.height ?? image.height.toDouble();

        // Align coordinates based on device rotation
        final double viewWidth = (rotation == InputImageRotation.rotation90deg || rotation == InputImageRotation.rotation270deg)
            ? imageHeight
            : imageWidth;
        final double viewHeight = (rotation == InputImageRotation.rotation90deg || rotation == InputImageRotation.rotation270deg)
            ? imageWidth
            : imageHeight;

        final double cx = obj.boundingBox.left + obj.boundingBox.width / 2;
        final double cy = obj.boundingBox.top + obj.boundingBox.height / 2;

        // Calculate area ratio
        final double objArea = obj.boundingBox.width * obj.boundingBox.height;
        final double totalArea = viewWidth * viewHeight;
        final double areaRatio = (totalArea > 0) ? (objArea / totalArea) : 0.0;

        // Normalize to [-1.0, 1.0] range
        double dx = (cx / viewWidth) * 2.0 - 1.0;
        double dy = (cy / viewHeight) * 2.0 - 1.0;

        // Mirror horizontal axis if it's the front camera so the eyes look in the correct direction
        final isFront = camera.lensDirection == CameraLensDirection.front;
        if (isFront) {
          dx = -dx;
        }

        dx = dx.clamp(-1.0, 1.0);
        dy = dy.clamp(-1.0, 1.0);

        // Map to Koda face lookOffset limits (-12.0 to 12.0 for X, -6.0 to 6.0 for Y)
        final targetOffset = Offset(dx * 12.0, dy * 6.0);
        onObjectDetected(ObjectTrackingData(targetOffset, areaRatio));
      }
    } catch (e) {
      debugPrint('Object tracking error: $e');
    } finally {
      _isBusy = false;
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image, CameraDescription camera) {
    try {
      final sensorOrientation = camera.sensorOrientation;
      final rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
      if (rotation == null) return null;

      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      if (format == null) return null;

      if (image.planes.isEmpty) return null;

      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      final metadata = InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes[0].bytesPerRow,
      );

      return InputImage.fromBytes(bytes: bytes, metadata: metadata);
    } catch (e) {
      debugPrint('Error converting CameraImage to InputImage: $e');
      return null;
    }
  }

  void dispose() {
    _objectDetector?.close();
  }
}
