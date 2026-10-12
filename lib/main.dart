import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hand_landmarker/hand_landmarker.dart';
import 'package:permission_handler/permission_handler.dart';

late List<CameraDescription> cameras;

const List<List<int>> handConnections = [
  [0, 1], [1, 2], [2, 3], [3, 4],
  [0, 5], [5, 6], [6, 7], [7, 8],
  [5, 9], [9, 10], [10, 11], [11, 12],
  [9, 13], [13, 14], [14, 15], [15, 16],
  [13, 17], [17, 18], [18, 19], [19, 20],
  [0, 17],
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Принудительно горизонтальная ориентация
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await Permission.camera.request();
  cameras = await availableCameras();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: HandARScreen());
}

class HandARScreen extends StatefulWidget {
  const HandARScreen({super.key});
  @override
  State<HandARScreen> createState() => _HandARScreenState();
}

class _HandARScreenState extends State<HandARScreen> {
  CameraController? _controller;
  HandLandmarkerPlugin? _plugin;
  List<Hand> _hands = [];
  bool _isInitialized = false;
  bool _isDetecting = false; // Защита от перегрузки кадров

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    // Ищем ЗАДНЮЮ камеру
    final camera = cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    _plugin = HandLandmarkerPlugin.create(
      numHands: 2,
      minHandDetectionConfidence: 0.5, // Снижено для лучшего распознавания
      delegate: HandLandmarkerDelegate.gpu,
    );

    await _controller!.initialize();
    await _controller!.startImageStream(_processCameraImage);

    _plugin!.landmarkStream.listen((hands) {
      if (mounted) {
        setState(() {
          _hands = hands;
        });
      }
    });

    if (mounted) {
      setState(() => _isInitialized = true);
    }
  }

  void _processCameraImage(CameraImage image) {
    if (_isDetecting) return;
    _isDetecting = true;
    
    // ВАЖНО: передаём sensorOrientation, иначе руки не распознаются
    _plugin?.processFrame(image, _controller!.description.sensorOrientation);
    
    _isDetecting = false;
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized || _controller == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Вычисляем угол поворота по формуле из документации
    final sensorOrientation = _controller!.description.sensorOrientation;
    final quarterTurns = (sensorOrientation ~/ 90) % 4;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // RotatedBox с правильным quarterTurns для горизонтальной ориентации
          RotatedBox(
            quarterTurns: quarterTurns,
            child: CameraPreview(_controller!),
          ),
          CustomPaint(
            painter: _HandSkeletonPainter(
              hands: _hands,
              imageSize: Size(
                _controller!.value.previewSize!.height,
                _controller!.value.previewSize!.width,
              ),
              isFrontCamera: false,
              quarterTurns: quarterTurns,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    _plugin?.dispose();
    super.dispose();
  }
}

class _HandSkeletonPainter extends CustomPainter {
  final List<Hand> hands;
  final Size imageSize;
  final bool isFrontCamera;
  final int quarterTurns;

  _HandSkeletonPainter({
    required this.hands,
    required this.imageSize,
    required this.isFrontCamera,
    required this.quarterTurns,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    Offset map(Offset p) {
      var x = p.dx * scaleX;
      var y = p.dy * scaleY;
      
      // Корректировка координат с учётом поворота
      if (quarterTurns == 1) {
        return Offset(y, size.width - x);
      } else if (quarterTurns == 3) {
        return Offset(size.height - y, x);
      }
      
      if (isFrontCamera) x = size.width - x;
      return Offset(x, y);
    }

    final bonePaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final jointPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    for (final hand in hands) {
      final pts = hand.landmarks
          .map((lm) => map(Offset(lm.x, lm.y)))
          .toList();

      if (pts.length < 21) continue; // Проверка на корректность данных

      final palmPath = Path()
        ..moveTo(pts[0].dx, pts[0].dy)
        ..lineTo(pts[5].dx, pts[5].dy)
        ..lineTo(pts[9].dx, pts[9].dy)
        ..lineTo(pts[13].dx, pts[13].dy)
        ..lineTo(pts[17].dx, pts[17].dy)
        ..close();
      canvas.drawPath(
        palmPath,
        Paint()
          ..color = Colors.white.withOpacity(0.35)
          ..style = PaintingStyle.fill,
      );

      for (final c in handConnections) {
        canvas.drawLine(pts[c[0]], pts[c[1]], bonePaint);
      }

      for (final p in pts) {
        canvas.drawCircle(p, 8, jointPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HandSkeletonPainter old) =>
      old.hands != hands || old.imageSize != imageSize || old.quarterTurns != quarterTurns;
}
