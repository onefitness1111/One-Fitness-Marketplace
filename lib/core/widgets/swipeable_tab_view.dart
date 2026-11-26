import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
import "../navigation/local_back_stack.dart";
import "segmented_toggle.dart";

/// Flutter's default ScrollBehavior only accepts touch/stylus drags — mouse
/// is deliberately excluded so desktop users don't accidentally scroll by
/// clicking a list. That's the right call for a normal scrollable, but this
/// PageView's whole purpose is "swipe to switch tabs" — mouse-drag should
/// work too (Flutter web on desktop, and it's how this got verified).
class _SwipeScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.trackpad,
      };
}

/// A pill row wired to a swipeable [PageView]. Tapping a segment or swiping
/// the page both keep the two in sync, and the pill follows the page.
/// Shared by Plans (Workout/Nutrition) and Log Progress (Overview/Body/
/// Lifts/Photos). The owning shell must exclude this screen from its own
/// swipe-to-go-back gesture (see client_shell.dart's `_swipeOwnedByScreen`)
/// or the two horizontal-drag gestures fight.
class SwipeableTabView extends StatefulWidget {
  const SwipeableTabView({
    super.key,
    required this.labels,
    required this.children,
    this.onIndexChanged,
    this.focusIndex,
    this.focusRequest = 0,
  });

  final List<String> labels;
  final List<Widget> children;
  final ValueChanged<int>? onIndexChanged;

  /// Moves to [focusIndex] each time [focusRequest] changes, e.g. Plans
  /// jumping to Workout when a coach starts a session (L2).
  final int? focusIndex;
  final int focusRequest;

  /// True while any of these tab rows is on screen. Shells use it so a
  /// sideways drag changes tabs instead of leaving the screen. Plans is
  /// also listed by name in the client shell; this covers a tab row that
  /// sits inside another screen, such as a coach's client Progress page.
  static bool get ownsHorizontalSwipe => _owners > 0;
  static int _owners = 0;

  @override
  State<SwipeableTabView> createState() => _SwipeableTabViewState();
}

class _SwipeableTabViewState extends State<SwipeableTabView> {
  late final PageController _controller = PageController();
  int _index = 0;

  /// Tabs visited before this one, in order — back steps through them one
  /// at a time (Workout → Nutrition → back → Workout) before leaving the
  /// screen, registered with the shell via [LocalBackScope] below.
  final List<int> _history = [];

  /// Set while a tap / back animates to a tab, so the pages it passes over on
  /// the way (0 → 2 goes through 1) aren't recorded as visits.
  int? _animatingTo;

  @override
  void initState() {
    super.initState();
    SwipeableTabView._owners++;
  }

  @override
  void didUpdateWidget(covariant SwipeableTabView old) {
    super.didUpdateWidget(old);
    final target = widget.focusIndex;
    if (target != null && widget.focusRequest != old.focusRequest && target >= 0 && target < widget.children.length) {
      _goTo(target);
    }
  }

  void _animate(int i) {
    _animatingTo = i;
    _controller.animateToPage(i, duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
  }

  void _goTo(int i) {
    if (i == _index) return;
    setState(() => _history.add(_index));
    _animate(i);
  }

  void _back() {
    if (_history.isEmpty) return;
    final previous = _history.last;
    setState(() => _history.removeLast());
    _animate(previous);
  }

  void _onPageChanged(int i) {
    setState(() {
      if (_animatingTo == null) {
        // A swipe by the user — a visit like any tap.
        _history.add(_index);
      } else if (_animatingTo == i) {
        _animatingTo = null;
      }
      _index = i;
    });
    widget.onIndexChanged?.call(i);
  }

  @override
  void dispose() {
    SwipeableTabView._owners--;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LocalBackScope(
      isOpen: _history.isNotEmpty,
      onBack: _back,
      child: _buildTabs(),
    );
  }

  Widget _buildTabs() {
    return Column(
      children: [
        ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final count = widget.labels.length;
            final raw = _controller.hasClients ? (_controller.page ?? _index.toDouble()) : _index.toDouble();
            final page = count <= 1 ? 0.0 : raw.clamp(0.0, (count - 1).toDouble());
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: SegmentedToggle(
                labels: widget.labels,
                index: _index,
                position: page,
                onChanged: _goTo,
              ),
            );
          },
        ),
        Expanded(
          child: ScrollConfiguration(
            behavior: _SwipeScrollBehavior(),
            child: PageView(
              controller: _controller,
              onPageChanged: _onPageChanged,
              children: widget.children,
            ),
          ),
        ),
      ],
    );
  }
}

