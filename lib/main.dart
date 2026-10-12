import 'dart:async';
import 'dart:math' as math;
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

// ========== Класс частицы паутины ==========
class WebParticle {
  Offset position;
  Offset velocity;
  double life; // 1.0 → 0.0

  WebParticle({
    required this.position,
    required this.velocity,
    this.life = 1.0,
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

  // Список частиц живёт в State, чтобы сохраняться между кадрами
  final List<WebParticle> _webParticles = [];

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    // Задняя камера
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
      minHandDetectionConfidence: 0.6,
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
    // Ключевой момент: передаём sensorOrientation, иначе руки не находятся
    _plugin?.processFrame(image, _controller!.description.sensorOrientation);
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized || _controller == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final sensorOrientation = _controller!.description.sensorOrientation;
    final quarterTurns = (sensorOrientation ~/ 90) % 4;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
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
              webParticles: _webParticles,
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
  final List<WebParticle> webParticles;

  _HandSkeletonPainter({
    required this.hands,
    required this.imageSize,
    required this.isFrontCamera,
    required this.quarterTurns,
    required this.webParticles,
  });

  // ========== Определение жеста «человек-паук» ==========
  // Средний и безымянный согнуты, указательный и мизинец выпрямлены
  bool _isSpiderManGesture(List<Landmark> lm) {
    const indexTip = 8, indexPip = 6;
    const middleTip = 12, middlePip = 10;
    const ringTip = 16, ringPip = 14;
    const pinkyTip = 20, pinkyPip = 18;

    final middleCurled = lm[middleTip].y > lm[middlePip].y;
    final ringCurled = lm[ringTip].y > lm[ringPip].y;
    final indexExtended = lm[indexTip].y < lm[indexPip].y;
    final pinkyExtended = lm[pinkyTip].y < lm[pinkyPip].y;

    return middleCurled && ringCurled && indexExtended && pinkyExtended;
  }

  // ========== Создание частиц паутины ==========
  void _spawnWebParticles(Offset origin) {
    for (int i = 0; i < 15; i++) {
      final angle = (i / 15.0) * 2 * math.pi;
      webParticles.add(WebParticle(
        position: origin,
        velocity: Offset(math.cos(angle) * 8, math.sin(angle) * 8),
        life: 1.0,
      ));
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    Offset map(Offset p) {
      var x = p.dx * scaleX;
      var y = p.dy * scaleY;

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

    // ===== Рисуем скелет и проверяем жест =====
    for (final hand in hands) {
      final pts = hand.landmarks
          .map((lm) => map(Offset(lm.x, lm.y)))
          .toList();

      if (pts.length < 21) continue;

      // Жест «человек-паук» → из запястья летит паутина
      if (_isSpiderManGesture(hand.landmarks)) {
        _spawnWebParticles(pts[0]); // pts[0] — запястье
      }

      // Белая маска ладони
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
          ..color = Colors.white.withValues(alpha: 0.35)
          ..style = PaintingStyle.fill,
      );

      // Линии скелета
      for (final c in handConnections) {
        canvas.drawLine(pts[c[0]], pts[c[1]], bonePaint);
      }

      // Точки-суставы
      for (final p in pts) {
        canvas.drawCircle(p, 8, jointPaint);
      }
    }

    // ===== Обновляем и рисуем частицы паутины =====
    webParticles.removeWhere((p) => p.life <= 0);
    for (final p in webParticles) {
      p.position += p.velocity;
      p.velocity *= 0.95; // замедление
      p.life -= 0.03;     // затухание
    }

    for (final p in webParticles) {
      final alpha = (p.life * 255).clamp(0, 255).toInt();
      canvas.drawCircle(
        p.position,
        6,
        Paint()..color = Colors.white.withValues(alpha: alpha / 255),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HandSkeletonPainter old) =>
      old.hands != hands ||
      old.imageSize != imageSize ||
      old.quarterTurns != quarterTurns ||
      old.webParticles.length != webParticles.length;
}
