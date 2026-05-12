class DroneOption {
  final int? dbId;
  final String id;
  final String name;
  final String type;
  final String location;
  final bool isActive;
  final double latitude;
  final double longitude;

  DroneOption({
    this.dbId,
    required this.id,
    required this.name,
    required this.type,
    this.location = '-',
    this.isActive = false,
    this.latitude = 0,
    this.longitude = 0,
  });

  factory DroneOption.fromJson(Map<String, dynamic> json) {
    return DroneOption(
      dbId: json['id'],
      id: json['drone_id'] ?? '',
      name: json['name'] ?? '-',
      type: json['type'] ?? '-',
      location: json['location'] ?? '-',
      // Handle both is_active dan status
      isActive:
          json['is_active'] ?? (json['status'] == 1 || json['status'] == true),
      latitude: double.tryParse(json['latitude']?.toString() ?? '0') ?? 0.0,
      longitude: double.tryParse(json['longitude']?.toString() ?? '0') ?? 0.0,
    );
  }
}

// ============================================================
// Data Dummy
// ============================================================
// final List<DroneOption> dummyDrones = [
//   DroneOption(id: 'DRONE-001', name: 'Syma W2', type: 'Quadcopter'),
//   DroneOption(id: 'DRONE-002', name: 'DJI Mini 3', type: 'Quadcopter'),
//   DroneOption(id: 'DRONE-003', name: 'Autel EVO', type: 'Hexacopter'),
// ];
// ============================================================
