import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_hand_detection/google_mlkit_hand_detection.dart';
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
  late CameraController _camera;
  final HandDetector _detector = HandDetector(
    options: HandDetectorOptions(
      mode: DetectionMode.stream,
      minHandDetectionConfidence: 0.5,
      minTrackingConfidence: 0.5,
      // ВАЖНО: без этого будет только 1 рука
      // (в некоторых версиях плагина поле называется иначе)
    ),
  );

  List<Hand> _hands = [];
  Size _imageSize = const Size(1, 1);
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cam = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    _camera = CameraController(
      cam,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await _camera.initialize();
    _camera.startImageStream(_processFrame);
    setState(() {});
  }

  Future<void> _processFrame(CameraImage image) async {
    if (_busy) return;
    _busy = true;
    try {
      final input = _toInputImage(image);
      if (input != null) {
        final hands = await _detector.processImage(input);
        // ML Kit сам вернёт до 2 рук, если они видны
        setState(() {
          _hands = hands;
          _imageSize =
              Size(image.width.toDouble(), image.height.toDouble());
        });
      }
    } catch (_) {}
    _busy = false;
  }

  InputImage? _toInputImage(CameraImage image) {
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;
    final rotation = InputImageRotationValue.fromRawValue(
            _camera.description.sensorOrientation) ??
        InputImageRotation.rotation0deg;

    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  static const List<List<int>> _connections = [
    [0, 1], [1, 2], [2, 3], [3, 4],
    [0, 5], [5, 6], [6, 7], [7, 8],
    [5, 9], [9, 10], [10, 11], [11, 12],
    [9, 13], [13, 14], [14, 15], [15, 16],
    [13, 17], [17, 18], [18, 19], [19, 20],
    [0, 17],
  ];

  @override
  Widget build(BuildContext context) {
    if (!_camera.value.isInitialized) {
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
          CameraPreview(_camera),
          CustomPaint(
            painter: _HandSkeletonPainter(
              hands: _hands,
              imageSize: _imageSize,
              isFrontCamera:
                  _camera.description.lensDirection ==
                      CameraLensDirection.front,
            ),
          ),
          // Счётчик рук
          Positioned(
            top: 40,
            left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Рук: ${_hands.length}',
                style: const TextStyle(
                    color: Colors.white, fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _camera.dispose();
    _detector.close();
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

  // Разные цвета для левой и правой руки
  static const Color _leftColor = Color(0xFF4FC3F7);  // голубой
  static const Color _rightColor = Color(0xFFFF7043); // оранжевый

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
      // Определяем цвет по типу руки
      final isLeft = hand.type == HandType.left;
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
          ..color = Colors.white.withOpacity(0.35)
          ..style = PaintingStyle.fill,
      );

      // Кости
      for (final c in _HandARScreenState._connections) {
        canvas.drawLine(pts[c[0]], pts[c[1]], bonePaint);
      }

      // Суставы: белый круг + цветная обводка
      for (final p in pts) {
        canvas.drawCircle(p, 8, jointPaint);
        canvas.drawCircle(p, 8, jointBorderPaint);
      }

      // Подпись L / R возле запястья
      final wrist = pts[0];
      final label = isLeft ? 'L' : 'R';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: baseColor,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, wrist + const Offset(-30, -40));
    }
  }

  @override
  bool shouldRepaint(covariant _HandSkeletonPainter old) =>
      old.hands != hands || old.imageSize != imageSize;
}