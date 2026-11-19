import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/theme/tokens.dart';
import 'package:motocam/core/ui/kit.dart';

import '../../support/load_fonts.dart';
import 'kit_harness.dart';

void main() {
  setUpAll(loadBundledFonts);

  group('StateBand', () {
    const cases = <BandState, (String, String?, String?)>{
      BandState.ready: ('READY', '00:00', null),
      BandState.starting: ('STARTING', '00:00', null),
      BandState.recording: ('REC', '1:41:12', 'Writing, last 0.4 s ago'),
      BandState.saving: ('SAVING', '41:12', null),
      BandState.locked: ('LOCKED', '14:02 to 14:08', null),
    };

    for (final surface in kitSurfaces.entries) {
      for (final scale in [1.0, 1.3]) {
        for (final entry in cases.entries) {
          testWidgets(
            '${entry.key.name} on ${surface.key} at text scale $scale',
            (tester) async {
              final (label, trailing, detail) = entry.value;
              await pumpKit(
                tester,
                surface.value,
                StateBand(state: entry.key, trailing: trailing, detail: detail),
                textScale: scale,
              );
              expectNoLayoutErrors(tester);
              expect(find.text(label), findsOneWidget);
              await expectAccessibleKit(tester);
            },
          );
        }
      }
    }

    testWidgets('states differ by fill or outline, not colour alone', (
      tester,
    ) async {
      final looks = <String>{};
      for (final state in BandState.values) {
        await pumpKit(tester, const Size(390, 844), StateBand(state: state));
        final box = tester.widget<Container>(
          find.descendant(
            of: find.byType(StateBand),
            matching: find.byType(Container),
          ),
        );
        final decoration = box.decoration! as BoxDecoration;
        final glyph = find.descendant(
          of: find.byType(StateBand),
          matching: find.byType(MotoGlyph),
        );
        final shape = glyph.evaluate().isEmpty
            ? 'icon'
            : tester.widget<MotoGlyph>(glyph).shape.name;
        looks.add(
          '${decoration.color != null}/${decoration.border != null}/$shape',
        );
      }
      expect(looks, hasLength(BandState.values.length));
    });

    testWidgets('carries a status label for TalkBack', (tester) async {
      await pumpKit(
        tester,
        const Size(390, 844),
        const StateBand(state: BandState.ready),
      );
      expect(
        find.bySemanticsLabel('State: ready, not recording'),
        findsOneWidget,
      );
    });
  });

  group('StatusChip', () {
    Widget chips(StatusChipVariant variant) => Row(
      children: [
        StatusChip(
          variant: variant,
          semanticsLabel: 'Phone temperature',
          icon: Icons.thermostat,
          width: 64,
        ),
        const SizedBox(width: 8),
        StatusChip(
          variant: variant,
          semanticsLabel: 'Storage: 6.2 hours left',
          icon: Icons.sd_storage_outlined,
          value: '6.2',
          unit: 'h',
          width: 108,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: StatusChip(
            variant: variant,
            semanticsLabel: 'Applied recording profile',
            caption: 'APPLIED',
            value: '1080p30 / 20 Mbps',
          ),
        ),
      ],
    );

    for (final surface in kitSurfaces.entries) {
      for (final variant in StatusChipVariant.values) {
        testWidgets('${variant.name} on ${surface.key}', (tester) async {
          await pumpKit(tester, surface.value, chips(variant));
          expectNoLayoutErrors(tester);
          expect(find.text('APPLIED'), findsOneWidget);
          expect(
            find.bySemanticsLabel('Storage: 6.2 hours left'),
            findsOneWidget,
          );
          expect(
            tester.getSize(find.byType(StatusChip).first).height,
            greaterThanOrEqualTo(MotoSize.chip),
          );
          await expectAccessibleKit(tester);
        });
      }
    }

    testWidgets('only the reserved variant is dashed', (tester) async {
      for (final variant in StatusChipVariant.values) {
        await pumpKit(tester, const Size(390, 844), chips(variant));
        expect(
          find.byType(DashedOutline),
          variant == StatusChipVariant.reserved
              ? findsNWidgets(3)
              : findsNothing,
        );
      }
    });

    testWidgets('scales with text at 1.3 without overflow', (tester) async {
      await pumpKit(
        tester,
        const Size(390, 844),
        chips(StatusChipVariant.warning),
        textScale: 1.3,
      );
      expectNoLayoutErrors(tester);
    });
  });

  group('ThumbButton', () {
    const variants = <ThumbButtonVariant, (String, String, IconData?)>{
      ThumbButtonVariant.start: ('START', 'START RECORDING', null),
      ThumbButtonVariant.stop: ('STOP', 'STOP RECORDING', null),
      ThumbButtonVariant.lock: ('LOCK', 'LOCK', null),
      ThumbButtonVariant.locked: ('LOCKED', 'Locked', null),
      ThumbButtonVariant.secondary: ('Rides', 'HISTORY', Icons.list),
      ThumbButtonVariant.quiet: ('Dark', 'Enter blackout', Icons.dark_mode),
    };

    for (final surface in kitSurfaces.entries) {
      final landscape = surface.value.width > surface.value.height;
      for (final scale in [1.0, 1.3]) {
        for (final entry in variants.entries) {
          for (final enabled in [true, false]) {
            testWidgets('${entry.key.name}${enabled ? '' : ' disabled'} on '
                '${surface.key} at text scale $scale', (tester) async {
              final (label, semantics, icon) = entry.value;
              var taps = 0;
              await pumpKit(
                tester,
                surface.value,
                SizedBox(
                  width: landscape ? 380 : double.infinity,
                  child: ThumbButton(
                    variant: entry.key,
                    label: label,
                    semanticsLabel: semantics,
                    icon: icon,
                    hint: entry.key == ThumbButtonVariant.stop
                        ? 'hold 1 s'
                        : null,
                    direction: landscape ? Axis.vertical : Axis.horizontal,
                    height:
                        landscape &&
                            (entry.key == ThumbButtonVariant.lock ||
                                entry.key == ThumbButtonVariant.locked ||
                                entry.key == ThumbButtonVariant.start)
                        ? 200
                        : null,
                    onPressed: enabled ? () => taps++ : null,
                  ),
                ),
                textScale: scale,
              );
              expectNoLayoutErrors(tester);
              expect(find.text(label), findsOneWidget);
              expect(find.bySemanticsLabel(semantics), findsOneWidget);
              final size = tester.getSize(find.byType(ThumbButton));
              expect(size.height, greaterThanOrEqualTo(MotoSize.minTarget));
              expect(size.width, greaterThanOrEqualTo(MotoSize.minTarget));
              await tester.tap(find.text(label), warnIfMissed: false);
              expect(taps, enabled ? 1 : 0);
              await expectAccessibleKit(tester);
            });
          }
        }
      }
    }

    testWidgets('a semantics tap runs onPressed', (tester) async {
      final semantics = tester.ensureSemantics();
      var taps = 0;
      await pumpKit(
        tester,
        const Size(390, 844),
        ThumbButton(
          variant: ThumbButtonVariant.start,
          label: 'START',
          semanticsLabel: 'START RECORDING',
          onPressed: () => taps++,
        ),
      );
      tester.semantics.tap(find.semantics.byLabel('START RECORDING'));
      expect(taps, 1);
      semantics.dispose();
    });

    testWidgets('shows a press state while held down', (tester) async {
      await pumpKit(
        tester,
        const Size(390, 844),
        ThumbButton(
          variant: ThumbButtonVariant.lock,
          label: 'LOCK',
          semanticsLabel: 'LOCK',
          onPressed: () {},
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('LOCK')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final inkFeatures = tester.allRenderObjects.firstWhere(
        (object) => object.runtimeType.toString() == '_RenderInkFeatures',
      );
      expect(inkFeatures, paints..rect());
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  group('HoldButton', () {
    Future<(List<String>, void Function(bool))> pumpHold(
      WidgetTester tester,
    ) async {
      final events = <String>[];
      var enabled = true;
      late StateSetter setOuter;
      await pumpKit(
        tester,
        const Size(390, 844),
        StatefulBuilder(
          builder: (context, setState) {
            setOuter = setState;
            return HoldButton(
              enabled: enabled,
              onHold: () => events.add('hold'),
              onTapHint: () => events.add('hint'),
              builder: (context, hold) => ThumbButton(
                variant: ThumbButtonVariant.stop,
                label: 'STOP',
                semanticsLabel: 'STOP RECORDING',
                hint: 'hold 1 s',
                onPressed: hold.onTap,
                semanticsOnLongPress: hold.onLongPress,
                holdProgress: hold.progress,
              ),
            );
          },
        ),
      );
      return (events, (bool value) => setOuter(() => enabled = value));
    }

    testWidgets('a tap shows the hint and does not run the action', (
      tester,
    ) async {
      final (events, _) = await pumpHold(tester);
      await tester.tap(find.text('STOP'));
      await tester.pumpAndSettle();
      expect(events, ['hint']);
    });

    testWidgets('a hold shorter than 1 s does nothing but the hint', (
      tester,
    ) async {
      final (events, _) = await pumpHold(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('STOP')),
      );
      // The hold timer starts on the next frame.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      expect(events, isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(events, ['hint']);
    });

    testWidgets('a 1 s hold runs the action once, with no hint after', (
      tester,
    ) async {
      final (events, _) = await pumpHold(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('STOP')),
      );
      // The hold timer starts on the next frame.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final progress = tester
          .widget<ThumbButton>(find.byType(ThumbButton))
          .holdProgress;
      expect(progress, closeTo(0.5, 0.05));
      await tester.pump(const Duration(milliseconds: 600));
      expect(events, ['hold']);
      await tester.pump(const Duration(seconds: 2));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(events, ['hold']);
    });

    testWidgets('sliding off cancels the hold', (tester) async {
      final (events, _) = await pumpHold(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('STOP')),
      );
      // The hold timer starts on the next frame.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(events, isEmpty);
    });

    testWidgets('a hold while disabled is a no-op', (tester) async {
      final (events, setEnabled) = await pumpHold(tester);
      setEnabled(false);
      await tester.pump();
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('STOP')),
      );
      // The hold timer starts on the next frame.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1500));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(events, isEmpty);
    });

    testWidgets('disabling mid-hold cancels it', (tester) async {
      final (events, setEnabled) = await pumpHold(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('STOP')),
      );
      // The hold timer starts on the next frame.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      setEnabled(false);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(events, isEmpty);
    });

    testWidgets('TalkBack: long press runs the action, tap shows the hint', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final (events, _) = await pumpHold(tester);
      final node = find.semantics.byLabel('STOP RECORDING');
      tester.semantics.longPress(node);
      tester.semantics.tap(node);
      expect(events, ['hold', 'hint']);
      semantics.dispose();
    });
  });

  group('InstrumentRow', () {
    Widget rows() => Column(
      children: [
        const InstrumentRow(
          leading: Icon(Icons.verified_user_outlined),
          title: 'Permissions',
          subtitle: 'Camera, microphone, location',
          trailing: SizedBox(
            width: 76,
            child: Text('OK', textAlign: TextAlign.center),
          ),
        ),
        const SizedBox(height: 8),
        InstrumentRow(
          leading: const Icon(Icons.battery_alert_outlined),
          title: 'Battery',
          subtitle: 'Battery saver may stop recording',
          attention: true,
          trailing: SizedBox(
            width: 76,
            height: 48,
            child: FilledButton(onPressed: () {}, child: const Text('Fix')),
          ),
        ),
        const SizedBox(height: 8),
        InstrumentRow(
          title: 'Storage',
          subtitle: 'Budget 64 GB, 7.1 h. Gallery copies off',
          minHeight: 48,
          semanticsLabel: 'Storage settings',
          trailing: const Icon(Icons.chevron_right),
          onTap: () {},
        ),
      ],
    );

    for (final surface in kitSurfaces.entries) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('variants on ${surface.key} at text scale $scale', (
          tester,
        ) async {
          await pumpKit(
            tester,
            surface.value,
            SingleChildScrollView(child: rows()),
            textScale: scale,
          );
          expectNoLayoutErrors(tester);
          expect(find.text('Battery'), findsOneWidget);
          expect(
            tester.getSize(find.byType(InstrumentRow).first).height,
            greaterThanOrEqualTo(MotoSize.row),
          );
          await expectAccessibleKit(tester, pixelContrast: false);
        });
      }
    }
  });

  group('SegmentedRow', () {
    Widget segmented(ValueChanged<int> onChanged, {int selected = 1080}) =>
        SegmentedRow<int>(
          label: 'Resolution',
          status: 'Applied 1080p',
          selected: selected,
          onChanged: onChanged,
          options: const [
            SegmentOption(value: 720, label: '720p'),
            SegmentOption(value: 1080, label: '1080p'),
            SegmentOption(value: 2160, label: '4K', enabled: false),
          ],
        );

    for (final surface in kitSurfaces.entries) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('on ${surface.key} at text scale $scale', (tester) async {
          await pumpKit(
            tester,
            surface.value,
            segmented((_) {}),
            textScale: scale,
          );
          expectNoLayoutErrors(tester);
          final tray = tester.getSize(
            find.ancestor(
              of: find.text('720p'),
              matching: find.byType(Expanded),
            ),
          );
          expect(tray.height, greaterThanOrEqualTo(MotoSize.minTarget));
          await expectAccessibleKit(tester, pixelContrast: false);
        });
      }
    }

    testWidgets('a tap selects; a disabled choice ignores taps', (
      tester,
    ) async {
      final chosen = <int>[];
      await pumpKit(tester, const Size(390, 844), segmented(chosen.add));
      await tester.tap(find.text('720p'));
      await tester.tap(find.text('4K'));
      expect(chosen, [720]);
    });

    testWidgets('marks the selected choice for TalkBack', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpKit(tester, const Size(390, 844), segmented((_) {}));
      expect(
        tester.getSemantics(find.bySemanticsLabel('1080p')),
        matchesSemantics(
          label: '1080p',
          isButton: true,
          isInMutuallyExclusiveGroup: true,
          hasCheckedState: true,
          isChecked: true,
          hasSelectedState: true,
          isSelected: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      semantics.dispose();
    });
  });

  group('BigNumeral', () {
    for (final surface in kitSurfaces.entries) {
      for (final value in ['7', '62', '188']) {
        testWidgets('speed $value on ${surface.key}', (tester) async {
          await pumpKit(
            tester,
            surface.value,
            BigNumeral(
              value: value,
              unit: 'km/h',
              semanticsLabel: 'Speed $value kilometres per hour',
            ),
          );
          expectNoLayoutErrors(tester);
          expect(find.text(value), findsOneWidget);
          expect(
            find.bySemanticsLabel('Speed $value kilometres per hour'),
            findsOneWidget,
          );
          await expectAccessibleKit(tester);
        });
      }
    }

    testWidgets('uses tabular figures so the width does not jitter', (
      tester,
    ) async {
      double widthOf(String value) {
        return tester.getSize(find.text(value)).width;
      }

      await pumpKit(
        tester,
        const Size(390, 844),
        const Column(
          children: [
            BigNumeral(value: '11', semanticsLabel: 'a', size: 120),
            BigNumeral(value: '88', semanticsLabel: 'b', size: 120),
          ],
        ),
      );
      expect(widthOf('11'), closeTo(widthOf('88'), 0.01));
    });

    testWidgets('timer at 50 px on the REC band colours', (tester) async {
      await pumpKit(
        tester,
        const Size(844, 390),
        const ColoredBox(
          color: MotoColors.rec,
          child: BigNumeral(
            value: '41:12',
            semanticsLabel: 'Elapsed 41 minutes 12 seconds',
            size: 50,
            color: MotoColors.bg,
          ),
        ),
      );
      expectNoLayoutErrors(tester);
      await expectAccessibleKit(tester);
    });
  });
}
