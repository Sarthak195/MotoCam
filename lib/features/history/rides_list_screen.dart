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
	bool _isOpeningRide = false;

	Widget _buildStatusBadge({
		required String label,
		required Color color,
	}) {
		return Container(
			padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
			decoration: BoxDecoration(
				color: color.withValues(alpha: 0.2),
				borderRadius: BorderRadius.circular(12),
			),
			child: Text(
				label,
				style: TextStyle(
					color: color,
					fontSize: 11,
					fontWeight: FontWeight.w700,
				),
			),
		);
	}

	bool _hasLoadedRides = false;

	@override
	void didChangeDependencies() {
		super.didChangeDependencies();
		if (!_hasLoadedRides) {
			_hasLoadedRides = true;
			_ridesFuture = _loadRides();
		}
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
			try {
				final ride = await RideRecord.fromTelemetryFile(telemetryFile);
				if (ride != null) {
					rides.add(ride);
				}
			} catch (_) {
				// Skip malformed telemetry entries and continue loading others.
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
		final hasTelemetry = ride.telemetryPath != null;
		final segmentCount = ride.segmentPaths.length;
		final integrityIsModified =
			ride.integrity.status == RideIntegrityStatus.modified;
		final integrityIsVerified =
			ride.integrity.status == RideIntegrityStatus.verified;
		final canToggleLockState =
			!integrityIsModified && !ride.hasQuarantinedSegments;

		return Card(
			child: ListTile(
				contentPadding: const EdgeInsets.all(12),
				title: Row(
					children: [
						Expanded(child: Text(ride.fileName)),
						if (!hasTelemetry) ...[
							Container(
								padding:
									const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
								decoration: BoxDecoration(
									color: Colors.blueGrey.withValues(alpha: 0.2),
									borderRadius: BorderRadius.circular(12),
								),
								child: const Text(
									'VIDEO ONLY (RECOVERED)',
									style: TextStyle(
										color: Colors.blueGrey,
										fontSize: 11,
										fontWeight: FontWeight.w700,
									),
								),
							),
							const SizedBox(width: 6),
						],
						if (integrityIsModified) ...[
							_buildStatusBadge(
								label: 'INTEGRITY WARNING',
								color: Colors.redAccent,
							),
							const SizedBox(width: 6),
						] else if (integrityIsVerified) ...[
							_buildStatusBadge(
								label: 'VERIFIED',
								color: Colors.lightGreen,
							),
							const SizedBox(width: 6),
						],
						if (ride.hasQuarantinedSegments)
							_buildStatusBadge(
								label:
									'QUARANTINED ${ride.quarantinedSegmentPaths.length}',
								color: Colors.deepOrangeAccent,
							),
						if (ride.isLocked)
							_buildStatusBadge(label: 'LOCKED', color: Colors.orange),
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
						Text('Avg speed: ${ride.averageSpeedKmh.toStringAsFixed(1)} km/h'),
						Text('Segments: $segmentCount'),
						Text('Samples: ${ride.samples.length}'),
						Text('Integrity: ${ride.integrityLabel}'),
						if (ride.hasQuarantinedSegments)
							Text(
								'Quarantined paths: ${ride.quarantinedSegmentPaths.length}',
								style: const TextStyle(color: Colors.deepOrangeAccent),
							),
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
									tooltip: canToggleLockState
										? 'Unlock clip'
										: 'Integrity warning: lock state changes disabled',
									padding: EdgeInsets.zero,
									constraints: const BoxConstraints(
										minWidth: 28,
										minHeight: 28,
									),
									iconSize: 20,
									onPressed: !canToggleLockState
										? null
										: () async {
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
				onTap: () async {
					if (_isOpeningRide) {
						return;
					}
					_isOpeningRide = true;
					try {
						await Navigator.of(context).push(
							MaterialPageRoute(
								builder: (_) => RidePlaybackScreen(ride: ride),
							),
						);
					} finally {
						_isOpeningRide = false;
					}
				},
			),
		);
	}
}
