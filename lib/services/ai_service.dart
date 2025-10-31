import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:uuid/uuid.dart';

// --- ISOLATE ENTRY POINT ---
// This function runs in a separate isolate to avoid blocking the UI thread.
Future<Uint8List?> applyColorInIsolate(Map<String, dynamic> params) async {
  final int interpreterAddress = params['interpreterAddress'];
  final img.Image originalImage = params['image'];
  final Color targetColor = Color(params['colorValue']);
  final AIServiceConfig config = params['config'];

  // Create a temporary service and interpreter for this background task
  final service = AIService(config: config);
  service.interpreter = Interpreter.fromAddress(interpreterAddress);

  // Run the heavy hair color logic
  final img.Image? processedImage =
      service._applyHairColor(originalImage, targetColor);
  if (processedImage == null) {
    return null;
  }

  // Encode the result to JPG bytes
  final List<int> encoded =
      img.encodeJpg(processedImage, quality: config.outputJpegQuality);
  return Uint8List.fromList(encoded);
}

class AIServiceConfig {
  const AIServiceConfig({
    this.enableGpuDelegate = true,
    this.cpuThreads = 2,
    this.maskBlurRadius = 0, // Disabled for major performance gain
    this.maskAlphaCutoff = 0.15,
    this.outputJpegQuality = 80,
  }) : assert(cpuThreads >= 1, 'cpuThreads must be greater than or equal to 1');

  final bool enableGpuDelegate;
  final int cpuThreads;
  final int maskBlurRadius;
  final double maskAlphaCutoff;
  final int outputJpegQuality;
}

class AIService {
  AIService({AIServiceConfig config = const AIServiceConfig()}) : _config = config;

  Interpreter? interpreter;
  static const int _inputSize = 256;
  final AIServiceConfig _config;

  // Public getters for isolate parameters
  int get interpreterAddress => interpreter?.address ?? 0;
  AIServiceConfig get config => _config;

  Future<bool> loadModel() async {
    try {
      final options = InterpreterOptions()..threads = _config.cpuThreads;
      if (_config.enableGpuDelegate) {
        try {
          options.addDelegate(GpuDelegateV2());
        } catch (e) {
          debugPrint('GPU delegate unavailable, falling back to CPU: $e');
        }
      }
      interpreter = await Interpreter.fromAsset(
        'assets/models/selfie_multiclass_256x256.tflite',
        options: options,
      );
      interpreter!.allocateTensors();
      debugPrint('Model AI sukses di-load.');
      return true;
    } catch (e) {
      debugPrint('Error loading model: $e');
      return false;
    }
  }

  Future<String> processImage(XFile imageFile, Color targetColor) async {
    if (interpreter == null) {
      debugPrint("Error: Interpreter belum di-load.");
      return imageFile.path;
    }

    try {
      final Uint8List imageBytes = await File(imageFile.path).readAsBytes();
      final img.Image? originalImage = img.decodeImage(imageBytes);
      if (originalImage == null) return imageFile.path;

      if (targetColor == Colors.transparent) {
        debugPrint("Warna 'Natural' dipilih, skip processing.");
        return imageFile.path;
      }

      final img.Image? processedImage =
          _applyHairColor(originalImage, targetColor);
      if (processedImage == null) return imageFile.path;

      final Directory tempDir = await getTemporaryDirectory();
      final String tempPath = '${tempDir.path}/${const Uuid().v4()}.jpg';

      await img.encodeJpgFile(tempPath, processedImage, quality: 90);

      debugPrint('Gambar selesai diproses, disimpan di: $tempPath');
      return tempPath;
    } catch (e) {
      debugPrint('Error processing image: $e');
      return imageFile.path;
    }
  }

  // This function now offloads the heavy work to a background isolate.
  Future<Uint8List?> processCameraImage(
    CameraImage cameraImage,
    CameraDescription description,
    Color targetColor,
  ) async {
    if (interpreter == null || interpreterAddress == 0) {
      debugPrint("Error: Interpreter not loaded or has no address.");
      return null;
    }
    if (targetColor == Colors.transparent) {
      return null;
    }

    // 1. Convert camera image on the main thread (fast).
    final img.Image? originalImage = _convertCameraImage(cameraImage, description);
    if (originalImage == null) {
      return null;
    }

    // 2. Prepare parameters for the isolate.
    final params = {
      'interpreterAddress': interpreterAddress,
      'image': originalImage,
      'colorValue': targetColor.value,
      'config': config,
    };

    // 3. Run the heavy processing in the background isolate using compute.
    return await compute(applyColorInIsolate, params);
  }

  void dispose() {
    interpreter?.close();
  }

  img.Image? _applyHairColor(img.Image originalImage, Color targetColor) {
    if (interpreter == null) return null;

    // --- OPTIMIZATION: Downscale image for processing if it's too large ---
    const int maxProcessingSize = 360;
    img.Image processingImage = originalImage;
    bool wasResized = false;

    if (originalImage.width > maxProcessingSize ||
        originalImage.height > maxProcessingSize) {
      processingImage = img.copyResize(
        originalImage,
        width: (originalImage.width > originalImage.height)
            ? maxProcessingSize
            : null,
        height: (originalImage.height >= originalImage.width)
            ? maxProcessingSize
            : null,
        interpolation: img.Interpolation.average,
      );
      wasResized = true;
    }
    // --- END OPTIMIZATION ---

    final img.Image inputImage = img.copyResize(
      processingImage, // Use the (potentially smaller) processingImage
      width: _inputSize,
      height: _inputSize,
      interpolation: img.Interpolation.average,
    );

    final inputBytes = inputImage.getBytes(order: img.ChannelOrder.rgb);
    final input = List.generate(
      1,
      (_) => List.generate(
        _inputSize,
        (y) => List.generate(_inputSize, (x) {
          final int index = (y * _inputSize + x) * 3;
          return [
            (inputBytes[index] - 127.5) / 127.5,
            (inputBytes[index + 1] - 127.5) / 127.5,
            (inputBytes[index + 2] - 127.5) / 127.5,
          ];
        }),
      ),
    );

    final output = List.generate(
      1,
      (_) => List.generate(
        _inputSize,
        (_) => List.generate(_inputSize, (_) => List.filled(6, 0.0)),
      ),
    );

    interpreter!.run(input, output);

    final img.Image hairMask = img.Image(width: _inputSize, height: _inputSize);
    const int hairClassIndex = 1;

    final List<List<List<double>>> outputMask = output[0];
    for (int y = 0; y < _inputSize; y++) {
      for (int x = 0; x < _inputSize; x++) {
        final List<double> pixelScores = outputMask[y][x];
        int maxIndex = 0;
        for (int i = 1; i < pixelScores.length; i++) {
          if (pixelScores[i] > pixelScores[maxIndex]) {
            maxIndex = i;
          }
        }
        if (maxIndex == hairClassIndex) {
          hairMask.setPixelRgb(x, y, 255, 255, 255);
        }
      }
    }

    img.Image resizedMask = img.copyResize(
      hairMask,
      width: processingImage.width, // Use processingImage dimensions
      height: processingImage.height, // Use processingImage dimensions
      interpolation: img.Interpolation.linear,
    );

    if (_config.maskBlurRadius > 0) {
      resizedMask =
          img.gaussianBlur(resizedMask, radius: _config.maskBlurRadius);
    }

    final img.Image finalImage = img.Image.from(processingImage);
    final tR = targetColor.red.toDouble();
    final tG = targetColor.green.toDouble();
    final tB = targetColor.blue.toDouble();

    for (int y = 0; y < finalImage.height; y++) {
      for (int x = 0; x < finalImage.width; x++) {
        final double alpha = resizedMask.getPixel(x, y).r / 255.0;
        if (alpha <= _config.maskAlphaCutoff) continue;

        // --- VISUAL IMPROVEMENT: Strengthen alpha ---
        final double adjustedAlpha = pow(alpha, 0.5).toDouble();

        final originalPixel =
            processingImage.getPixel(x, y); // Get pixel from processingImage
        final oR = originalPixel.r.toDouble();
        final oG = originalPixel.g.toDouble();
        final oB = originalPixel.b.toDouble();

        double r = (oR < 128)
            ? (2 * oR * tR) / 255
            : (255 - (2 * (255 - oR) * (255 - tR) / 255));
        double g = (oG < 128)
            ? (2 * oG * tG) / 255
            : (255 - (2 * (255 - oG) * (255 - tG) / 255));
        double b = (oB < 128)
            ? (2 * oB * tB) / 255
            : (255 - (2 * (255 - oB) * (255 - tB) / 255));

        // Use adjustedAlpha for blending
        r = (r * adjustedAlpha) + (oR * (1.0 - adjustedAlpha));
        g = (g * adjustedAlpha) + (oG * (1.0 - adjustedAlpha));
        b = (b * adjustedAlpha) + (oB * (1.0 - adjustedAlpha));

        finalImage.setPixelRgb(x, y, r.round(), g.round(), b.round());
      }
    }

    if (wasResized) {
      return img.copyResize(
        finalImage,
        width: originalImage.width,
        height: originalImage.height,
        interpolation: img.Interpolation.linear,
      );
    }

    return finalImage;
  }

  img.Image? _convertCameraImage(
    CameraImage cameraImage,
    CameraDescription cameraDescription,
  ) {
    final int width = cameraImage.width;
    final int height = cameraImage.height;

    final int sensorOrientation = cameraDescription.sensorOrientation;
    final bool isFrontCamera =
        cameraDescription.lensDirection == CameraLensDirection.front;

    final bool isRotated = sensorOrientation == 90 || sensorOrientation == 270;
    final int outWidth = isRotated ? height : width;
    final int outHeight = isRotated ? width : height;

    final img.Image image = img.Image(width: outWidth, height: outHeight);

    final Plane planeY = cameraImage.planes[0];
    final Plane planeU = cameraImage.planes[1];
    final Plane planeV = cameraImage.planes[2];

    final Uint8List bytesY = planeY.bytes;
    final Uint8List bytesU = planeU.bytes;
    final Uint8List bytesV = planeV.bytes;

    final int rowStrideY = planeY.bytesPerRow;
    final int rowStrideU = planeU.bytesPerRow;
    final int rowStrideV = planeV.bytesPerRow;

    final int pixelStrideU = planeU.bytesPerPixel!;
    final int pixelStrideV = planeV.bytesPerPixel!;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int uvx = x ~/ 2;
        final int uvy = y ~/ 2;

        final int yIndex = y * rowStrideY + x;
        final int uIndex = uvy * rowStrideU + uvx * pixelStrideU;
        final int vIndex = uvy * rowStrideV + uvx * pixelStrideV;

        final int Y = bytesY[yIndex];
        final int U = bytesU[uIndex];
        final int V = bytesV[vIndex];

        final int r = (Y + 1.402 * (V - 128)).round();
        final int g = (Y - 0.344136 * (U - 128) - 0.714136 * (V - 128)).round();
        final int b = (Y + 1.772 * (U - 128)).round();

        int destX, destY;

        switch (sensorOrientation) {
          case 90:
            destX = y;
            destY = outHeight - 1 - x;
            break;
          case 180:
            destX = outWidth - 1 - x;
            destY = outHeight - 1 - y;
            break;
          case 270:
            destX = outWidth - 1 - y;
            destY = x;
            break;
          default: // 0
            destX = x;
            destY = y;
        }

        if (isFrontCamera) {
          if (isRotated) {
            destY = outHeight - 1 - destY;
          } else {
            destX = outWidth - 1 - destX;
          }
        }

        image.setPixelRgb(
            destX, destY, r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255));
      }
    }

    return image;
  }
}