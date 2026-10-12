import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:hand_landmarker/hand_landmarker.dart';
import 'package:permission_handler/permission_handler.dart';

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  bool _isDetecting = false;

  // Скелет руки: какие точки соединять линиями
  static const List<List<int>> _connections = [
    [0, 1], [1, 2], [2, 3], [3, 4],
    [0, 5], [5, 6], [6, 7], [7, 8],
    [5, 9], [9, 10], [10, 11], [11, 12],
    [9, 13], [13, 14], [14, 15], [15, 16],
    [13, 17], [17, 18], [18, 19], [19, 20],
    [0, 17],
  ];

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    // 1. Выбираем фронтальную камеру (или первую доступную)
    final camera = cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    // 2. Создаём плагин для трекинга рук
    _plugin = HandLandmarkerPlugin.create(
      numHands: 2,
      minHandDetectionConfidence: 0.7,
      delegate: HandLandmarkerDelegate.gpu,
    );

    // 3. Инициализируем камеру и запускаем поток кадров
    await _controller!.initialize();
    await _controller!.startImageStream(_processCameraImage);

    // 4. Подписываемся на поток результатов от плагина
    _plugin!.landmarkStream.listen((hands) {
      if (mounted) {
        setState(() {
          _hands = hands;
        });
      }
    });

    if (mounted) {
      setState(() {
        _isInitialized = true;
      });
    }
  }

  void _processCameraImage(CameraImage image) {
    // Защита от перегрузки: обрабатываем кадр только если предыдущий завершён
    if (_isDetecting) return;
    _isDetecting = true;

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

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_controller!),
          CustomPaint(
            painter: _HandSkeletonPainter(
              hands: _hands,
              imageSize: Size(
                _controller!.value.previewSize!.height,
                _controller!.value.previewSize!.width,
              ),
              isFrontCamera:
                  _controller!.description.lensDirection ==
                      CameraLensDirection.front,
            ),
          ),
          Positioned(
            top: 40,
            left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Рук: ${_hands.length}',
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
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

  _HandSkeletonPainter({
    required this.hands,
    required this.imageSize,
    required this.isFrontCamera,
  });

  static const Color _leftColor = Color(0xFF4FC3F7);
  static const Color _rightColor = Color(0xFFFF7043);

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    Offset map(Offset p) {
      var x = p.dx * scaleX;
      if (isFrontCamera) x = size.width - x;
      return Offset(x, p.dy * scaleY);
    }

    for (final hand in hands) {
      final isLeft = hand.handedness == Handedness.left;
      final baseColor = isLeft ? _leftColor : _rightColor;

      final bonePaint = Paint()
        ..color = baseColor
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;

      final jointPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;

      final jointBorderPaint = Paint()
        ..color = baseColor
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke;

      final pts = hand.landmarks
          .map((lm) => map(Offset(lm.x, lm.y)))
          .toList();

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

      for (final c in HandARScreen._connections) {
        canvas.drawLine(pts[c[0]], pts[c[1]], bonePaint);
      }

      for (final p in pts) {
        canvas.drawCircle(p, 8, jointPaint);
        canvas.drawCircle(p, 8, jointBorderPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HandSkeletonPainter old) =>
      old.hands != hands || old.imageSize != imageSize;
}
