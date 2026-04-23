import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/gestures.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';

void main() {
  runApp(const OrbitApp());
}

class OrbitApp extends StatelessWidget {
  const OrbitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Orbit Planner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF02040A),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontFamily: 'Serif', color: Colors.white70),
        ),
      ),
      home: const OrbitScreen(),
    );
  }
}

enum BodyType { sun, planet, moon }

enum MapMode { system, focused }

enum AttachmentType { image, document }

class NoteAttachment {
  final String path;
  final String name;
  final AttachmentType type;
  final Uint8List? bytes;

  const NoteAttachment({
    required this.path,
    required this.name,
    required this.type,
    this.bytes,
  });
}

class Body {
  String text;
  String overview;
  final List<NoteAttachment> attachments;
  BodyType type;
  Body? parent;

  double orbitRadius;
  double orbitHeight;
  double orbitTilt;
  double angle;
  double speed;
  Color color;

  Offset position = Offset.zero;
  bool isCompleted;

  Body({
    required this.text,
    this.overview = "",
    List<NoteAttachment>? attachments,
    required this.type,
    this.parent,
    required this.orbitRadius,
    double? orbitHeight,
    double? orbitTilt,
    required this.angle,
    required this.speed,
    this.color = Colors.white,
    this.isCompleted = false,
  }) : orbitHeight = orbitHeight ?? orbitRadius,
       orbitTilt = orbitTilt ?? 0,
       attachments = attachments ?? [];
}

class JournalEntry {
  String task;
  bool isDone;
  DateTime? deadline;
  bool deadlineAlertShown;
  JournalEntry({
    required this.task,
    this.isDone = false,
    this.deadline,
    this.deadlineAlertShown = false,
  });
}

bool _isCompactViewport(Size viewportSize) {
  return min(viewportSize.width, viewportSize.height) < 700;
}

double _moonColumnOffsetPx(Size viewportSize) {
  final desiredOffset =
      viewportSize.width * (_isCompactViewport(viewportSize) ? 0.24 : 0.28);
  return desiredOffset.clamp(140.0, 220.0);
}

double _moonRowSpacing(Size viewportSize) {
  return _isCompactViewport(viewportSize) ? 84.0 : 100.0;
}

const List<({String label, Color color})> _planetColorOptions = [
  (label: "Ocean Blue", color: Colors.blue),
  (label: "Emerald Green", color: Colors.green),
  (label: "Solar Red", color: Colors.red),
  (label: "Royal Purple", color: Colors.purple),
  (label: "Ice Cyan", color: Colors.cyan),
  (label: "Amber Gold", color: Colors.amber),
];

Offset _focusedMoonTargetPosition({
  required Body moon,
  required Body selectedPlanet,
  required List<Body> bodies,
  required Size viewportSize,
  required double zoomLevel,
}) {
  final moons = bodies
      .where(
        (body) => body.parent == selectedPlanet && body.type == BodyType.moon,
      )
      .toList();
  final index = moons.indexOf(moon);
  if (index == -1) return moon.position;

  final safeZoom = zoomLevel <= 0 ? 1.0 : zoomLevel;
  final columnX =
      selectedPlanet.position.dx -
      (_moonColumnOffsetPx(viewportSize) / safeZoom);
  final rowSpacing = _moonRowSpacing(viewportSize);
  final columnY =
      selectedPlanet.position.dy -
      ((moons.length - 1) * rowSpacing) / 2 +
      index * rowSpacing;

  return Offset(columnX, columnY);
}

Offset _resolvedBodyPosition({
  required Body body,
  required Body? selected,
  required MapMode mode,
  required List<Body> bodies,
  required Size viewportSize,
  required double zoomLevel,
  required double focusProgress,
}) {
  if (mode == MapMode.focused &&
      selected != null &&
      body.parent == selected &&
      body.type == BodyType.moon) {
    final target = _focusedMoonTargetPosition(
      moon: body,
      selectedPlanet: selected,
      bodies: bodies,
      viewportSize: viewportSize,
      zoomLevel: zoomLevel,
    );
    return Offset.lerp(body.position, target, focusProgress)!;
  }

  return body.position;
}

Offset _orbitalPosition(Body body) {
  final parent = body.parent;
  if (parent == null) return body.position;

  final orbitX = cos(body.angle) * body.orbitRadius;
  final orbitY = sin(body.angle) * body.orbitHeight;
  final cosTilt = cos(body.orbitTilt);
  final sinTilt = sin(body.orbitTilt);

  return Offset(
    parent.position.dx + orbitX * cosTilt - orbitY * sinTilt,
    parent.position.dy + orbitX * sinTilt + orbitY * cosTilt,
  );
}

double _stableUnitFromString(String value) {
  final hash = value.codeUnits.fold<int>(0, (total, unit) => total + unit);
  return (hash % 1000) / 1000;
}

double _planetSafetyRadius(Body body) {
  return body.type == BodyType.planet ? 72.0 : 0.0;
}

double _bestPlanetStartAngle(List<Body> siblingPlanets) {
  if (siblingPlanets.isEmpty) {
    return 0;
  }

  final siblingAngles = siblingPlanets.map((planet) => planet.angle).toList()
    ..sort();
  double bestAngle = siblingAngles.first + pi;
  double largestGap = 0;

  for (int i = 0; i < siblingAngles.length; i++) {
    final current = siblingAngles[i];
    final next = i == siblingAngles.length - 1
        ? siblingAngles.first + pi * 2
        : siblingAngles[i + 1];
    final gap = next - current;
    if (gap > largestGap) {
      largestGap = gap;
      bestAngle = current + gap / 2;
    }
  }

  return bestAngle % (pi * 2);
}

class OrbitScreen extends StatefulWidget {
  const OrbitScreen({super.key});

  @override
  State<OrbitScreen> createState() => _OrbitScreenState();
}

class _OrbitScreenState extends State<OrbitScreen>
    with SingleTickerProviderStateMixin {
  static const double _minZoom = 0.15;
  static const double _maxZoom = 5.0;
  static const double _defaultZoom = 0.8;

  final List<Body> bodies = [];
  final List<JournalEntry> journal = [];
  Body? selected;
  Body? panelBody;

  MapMode mode = MapMode.system;
  Offset camera = Offset.zero;
  Offset cameraTarget = Offset.zero;
  double zoom = 0.8;
  double zoomTarget = 0.8;
  double focusProgress = 0;

  bool showPanel = false;
  bool isEditMode = false;
  final TextEditingController _notesController = TextEditingController();
  final ImagePicker _imagePicker = ImagePicker();

  final Random random = Random();
  late final Ticker ticker;
  Timer? _deadlineTimer;
  double _gestureStartZoom = _defaultZoom;
  Offset _gestureStartCamera = Offset.zero;
  Offset _gestureStartFocalPoint = Offset.zero;
  bool _deadlineDialogOpen = false;

  @override
  void initState() {
    super.initState();
    ticker = createTicker((_) {
      updateSystem();
    })..start();
    _deadlineTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkDeadlines(),
    );
  }

  void updateSystem() {
    Body? frozenPlanet;
    if (mode == MapMode.focused && selected != null) {
      frozenPlanet = selected!.type == BodyType.planet
          ? selected
          : selected!.parent;
    }

    for (final b in bodies) {
      if (b.parent == null) continue;
      if (frozenPlanet != null) {
        if (b == frozenPlanet || b.parent == frozenPlanet) {
          continue;
        }
      }

      b.angle += b.speed;
      b.position = _orbitalPosition(b);
    }

    final suns = bodies.where((b) => b.type == BodyType.sun).toList();
    for (final sun in suns) {
      final planets = bodies
          .where((b) => b.parent == sun && b.type == BodyType.planet)
          .toList();
      for (int i = 0; i < planets.length; i++) {
        for (int j = i + 1; j < planets.length; j++) {
          final a = planets[i];
          final b = planets[j];
          final minDistance = _planetSafetyRadius(a) + _planetSafetyRadius(b);
          final distance = (a.position - b.position).distance;
          if (distance >= minDistance || distance == 0) continue;

          final separation = (minDistance - distance) / minDistance;
          final push = max(0.002, separation * 0.035);
          if (a.orbitRadius <= b.orbitRadius) {
            a.angle -= push;
            b.angle += push;
          } else {
            a.angle += push;
            b.angle -= push;
          }
          a.position = _orbitalPosition(a);
          b.position = _orbitalPosition(b);
        }
      }
    }

    if (mode == MapMode.focused) {
      focusProgress = min(1, focusProgress + 0.05);
    } else {
      focusProgress = max(0, focusProgress - 0.05);
    }

    camera = Offset.lerp(camera, cameraTarget, 0.1)!;
    zoom = lerpDouble(zoom, zoomTarget, 0.1)!;

    setState(() {});
  }

  Future<void> createSubject() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Initialize New Core"),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(hintText: "Enter core name"),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: const Text("Create"),
          ),
        ],
      ),
    );

    if (name == null || name.isEmpty) return;

    setState(() {
      bodies.clear();
      final sun = Body(
        text: name,
        type: BodyType.sun,
        orbitRadius: 0,
        angle: 0,
        speed: 0,
        color: Colors.orangeAccent,
      );
      sun.position = const Offset(0, 0);
      bodies.add(sun);
      selected = sun;
      mode = MapMode.system;
      zoomTarget = _defaultZoom;
      cameraTarget = Offset.zero;
      showPanel = false;
    });
  }

  Future<void> _addNewCore() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Add Additional Core"),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(hintText: "Enter core name"),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: const Text("Create"),
          ),
        ],
      ),
    );

    if (name == null || name.isEmpty) return;

    setState(() {
      final sun = Body(
        text: name,
        type: BodyType.sun,
        orbitRadius: 0,
        angle: 0,
        speed: 0,
        color: Colors.orangeAccent,
      );

      // Place new core far away to avoid collision
      double angle = random.nextDouble() * 2 * pi;
      double dist = 3000.0 + random.nextDouble() * 1000.0;
      sun.position = Offset(cos(angle) * dist, sin(angle) * dist);

      bodies.add(sun);
      selected = sun;
      cameraTarget = sun.position;
      zoomTarget = _defaultZoom;
    });
  }

  Future<void> createPlanet() async {
    final suns = bodies.where((b) => b.type == BodyType.sun).toList();
    if (suns.isEmpty) return;

    Body targetSun = suns.first;
    if (selected != null) {
      Body? p = selected;
      while (p != null && p.type != BodyType.sun) {
        p = p.parent;
      }
      if (p != null) targetSun = p;
    }

    final c = TextEditingController();
    final createdPlanet = await showDialog<({String name, Color color})>(
      context: context,
      builder: (_) {
        var selectedColor = _planetColorOptions.first.color;

        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text("New Planet for ${targetSun.text}"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: c,
                  decoration: const InputDecoration(
                    hintText: "Enter planet name",
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  "Planet color",
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<Color>(
                  value: selectedColor,
                  dropdownColor: const Color(0xFF0F1633),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                  ),
                  items: _planetColorOptions.map((option) {
                    return DropdownMenuItem<Color>(
                      value: option.color,
                      child: Row(
                        children: [
                          Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: option.color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(option.label),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() {
                      selectedColor = value;
                    });
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel"),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context, (
                    name: c.text.trim(),
                    color: selectedColor,
                  ));
                },
                child: const Text("Create"),
              ),
            ],
          ),
        );
      },
    );

    if (createdPlanet == null || createdPlanet.name.isEmpty) return;

    setState(() {
      final siblingPlanets = bodies
          .where((b) => b.parent == targetSun && b.type == BodyType.planet)
          .toList();
      const firstOrbitRadius = 240.0;
      const orbitSpacing = 110.0;
      final orbitSeed = _stableUnitFromString(
        "${targetSun.text}-${createdPlanet.name}",
      );
      final radius = firstOrbitRadius + siblingPlanets.length * orbitSpacing;
      final flattening = 0.56 + orbitSeed * 0.26;
      final orbitTilt = -0.55 + orbitSeed * 1.1;
      final angle = _bestPlanetStartAngle(siblingPlanets);
      final planet = Body(
        text: createdPlanet.name,
        type: BodyType.planet,
        parent: targetSun,
        orbitRadius: radius,
        orbitHeight: radius * flattening,
        orbitTilt: orbitTilt,
        angle: angle,
        speed: 0.0018 + random.nextDouble() * 0.0025,
        color: createdPlanet.color,
      );

      bodies.add(planet);
    });
  }

  Future<void> createMoon() async {
    if (selected == null ||
        (selected!.type != BodyType.planet && selected!.type != BodyType.moon))
      return;

    final parentPlanet = selected!.type == BodyType.planet
        ? selected!
        : selected!.parent!;

    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("New Moon"),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(hintText: "Enter moon name"),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: const Text("Create"),
          ),
        ],
      ),
    );

    if (name == null || name.isEmpty) return;

    setState(() {
      final moons = bodies
          .where((b) => b.parent == parentPlanet && b.type == BodyType.moon)
          .toList();
      final count = moons.length + 1;
      const radius = 80.0;

      for (int i = 0; i < moons.length; i++) {
        moons[i].angle = (2 * pi / count) * i;
      }

      final newAngle = (2 * pi / count) * moons.length;
      final moon = Body(
        text: name,
        overview: "",
        type: BodyType.moon,
        parent: parentPlanet,
        orbitRadius: radius,
        angle: newAngle,
        speed: 0.01,
        color: Colors.grey.shade400,
      );

      bodies.add(moon);
    });
  }

  void focusBody(Body b, Size viewportSize) {
    selected = b;
    mode = MapMode.focused;
    focusProgress = 0;
    cameraTarget = b.position;
    zoomTarget = _focusZoomForBody(b, viewportSize);
    showPanel = false;
  }

  double _focusZoomForBody(Body body, Size viewportSize) {
    if (body.type == BodyType.sun) {
      return 1.4.clamp(_minZoom, _maxZoom);
    }

    if (body.type == BodyType.planet) {
      final moons = bodies
          .where((b) => b.parent == body && b.type == BodyType.moon)
          .toList();
      if (moons.isEmpty) {
        return 1.9.clamp(_minZoom, _maxZoom);
      }

      final maxMoonOrbit = moons
          .map((moon) => moon.orbitRadius)
          .fold<double>(0, max);
      final isCompact = _isCompactViewport(viewportSize);
      final horizontalPadding = isCompact ? 48.0 : 120.0;
      final verticalPadding = isCompact ? 220.0 : 180.0;
      final usableWidth = max(160.0, viewportSize.width - horizontalPadding);
      final usableHeight = max(220.0, viewportSize.height - verticalPadding);
      final orbitDiameter = (maxMoonOrbit + 90) * 2;
      final orbitFitZoom = min(usableWidth, usableHeight) / orbitDiameter;

      final moonColumnHalfHeight =
          ((moons.length - 1) * _moonRowSpacing(viewportSize)) / 2 + 40;
      final columnFitZoom = usableHeight / (moonColumnHalfHeight * 2);
      final fittedZoom = min(orbitFitZoom, columnFitZoom);

      return fittedZoom.clamp(isCompact ? 0.55 : 0.8, 1.6);
    }

    return 1.2.clamp(_minZoom, _maxZoom);
  }

  void openPanel(Body b) {
    setState(() {
      panelBody = b;
      showPanel = true;
      isEditMode = false;
      _notesController.text = b.overview;
    });
  }

  Offset screenToWorld(Offset s, Size size) {
    return (s - Offset(size.width / 2, size.height / 2)) / zoom + camera;
  }

  void _setZoom(double nextZoom) {
    setState(() {
      zoomTarget = nextZoom.clamp(_minZoom, _maxZoom);
    });
  }

  Future<void> _pickImageAttachment() async {
    if (panelBody == null) return;

    final file = await _imagePicker.pickImage(source: ImageSource.gallery);
    if (file == null || !mounted) return;
    final bytes = kIsWeb ? await file.readAsBytes() : null;

    setState(() {
      panelBody!.attachments.add(
        NoteAttachment(
          path: file.path,
          name: file.name,
          type: AttachmentType.image,
          bytes: bytes,
        ),
      );
    });
  }

  Future<void> _pickDocumentAttachment() async {
    if (panelBody == null) return;

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ["pdf", "doc", "docx"],
      withData: kIsWeb,
    );
    if (result == null || result.files.isEmpty || !mounted) return;

    final picked = result.files.single;
    final path = picked.path ?? "";
    if (path.isEmpty && picked.bytes == null) return;

    setState(() {
      panelBody!.attachments.add(
        NoteAttachment(
          path: path,
          name: picked.name,
          type: AttachmentType.document,
          bytes: picked.bytes,
        ),
      );
    });
  }

  Future<void> _openAttachment(NoteAttachment attachment) async {
    if (attachment.type == AttachmentType.image) {
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(16),
          child: InteractiveViewer(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: _buildAttachmentImage(attachment, fit: BoxFit.contain),
            ),
          ),
        ),
      );
      return;
    }

    if (kIsWeb) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Document opening is available on Android. Web preview is not supported yet.",
          ),
        ),
      );
      return;
    }

    await OpenFilex.open(attachment.path);
  }

  Widget _buildAttachmentImage(
    NoteAttachment attachment, {
    required BoxFit fit,
    double? height,
    double? width,
  }) {
    if (attachment.bytes != null) {
      return Image.memory(
        attachment.bytes!,
        height: height,
        width: width,
        fit: fit,
        errorBuilder: (_, __, ___) => _brokenImagePlaceholder(height),
      );
    }

    if (!kIsWeb && attachment.path.isNotEmpty) {
      return Image.file(
        File(attachment.path),
        height: height,
        width: width,
        fit: fit,
        errorBuilder: (_, __, ___) => _brokenImagePlaceholder(height),
      );
    }

    return _brokenImagePlaceholder(height);
  }

  Widget _brokenImagePlaceholder(double? height) {
    return Container(
      height: height,
      color: Colors.white10,
      alignment: Alignment.center,
      child: const Icon(Icons.broken_image_outlined, color: Colors.white24),
    );
  }

  Widget _buildAttachmentSection(bool isCompact) {
    final body = panelBody;
    if (body == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                "ATTACHMENTS",
                style: TextStyle(
                  color: Colors.white60,
                  fontSize: isCompact ? 11 : 12,
                  letterSpacing: 2,
                ),
              ),
            ),
            if (isEditMode) ...[
              IconButton(
                onPressed: _pickImageAttachment,
                icon: const Icon(Icons.image_outlined, color: Colors.white70),
                tooltip: "Add image",
              ),
              IconButton(
                onPressed: _pickDocumentAttachment,
                icon: const Icon(Icons.attach_file, color: Colors.white70),
                tooltip: "Add PDF or Word file",
              ),
            ],
          ],
        ),
        const SizedBox(height: 10),
        if (body.attachments.isEmpty)
          const Text(
            "No attachments yet.",
            style: TextStyle(color: Colors.white24, fontSize: 13),
          )
        else
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: body.attachments.map((attachment) {
              final isImage = attachment.type == AttachmentType.image;
              return GestureDetector(
                onTap: () => _openAttachment(attachment),
                child: Container(
                  width: isImage
                      ? (isCompact ? 110 : 140)
                      : (isCompact ? 140 : 180),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isImage)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: _buildAttachmentImage(
                            attachment,
                            height: isCompact ? 80 : 100,
                            width: double.infinity,
                            fit: BoxFit.cover,
                          ),
                        )
                      else
                        Container(
                          height: isCompact ? 80 : 100,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white10,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            attachment.name.toLowerCase().endsWith(".pdf")
                                ? Icons.picture_as_pdf_outlined
                                : Icons.description_outlined,
                            color: Colors.white70,
                            size: 34,
                          ),
                        ),
                      const SizedBox(height: 8),
                      Text(
                        attachment.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  void _stepZoom(double delta) {
    _setZoom(zoomTarget + delta);
  }

  Body? detectBody(Offset world, Size viewportSize) {
    for (final b in bodies.reversed) {
      final hitPos = _resolvedBodyPosition(
        body: b,
        selected: selected,
        mode: mode,
        bodies: bodies,
        viewportSize: viewportSize,
        zoomLevel: zoom,
        focusProgress: focusProgress,
      );

      final r =
          (b.type == BodyType.sun
              ? 60
              : (b.type == BodyType.planet ? 40 : 25)) /
          zoom;
      if ((hitPos - world).distance < r) {
        return b;
      }
    }
    return null;
  }

  void _checkDeadlines() {
    if (!mounted || _deadlineDialogOpen) return;

    final now = DateTime.now();
    JournalEntry? dueEntry;
    for (final entry in journal) {
      if (entry.isDone || entry.deadline == null || entry.deadlineAlertShown) {
        continue;
      }

      final remaining = entry.deadline!.difference(now);
      if (remaining <= const Duration(minutes: 5) &&
          remaining > Duration.zero) {
        dueEntry = entry;
        break;
      }
    }

    if (dueEntry == null) return;

    dueEntry.deadlineAlertShown = true;
    _deadlineDialogOpen = true;
    final localizations = MaterialLocalizations.of(context);
    final deadlineText =
        "${localizations.formatMediumDate(dueEntry.deadline!)} ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(dueEntry.deadline!))}";

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Deadline Approaching"),
        content: Text(
          "\"${dueEntry!.task}\" is due at $deadlineText.\nAbout 5 minutes remain.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Dismiss"),
          ),
        ],
      ),
    ).whenComplete(() {
      _deadlineDialogOpen = false;
    });
  }

  @override
  void dispose() {
    ticker.dispose();
    _deadlineTimer?.cancel();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final shortestSide = min(size.width, size.height);
    final isCompact = shortestSide < 700;
    final suns = bodies.where((b) => b.type == BodyType.sun).toList();

    return Scaffold(
      body: Stack(
        children: [
          // MAP LAYER
          Positioned.fill(
            child: Listener(
              onPointerSignal: (e) {
                if (e is PointerScrollEvent) {
                  _setZoom(zoomTarget - e.scrollDelta.dy * 0.0005);
                }
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (details) {
                  _gestureStartZoom = zoomTarget;
                  _gestureStartCamera = cameraTarget;
                  _gestureStartFocalPoint = details.localFocalPoint;
                },
                onScaleUpdate: (details) {
                  if (details.pointerCount > 1) {
                    _setZoom(_gestureStartZoom * details.scale);
                    return;
                  }

                  setState(() {
                    cameraTarget =
                        _gestureStartCamera -
                        (details.localFocalPoint - _gestureStartFocalPoint) /
                            zoom;
                  });
                },
                onTapDown: (d) {
                  final world = screenToWorld(d.localPosition, size);
                  final b = detectBody(world, size);
                  if (b != null) {
                    if (b.type == BodyType.moon) {
                      openPanel(b);
                    } else {
                      focusBody(b, size);
                    }
                  } else {
                    if (bodies.isNotEmpty) {
                      // Click empty space -> navigate back to nearest sun or current selected sun
                      Body? root = bodies.firstWhere(
                        (b) => b.type == BodyType.sun,
                      );
                      if (selected != null) {
                        Body? p = selected;
                        while (p != null && p.type != BodyType.sun) {
                          p = p.parent;
                        }
                        if (p != null) root = p;
                      }
                      selected = root;
                      mode = MapMode.system;
                      zoomTarget = _defaultZoom;
                      cameraTarget = root.position;
                      showPanel = false;
                    }
                  }
                },
                child: CustomPaint(
                  painter: OrbitPainter(
                    bodies,
                    camera,
                    zoom,
                    selected,
                    mode,
                    focusProgress,
                    size,
                  ),
                  child: Container(),
                ),
              ),
            ),
          ),

          // START PROMPT
          if (bodies.isEmpty)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "NO SYSTEM FOUND",
                    style: TextStyle(
                      letterSpacing: 6,
                      color: Colors.white24,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: createSubject,
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text("INITIALIZE CORE"),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                      backgroundColor: Colors.white.withValues(alpha: 0.05),
                      side: const BorderSide(color: Colors.white12),
                    ),
                  ),
                ],
              ),
            ),

          // OVERLAY UI
          if (bodies.isNotEmpty) ...[
            // TOP SYSTEMS TABS
            if (suns.length > 1)
              Positioned(
                top: 20,
                left: isCompact ? 72 : 100,
                right: isCompact ? 72 : 100,
                child: Center(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: suns.map((sun) {
                        bool isActive = false;
                        if (selected != null) {
                          Body? p = selected;
                          while (p != null && p.type != BodyType.sun) {
                            p = p.parent;
                          }
                          if (p == sun) isActive = true;
                        }
                        return GestureDetector(
                          onTap: () {
                            setState(() {
                              selected = sun;
                              mode = MapMode.system;
                              cameraTarget = sun.position;
                              zoomTarget = _defaultZoom;
                              showPanel = false;
                            });
                          },
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Colors.black45,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: isActive
                                    ? Colors.cyanAccent
                                    : Colors.white12,
                              ),
                            ),
                            child: Text(
                              sun.text.toUpperCase(),
                              style: TextStyle(
                                fontSize: 12,
                                letterSpacing: 2,
                                color: isActive
                                    ? Colors.cyanAccent
                                    : Colors.white60,
                                fontWeight: isActive
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),

            // SIDEBAR
            if (!isCompact)
              Positioned(
                left: 20,
                top: 60,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sidebarBtn(Icons.auto_awesome, _addNewCore, "SYSTEM"),
                    _sidebarBtn(Icons.refresh, createSubject, "RESET"),
                    _sidebarBtn(Icons.public, createPlanet, "PLANET"),
                    if (selected?.type == BodyType.planet ||
                        selected?.type == BodyType.moon)
                      _sidebarBtn(Icons.brightness_3, createMoon, "TOPIC"),
                    const SizedBox(height: 10),
                    _sidebarBtn(Icons.auto_fix_high, () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ProgressTrackerPage(
                            bodies: List<Body>.from(bodies),
                          ),
                        ),
                      );
                    }, "TRACKER"),
                    _sidebarBtn(Icons.book, () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => JournalPage(journal: journal),
                        ),
                      );
                    }, "TO-DO"),
                  ],
                ),
              ),

            // BOTTOM TITLE
            if (selected != null && !showPanel)
              Positioned(
                bottom: isCompact ? 118 : 60,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: Column(
                      children: [
                        Text(
                          selected!.text.toUpperCase(),
                          style: TextStyle(
                            fontSize: isCompact ? 20 : 28,
                            letterSpacing: isCompact ? 3 : 6,
                            fontWeight: FontWeight.w200,
                            color: Colors.white,
                            shadows: [
                              Shadow(
                                color: selected!.color.withValues(alpha: 0.5),
                                blurRadius: 20,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          width: 150,
                          height: 1,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.transparent,
                                Colors.white24,
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            Positioned(
              right: 16,
              bottom: isCompact ? 108 : 24,
              child: _buildZoomControls(),
            ),

            if (isCompact)
              Positioned(
                left: 12,
                right: 12,
                bottom: 20,
                child: _buildCompactActionBar(),
              ),

            // SIDE PANEL
            if (showPanel && panelBody != null)
              _buildSidePanel(size, isCompact),
          ],
        ],
      ),
    );
  }

  Widget _sidebarBtn(IconData icon, VoidCallback tap, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(icon, color: Colors.white70, size: 24),
            onPressed: tap,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFF0F1633).withValues(alpha: 0.8),
              side: const BorderSide(color: Colors.white12),
              padding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              letterSpacing: 2,
              color: Colors.white38,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildZoomControls() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0F1633).withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: () => _stepZoom(0.15),
            icon: const Icon(Icons.add, color: Colors.white70),
            tooltip: "Zoom in",
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              "${(zoomTarget * 100).round()}%",
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 11,
                letterSpacing: 1,
              ),
            ),
          ),
          IconButton(
            onPressed: () => _stepZoom(-0.15),
            icon: const Icon(Icons.remove, color: Colors.white70),
            tooltip: "Zoom out",
          ),
        ],
      ),
    );
  }

  Widget _buildCompactActionBar() {
    final actions = <Widget>[
      _compactActionBtn(Icons.auto_awesome, "System", _addNewCore),
      _compactActionBtn(Icons.refresh, "Reset", createSubject),
      _compactActionBtn(Icons.public, "Planet", createPlanet),
      if (selected?.type == BodyType.planet || selected?.type == BodyType.moon)
        _compactActionBtn(Icons.brightness_3, "Topic", createMoon),
      _compactActionBtn(Icons.auto_fix_high, "Tracker", () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                ProgressTrackerPage(bodies: List<Body>.from(bodies)),
          ),
        );
      }),
      _compactActionBtn(Icons.book, "To-Do", () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => JournalPage(journal: journal),
          ),
        );
      }),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF0F1633).withValues(alpha: 0.86),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 18,
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(children: actions),
        ),
      ),
    );
  }

  Widget _compactActionBtn(IconData icon, String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18, color: Colors.white70),
        label: Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 10,
            letterSpacing: 1.4,
            color: Colors.white60,
          ),
        ),
      ),
    );
  }

  Widget _buildSidePanel(Size size, bool isCompact) {
    final width = isCompact ? min(size.width - 24, 420.0) : size.width * 0.45;
    return Positioned(
      right: isCompact ? 12 : 0,
      top: isCompact ? 12 : 0,
      bottom: isCompact ? 12 : 0,
      child: Container(
        width: width,
        decoration: BoxDecoration(
          color: const Color(0xFF0F1633).withValues(alpha: 0.98),
          border: Border.all(color: Colors.white24, width: 2),
          borderRadius: isCompact ? BorderRadius.circular(18) : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 40,
            ),
          ],
        ),
        child: Column(
          children: [
            // Header
            Container(
              height: 60,
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.white24, width: 2),
                ),
              ),
              child: IntrinsicHeight(
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                panelBody!.text,
                                style: const TextStyle(
                                  fontSize: 22,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w300,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              onPressed: () {
                                setState(() {
                                  panelBody!.isCompleted =
                                      !panelBody!.isCompleted;
                                });
                              },
                              icon: Icon(
                                panelBody!.isCompleted
                                    ? Icons.check_circle
                                    : Icons.radio_button_unchecked,
                                color: panelBody!.isCompleted
                                    ? Colors.cyanAccent
                                    : Colors.white24,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const VerticalDivider(
                      color: Colors.white38,
                      width: 1,
                      thickness: 1.5,
                    ),
                    Expanded(
                      child: InkWell(
                        onTap: () => setState(() => isEditMode = true),
                        child: const Center(
                          child: Icon(
                            Icons.edit,
                            color: Colors.white60,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                    const VerticalDivider(
                      color: Colors.white38,
                      width: 1,
                      thickness: 1.5,
                    ),
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            bodies.remove(panelBody);
                            showPanel = false;
                            if (selected == panelBody)
                              selected = bodies.isNotEmpty
                                  ? bodies.first
                                  : null;
                          });
                        },
                        child: const Center(
                          child: Icon(
                            Icons.delete,
                            color: Colors.redAccent,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Notes Body
            Expanded(
              child: Container(
                padding: EdgeInsets.all(isCompact ? 18 : 30),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isEditMode)
                        SizedBox(
                          height: isCompact ? 180 : 240,
                          child: TextField(
                            controller: _notesController,
                            maxLines: null,
                            expands: true,
                            style: TextStyle(
                              fontSize: isCompact ? 16 : 20,
                              color: Colors.white,
                              height: 1.6,
                            ),
                            decoration: const InputDecoration(
                              hintText: "Write notes here...",
                              hintStyle: TextStyle(color: Colors.white24),
                              border: InputBorder.none,
                            ),
                          ),
                        )
                      else
                        Text(
                          panelBody!.overview.isEmpty
                              ? "No text notes yet."
                              : panelBody!.overview,
                          style: TextStyle(
                            fontSize: isCompact ? 16 : 20,
                            color: panelBody!.overview.isEmpty
                                ? Colors.white24
                                : Colors.white70,
                            height: 1.6,
                          ),
                        ),
                      const SizedBox(height: 24),
                      _buildAttachmentSection(isCompact),
                    ],
                  ),
                ),
              ),
            ),
            // Footer
            Container(
              height: 60,
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: Colors.white24, width: 2),
                ),
              ),
              child: IntrinsicHeight(
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => setState(() => showPanel = false),
                        child: const Center(
                          child: Text(
                            "close",
                            style: TextStyle(
                              fontSize: 18,
                              color: Colors.white60,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (isEditMode) ...[
                      const VerticalDivider(
                        color: Colors.white38,
                        width: 1,
                        thickness: 1.5,
                      ),
                      Expanded(
                        child: InkWell(
                          onTap: () {
                            setState(() {
                              panelBody!.overview = _notesController.text;
                              isEditMode = false;
                            });
                          },
                          child: const Center(
                            child: Text(
                              "save",
                              style: TextStyle(
                                fontSize: 18,
                                color: Colors.white60,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ProgressTrackerPage extends StatefulWidget {
  final List<Body> bodies;
  const ProgressTrackerPage({super.key, required this.bodies});

  @override
  State<ProgressTrackerPage> createState() => _ProgressTrackerPageState();
}

class _ProgressTrackerPageState extends State<ProgressTrackerPage> {
  int _currentSunIndex = 0;
  int _selectedPlanetIndex = 0;
  List<Body> suns = [];

  @override
  void initState() {
    super.initState();
    suns = widget.bodies.where((b) => b.type == BodyType.sun).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (suns.isEmpty)
      return const Scaffold(body: Center(child: Text("No Cores")));

    final size = MediaQuery.of(context).size;
    final isCompact = min(size.width, size.height) < 700;
    final currentSun = suns[_currentSunIndex];
    final planets = widget.bodies
        .where((b) => b.parent == currentSun && b.type == BodyType.planet)
        .toList();

    final moons = widget.bodies.where((b) {
      if (b.type != BodyType.moon) return false;
      Body? p = b.parent;
      while (p != null && p.type != BodyType.sun) {
        p = p.parent;
      }
      return p == currentSun;
    }).toList();

    final completedCount = moons.where((m) => m.isCompleted).length;
    final totalCount = moons.length;
    final progress = totalCount == 0 ? 0.0 : completedCount / totalCount;

    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: SkyrimBackground()),

          // Global Progress Tree for the current System
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return CustomPaint(
                  painter: GlobalTreePainter(
                    sun: currentSun,
                    bodies: widget.bodies,
                    selectedIndex: _selectedPlanetIndex,
                    canvasSize: constraints.biggest,
                  ),
                );
              },
            ),
          ),

          // Top UI (Systems Navigation & Progress)
          Positioned(
            top: isCompact ? 24 : 40,
            left: 0,
            right: 0,
            child: Column(
              children: [
                if (suns.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: suns.asMap().entries.map((entry) {
                          int idx = entry.key;
                          Body s = entry.value;
                          bool isSel = idx == _currentSunIndex;
                          return GestureDetector(
                            onTap: () => setState(() {
                              _currentSunIndex = idx;
                              _selectedPlanetIndex = 0;
                            }),
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 8),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: isSel
                                      ? Colors.cyanAccent
                                      : Colors.white12,
                                ),
                                borderRadius: BorderRadius.circular(15),
                                color: isSel
                                    ? Colors.cyanAccent.withValues(alpha: 0.1)
                                    : Colors.black26,
                              ),
                              child: Text(
                                s.text.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 10,
                                  letterSpacing: 1,
                                  color: isSel
                                      ? Colors.cyanAccent
                                      : Colors.white38,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                _buildTopUI(progress, completedCount, totalCount),
              ],
            ),
          ),

          // Planet Switcher (Invisible PageView control logic)
          if (planets.isNotEmpty)
            Positioned(
              bottom: 180,
              left: 0,
              right: 0,
              height: 100,
              child: PageView.builder(
                onPageChanged: (i) => setState(() => _selectedPlanetIndex = i),
                itemCount: planets.length,
                itemBuilder: (context, index) => Container(),
              ),
            ),

          Positioned(
            bottom: 120,
            left: 0,
            right: 0,
            child: Column(
              children: [
                if (planets.isNotEmpty &&
                    _selectedPlanetIndex < planets.length) ...[
                  Builder(
                    builder: (context) {
                      final selectedPlanet = planets[_selectedPlanetIndex];
                      final pMoons = widget.bodies
                          .where(
                            (b) =>
                                b.parent == selectedPlanet &&
                                b.type == BodyType.moon,
                          )
                          .toList();
                      final level = pMoons.isEmpty
                          ? 15
                          : (pMoons.where((m) => m.isCompleted).length /
                                        pMoons.length *
                                        85 +
                                    15)
                                .toInt();
                      return Text(
                        "${selectedPlanet.text.toUpperCase()} $level",
                        style: TextStyle(
                          fontSize: isCompact ? 16 : 22,
                          letterSpacing: isCompact ? 2 : 4,
                          color: Colors.white,
                          fontWeight: FontWeight.w300,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Container(width: 150, height: 2, color: Colors.white30),
                  const SizedBox(height: 16),
                ],
                Text(
                  currentSun.text.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: isCompact ? 34 : 64,
                    letterSpacing: isCompact ? 5 : 12,
                    fontWeight: FontWeight.w100,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Container(width: 200, height: 2, color: Colors.white30),
              ],
            ),
          ),

          Positioned(bottom: 30, left: 0, right: 0, child: _buildBottomBars()),

          Positioned(
            top: 20,
            left: 20,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white38),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopUI(double progress, int completed, int total) {
    final size = MediaQuery.of(context).size;
    final isCompact = min(size.width, size.height) < 700;
    return Column(
      children: [
        Text(
          "PROGRESS",
          style: TextStyle(
            fontSize: isCompact ? 16 : 20,
            letterSpacing: isCompact ? 3 : 4,
            fontWeight: FontWeight.w300,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          width: min(size.width * 0.72, 300.0),
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white10,
            border: Border.all(color: Colors.white24, width: 0.5),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: progress.clamp(0.0, 1.0),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.cyanAccent,
                boxShadow: [
                  BoxShadow(
                    color: Colors.cyanAccent.withValues(alpha: 0.5),
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 15),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white12),
            color: Colors.black26,
          ),
          child: Text(
            "Topics to complete: ${total - completed}",
            style: const TextStyle(
              fontSize: 13,
              letterSpacing: 2,
              color: Colors.white60,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomBars() {
    final size = MediaQuery.of(context).size;
    final isCompact = min(size.width, size.height) < 700;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: isCompact ? 16 : 40,
      runSpacing: 12,
      children: [
        _statBar("MODULES", const Color(0xFF4A90E2), 0.8, isCompact),
        _statBar("COMPLETION", const Color(0xFFD0021B), 1.0, isCompact),
        _statBar("MASTERY", const Color(0xFF417505), 0.6, isCompact),
      ],
    );
  }

  Widget _statBar(String label, Color color, double val, bool isCompact) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: isCompact ? 110 : 200,
          height: 8,
          decoration: BoxDecoration(
            color: Colors.black45,
            border: Border.all(color: Colors.white10),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: val,
            child: Container(color: color.withValues(alpha: 0.8)),
          ),
        ),
      ],
    );
  }
}

class GlobalTreePainter extends CustomPainter {
  final Body sun;
  final List<Body> bodies;
  final int selectedIndex;
  final Size canvasSize;

  GlobalTreePainter({
    required this.sun,
    required this.bodies,
    required this.selectedIndex,
    required this.canvasSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    // Core node anchor
    final centerY = size.height - 250;
    final sunPos = Offset(centerX, centerY);

    final planets = bodies
        .where((b) => b.parent == sun && b.type == BodyType.planet)
        .toList();
    if (planets.isEmpty) return;

    double baseScale = min(size.width / 800, size.height / 800).clamp(0.5, 1.0);

    for (int i = 0; i < planets.length; i++) {
      final planet = planets[i];
      final isSelected = i == selectedIndex;

      double spreadAngle = pi * 0.6;
      double startAngle = -pi / 2 - spreadAngle / 2;
      double planetAngle = planets.length > 1
          ? startAngle + (i / (planets.length - 1)) * spreadAngle
          : -pi / 2;

      double planetDist = (isSelected ? 180.0 : 150.0) * baseScale;
      final planetPos =
          sunPos +
          Offset(cos(planetAngle) * planetDist, sin(planetAngle) * planetDist);

      final linePaint = Paint()
        ..color = planet.color.withValues(alpha: isSelected ? 0.4 : 0.1)
        ..strokeWidth = 0.8;

      canvas.drawLine(sunPos, planetPos, linePaint);

      final moons = bodies
          .where((b) => b.parent == planet && b.type == BodyType.moon)
          .toList();

      for (int j = 0; j < moons.length; j++) {
        final moon = moons[j];
        double moonSpread = pi * 0.3;
        double moonAngle =
            planetAngle +
            (moons.length > 1
                ? (j / (moons.length - 1) - 0.5) * moonSpread
                : 0);
        double moonDist = (isSelected ? 80.0 : 60.0) * baseScale;
        final moonPos =
            planetPos +
            Offset(cos(moonAngle) * moonDist, sin(moonAngle) * moonDist);

        // Connect Planet to Moon ONLY
        canvas.drawLine(
          planetPos,
          moonPos,
          linePaint
            ..color = planet.color.withValues(alpha: isSelected ? 0.3 : 0.1),
        );

        final starColor = moon.isCompleted ? Colors.white : Colors.white24;
        if (moon.isCompleted) {
          canvas.drawCircle(
            moonPos,
            10 * baseScale,
            Paint()
              ..color = planet.color.withValues(alpha: 0.2)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
          );
        }
        canvas.drawCircle(
          moonPos,
          (isSelected ? 4 : 2) * baseScale,
          Paint()..color = starColor,
        );

        if (isSelected) {
          final tp = TextPainter(
            text: TextSpan(
              text: moon.text.toUpperCase(),
              style: TextStyle(
                color: starColor,
                fontSize: 9 * baseScale,
                letterSpacing: 1,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(canvas, moonPos + Offset(-tp.width / 2, 10 * baseScale));
        }
      }

      canvas.drawCircle(
        planetPos,
        (isSelected ? 8 : 5) * baseScale,
        Paint()
          ..color = planet.color
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, isSelected ? 10 : 5),
      );
      canvas.drawCircle(
        planetPos,
        (isSelected ? 4 : 2) * baseScale,
        Paint()..color = Colors.white,
      );
    }

    // Core Node
    canvas.drawCircle(
      sunPos,
      15 * baseScale,
      Paint()
        ..color = Colors.orangeAccent.withValues(alpha: 0.2)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15),
    );
    canvas.drawCircle(
      sunPos,
      8 * baseScale,
      Paint()..color = Colors.orangeAccent,
    );
  }

  @override
  bool shouldRepaint(covariant GlobalTreePainter oldDelegate) => true;
}

class JournalPage extends StatefulWidget {
  final List<JournalEntry> journal;
  const JournalPage({super.key, required this.journal});

  @override
  State<JournalPage> createState() => _JournalPageState();
}

class _JournalPageState extends State<JournalPage> {
  final TextEditingController _controller = TextEditingController();

  void _addTask() {
    if (_controller.text.trim().isEmpty) return;
    setState(() {
      widget.journal.add(JournalEntry(task: _controller.text.trim()));
      _controller.clear();
    });
  }

  String _formatDeadline(DateTime deadline) {
    final localizations = MaterialLocalizations.of(context);
    return "${localizations.formatMediumDate(deadline)} ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(deadline))}";
  }

  Future<void> _setDeadline(JournalEntry entry) async {
    final now = DateTime.now();
    final initialDate = entry.deadline ?? now;
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 5),
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Colors.cyanAccent,
              onPrimary: Colors.black,
              surface: Color(0xFF0F1633),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (pickedDate == null || !mounted) return;

    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: entry.deadline != null
          ? TimeOfDay.fromDateTime(entry.deadline!)
          : TimeOfDay.now(),
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Colors.cyanAccent,
              onPrimary: Colors.black,
              surface: Color(0xFF0F1633),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        entry.deadline = DateTime(
          pickedDate.year,
          pickedDate.month,
          pickedDate.day,
          picked.hour,
          picked.minute,
        );
        entry.deadlineAlertShown = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isCompact = min(size.width, size.height) < 700;
    final completedCount = widget.journal.where((item) => item.isDone).length;
    final totalCount = widget.journal.length;
    final progress = totalCount == 0 ? 0.0 : completedCount / totalCount;

    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: SkyrimBackground()),
          Positioned(
            top: isCompact ? 20 : 40,
            left: isCompact ? 12 : 20,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white38),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          Center(
            child: Container(
              width: min(size.width - (isCompact ? 24 : 48), 500.0),
              height: min(size.height - (isCompact ? 40 : 80), 600.0),
              padding: EdgeInsets.all(isCompact ? 18 : 30),
              decoration: BoxDecoration(
                color: const Color(0xFF0F1633).withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                children: [
                  Text(
                    "TO-DO LIST",
                    style: TextStyle(
                      fontSize: isCompact ? 22 : 28,
                      letterSpacing: isCompact ? 4 : 8,
                      fontWeight: FontWeight.w200,
                    ),
                  ),
                  const Divider(color: Colors.white24, height: 40),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          decoration: const InputDecoration(
                            hintText: "Add new task...",
                            hintStyle: TextStyle(color: Colors.white24),
                            border: InputBorder.none,
                          ),
                          onSubmitted: (_) => _addTask(),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add, color: Colors.cyanAccent),
                        onPressed: _addTask,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: ListView.builder(
                      itemCount: widget.journal.length,
                      itemBuilder: (context, index) {
                        final item = widget.journal[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Checkbox(
                            value: item.isDone,
                            activeColor: Colors.cyanAccent,
                            onChanged: (val) => setState(() {
                              item.isDone = val!;
                              if (item.isDone) {
                                item.deadlineAlertShown = true;
                              } else if (item.deadline != null &&
                                  item.deadline!.isAfter(DateTime.now())) {
                                item.deadlineAlertShown = false;
                              }
                            }),
                          ),
                          title: Text(
                            item.task,
                            style: TextStyle(
                              color: item.isDone
                                  ? Colors.white24
                                  : Colors.white70,
                              decoration: item.isDone
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                          subtitle: item.deadline != null
                              ? Text(
                                  "Deadline: ${_formatDeadline(item.deadline!)}",
                                  style: const TextStyle(
                                    color: Colors.cyanAccent,
                                    fontSize: 12,
                                  ),
                                )
                              : null,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(
                                  item.deadline != null
                                      ? Icons.alarm_on
                                      : Icons.alarm_add,
                                  color: item.deadline != null
                                      ? Colors.cyanAccent
                                      : Colors.white24,
                                  size: 20,
                                ),
                                onPressed: () => _setDeadline(item),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.redAccent,
                                  size: 20,
                                ),
                                onPressed: () => setState(
                                  () => widget.journal.removeAt(index),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Divider(color: Colors.white12),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 6,
                          decoration: BoxDecoration(
                            color: Colors.white10,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: progress,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.cyanAccent,
                                borderRadius: BorderRadius.circular(3),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.cyanAccent.withValues(
                                      alpha: 0.5,
                                    ),
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 15),
                      Text(
                        "${(progress * 100).toInt()}%",
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.cyanAccent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SkyrimBackground extends StatelessWidget {
  const SkyrimBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 1.5,
          colors: [Color(0xFF141B3D), Color(0xFF0A1028), Color(0xFF02040A)],
        ),
      ),
      child: Stack(
        children: [
          _nebula(
            Colors.indigo.withValues(alpha: 0.1),
            const Offset(-0.3, -0.2),
            400,
          ),
          _nebula(
            Colors.teal.withValues(alpha: 0.1),
            const Offset(0.4, 0.5),
            500,
          ),
          CustomPaint(painter: StarPainter(), child: Container()),
        ],
      ),
    );
  }

  Widget _nebula(Color color, Offset align, double size) {
    return Align(
      alignment: Alignment(align.dx, align.dy),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, Colors.transparent]),
        ),
      ),
    );
  }
}

class StarPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final random = Random(123);
    for (int i = 0; i < 300; i++) {
      final pos = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      canvas.drawCircle(
        pos,
        random.nextDouble() * 1.5,
        Paint()
          ..color = Colors.white.withValues(alpha: random.nextDouble() * 0.4),
      );
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}

class OrbitPainter extends CustomPainter {
  final List<Body> bodies;
  final Offset camera;
  final double zoom;
  final Body? selected;
  final MapMode mode;
  final double focusProgress;
  final Size viewportSize;

  OrbitPainter(
    this.bodies,
    this.camera,
    this.zoom,
    this.selected,
    this.mode,
    this.focusProgress,
    this.viewportSize,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final bgPaint = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 1.5,
        colors: [const Color(0xFF0A1028), const Color(0xFF02040A)],
      ).createShader(rect);
    canvas.drawRect(rect, bgPaint);

    final random = Random(42);
    for (int i = 0; i < 200; i++) {
      final starPos = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      final alpha = random.nextDouble() * 0.4 + 0.1;
      canvas.drawCircle(
        starPos,
        random.nextDouble() * 1.5,
        Paint()..color = Colors.white.withOpacity(alpha),
      );
    }

    final nebulaPaint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 80);
    canvas.drawCircle(
      Offset(size.width * 0.2, size.height * 0.3),
      250,
      nebulaPaint..color = Colors.indigo.withValues(alpha: 0.05),
    );
    canvas.drawCircle(
      Offset(size.width * 0.8, size.height * 0.7),
      300,
      nebulaPaint..color = Colors.blueGrey.withValues(alpha: 0.05),
    );

    if (bodies.isEmpty) return;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(zoom);
    canvas.translate(-camera.dx, -camera.dy);

    for (final b in bodies) {
      if (b.type == BodyType.planet && b.parent != null) {
        canvas.save();
        canvas.translate(b.parent!.position.dx, b.parent!.position.dy);
        canvas.rotate(b.orbitTilt);
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset.zero,
            width: b.orbitRadius * 2,
            height: b.orbitHeight * 2,
          ),
          Paint()
            ..style = PaintingStyle.stroke
            ..color = Colors.white.withValues(alpha: 0.03)
            ..strokeWidth = 1.0 / zoom,
        );
        canvas.restore();
      }

      if (b.parent != null) {
        Offset start = b.parent!.position;
        Offset end = _resolvedBodyPosition(
          body: b,
          selected: selected,
          mode: mode,
          bodies: bodies,
          viewportSize: viewportSize,
          zoomLevel: zoom,
          focusProgress: focusProgress,
        );

        final linePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (b == selected ? 2.0 : 0.5) / zoom
          ..color = (b == selected || b.isCompleted ? b.color : Colors.white)
              .withValues(alpha: 0.1);
        canvas.drawLine(start, end, linePaint);
      }
    }

    for (final b in bodies) {
      final drawPos = _resolvedBodyPosition(
        body: b,
        selected: selected,
        mode: mode,
        bodies: bodies,
        viewportSize: viewportSize,
        zoomLevel: zoom,
        focusProgress: focusProgress,
      );

      switch (b.type) {
        case BodyType.sun:
          _drawSun(canvas, drawPos);
          break;
        case BodyType.planet:
          _drawPlanet(canvas, drawPos, b.color, b == selected || b.isCompleted);
          break;
        case BodyType.moon:
          _drawMoon(
            canvas,
            drawPos,
            b == selected || b.isCompleted,
            b.isCompleted,
          );
          break;
      }

      if (zoom > 0.4) {
        final isHighlighted = b == selected || b.isCompleted;
        final tp = TextPainter(
          text: TextSpan(
            text: b.text.toUpperCase(),
            style: TextStyle(
              color: isHighlighted ? Colors.white : Colors.white24,
              fontSize: (b.type == BodyType.sun ? 14 : 10) / zoom,
              letterSpacing: 2,
              fontWeight: isHighlighted ? FontWeight.w400 : FontWeight.w200,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          drawPos +
              Offset(-tp.width / 2, (b.type == BodyType.sun ? 50 : 30) / zoom),
        );
      }
    }

    canvas.restore();
  }

  void _drawSun(Canvas canvas, Offset pos) {
    canvas.drawCircle(
      pos,
      50,
      Paint()
        ..color = Colors.orangeAccent.withValues(alpha: 0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30),
    );
    canvas.drawCircle(
      pos,
      45,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white,
            Colors.yellow,
            Colors.orange,
            Colors.transparent,
          ],
          stops: const [0.0, 0.3, 0.7, 1.0],
        ).createShader(Rect.fromCircle(center: pos, radius: 45)),
    );
  }

  void _drawPlanet(Canvas canvas, Offset pos, Color color, bool isHighlighted) {
    final radius = 24.0;
    if (isHighlighted)
      canvas.drawCircle(
        pos,
        radius + 8,
        Paint()
          ..color = color.withValues(alpha: 0.2)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );
    canvas.drawCircle(
      pos,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.4, -0.4),
          colors: [
            color.withValues(alpha: 0.9),
            color.withValues(alpha: 0.6),
            color.withValues(alpha: 0.2),
            Colors.black,
          ],
          stops: const [0.0, 0.3, 0.7, 1.0],
        ).createShader(Rect.fromCircle(center: pos, radius: radius)),
    );
    canvas.drawCircle(
      pos,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white.withValues(alpha: 0.1)
        ..strokeWidth = 1,
    );
  }

  void _drawMoon(
    Canvas canvas,
    Offset pos,
    bool isHighlighted,
    bool isCompleted,
  ) {
    final radius = 10.0;
    final color = isCompleted ? Colors.cyanAccent : Colors.grey.shade300;
    canvas.drawCircle(
      pos,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.2, -0.2),
          colors: [color, color.withValues(alpha: 0.5), Colors.black],
        ).createShader(Rect.fromCircle(center: pos, radius: radius)),
    );
    if (isHighlighted)
      canvas.drawCircle(
        pos,
        radius + 5,
        Paint()
          ..color = color.withValues(alpha: 0.15)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    canvas.drawCircle(
      pos + const Offset(2, -2),
      1.5,
      Paint()..color = Colors.black26,
    );
    canvas.drawCircle(
      pos + const Offset(-3, 1),
      1.2,
      Paint()..color = Colors.black26,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
