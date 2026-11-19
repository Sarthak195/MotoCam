// lib/core/ui/hold_button.dart

import 'dart:async';

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/widgets.dart';

/// What a [HoldButton] hands to its builder.
@immutable
class HoldButtonState {
  /// Creates the builder's view of a hold.
  const HoldButtonState({
    required this.onTap,
    required this.onLongPress,
    required this.progress,
  });

  /// Wire to the button's tap: a short tap calls the hold button's
  /// `onTapHint` (for example "Hold to stop") and never the action. Null
  /// while the hold button is disabled.
  final VoidCallback? onTap;

  /// Wire to the button's accessibility long-press action (TalkBack), which
  /// runs the action at once. Null while disabled.
  final VoidCallback? onLongPress;

  /// How far the current hold has run, 0 to 1.
  final double progress;
}

/// Press-and-hold wrapper: [onHold] runs only after the pointer has stayed
/// down for [holdDuration]. A short tap calls [onTapHint] instead.
///
/// Built for hold-to-stop, which waits on the owner's decision
/// (`kHoldToStop` in build_flags.dart); nothing uses it until then.
class HoldButton extends StatefulWidget {
  /// Creates a hold button.
  const HoldButton({
    super.key,
    required this.builder,
    required this.onHold,
    this.onTapHint,
    this.holdDuration = const Duration(seconds: 1),
    this.enabled = true,
  });

  /// Builds the visible button from the current [HoldButtonState].
  final Widget Function(BuildContext context, HoldButtonState hold) builder;

  /// The action, run once per completed hold.
  final VoidCallback onHold;

  /// Called on a short tap, to explain that a hold is needed.
  final VoidCallback? onTapHint;

  /// How long the pointer must stay down.
  final Duration holdDuration;

  /// False ignores holds and taps (for example while already stopping).
  final bool enabled;

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.holdDuration,
  )..addStatusListener(_onStatus);

  Offset? _downPosition;

  // True once the current press has run the action, so the tap that ends
  // the same press does not also show the hint.
  bool _firedThisPress = false;

  @override
  void didUpdateWidget(HoldButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.holdDuration;
    if (!widget.enabled) {
      _cancel();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _firedThisPress) {
      return;
    }
    if (!widget.enabled || _downPosition == null) {
      return;
    }
    _firedThisPress = true;
    widget.onHold();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.enabled || _downPosition != null) {
      return;
    }
    _firedThisPress = false;
    _downPosition = event.position;
    // The returned TickerFuture only reports the end of the run; the status
    // listener acts on completion.
    unawaited(_controller.forward(from: 0));
  }

  void _onPointerMove(PointerMoveEvent event) {
    final down = _downPosition;
    if (down != null && (event.position - down).distance > kTouchSlop * 2) {
      _cancel();
    }
  }

  void _cancel() {
    _downPosition = null;
    _controller
      ..stop()
      ..value = 0;
  }

  void _handleTap() {
    if (_firedThisPress) {
      _firedThisPress = false;
      return;
    }
    if (widget.enabled) {
      widget.onTapHint?.call();
    }
  }

  void _handleSemanticLongPress() {
    if (widget.enabled) {
      widget.onHold();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (_) => _cancel(),
      onPointerCancel: (_) => _cancel(),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => widget.builder(
          context,
          HoldButtonState(
            onTap: widget.enabled ? _handleTap : null,
            onLongPress: widget.enabled ? _handleSemanticLongPress : null,
            progress: _controller.value,
          ),
        ),
      ),
    );
  }
}
