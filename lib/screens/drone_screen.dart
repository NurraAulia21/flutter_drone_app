import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/rendering.dart';
import '../constants/app_colors.dart';
import '../models/drone.dart';

class DroneScreen extends StatefulWidget {
  final DroneOption drone;
  const DroneScreen({super.key, required this.drone});

  @override
  State<DroneScreen> createState() => _DroneScreenState();
}

class _DroneScreenState extends State<DroneScreen> with WidgetsBindingObserver {
  bool _isActive = false;
  bool _isPosting = false;
  String _status = 'IDLE';

  double? _latitude;
  double? _longitude;
  String _locationText = 'Menunggu GPS...';

  double _waterLevel = 0.0;
  File? _capturedPhoto;
  File? _taggedPhoto;
  bool _showReportPreview = false;

  StreamSubscription<Position>? _positionStream;
  Timer? _hoverTimer;
  Timer? _postTimer;
  Timer? _statusDebounceTimer;
  Timer? _droneCheckTimer;

  static const String _baseUrl = 'https://api-drone.heivet.com/api';
  static const bool isTesting = true;
  static const double _accuracyThreshold = 50.0;
  static const double _speedFlyingThreshold = isTesting ? 0.4 : 2.0;
  static const double _speedHoverThreshold = 0.15;
  double _currentSpeed = 0.0;
  double _averageSpeed = 0.0;

  final List<double> _speedBuffer = [];
  static const int _bufferSize = 4;
  String _pendingStatus = 'IDLE';
  final ImagePicker _picker = ImagePicker();
  final http.Client _httpClient = http.Client();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkLocationPermission();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _hoverTimer?.cancel();
    _postTimer?.cancel();
    _statusDebounceTimer?.cancel();
    _droneCheckTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);

    // FORCE STOP saat screen ditutup
    if (_isActive) {
      _forceStopDrone();
    }

    _httpClient.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      if (_isActive) {
        _httpClient.post(
          Uri.parse('$_baseUrl/stop-drone'),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({'drone_id': widget.drone.id}),
        );
        _positionStream?.cancel();
        _hoverTimer?.cancel();
        _postTimer?.cancel();
        _statusDebounceTimer?.cancel();
        _droneCheckTimer?.cancel();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_isActive && _positionStream == null) {
        _startLocationStream();
      }
    }
  }

  // ==================== PERMISSION ====================

  Future<void> _checkLocationPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      setState(() => _locationText = 'Izin GPS ditolak permanen');
      return;
    }
    _getInitialLocation();
  }

  Future<void> _getInitialLocation() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      setState(() {
        _latitude = position.latitude;
        _longitude = position.longitude;
        _locationText =
            '${position.latitude.toStringAsFixed(6)}° , ${position.longitude.toStringAsFixed(6)}°';
      });
    } catch (e) {
      setState(() => _locationText = 'Gagal ambil lokasi');
    }
  }

  // ==================== GPS ====================

  double _getAverageSpeed(double newSpeed) {
    _speedBuffer.add(newSpeed);
    if (_speedBuffer.length > _bufferSize) _speedBuffer.removeAt(0);
    return _speedBuffer.reduce((a, b) => a + b) / _speedBuffer.length;
  }

  void _setStatusWithDebounce(String newStatus) {
    if (_status == newStatus) return;
    _pendingStatus = newStatus;
    _statusDebounceTimer?.cancel();
    _statusDebounceTimer = Timer(const Duration(seconds: 2), () {
      if (_isActive && _status != _pendingStatus) {
        setState(() => _status = _pendingStatus);
      }
    });
  }

  void _resetHoverTimer() {
    _hoverTimer?.cancel();
    _hoverTimer = Timer(const Duration(seconds: 4), () {
      if (_isActive) _setStatusWithDebounce('HOVERING');
    });
  }

  void _startLocationStream() {
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      ),
    ).listen((Position position) {
      double speed = position.speed < 0 ? 0 : position.speed;
      double accuracy = position.accuracy;
      if (accuracy > _accuracyThreshold) return;
      double avgSpeed = _getAverageSpeed(speed);
      setState(() {
        _currentSpeed = speed;
        _averageSpeed = avgSpeed;
      });
      print(
          'Speed: ${speed.toStringAsFixed(2)} | Avg Speed: ${avgSpeed.toStringAsFixed(2)} | Accuracy: ${accuracy.toStringAsFixed(1)}');
      if (avgSpeed > _speedFlyingThreshold) {
        _setStatusWithDebounce('FLYING');
        _resetHoverTimer();
      } else if (avgSpeed < _speedHoverThreshold) {
        _resetHoverTimer();
      }
      setState(() {
        _latitude = position.latitude;
        _longitude = position.longitude;
        _locationText =
            '${position.latitude.toStringAsFixed(6)}° , ${position.longitude.toStringAsFixed(6)}°';
      });
    });
  }

  // ==================== WATER LEVEL ====================

  double _randomWaterLevel() {
    return (Random().nextInt(11) + 5) / 10.0;
  }

  // ==================== REPORT / TAGGING ====================

  Future<void> _openReport() async {
    _postTimer?.cancel();

    final XFile? photo =
        await _picker.pickImage(source: ImageSource.camera, imageQuality: 85);

    // Jika cancel kamera tanpa ambil foto
    if (photo == null) {
      if (_isActive) {
        _postTimer = Timer.periodic(
          const Duration(seconds: 5),
          (_) => _postData(),
        );
      }
      return;
    }

    setState(() {
      _capturedPhoto = File(photo.path);
      _showReportPreview = true;
      _taggedPhoto = null;
    });

    await Future.delayed(const Duration(milliseconds: 300));
    await _captureTaggedPhoto();
  }

  // Capture widget tag menjadi file gambar
  Future<void> _captureTaggedPhoto() async {
    if (_isActive) {
      _postTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _postData(),
      );
    }

    if (_capturedPhoto == null) return;

    try {
      final Uint8List originalBytes = await _capturedPhoto!.readAsBytes();
      final ui.Codec codec = await ui.instantiateImageCodec(originalBytes);
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ui.Image originalImage = frameInfo.image;

      final int imgWidth = originalImage.width;
      final int imgHeight = originalImage.height;

      // Output setengah resolusi untuk hemat ukuran
      final int outWidth = imgWidth ~/ 2;
      final int outHeight = imgHeight ~/ 2;

      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, outWidth.toDouble(), outHeight.toDouble()),
      );

      // Scale foto ke output size
      canvas.scale(0.5, 0.5);
      canvas.drawImage(originalImage, Offset.zero, Paint());

      // Siapkan teks tag
      final now = DateTime.now();
      final timeStr =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

      final List<String> lines = [
        '[LOC]  Lat: ${_latitude?.toStringAsFixed(6)} | Lng: ${_longitude?.toStringAsFixed(6)}',
        '[ALT]  Ketinggian Banjir: ${_waterLevel.toStringAsFixed(1)} m',
        '[DRN]  ${widget.drone.id} · ${widget.drone.name}',
        '[TME]  $timeStr',
      ];

      final double fontSize = imgWidth * 0.028;
      final double padding = imgWidth * 0.025;
      final double lineHeight = fontSize * 1.6;
      final double overlayHeight = (lines.length * lineHeight) + (padding * 2);

      // Background gelap
      final Paint bgPaint = Paint()..color = const Color(0xCC000000);
      canvas.drawRect(
        Rect.fromLTWH(
            0, imgHeight - overlayHeight, imgWidth.toDouble(), overlayHeight),
        bgPaint,
      );

      // Warna per baris
      final List<Color> lineColors = [
        Colors.white,
        Colors.lightBlueAccent,
        Colors.white70,
        Colors.white70,
      ];

      // Tulis teks
      for (int i = 0; i < lines.length; i++) {
        final textPainter = TextPainter(
          text: TextSpan(
            text: lines[i],
            style: TextStyle(
              color: lineColors[i],
              fontSize: fontSize,
              fontWeight: i == 1 ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout(maxWidth: imgWidth.toDouble());
        textPainter.paint(
          canvas,
          Offset(
            padding,
            imgHeight - overlayHeight + padding + (i * lineHeight),
          ),
        );
      }

      // Render ke image
      final ui.Image taggedImage =
          await recorder.endRecording().toImage(outWidth, outHeight);
      final ByteData? byteData =
          await taggedImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      // Simpan PNG dulu
      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tempFile = File('${directory.path}/temp_$timestamp.png');
      await tempFile.writeAsBytes(byteData.buffer.asUint8List());

      // Kompres ke JPEG pakai flutter_image_compress
      final String finalPath = '${directory.path}/tagged_$timestamp.jpg';
      final Uint8List? compressedBytes =
          await FlutterImageCompress.compressAndGetFile(
        tempFile.path,
        finalPath,
        quality: 60,
        format: CompressFormat.jpeg,
      ).then((file) => file?.readAsBytes());

      // Hapus temp file
      await tempFile.delete();

      if (compressedBytes != null) {
        final finalFile = File(finalPath);
        print(
            'Tagged photo size: ${(finalFile.lengthSync() / 1024).toStringAsFixed(1)} KB');
        setState(() => _taggedPhoto = finalFile);
      }
    } catch (e) {
      print('Capture tag error: $e');
    }
  }

  void _retakePhoto() {
    setState(() {
      _capturedPhoto = null;
      _taggedPhoto = null;
      _showReportPreview = false;
    });
    _openReport();
  }

  void _cancelReport() {
    setState(() {
      _capturedPhoto = null;
      _taggedPhoto = null;
      _showReportPreview = false;
    });

    if (_isActive) {
      _postTimer?.cancel();
      _postTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _postData(),
      );
    }
  }

  Future<void> _sendReport() async {
    if (_taggedPhoto == null || _latitude == null || _longitude == null) return;

    print('--- SEND REPORT ---');
    print(
        'ID: ${widget.drone.id} | Altitude: ${_waterLevel.toStringAsFixed(1)}m');
    print('Lat: $_latitude | Lng: $_longitude');
    print('Tagged photo path: ${_taggedPhoto!.path}');
    print('Tagged photo exists: ${await _taggedPhoto!.exists()}');

    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/upload-flood-image'),
      );
      request.headers['Accept'] = 'application/json';
      request.fields['drone_id'] = widget.drone.id;
      request.fields['latitude'] = _latitude.toString();
      request.fields['longitude'] = _longitude.toString();
      request.fields['altitude'] = _waterLevel.toStringAsFixed(1);

      print('Fields: ${request.fields}');

      request.files.add(
        await http.MultipartFile.fromPath('image', _taggedPhoto!.path),
      );

      final response =
          await request.send().timeout(const Duration(seconds: 30));
      final responseBody = await response.stream.bytesToString();
      print('Upload report: ${response.statusCode} $responseBody');

      if (response.statusCode == 200 || response.statusCode == 201) {
        if (!mounted) return;
        setState(() {
          _capturedPhoto = null;
          _taggedPhoto = null;
          _showReportPreview = false;
        });

        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.check_circle, color: Color(0xFF4CAF50)),
                  SizedBox(width: 8),
                  Text(
                    'Laporan Terkirim!',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              content: Text(
                'Laporan banjir dari ${widget.drone.id} berhasil dikirim ke server.',
                style: const TextStyle(
                    fontSize: 14, color: AppColors.textSecondary),
              ),
              actions: [
                ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                  ),
                  child:
                      const Text('OK', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  'Gagal mengirim laporan (${response.statusCode}), coba lagi'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      print('Send report error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Tidak bisa terhubung ke server'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ==================== POST KOORDINAT ====================

  Future<void> _postData() async {
    if (_isPosting) return;
    _isPosting = true;

    if (_latitude == null || _longitude == null) return;

    print('--- POST DATA ---');
    print(
        'ID: ${widget.drone.id} | Name: ${widget.drone.name} | Status: $_status | Water: ${_waterLevel.toStringAsFixed(1)}m | Lat: $_latitude | Lng: $_longitude');

    try {
      final response = await _httpClient.post(
        Uri.parse('$_baseUrl/update-coordinates'),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
        },
        body: {
          'drone_id': widget.drone.id,
          'latitude': _latitude.toString(),
          'longitude': _longitude.toString(),
          'type': widget.drone.type,
        },
      ).timeout(const Duration(seconds: 8));
      print('Koordinat: ${response.statusCode} ${response.body}');
    } catch (e) {
      print('POST koordinat error: $e');
    } finally {
      _isPosting = false;
    }
  }

  // ==================== CONTROL ====================

  void _startDrone() {
    setState(() {
      _isActive = true;
      _status = 'HOVERING';
      _waterLevel = _randomWaterLevel();
    });
    _startLocationStream();
    _resetHoverTimer();
    _postTimer = Timer.periodic(const Duration(seconds: 5), (_) => _postData());

    // Cek apakah drone masih ada di server setiap 30 detik
    _droneCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkDroneStillExists(),
    );
  }

  Future<void> _stopDrone() async {
    _positionStream?.cancel();
    _hoverTimer?.cancel();
    _postTimer?.cancel();
    _statusDebounceTimer?.cancel();
    _speedBuffer.clear();
    _droneCheckTimer?.cancel();

    setState(() {
      _isActive = false;
      _status = 'IDLE';
      _capturedPhoto = null;
      _taggedPhoto = null;
      _showReportPreview = false;
    });

    try {
      final response = await _httpClient
          .post(
            Uri.parse('$_baseUrl/stop-drone'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'drone_id': widget.drone.id,
            }),
          )
          .timeout(const Duration(seconds: 5));
      print('Drone stopped: ${response.statusCode} ${response.body}');
    } catch (e) {
      print('Stop drone error: $e');
    }
  }

  Future<void> _checkDroneStillExists() async {
    try {
      final response = await _httpClient.get(
        Uri.parse('$_baseUrl/drones'),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List list = data['data'];
        final exists = list.any(
          (d) => d['drone_id'].toString() == widget.drone.id,
        );

        if (!exists && mounted) {
          await _stopDrone();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                    'Drone ini telah dihapus dari sistem. Kembali ke daftar drone.'),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 3),
              ),
            );
            await Future.delayed(const Duration(seconds: 3));
            if (mounted) Navigator.pushReplacementNamed(context, '/');
          }
        }
      }
    } catch (e) {
      print('Check drone error: $e');
    }
  }

  Future<void> _forceStopDrone() async {
    try {
      await _httpClient.post(
        Uri.parse('$_baseUrl/stop-drone'),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
        },
        body: {
          'drone_id': widget.drone.id,
        },
      );
    } catch (_) {}
  }

  void _confirmBack() {
    if (_showReportPreview) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            'Batalkan Laporan?',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          content: const Text(
            'Laporan belum dikirim. Apakah kamu ingin membatalkan dan kembali ke halaman kontrol drone?',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context, rootNavigator: true).pop();
              },
              child: const Text('Lanjutkan Laporan',
                  style: TextStyle(color: AppColors.primary)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context, rootNavigator: true).pop();
                _cancelReport();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFA5858),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                elevation: 0,
              ),
              child: const Text('Batalkan Laporan',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      );
      return;
    }

    if (!_isActive) {
      if (mounted) Navigator.pushReplacementNamed(context, '/');
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Kembali ke Daftar Drone?',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        content: const Text(
          'Drone masih aktif. Apakah kamu ingin menghentikan drone dan kembali ke halaman pilih drone?',
          style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () async {
              if (mounted) Navigator.pop(context);
              await _stopDrone();
              await Future.delayed(const Duration(milliseconds: 500));
              if (mounted) {
                Navigator.pushReplacementNamed(context, '/');
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFA5858),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            child: const Text('Hentikan & Kembali',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  // ==================== UI ====================

  Color get _statusColor {
    switch (_status) {
      case 'FLYING':
        return AppColors.statusOn;
      case 'HOVERING':
        return const Color(0xFFFFA726);
      default:
        return AppColors.statusOff;
    }
  }

  // Widget tag yang ditempel di atas foto
  Widget _buildTagOverlay() {
    final now = DateTime.now();
    final timeStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

    return Stack(
      children: [
        if (_capturedPhoto != null)
          Image.file(
            _capturedPhoto!,
            width: double.infinity,
            height: 280,
            fit: BoxFit.cover,
          ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.9),
                  Colors.transparent,
                ],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.location_on, color: Colors.white, size: 13),
                  const SizedBox(width: 4),
                  Text(
                    'Lat: ${_latitude?.toStringAsFixed(6)} | Lng: ${_longitude?.toStringAsFixed(6)}',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ]),
                const SizedBox(height: 3),
                Row(children: [
                  const Icon(Icons.water,
                      color: Colors.lightBlueAccent, size: 13),
                  const SizedBox(width: 4),
                  Text(
                    'Ketinggian Banjir: ${_waterLevel.toStringAsFixed(1)} m',
                    style: const TextStyle(
                      color: Colors.lightBlueAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ]),
                const SizedBox(height: 3),
                Row(children: [
                  const Icon(Icons.router, color: Colors.white70, size: 13),
                  const SizedBox(width: 4),
                  Text(
                    '${widget.drone.id} · ${widget.drone.name}',
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ]),
                const SizedBox(height: 3),
                Row(children: [
                  const Icon(Icons.access_time,
                      color: Colors.white70, size: 13),
                  const SizedBox(width: 4),
                  Text(
                    timeStr,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;

        _confirmBack();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
            onPressed: () => _confirmBack(),
          ),
          title: Row(
            children: [
              Icon(Icons.track_changes, color: AppColors.primary, size: 22),
              const SizedBox(width: 8),
              Text(
                'TACTICALOBSERVER',
                style: TextStyle(
                  color: AppColors.primary,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.notifications_outlined,
                  color: AppColors.textPrimary),
              onPressed: () {},
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.person, color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
        body: _showReportPreview ? _buildReportPreview() : _buildMainScreen(),
      ),
    );
  }

  // ==================== SCREEN UTAMA ====================

  Widget _buildMainScreen() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          const Text(
            'Drone Control',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const Text(
            'Monitor & kendalikan drone kamu',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 24),

          // Card utama
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.cardBg,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // STATUS
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: _statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _status,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: _statusColor,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),

                    const Spacer(),

                    // SPEED
                    if (_isActive)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'SPD ${_currentSpeed.toStringAsFixed(2)} m/s',
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textSecondary,
                              letterSpacing: 0.5,
                            ),
                          ),
                          Text(
                            'AVG ${_averageSpeed.toStringAsFixed(2)}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),

                    if (_isActive) ...[
                      const SizedBox(width: 12),

                      // LIVE
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.live.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: AppColors.live,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Text(
                              'LIVE',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.live,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),

                // ID + Nama drone
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        widget.drone.id,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      widget.drone.name,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '(${widget.drone.type})',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // Icon drone
                Center(
                  child: Icon(
                    Icons.router,
                    size: 80,
                    color: _isActive ? AppColors.primary : AppColors.statusOff,
                  ),
                ),
                const SizedBox(height: 20),

                // Koordinat
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'KOORDINAT TERKINI',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _locationText,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Ketinggian banjir
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'KETINGGIAN BANJIR',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _isActive ? '${_waterLevel.toStringAsFixed(1)} m' : '-',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: _isActive
                              ? AppColors.textPrimary
                              : AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),

          // Tombol REPORT (hanya saat aktif)
          if (_isActive) ...[
            SizedBox(
              width: double.infinity,
              height: 52,
              child: OutlinedButton.icon(
                onPressed: _openReport,
                icon: const Icon(Icons.camera_alt_outlined,
                    color: AppColors.primary),
                label: const Text(
                  'REPORT',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.primary),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Tombol START / STOP
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: _isActive
                  ? () async {
                      await _stopDrone();
                      await Future.delayed(const Duration(milliseconds: 500));
                    }
                  : _startDrone,
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    _isActive ? const Color(0xFFFA5858) : AppColors.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              child: Text(
                _isActive ? 'STOP DRONE' : 'START DRONE',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ==================== SCREEN PREVIEW REPORT ====================

  Widget _buildReportPreview() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          const Text(
            'Preview Laporan',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const Text(
            'Pastikan foto dan data sudah benar sebelum kirim',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 20),

          // Foto dengan tag
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: _buildTagOverlay(),
            ),
          ),
          const SizedBox(height: 16),

          // Info card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.cardBg,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              children: [
                _infoRow(Icons.router_outlined, 'Drone',
                    '${widget.drone.id} · ${widget.drone.name}'),
                const Divider(height: 16),
                _infoRow(
                    Icons.location_on_outlined, 'Koordinat', _locationText),
                const Divider(height: 16),
                _infoRow(Icons.water_outlined, 'Ketinggian Banjir',
                    '${_waterLevel.toStringAsFixed(1)} m'),
                const Divider(height: 16),
                _infoRow(Icons.access_time_outlined, 'Waktu', () {
                  final now = DateTime.now();
                  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
                      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
                }()),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Tombol Ambil Ulang
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton.icon(
              onPressed: _retakePhoto,
              icon: const Icon(Icons.replay_outlined, color: AppColors.primary),
              label: const Text(
                'AMBIL ULANG',
                style: TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Tombol Batal
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton.icon(
              onPressed: _cancelReport,
              icon: const Icon(Icons.close, color: Colors.red),
              label: const Text(
                'BATAL',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.red),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Tombol Kirim
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: _taggedPhoto != null ? _sendReport : null,
              icon: const Icon(Icons.send, color: Colors.white),
              label: const Text(
                'KIRIM LAPORAN',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: 1.2,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                disabledBackgroundColor:
                    AppColors.primary.withValues(alpha: 0.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: AppColors.primary, size: 18),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
                letterSpacing: 0.5,
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
