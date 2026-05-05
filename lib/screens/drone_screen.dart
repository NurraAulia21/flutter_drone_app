import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
//import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../constants/app_colors.dart';
import '../models/drone.dart';

class DroneScreen extends StatefulWidget {
  final DroneOption drone;
  const DroneScreen({super.key, required this.drone});

  @override
  State<DroneScreen> createState() => _DroneScreenState();
}

class _DroneScreenState extends State<DroneScreen> {
  bool _isActive = false;
  String _status = 'IDLE';

  double? _latitude;
  double? _longitude;
  String _locationText = 'Menunggu GPS...';

  // Banyak foto
  final List<File> _photos = [];
  double _waterLevel = 0.0;

  StreamSubscription<Position>? _positionStream;
  Timer? _hoverTimer;
  Timer? _postTimer;
  Timer? _statusDebounceTimer;

  static const String _baseUrl = 'http://192.168.10.50:8000/api';
  static const double _accuracyThreshold = 50.0;
  static const double _speedFlyingThreshold = 0.4;
  static const double _speedHoverThreshold = 0.15;

  final List<double> _speedBuffer = [];
  static const int _bufferSize = 4;
  String _pendingStatus = 'IDLE';
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _checkLocationPermission();
    _loadSavedPhotos();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _hoverTimer?.cancel();
    _postTimer?.cancel();
    _statusDebounceTimer?.cancel();
    super.dispose();
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

      // Log GPS ke terminal
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

  // ==================== FOTO ====================

  // Load foto yang sudah disimpan sebelumnya untuk drone ini
  Future<void> _loadSavedPhotos() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final droneFolder = Directory('${directory.path}/${widget.drone.id}');
      if (!await droneFolder.exists()) return;

      final files = droneFolder
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jpg'))
          .toList();

      files.sort((a, b) => a.path.compareTo(b.path));

      setState(() {
        _photos.clear();
        _photos.addAll(files);
      });
    } catch (e) {
      print('Load photos error: $e');
    }
  }

  Future<void> _takePhoto() async {
    final XFile? photo =
        await _picker.pickImage(source: ImageSource.camera, imageQuality: 70);
    if (photo == null) return;

    try {
      // Simpan permanen per drone
      final directory = await getApplicationDocumentsDirectory();
      final droneFolder = Directory('${directory.path}/${widget.drone.id}');
      if (!await droneFolder.exists()) await droneFolder.create();

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final savedFile =
          await File(photo.path).copy('${droneFolder.path}/$timestamp.jpg');

      setState(() {
        _photos.add(savedFile);
        _waterLevel = _randomWaterLevel();
      });

      // 2. POST foto ke /api/upload-flood-image
      try {
        final request = http.MultipartRequest(
          'POST',
          Uri.parse('$_baseUrl/upload-flood-image'),
        );
        request.fields['drone_id'] = widget.drone.id;
        request.fields['latitude'] = _latitude?.toString() ?? '0';
        request.fields['longitude'] = _longitude?.toString() ?? '0';
        request.files.add(
          await http.MultipartFile.fromPath('image', savedFile.path),
        );

        final response = await request.send();
        final responseBody = await response.stream.bytesToString();
        print('Upload foto: ${response.statusCode} $responseBody');
      } catch (e) {
        print('POST foto error: $e');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Foto ${_photos.length} diambil. Ketinggian: ${_waterLevel.toStringAsFixed(1)}m'),
            backgroundColor: AppColors.primary,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('Save photo error: $e');
    }
  }

  void _deletePhoto(int index) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus Foto'),
        content: const Text('Yakin ingin menghapus foto ini?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await _photos[index].delete();
              } catch (_) {}
              setState(() => _photos.removeAt(index));
            },
            child: const Text('Hapus', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // ==================== WATER LEVEL ====================

  double _randomWaterLevel() {
    return (Random().nextInt(11) + 5) / 10.0;
  }

  // ==================== LOG & POST ====================

  Future<void> _saveToTxt(Map<String, dynamic> data) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/drone_log.txt');
      final line =
          '${data['timestamp']} | ID: ${data['drone_id']} | Status: ${data['status']} | '
          'Lat: ${data['latitude']} | Lng: ${data['longitude']} | '
          'Water: ${data['water_level']}m | Photos: ${data['photo_count']}\n';
      await file.writeAsString(line, mode: FileMode.append);
      print('Log saved: $line');
    } catch (e) {
      print('Log error: $e');
    }
  }

  Future<void> _postData() async {
    if (_latitude == null || _longitude == null) return;

    final Map<String, dynamic> logPayload = {
      'drone_id': widget.drone.id,
      'drone_name': widget.drone.name,
      'latitude': _latitude,
      'longitude': _longitude,
      'status': _status,
      'water_level': _waterLevel,
      'photo_count': _photos.length,
      'timestamp': DateTime.now().toIso8601String(),
    };

    await _saveToTxt(logPayload);

    // 1. POST koordinat ke /api/update-coordinates
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/update-coordinates'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'drone_id': widget.drone.id,
          'latitude': _latitude.toString(),
          'longitude': _longitude.toString(),
        },
      );
      print('Koordinat: ${response.statusCode} ${response.body}');
    } catch (e) {
      print('POST koordinat error: $e');
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
  }

  Future<void> _stopDrone() async {
    _positionStream?.cancel();
    _hoverTimer?.cancel();
    _postTimer?.cancel();
    _statusDebounceTimer?.cancel();
    _speedBuffer.clear();

    setState(() {
      _isActive = false;
      _status = 'IDLE';
    });

    // Pastikan server selesai dulu sebelum lanjut
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/stop-drone'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {'drone_id': widget.drone.id},
      ).timeout(const Duration(seconds: 5));
      print('Drone stopped: ${response.statusCode} ${response.body}');
    } catch (e) {
      print('Stop drone error: $e');
    }
  }

  void _confirmBack() {
    if (!_isActive) {
      Navigator.pushReplacementNamed(context, '/');
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
            child: const Text(
              'Batal',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context); // tutup dialog
              await _stopDrone(); // tunggu server selesai

              // Tunggu sebentar agar server benar-benar selesai update
              await Future.delayed(const Duration(milliseconds: 500));

              if (mounted) {
                Navigator.pushReplacementNamed(context, '/');
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFA5858),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              elevation: 0,
            ),
            child: const Text(
              'Hentikan & Kembali',
              style:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
            ),
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _confirmBack();
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
        body: SingleChildScrollView(
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
                    // Status + LIVE
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
                        const Spacer(),
                        if (_isActive)
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
                        color:
                            _isActive ? AppColors.primary : AppColors.statusOff,
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
                            _isActive
                                ? '${_waterLevel.toStringAsFixed(1)} m'
                                : '-',
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
              const SizedBox(height: 16),

              // Section foto
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'FOTO (${_photos.length})',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                            letterSpacing: 1,
                          ),
                        ),
                        // Tombol tambah foto
                        GestureDetector(
                          onTap: _takePhoto,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.add_a_photo_outlined,
                                    color: AppColors.primary, size: 16),
                                const SizedBox(width: 6),
                                const Text(
                                  'Tambah Foto',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Grid foto atau placeholder
                    _photos.isEmpty
                        ? Container(
                            width: double.infinity,
                            height: 80,
                            decoration: BoxDecoration(
                              color: AppColors.background,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Center(
                              child: Text(
                                'Belum ada foto',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                          )
                        : SizedBox(
                            height: 100,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              itemCount: _photos.length,
                              itemBuilder: (context, index) {
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Stack(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: Image.file(
                                          _photos[index],
                                          width: 100,
                                          height: 100,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                      // Tombol hapus
                                      Positioned(
                                        top: 4,
                                        right: 4,
                                        child: GestureDetector(
                                          onTap: () => _deletePhoto(index),
                                          child: Container(
                                            width: 22,
                                            height: 22,
                                            decoration: BoxDecoration(
                                              color: Colors.black
                                                  .withValues(alpha: 0.6),
                                              shape: BoxShape.circle,
                                            ),
                                            child: const Icon(
                                              Icons.close,
                                              color: Colors.white,
                                              size: 14,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Tombol START / STOP
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isActive
                      ? () async {
                          await _stopDrone();
                          await Future.delayed(
                              const Duration(milliseconds: 500));
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
        ),
      ),
    );
  }
}
