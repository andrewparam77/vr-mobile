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

// ========== Виртуальное окно ==========
class VirtualWindow {
  double x, y, z;      // позиция в виртуальном пространстве
  double width, height;
  String title;
  Color color;

  VirtualWindow({
    required this.x,
    required this.y,
    required this.z,
    required this.width,
    required this.height,
    required this.title,
    required this.color,
  });

  // Масштаб от глубины: чем дальше, тем меньше
  double get scale => 1.0 / (1.0 + z * 0.5);

  double get screenWidth => width * scale;
  double get screenHeight => height * scale;

  // Попала ли точка внутрь окна
  bool contains(Offset p) {
    return p.dx >= x &&
        p.dx <= x + screenWidth &&
        p.dy >= y &&
        p.dy <= y + screenHeight;
  }
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

  // Виртуальные окна
  final List<VirtualWindow> _windows = [];

  // Какое окно сейчас тащим
  VirtualWindow? _draggedWindow;
  Offset _dragOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
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

    // Стартовые окна
    _windows.addAll([
      VirtualWindow(
        x: 100, y: 150, z: 0.3,
        width: 300, height: 200,
        title: 'Монитор 1',
        color: Colors.cyan,
      ),
      VirtualWindow(
        x: 500, y: 200, z: 0.6,
        width: 260, height: 180,
        title: 'Монитор 2',
        color: Colors.orange,
      ),
      VirtualWindow(
        x: 800, y: 100, z: 0.1,
        width: 220, height: 150,
        title: 'Консоль',
        color: Colors.greenAccent,
      ),
    ]);

    if (mounted) {
      setState(() => _isInitialized = true);
    }
  }

  void _processCameraImage(CameraImage image) {
    _plugin?.processFrame(image, _controller!.description.sensorOrientation);
  }

  // ========== Взаимодействие рукой ==========
  void _handleHandInteraction(List<Hand> hands, Size canvasSize) {
    if (hands.isEmpty) {
      _draggedWindow = null;
      return;
    }

    final hand = hands.first;
    final lm = hand.landmarks;

    const indexTip = 8;
    const thumbTip = 4;

    // Расстояние между большим и указательным — жест «щипок»
    final pinchDist = (Offset(lm[thumbTip].x, lm[thumbTip].y) -
            Offset(lm[indexTip].x, lm[indexTip].y))
        .distance;
    final isPinching = pinchDist < 0.05;

    // Позиция кончика указательного пальца на экране
    final fingerPos = Offset(
      lm[indexTip].x * canvasSize.width,
      lm[indexTip].y * canvasSize.height,
    );

    if (isPinching) {
      if (_draggedWindow == null) {
        // Ищем окно под пальцем (сверху вниз — последнее добавленное первым)
        for (int i = _windows.length - 1; i >= 0; i--) {
          final w = _windows[i];
          if (w.contains(fingerPos)) {
            _draggedWindow = w;
            _dragOffset = fingerPos - Offset(w.x, w.y);
            break;
          }
        }
      } else {
        // Тащим окно за пальцем
        _draggedWindow!.x = fingerPos.dx - _dragOffset.dx;
        _draggedWindow!.y = fingerPos.dy - _dragOffset.dy;
      }
    } else {
      // Отпустили
      _draggedWindow = null;
    }
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
      body: LayoutBuilder(
        builder: (context, constraints) {
          final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);

          _handleHandInteraction(_hands, canvasSize);

          return Stack(
            fit: StackFit.expand,
            children: [
              RotatedBox(
                quarterTurns: quarterTurns,
                child: CameraPreview(_controller!),
              ),
              CustomPaint(
                painter: _ARSpacePainter(
                  hands: _hands,
                  windows: _windows,
                  imageSize: Size(
                    _controller!.value.previewSize!.height,
                    _controller!.value.previewSize!.width,
                  ),
                  isFrontCamera: false,
                  quarterTurns: quarterTurns,
                ),
              ),
            ],
          );
        },
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

class _ARSpacePainter extends CustomPainter {
  final List<Hand> hands;
  final List<VirtualWindow> windows;
  final Size imageSize;
  final bool isFrontCamera;
  final int quarterTurns;

  _ARSpacePainter({
    required this.hands,
    required this.windows,
    required this.imageSize,
    required this.isFrontCamera,
    required this.quarterTurns,
  });

  Offset map(Offset p, Size size) {
    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;
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

  @override
  void paint(Canvas canvas, Size size) {
    // ===== 1. Окна =====
    // Сортируем по Z: дальние — первыми, ближние — поверх
    final sorted = List<VirtualWindow>.from(windows)
      ..sort((a, b) => b.z.compareTo(a.z));

    for (final w in sorted) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(w.x, w.y, w.screenWidth, w.screenHeight),
        const Radius.circular(12),
      );

      // Тень — создаёт ощущение «парения»
      canvas.drawRRect(
        rect.shift(const Offset(6, 8)),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.4)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );

      // Полупрозрачный фон
      canvas.drawRRect(
        rect,
        Paint()..color = w.color.withValues(alpha: 0.25),
      );

      // Обводка
      canvas.drawRRect(
        rect,
        Paint()
          ..color = w.color.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );

      // Заголовок
      final titlePainter = TextPainter(
        text: TextSpan(
          text: w.title,
          style: TextStyle(
            color: w.color,
            fontSize: 16 * w.scale,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      titlePainter.paint(canvas, Offset(w.x + 12, w.y + 10));

      // Полоска глубины
      final depthBar = Rect.fromLTWH(
        w.x + 12,
        w.y + w.screenHeight - 16,
        (w.screenWidth - 24) * (1.0 - w.z.clamp(0.0, 1.0)),
        4,
      );
      canvas.drawRect(
        depthBar,
        Paint()..color = w.color.withValues(alpha: 0.7),
      );
    }

    // ===== 2. Скелет руки =====
    final bonePaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final jointPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    for (final hand in hands) {
      final pts = hand.landmarks
          .map((lm) => map(Offset(lm.x, lm.y), size))
          .toList();

      if (pts.length < 21) continue;

      for (final c in handConnections) {
        canvas.drawLine(pts[c[0]], pts[c[1]], bonePaint);
      }

      for (final p in pts) {
        canvas.drawCircle(p, 6, jointPaint);
      }

      // Подсветка кончика указательного пальца
      canvas.drawCircle(
        pts[8],
        12,
        Paint()
          ..color = Colors.yellowAccent.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ARSpacePainter old) => true;
}
