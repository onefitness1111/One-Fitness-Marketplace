import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "../motion/motion.dart";
import "../session/login_prompts.dart";
import "../theme/app_colors.dart";

/// A tap target that paints a gray or white wash on top of [child] while
/// the finger is down.
///
/// Material's splash is drawn behind the child, so it disappears on the
/// solid cards, chips, and rows this app is built from. This wash sits in
/// front. Pass [selected] for a chip, tab, meal, or exercise that should
/// stay lit until it is unchosen. A press on a selected target still
/// flashes, then settles back to the held wash.
class TapHighlight extends StatefulWidget {
  const TapHighlight({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.borderRadius,
    this.shape = BoxShape.rectangle,
    this.behavior = HitTestBehavior.opaque,
    this.selected = false,
    this.haptic = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final BorderRadius? borderRadius;
  final BoxShape shape;
  final HitTestBehavior behavior;

  /// Stays highlighted after the finger lifts, until this becomes false.
  final bool selected;

  /// A light tap through the phone's haptic engine. Used for buttons.
  final bool haptic;

  bool get _enabled => onTap != null || onLongPress != null;

  @override
  State<TapHighlight> createState() => _TapHighlightState();
}

class _TapHighlightState extends State<TapHighlight> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (!mounted || _pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget._enabled;
    final show = enabled && (_pressed || widget.selected);
    final color = _pressed ? AppColors.pressOverlay : AppColors.selectedOverlay;
    return Listener(
      onPointerDown: enabled ? (_) => _setPressed(true) : null,
      onPointerUp: enabled ? (_) => _setPressed(false) : null,
      onPointerCancel: enabled ? (_) => _setPressed(false) : null,
      child: GestureDetector(
        onTap: widget.onTap == null
            ? null
            : () {
                if (LoginPrompts.claim()) return;
                if (widget.haptic) HapticFeedback.lightImpact();
                widget.onTap!();
              },
        onLongPress: widget.onLongPress,
        behavior: widget.behavior,
        child: AnimatedScale(
          scale: enabled && _pressed && !reduceMotionOf(context) ? 0.97 : 1,
          duration: motionPress,
          curve: Curves.easeOut,
          child: _TapWash(
          show: show,
          color: color,
          borderRadius: widget.shape == BoxShape.circle ? null : widget.borderRadius,
          shape: widget.shape,
          child: widget.child,
        ),
        ),
      ),
    );
  }
}

/// The wash itself, so a test can find it while a finger is down.
class TapWash extends StatelessWidget {
  const TapWash({super.key, required this.color, required this.child, this.borderRadius, this.shape = BoxShape.rectangle});

  final Color color;
  final Widget child;
  final BorderRadius? borderRadius;
  final BoxShape shape;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        color: color,
        borderRadius: shape == BoxShape.circle ? null : borderRadius,
        shape: shape,
      ),
      child: child,
    );
  }
}

class _TapWash extends StatelessWidget {
  const _TapWash({
    required this.show,
    required this.color,
    required this.child,
    this.borderRadius,
    this.shape = BoxShape.rectangle,
  });

  final bool show;
  final Color color;
  final Widget child;
  final BorderRadius? borderRadius;
  final BoxShape shape;

  @override
  Widget build(BuildContext context) {
    if (!show) return child;
    return TapWash(color: color, borderRadius: borderRadius, shape: shape, child: child);
  }
}
