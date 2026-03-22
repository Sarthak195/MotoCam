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

		final telemetryFiles = recordings
				.whereType<File>()
				.where((file) => file.path.toLowerCase().endsWith('.telemetry.json'))
				.toList();

		final rides = <RideRecord>[];
		for (final telemetryFile in telemetryFiles) {
			final ride = await RideRecord.fromTelemetryFile(telemetryFile);
			if (ride != null) {
				rides.add(ride);
			}
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

					final lockedRides = rides.where((ride) => ride.isLocked).toList();
					final otherRides = rides.where((ride) => !ride.isLocked).toList();

					return RefreshIndicator(
						onRefresh: () async {
							setState(() {
								_ridesFuture = _loadRides();
							});
							await _ridesFuture;
						},
						child: ListView(
							padding: const EdgeInsets.all(12),
							children: [
								if (lockedRides.isNotEmpty) ...[
									const Padding(
										padding: EdgeInsets.only(bottom: 8),
										child: Text(
											'Locked Clips',
											style: TextStyle(
												fontSize: 16,
												fontWeight: FontWeight.bold,
											),
										),
									),
									...lockedRides
										.map((ride) => _buildRideCard(context, ride))
										.expand((card) => [card, const SizedBox(height: 10)]),
								],
								const Padding(
									padding: EdgeInsets.only(bottom: 8, top: 6),
									child: Text(
										'All Rides',
										style: TextStyle(
											fontSize: 16,
											fontWeight: FontWeight.bold,
										),
									),
								),
								...otherRides
									.map((ride) => _buildRideCard(context, ride))
									.expand((card) => [card, const SizedBox(height: 10)]),
							],
						),
					);
				},
			),
		);
	}

	Widget _buildRideCard(BuildContext context, RideRecord ride) {
		final hasTelemetry = ride.samples.isNotEmpty;

		return Card(
			child: ListTile(
				contentPadding: const EdgeInsets.all(12),
				title: Row(
					children: [
						Expanded(child: Text(ride.fileName)),
						if (ride.isLocked)
							Container(
								padding:
									const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
								decoration: BoxDecoration(
									color: Colors.orange.withValues(alpha: 0.2),
									borderRadius: BorderRadius.circular(12),
								),
								child: const Text(
									'LOCKED',
									style: TextStyle(
										color: Colors.orange,
										fontSize: 11,
										fontWeight: FontWeight.w700,
									),
								),
							),
					],
				),
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
				trailing: SizedBox(
					width: ride.isLocked ? 84 : 32,
					child: Row(
						mainAxisSize: MainAxisSize.min,
						mainAxisAlignment: MainAxisAlignment.end,
						children: [
							if (ride.isLocked)
								IconButton(
									tooltip: 'Unlock clip',
									padding: EdgeInsets.zero,
									constraints: const BoxConstraints(
										minWidth: 28,
										minHeight: 28,
									),
									iconSize: 20,
									onPressed: () async {
										final messenger = ScaffoldMessenger.of(context);
										await ride.setLockState(false);
										if (!mounted) return;
										setState(() {
											_ridesFuture = _loadRides();
										});
										messenger.showSnackBar(
											const SnackBar(
												content: Text('Clip unlocked and moved to normal loop policy'),
												duration: Duration(seconds: 2),
											),
										);
									},
									icon: const Icon(Icons.lock_open),
								),
							const Icon(Icons.play_circle_outline),
						],
					),
				),
				onTap: () {
					Navigator.of(context).push(
						MaterialPageRoute(
							builder: (_) => RidePlaybackScreen(ride: ride),
						),
					);
				},
			),
		);
	}
}
