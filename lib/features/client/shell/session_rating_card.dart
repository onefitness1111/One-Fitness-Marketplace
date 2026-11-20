import "package:flutter/material.dart";

import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/widgets.dart";

/// Full-screen ask after a checked-in session. It stays until the client
/// submits stars or taps Not today.
class SessionRatingCard extends StatefulWidget {
  const SessionRatingCard({super.key, required this.coachName, required this.onSubmit, required this.onNotToday});

  final String coachName;
  final void Function(int stars, String text) onSubmit;
  final VoidCallback onNotToday;

  @override
  State<SessionRatingCard> createState() => _SessionRatingCardState();
}

class _SessionRatingCardState extends State<SessionRatingCard> {
  int _stars = 0;
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Text(
                "How was your session with ${widget.coachName}?",
                style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, height: 1.2),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  for (var n = 1; n <= 5; n++)
                    IconButton(
                      onPressed: () => setState(() => _stars = n),
                      icon: Icon(Icons.star, color: n <= _stars ? Colors.white : AppColors.line),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _text,
                enabled: _stars > 0,
                maxLines: 3,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: _stars > 0 ? "Optional note" : "Choose stars first",
                  hintStyle: TextStyle(color: AppColors.mute),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.line)),
                  disabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.line)),
                  focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: Colors.white)),
                ),
              ),
              const Spacer(),
              BtnGold(
                full: true,
                onPressed: _stars == 0 ? null : () => widget.onSubmit(_stars, _text.text.trim()),
                child: const Text("Submit"),
              ),
              const SizedBox(height: 8),
              BtnGhost(full: true, onPressed: widget.onNotToday, child: const Text("Not today")),
            ],
          ),
        ),
      ),
    );
  }
}
