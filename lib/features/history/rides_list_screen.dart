import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../camera/providers/camera_provider.dart';
import 'models/ride_record.dart';
import 'ride_playback_screen.dart';

class RidesListScreen extends StatefulWidget {
	const RidesListScreen({super.key});

	@override
	State<RidesListScreen> createState() => _RidesListScreenState();
}

class _RidesListScreenState extends State<RidesListScreen> {
	late Future<List<RideRecord>> _ridesFuture;

	@override
	void initState() {
		super.initState();
		_ridesFuture = _loadRides();
	}

	Future<List<RideRecord>> _loadRides() async {
		final cameraProvider = context.read<CameraProvider>();
		final recordings = await cameraProvider.getRecordings();

		final videoFiles = recordings
				.whereType<File>()
				.where((file) => file.path.toLowerCase().endsWith('.mp4'))
				.toList();

		final rides = <RideRecord>[];
		for (final file in videoFiles) {
			rides.add(await RideRecord.fromVideoFile(file));
		}

		rides.sort((a, b) => b.createdAt.compareTo(a.createdAt));
		return rides;
	}

	String _formatDuration(Duration duration) {
		final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
		final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
		final hours = duration.inHours;
		return '$hours:$minutes:$seconds';
	}

	@override
	Widget build(BuildContext context) {
		return Scaffold(
			appBar: AppBar(
				title: const Text('Ride History'),
			),
			body: FutureBuilder<List<RideRecord>>(
				future: _ridesFuture,
				builder: (context, snapshot) {
					if (snapshot.connectionState == ConnectionState.waiting) {
						return const Center(child: CircularProgressIndicator());
					}

					if (snapshot.hasError) {
						return Center(
							child: Text('Failed to load rides: ${snapshot.error}'),
						);
					}

					final rides = snapshot.data ?? const <RideRecord>[];
					if (rides.isEmpty) {
						return const Center(
							child: Text('No rides found yet. Record a ride to see it here.'),
						);
					}

					return RefreshIndicator(
						onRefresh: () async {
							setState(() {
								_ridesFuture = _loadRides();
							});
							await _ridesFuture;
						},
						child: ListView.separated(
							padding: const EdgeInsets.all(12),
							itemCount: rides.length,
							separatorBuilder: (_, __) => const SizedBox(height: 10),
							itemBuilder: (context, index) {
								final ride = rides[index];
								final hasTelemetry = ride.samples.isNotEmpty;

								return Card(
									child: ListTile(
										contentPadding: const EdgeInsets.all(12),
										title: Text(ride.fileName),
										subtitle: Column(
											crossAxisAlignment: CrossAxisAlignment.start,
											mainAxisSize: MainAxisSize.min,
											children: [
												const SizedBox(height: 6),
												Text(DateFormat('dd MMM yyyy, hh:mm a').format(ride.createdAt)),
												const SizedBox(height: 4),
												Text('Distance: ${ride.distanceKm.toStringAsFixed(2)} km'),
												Text('Duration: ${_formatDuration(ride.duration)}'),
												Text('Max speed: ${ride.maxSpeedKmh.toStringAsFixed(1)} km/h'),
												Text(hasTelemetry ? 'Telemetry: Available' : 'Telemetry: Not available'),
											],
										),
										trailing: const Icon(Icons.play_circle_outline),
										onTap: () {
											Navigator.of(context).push(
												MaterialPageRoute(
													builder: (_) => RidePlaybackScreen(ride: ride),
												),
											);
										},
									),
								);
							},
						),
					);
				},
			),
		);
	}
}
