import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:convert';
import '../constants/app_colors.dart';

class DroneScreen extends StatefulWidget {
  const DroneScreen({super.key});

  @override
  State<DroneScreen> createState() => _DroneScreenState();
}

class _DroneScreenState extends State<DroneScreen> {
  static const String _droneId = 'DRONE-001';
  static const String _droneName = 'Syma W2';

  bool _isActive = false;
  String _status = 'IDLE';

  double? _latitude;
  double? _longitude;
  String _locationText = 'Menunggu GPS...';

  StreamSubscription<Position>? _positionStream;
  Timer? _hoverTimer;
  Timer? _postTimer;
  Timer? _statusDebounceTimer;

  static const String _postUrl = 'https://your-server.com/api/location';

  // Dinaikkan ke 50 agar indoor tetap terbaca
  static const double _accuracyThreshold = 50.0;
  static const double _speedFlyingThreshold = 0.4;
  static const double _speedHoverThreshold = 0.15;

  final List<double> _speedBuffer = [];
  static const int _bufferSize = 4;
  String _pendingStatus = 'IDLE';

  @override
  void initState() {
    super.initState();
    _checkLocationPermission();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _hoverTimer?.cancel();
    _postTimer?.cancel();
    _statusDebounceTimer?.cancel();
    super.dispose();
  }

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

      print(
          'Speed: ${speed.toStringAsFixed(2)} | Accuracy: ${accuracy.toStringAsFixed(1)}');

      if (accuracy > _accuracyThreshold) {
        print('Skip: GPS tidak akurat ($accuracy > $_accuracyThreshold)');
        return;
      }

      double avgSpeed = _getAverageSpeed(speed);
      print('Avg Speed: ${avgSpeed.toStringAsFixed(2)}');

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

  Future<void> _postLocation() async {
    if (_latitude == null || _longitude == null) return;
    try {
      await http.post(
        Uri.parse(_postUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'drone_id': _droneId,
          'drone_name': _droneName,
          'latitude': _latitude,
          'longitude': _longitude,
          'status': _status,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
    } catch (e) {
      print('POST error: $e');
    }
  }

  void _startDrone() {
    setState(() {
      _isActive = true;
      _status = 'HOVERING';
    });
    _startLocationStream();
    _resetHoverTimer();
    _postTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _postLocation();
    });
  }

  void _stopDrone() {
    setState(() {
      _isActive = false;
      _status = 'IDLE';
    });
    _positionStream?.cancel();
    _hoverTimer?.cancel();
    _postTimer?.cancel();
    _statusDebounceTimer?.cancel();
    _speedBuffer.clear();
  }

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
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
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
      body: Padding(
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
                  // Status + LIVE badge
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

                  // ID dan Nama Drone
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          _droneId,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        _droneName,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
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

                  // Koordinat GPS
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
                ],
              ),
            ),

            const SizedBox(height: 32),

            // Tombol START / STOP
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _isActive ? _stopDrone : _startDrone,
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
          ],
        ),
      ),
    );
  }
}
