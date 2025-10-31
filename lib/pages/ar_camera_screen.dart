import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:proto_hair/models.dart';
import 'package:proto_hair/services/ai_service.dart';
import 'package:proto_hair/theme/app_theme.dart';

class ARCameraScreen extends StatefulWidget {
  final HairColor selectedColor;
  final bool hasCapturedImage;
  final Function(HairColor color) onColorSelect;
  final Function(String beforeImage, String afterImage) onCapture;
  final VoidCallback onOpenGallery;
  final VoidCallback onOpenBeforeAfter;
  final VoidCallback onBack;

  const ARCameraScreen({
    super.key,
    required this.selectedColor,
    required this.onColorSelect,
    required this.onCapture,
    required this.onOpenGallery,
    required this.onOpenBeforeAfter,
    required this.hasCapturedImage,
    required this.onBack,
  });

  @override
  State<ARCameraScreen> createState() => _ARCameraScreenState();
}

class _ARCameraScreenState extends State<ARCameraScreen>
    with SingleTickerProviderStateMixin {
  bool _isScanning = false;
  CameraController? _controller;
  bool _isScreenReady = false;
  final AIService _aiService = AIService(
    config: AIServiceConfig(
      enableGpuDelegate: true,
      cpuThreads: 2,
      maskBlurRadius: 1,
      maskAlphaCutoff: 0.25,
      outputJpegQuality: 75,
    ),
  );
  late HairColor _selectedColor;
  late AnimationController _scanController;
  late Animation<double> _scanAnimation;
  Uint8List? _processedFrameBytes;
  bool _isProcessingFrame = false;
  DateTime _lastFrameProcessedAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _frameInterval = Duration(milliseconds: 450);

  @override
  void initState() {
    super.initState();
    _selectedColor = widget.selectedColor;
    _scanController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _scanAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _scanController, curve: Curves.easeInOut),
    );
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    try {
      final bool modelLoaded = await _aiService.loadModel();
      if (!modelLoaded && mounted) {
        _showErrorSnackbar("Gagal memuat engine AI.");
        return;
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) _showErrorSnackbar("Tidak ada kamera ditemukan.");
        return;
      }

      final frontCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        frontCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _controller!.initialize();
      await _startImageStream();
      if (!mounted) return;

      setState(() {
        _isScreenReady = true;
      });
    } catch (e) {
      debugPrint("Gagal menginisialisasi services: $e");
      if (mounted) _showErrorSnackbar("Gagal memulai kamera.");
    }
  }

  @override
  void dispose() {
    if (_controller != null) {
      if (_controller!.value.isStreamingImages) {
        _controller!.stopImageStream();
      }
      _controller!.dispose();
    }
    _aiService.dispose();
    _scanController.dispose();
    super.dispose();
  }

  void _handleCapture() async {
    if (!_isScreenReady || _controller?.value.isTakingPicture == true) {
      return;
    }

    setState(() {
      _isScanning = true;
    });
    _scanController.repeat();

    try {
      if (_controller!.value.isStreamingImages) {
        await _controller!.stopImageStream();
      }
      final XFile originalImage = await _controller!.takePicture();

      final String processedImagePath = await _aiService.processImage(
        originalImage,
        _selectedColor.color,
      );

      if (!mounted) return;

      widget.onCapture(originalImage.path, processedImagePath);

      _scanController.stop();
      setState(() {
        _isScanning = false;
      });

      widget.onOpenBeforeAfter();
    } catch (e) {
      debugPrint("Error taking picture or processing: $e");
      if (mounted) {
        _scanController.stop();
        setState(() {
          _isScanning = false;
        });
        _showErrorSnackbar("Gagal mengambil gambar.");
      }
    } finally {
      if (_controller != null && !_controller!.value.isStreamingImages) {
        try {
          await _startImageStream();
        } catch (e) {
          debugPrint('Gagal memulai ulang image stream: $e');
        }
      }
    }
  }

  Future<void> _startImageStream() async {
    if (_controller == null || _controller!.value.isStreamingImages) return;
    await _controller!.startImageStream(_processCameraImage);
  }

  Future<void> _processCameraImage(CameraImage cameraImage) async {
    if (!_isScreenReady || _controller == null) return;

    if (_selectedColor.color == Colors.transparent) {
      if (_processedFrameBytes != null && mounted) {
        setState(() {
          _processedFrameBytes = null;
        });
      }
      return;
    }

    if (_isProcessingFrame) return;

    final DateTime now = DateTime.now();
    if (now.difference(_lastFrameProcessedAt) < _frameInterval) return;
    
    _isProcessingFrame = true;
    _lastFrameProcessedAt = now;

    try {
      final Uint8List? frameBytes = await _aiService.processCameraImage(
        cameraImage,
        _controller!.description,
        _selectedColor.color,
      );

      if (mounted && frameBytes != null) {
        setState(() {
          _processedFrameBytes = frameBytes;
        });
      }
    } catch (e) {
      debugPrint('Error processing camera frame: $e');
    } finally {
      if(mounted) {
        setState(() {
          _isProcessingFrame = false;
        });
      }
    }
  }
  
  void _showErrorSnackbar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.destructive,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isScreenReady) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 60,
                height: 60,
                child: CircularProgressIndicator(
                  color: AppColors.primary,
                  strokeWidth: 3,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                "Initializing Camera",
                style: AppTextStyles.h3.copyWith(
                  color: AppColors.foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "Loading AI engine...",
                style: AppTextStyles.p.copyWith(
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // Camera Preview & Processed Frame
          Positioned.fill(
            child: Center(
              child: AspectRatio(
                aspectRatio: 3 / 4,
                child: ClipRect(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // This Transform ensures the camera preview fills the 3/4 aspect ratio box
                      // without being distorted.
                      if (_controller != null && _controller!.value.isInitialized)
                        Transform.scale(
                          scale: _controller!.value.aspectRatio / (3 / 4),
                          alignment: Alignment.center,
                          child: CameraPreview(_controller!),
                        ),
                      if (_processedFrameBytes != null)
                        IgnorePointer(
                          child: Image.memory(
                            _processedFrameBytes!,
                            fit: BoxFit.cover, // BoxFit.cover will fill the 3/4 box
                            gaplessPlayback: true,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Top gradient overlay
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 120,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.6),
                    Colors.black.withOpacity(0.3),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // Bottom gradient overlay
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 200,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withOpacity(0.8),
                    Colors.black.withOpacity(0.4),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // Top Bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildIconButton(
                      icon: LucideIcons.arrowLeft,
                      onPressed: widget.onBack,
                    ),
                    Row(
                      children: [
                        _buildIconButton(
                          icon: LucideIcons.grid3x3,
                          onPressed: widget.onOpenGallery,
                        ),
                        const SizedBox(width: 8),
                        _buildIconButton(
                          icon: LucideIcons.gitCompare,
                          onPressed: widget.hasCapturedImage
                              ? widget.onOpenBeforeAfter
                              : null,
                          isActive: widget.hasCapturedImage,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom Controls
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  _buildColorSelector(),
                  const SizedBox(height: 24),
                  _buildCaptureButton(),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),

          // Scanning Overlay
          if (_isScanning)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.7),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          // Rotating gradient ring
                          AnimatedBuilder(
                            animation: _scanAnimation,
                            builder: (context, child) => Transform.rotate(
                              angle: _scanAnimation.value * 6.28,
                              child: Container(
                                width: 80,
                                height: 80,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: SweepGradient(
                                    colors: [
                                      AppColors.primary,
                                      Colors.transparent,
                                    ],
                                    stops: const [0.5, 1.0],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // Inner circle
                          Container(
                            width: 60,
                            height: 60,
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.8),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              LucideIcons.sparkles,
                              color: AppColors.primary,
                              size: 32,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Processing Your Look',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Applying ${_selectedColor.name}...',
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required VoidCallback? onPressed,
    bool isActive = true,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: isActive
            ? Colors.black.withOpacity(0.4)
            : Colors.black.withOpacity(0.2),
        shape: BoxShape.circle,
        border: Border.all(
          color: isActive
              ? Colors.white.withOpacity(0.3)
              : Colors.white.withOpacity(0.1),
          width: 1,
        ),
      ),
      child: IconButton(
        icon: Icon(
          icon,
          color: isActive ? Colors.white : Colors.white38,
          size: 22,
        ),
        onPressed: onPressed,
        padding: const EdgeInsets.all(12),
      ),
    );
  }

  Widget _buildColorSelector() {
    return Container(
      height: 56,
      margin: const EdgeInsets.symmetric(horizontal: 20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.2),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: Colors.white.withOpacity(0.1),
                width: 1,
              ),
            ),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: kHairColors.length,
              itemBuilder: (context, index) {
                final color = kHairColors[index];
                final isSelected = _selectedColor.id == color.id;

                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedColor = color;
                      _processedFrameBytes = null;
                      _lastFrameProcessedAt = DateTime.fromMillisecondsSinceEpoch(0);
                    });
                    widget.onColorSelect(color);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 8,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? color.color.withOpacity(0.9)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                      border: isSelected
                          ? Border.all(color: Colors.white, width: 2)
                          : null,
                    ),
                    child: Center(
                      child: Text(
                        color.name,
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.white70,
                          fontSize: 14,
                          fontWeight: isSelected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCaptureButton() {
    return GestureDetector(
      onTap: _handleCapture,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Outer ring
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withOpacity(0.3),
                width: 3,
              ),
            ),
          ),
          // Inner button
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withOpacity(0.3),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(
              LucideIcons.camera,
              color: AppColors.background,
              size: 32,
            ),
          ),
        ],
      ),
    );
  }
}
