import "package:flutter/material.dart";

import "../../../core/health/health_stats.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/app_card.dart";
import "line_chart_painter.dart";

class HealthFlagList extends StatelessWidget {
  const HealthFlagList({super.key, required this.flags});

  final List<HealthFlag> flags;

  @override
  Widget build(BuildContext context) {
    if (flags.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final flag in flags)
          AppCard(
            borderColor: AppColors.line,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  flag.title,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: flag.onTarget ? AppColors.statusGreen : AppColors.warning,
                  ),
                ),
                const SizedBox(height: 4),
                Text(flag.detail, style: TextStyle(fontSize: 13, height: 1.35, color: AppColors.mute)),
              ],
            ),
          ),
      ],
    );
  }
}

class HealthTodayGrid extends StatelessWidget {
  const HealthTodayGrid({super.key, required this.reading, required this.now});

  final HealthReading reading;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final today = reading.dayOn(now);
    if (today == null) return const SizedBox.shrink();
    final sleepDown = healthFlags(days: reading.days, today: now).any((flag) => flag.title.startsWith("Sleep is down"));
    final tiles = <_Tile>[
      if (today.steps != null) _Tile("STEPS", formatCount(today.steps!), "Goal ${formatCount(kDailyStepGoal)}"),
      if (today.activeKcal != null) _Tile("ACTIVE CAL", formatNumber(today.activeKcal!, decimals: 0), "kcal"),
      if (today.restingHr != null) _Tile("RESTING HR", "${today.restingHr}", restingCaption(reading.days, now)),
      if (today.sleepMinutes != null) _Tile("SLEEP", formatSleep(today.sleepMinutes!), sleepDown ? "Down this week" : "Last night"),
      if (today.hrvMs != null) _Tile("HRV", formatNumber(today.hrvMs!, decimals: 0), "ms"),
      if (today.heartRate != null) _Tile("HEART RATE", "${today.heartRate}", "Latest"),
    ];
    if (tiles.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("TODAY", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: AppColors.mute)),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 8.0;
            final width = (constraints.maxWidth - gap * 2) / 3;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [for (final tile in tiles) SizedBox(width: width, child: tile)],
            );
          },
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, this.caption);

  final String label;
  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: AppColors.mute)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(caption, style: TextStyle(fontSize: 11, color: AppColors.mute)),
        ],
      ),
    );
  }
}

class HealthTrendsBlock extends StatefulWidget {
  const HealthTrendsBlock({super.key, required this.days, required this.now, this.weightGoalLb});

  final List<HealthDay> days;
  final DateTime now;
  final double? weightGoalLb;

  @override
  State<HealthTrendsBlock> createState() => _HealthTrendsBlockState();
}

class _HealthTrendsBlockState extends State<HealthTrendsBlock> {
  int _range = 30;
  BodyStat _stat = BodyStat.weight;

  @override
  Widget build(BuildContext context) {
    final lines = healthTrendLines(
      days: widget.days,
      today: widget.now,
      rangeDays: _range,
      weightGoalLb: widget.weightGoalLb,
    );
    final series = chartSeries(
      days: widget.days,
      today: widget.now,
      rangeDays: _range,
      read: switch (_stat) {
        BodyStat.weight => (day) => day.weightLb,
        BodyStat.bodyFat => (day) => day.bodyFatPct,
        BodyStat.lean => (day) => day.leanMassLb,
      },
    );
    final numbers = series.whereType<double>().toList();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("TRENDS", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: AppColors.mute)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final days in const [7, 30, 90])
                _Chip(
                  label: "${days}d",
                  selected: _range == days,
                  onTap: () => setState(() => _range = days),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _Chip(label: "Weight", selected: _stat == BodyStat.weight, onTap: () => setState(() => _stat = BodyStat.weight)),
              _Chip(label: "Body fat", selected: _stat == BodyStat.bodyFat, onTap: () => setState(() => _stat = BodyStat.bodyFat)),
              _Chip(label: "Lean mass", selected: _stat == BodyStat.lean, onTap: () => setState(() => _stat = BodyStat.lean)),
            ],
          ),
          const SizedBox(height: 12),
          if (numbers.length < 2)
            Text("Not enough days in this range yet.", style: TextStyle(fontSize: 12, color: AppColors.mute))
          else
            SizedBox(
              height: 110,
              width: double.infinity,
              child: CustomPaint(
                painter: LineChartPainter(
                  series: [ChartSeries(values: series, color: AppColors.txt)],
                  minY: numbers.reduce((a, b) => a < b ? a : b),
                  maxY: numbers.reduce((a, b) => a > b ? a : b),
                ),
              ),
            ),
          if (lines.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text("Trends vs. goals", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.mute)),
            const SizedBox(height: 6),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(line.label, style: const TextStyle(fontSize: 13))),
                    Text(line.value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    if (line.delta != null) ...[
                      const SizedBox(width: 8),
                      Text(line.delta!, style: TextStyle(fontSize: 12, color: AppColors.mute)),
                    ],
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.gold : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            border: Border.all(color: selected ? AppColors.gold : AppColors.line),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: selected ? AppColors.onGold : AppColors.mute),
          ),
        ),
      ),
    );
  }
}

class HealthWorkoutList extends StatelessWidget {
  const HealthWorkoutList({super.key, required this.workouts, required this.now});

  final List<HealthWorkout> workouts;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    if (workouts.isEmpty) return const SizedBox.shrink();
    final shown = workouts.take(8);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("SYNCED WORKOUTS", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: AppColors.mute)),
        const SizedBox(height: 8),
        for (final workout in shown)
          AppCard(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(workout.activity, style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(
                        "${workoutWhen(workout.startedAt, now)} · ${workout.durationMin} min"
                        "${workout.energyKcal == null ? "" : " · ${formatNumber(workout.energyKcal!, decimals: 0)} kcal"}",
                        style: TextStyle(fontSize: 12, color: AppColors.mute),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
