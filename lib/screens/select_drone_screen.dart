import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../constants/app_colors.dart';
import '../models/drone.dart';

class SelectDroneScreen extends StatefulWidget {
  const SelectDroneScreen({super.key});

  @override
  State<SelectDroneScreen> createState() => _SelectDroneScreenState();
}

class _SelectDroneScreenState extends State<SelectDroneScreen> {
  final TextEditingController _manualController = TextEditingController();
  String? _errorText;

  List<DroneOption> _drones = [];
  bool _isLoading = true;
  String? _loadError;

  static const String _baseUrl = 'https://api-drone.heivet.com/api';

  @override
  void initState() {
    super.initState();
    _loadDrones();
  }

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  // KONDISI 2: fetch dari server
  Future<void> _loadDrones() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/drones'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List list = data['data'];
        setState(() {
          _drones = list.map((e) => DroneOption.fromJson(e)).toList();
          _isLoading = false;
        });
      } else {
        setState(() {
          _loadError = 'Gagal memuat drone (${response.statusCode})';
          _isLoading = false;
        });
      }
    } catch (e) {
      print('LOAD DRONE ERROR: $e');

      setState(() {
        _loadError = 'Tidak bisa terhubung ke server';
        _isLoading = false;
      });
    }
  }

  void _selectDrone(DroneOption drone) {
    if (drone.isActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Drone sedang digunakan'),
        ),
      );
      return;
    }

    Navigator.pushReplacementNamed(
      context,
      '/drone',
      arguments: drone,
    );
  }

  void _submitManual() {
    String input = _manualController.text.trim();
    if (input.isEmpty) {
      setState(() => _errorText = 'Masukkan ID drone terlebih dahulu');
      return;
    }
    DroneOption? found;
    try {
      found = _drones.firstWhere(
        (d) => d.id.toLowerCase() == input.toLowerCase(),
      );
    } catch (_) {
      found = null;
    }
    if (found != null) {
      _selectDrone(found);
    } else {
      setState(() => _errorText = 'ID "$input" tidak ditemukan');
    }
  }

  void _showDropdown(BuildContext context) {
    if (_isLoading) return;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textSecondary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Pilih Drone',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            if (_drones.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Belum ada drone terdaftar.\nTambahkan drone di aplikasi Monitor.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: AppColors.textSecondary, fontSize: 13),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _drones.length,
                  itemBuilder: (context, index) {
                    final drone = _drones[index];
                    return ListTile(
                      onTap: () {
                        if (drone.isActive) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('${drone.id} sedang dipakai'),
                            ),
                          );
                          return;
                        }

                        Navigator.pop(context);
                        _selectDrone(drone);
                      },
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: drone.isActive
                              ? AppColors.statusOn.withValues(alpha: 0.1)
                              : AppColors.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.router,
                            color: drone.isActive
                                ? AppColors.statusOn
                                : AppColors.primary,
                            size: 22),
                      ),
                      title: Text(drone.name,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                      subtitle: Text(drone.type,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textSecondary)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(drone.id,
                                style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primary)),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: drone.isActive
                                  ? AppColors.statusOn
                                  : AppColors.statusOff,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadDrones,
          color: AppColors.primary,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: SizedBox(
                height: MediaQuery.of(context).size.height -
                    MediaQuery.of(context).padding.top -
                    MediaQuery.of(context).padding.bottom,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.track_changes,
                            color: AppColors.primary, size: 28),
                        const SizedBox(width: 10),
                        Text(
                          'TACTICALOBSERVER',
                          style: TextStyle(
                            color: AppColors.primary,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: _loadDrones,
                          icon: _isLoading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: AppColors.primary))
                              : const Icon(Icons.refresh,
                                  color: AppColors.primary),
                          tooltip: 'Refresh daftar drone',
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    const Text('Mulai Sesi',
                        style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary)),
                    const Text('Masukkan ID drone atau pilih dari daftar',
                        style: TextStyle(
                            fontSize: 14, color: AppColors.textSecondary)),
                    const SizedBox(height: 32),
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
                          const Text('ID DRONE',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.textSecondary,
                                  letterSpacing: 1)),
                          const SizedBox(height: 10),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _manualController,
                                  decoration: InputDecoration(
                                    hintText: 'Contoh: DRONE-001',
                                    hintStyle: const TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 13),
                                    errorText: _errorText,
                                    filled: true,
                                    fillColor: AppColors.background,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      borderSide: BorderSide.none,
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 14, vertical: 14),
                                  ),
                                  onChanged: (_) =>
                                      setState(() => _errorText = null),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                height: 48,
                                child: ElevatedButton(
                                  onPressed: _submitManual,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.primary,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(10)),
                                    elevation: 0,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16),
                                  ),
                                  child: const Text('Pilih',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                height: 48,
                                width: 48,
                                child: OutlinedButton(
                                  onPressed: _isLoading
                                      ? null
                                      : () async {
                                          await _loadDrones();
                                          _showDropdown(context);
                                        },
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(
                                        color: AppColors.primary),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(10)),
                                    padding: EdgeInsets.zero,
                                  ),
                                  child: _isLoading
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: AppColors.primary))
                                      : const Icon(Icons.keyboard_arrow_down,
                                          color: AppColors.primary),
                                ),
                              ),
                            ],
                          ),
                          if (_loadError != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Row(
                                children: [
                                  const Icon(Icons.warning_amber_rounded,
                                      color: Colors.orange, size: 16),
                                  const SizedBox(width: 6),
                                  Expanded(
                                      child: Text(_loadError!,
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.orange))),
                                  TextButton(
                                      onPressed: _loadDrones,
                                      child: const Text('Coba lagi',
                                          style: TextStyle(fontSize: 12))),
                                ],
                              ),
                            ),
                          if (!_isLoading && _loadError == null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                '${_drones.length} drone terdaftar',
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textSecondary),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
