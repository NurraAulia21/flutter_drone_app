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
      id: json['drone_id'],
      name: json['name'],
      type: json['type'],
      location: json['location'] ?? '-',
      isActive: json['is_active'] ?? false,
      latitude: double.tryParse(json['latitude'].toString()) ?? 0,
      longitude: double.tryParse(json['longitude'].toString()) ?? 0,
    );
  }
}
