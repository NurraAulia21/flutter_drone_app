class DroneOption {
  final String id;
  final String name;
  final String type;
  final String location;
  final bool isActive;
  final double latitude;
  final double longitude;

  DroneOption({
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
      id: json['drone_id'].toString(),
      name: json['name']?.toString() ?? '-',
      type: json['type']?.toString() ?? '-',
      location: json['location']?.toString() ?? '-',
      isActive: json['is_active'] ?? false,
      latitude: double.tryParse(json['latitude'].toString()) ?? 0,
      longitude: double.tryParse(json['longitude'].toString()) ?? 0,
    );
  }
}

// ============================================================
// KONDISI 1: DATA DUMMY (comment saat kondisi 2)
// ============================================================
// final List<DroneOption> dummyDrones = [
//   DroneOption(id: 'DRONE-001', name: 'Syma W2', type: 'Quadcopter'),
//   DroneOption(id: 'DRONE-002', name: 'DJI Mini 3', type: 'Quadcopter'),
//   DroneOption(id: 'DRONE-003', name: 'Autel EVO', type: 'Hexacopter'),
// ];
// ============================================================
