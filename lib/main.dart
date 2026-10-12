import 'dart:async';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hand_landmarker/hand_landmarker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';

late List<CameraDescription> cameras;

const List<List<int>> handConnections = [
  [0, 1], [1, 2], [2, 3], [3, 4],
  [0, 5], [5, 6], [6, 7], [7, 8],
  [5, 9], [9, 10], [10, 11], [11, 12],
  [9, 13], [13, 14], [14, 15], [15, 16],
  [13, 17], [17, 18], [18, 19], [19, 20],
  [0, 17],
];

// ========== Кнопка внутри окна ==========
class WindowButton {
  final String label;
  final Rect area;
  final VoidCallback onPressed;
  int highlightFrames;

  WindowButton({
    required this.label,
    required this.area,
    required this.onPressed,
    this.highlightFrames = 0,
  });
}

// ========== Виртуальное окно ==========
class VirtualWindow {
  double x, y, z;
  double width, height;
  String title;
  Color color;
  List<WindowButton> buttons;
  String? textContent;
  String? videoUrl;

  VirtualWindow({
    required this.x,
    required this.y,
    required this.z,
    required this.width,
    required this.height,
    required this.title,
    required this.color,
    this.buttons = const [],
    this.textContent,
    this.videoUrl,
  });

  double get scale => 1.0 / (1.0 + z * 0.5);
  double get screenWidth => width * scale;
  double get screenHeight => height * scale;

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

  final List<VirtualWindow> _windows = [];
  VirtualWindow? _draggedWindow;
  Offset _dragOffset = Offset.zero;

  VirtualWindow? _scalingWindow;
  double? _initialPinchDistance;
  double? _initialWindowWidth;
  double? _initialWindowHeight;

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
      if (mounted) setState(() => _hands = hands);
    });

    _windows.addAll([
      VirtualWindow(
        x: 100, y: 150, z: 0.3,
        width: 300, height: 200,
        title: 'Монитор 1',
        color: Colors.cyan,
        textContent: 'Система активна\nВсе датчики в норме',
        buttons: [
          WindowButton(
            label: 'Старт',
            area: const Rect.fromLTWH(12, 150, 80, 36),
            onPressed: () => debugPrint('Старт нажат'),
          ),
          WindowButton(
            label: 'Стоп',
            area: const Rect.fromLTWH(100, 150, 80, 36),
            onPressed: () => debugPrint('Стоп нажат'),
          ),
        ],
      ),
      VirtualWindow(
        x: 500, y: 200, z: 0.6,
        width: 260, height: 180,
        title: 'Монитор 2',
        color: Colors.orange,
        textContent: 'Температура: 42°C\nНагрузка: 67%',
      ),
      VirtualWindow(
        x: 800, y: 100, z: 0.1,
        width: 220, height: 150,
        title: 'Консоль',
        color: Colors.greenAccent,
        textContent: '> готов',
      ),
    ]);

    if (mounted) setState(() => _isInitialized = true);
  }

  void _processCameraImage(CameraImage image) {
    _plugin?.processFrame(image, _controller!.description.sensorOrientation);
  }

  // ========== Взаимодействие рукой ==========
  void _handleHandInteraction(List<Hand> hands, Size canvasSize) {
    for (final w in _windows) {
      for (final b in w.buttons) {
        if (b.highlightFrames > 0) b.highlightFrames--;
      }
    }

    if (hands.isEmpty) {
      _draggedWindow = null;
      _scalingWindow = null;
      return;
    }

    // ---- Двумя руками: масштабирование ----
    if (hands.length >= 2) {
      final p1 = _fingerPos(hands[0], canvasSize);
      final p2 = _fingerPos(hands[1], canvasSize);
      final bothPinching = _isPinching(hands[0]) && _isPinching(hands[1]);

      if (bothPinching && p1 != null && p2 != null) {
        final dist = (p1 - p2).distance;

        if (_scalingWindow == null) {
          for (final w in _windows) {
            if (w.contains(p1) || w.contains(p2)) {
              _scalingWindow = w;
              _initialPinchDistance = dist;
              _initialWindowWidth = w.width;
              _initialWindowHeight = w.height;
              break;
            }
          }
        } else {
          final ratio = dist / _initialPinchDistance!;
          final newW = _initialWindowWidth! * ratio;
          final newH = _initialWindowHeight! * ratio;
          setState(() {
            _scalingWindow!.width = newW.clamp(150, 800);
            _scalingWindow!.height = newH.clamp(100, 600);
          });
        }
        _draggedWindow = null;
        return;
      } else {
        _scalingWindow = null;
        _initialPinchDistance = null;
      }
    }

    // ---- Одной рукой: кнопки и перетаскивание ----
    final hand = hands.first;
    final lm = hand.landmarks;
    const indexTip = 8;
    const thumbTip = 4;

    final pinchDist = (Offset(lm[thumbTip].x, lm[thumbTip].y) -
            Offset(lm[indexTip].x, lm[indexTip].y))
        .distance;
    final isPinching = pinchDist < 0.05;

    final fingerPos = Offset(
      lm[indexTip].x * canvasSize.width,
      lm[indexTip].y * canvasSize.height,
    );

    if (isPinching) {
      if (_draggedWindow == null) {
        // Кнопки
        for (int i = _windows.length - 1; i >= 0; i--) {
          final w = _windows[i];
          if (!w.contains(fingerPos)) continue;

          final local = Offset(fingerPos.dx - w.x, fingerPos.dy - w.y);
          for (final b in w.buttons) {
            final scaledArea = Rect.fromLTWH(
              b.area.left * w.scale,
              b.area.top * w.scale,
              b.area.width * w.scale,
              b.area.height * w.scale,
            );
            if (scaledArea.contains(local)) {
              b.onPressed();
              b.highlightFrames = 12;
              return;
            }
          }
        }
        // Перетаскивание окна
        for (int i = _windows.length - 1; i >= 0; i--) {
          final w = _windows[i];
          if (w.contains(fingerPos)) {
            _draggedWindow = w;
            _dragOffset = fingerPos - Offset(w.x, w.y);
            break;
          }
        }
      } else {
        setState(() {
          _draggedWindow!.x = fingerPos.dx - _dragOffset.dx;
          _draggedWindow!.y = fingerPos.dy - _dragOffset.dy;
        });
      }
    } else {
      _draggedWindow = null;
    }
  }

  Offset? _fingerPos(Hand hand, Size canvasSize) {
    final lm = hand.landmarks;
    if (lm.length < 9) return null;
    return Offset(lm[8].x * canvasSize.width, lm[8].y * canvasSize.height);
  }

  bool _isPinching(Hand hand) {
    final lm = hand.landmarks;
    if (lm.length < 9) return false;
    final d = (Offset(lm[4].x, lm[4].y) - Offset(lm[8].x, lm[8].y)).distance;
    return d < 0.05;
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

          // Поворачиваем весь Stack целиком — превью, painter и видео вместе
          return RotatedBox(
            quarterTurns: quarterTurns,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(_controller!),
                CustomPaint(
                  painter: _ARSpacePainter(
                    hands: _hands,
                    windows: _windows,
                    imageSize: Size(
                      _controller!.value.previewSize!.height,
                      _controller!.value.previewSize!.width,
                    ),
                    isFrontCamera: false,
                    quarterTurns: 0, // поворот уже сделан через RotatedBox
                  ),
                ),
                ..._windows.where((w) => w.videoUrl != null).map((w) {
                  return Positioned(
                    left: w.x,
                    top: w.y,
                    width: w.screenWidth,
                    height: w.screenHeight,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12 * w.scale),
                      child: _VideoWidget(url: w.videoUrl!),
                    ),
                  );
                }),
              ],
            ),
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

// ========== Видео-виджет ==========
class _VideoWidget extends StatefulWidget {
  final String url;
  const _VideoWidget({required this.url});
  @override
  State<_VideoWidget> createState() => _VideoWidgetState();
}

class _VideoWidgetState extends State<_VideoWidget> {
  VideoPlayerController? _vpc;

  @override
  void initState() {
    super.initState();
    _vpc = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) setState(() {});
        _vpc?.setLooping(true);
        _vpc?.play();
      });
  }

  @override
  void dispose() {
    _vpc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_vpc == null || !_vpc!.value.isInitialized) {
      return Container(color: Colors.black26);
    }
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: _vpc!.value.size.width,
        height: _vpc!.value.size.height,
        child: VideoPlayer(_vpc!),
      ),
    );
  }
}

// ========== Painter ==========
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
    // ---- Окна ----
    final sorted = List<VirtualWindow>.from(windows)
      ..sort((a, b) => b.z.compareTo(a.z));

    for (final w in sorted) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(w.x, w.y, w.screenWidth, w.screenHeight),
        const Radius.circular(12),
      );

      canvas.drawRRect(
        rect.shift(const Offset(6, 8)),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.4)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );

      canvas.drawRRect(
        rect,
        Paint()..color = w.color.withValues(alpha: 0.25),
      );

      canvas.drawRRect(
        rect,
        Paint()
          ..color = w.color.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );

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

      if (w.textContent != null) {
        final textPainter = TextPainter(
          text: TextSpan(
            text: w.textContent,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 13 * w.scale,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: w.screenWidth - 24);
        textPainter.paint(canvas, Offset(w.x + 12, w.y + 40 * w.scale));
      }

      for (final b in w.buttons) {
        final scaledArea = Rect.fromLTWH(
          w.x + b.area.left * w.scale,
          w.y + b.area.top * w.scale,
          b.area.width * w.scale,
          b.area.height * w.scale,
        );

        final rrect = RRect.fromRectAndRadius(
          scaledArea,
          Radius.circular(6 * w.scale),
        );

        final isHighlighted = b.highlightFrames > 0;
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = isHighlighted
                ? w.color.withValues(alpha: 0.9)
                : w.color.withValues(alpha: 0.25),
        );
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = w.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );

        final btnText = TextPainter(
          text: TextSpan(
            text: b.label,
            style: TextStyle(
              color: isHighlighted ? Colors.black : Colors.white,
              fontSize: 12 * w.scale,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        btnText.paint(
          canvas,
          Offset(
            scaledArea.center.dx - btnText.width / 2,
            scaledArea.center.dy - btnText.height / 2,
          ),
        );
      }

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

    // ---- Скелет руки ----
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

      canvas.drawCircle(
        pts[8], 12,
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
