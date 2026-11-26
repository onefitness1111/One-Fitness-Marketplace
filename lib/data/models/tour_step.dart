import "package:flutter/widgets.dart";
import "package:shared_preferences/shared_preferences.dart";

/// One step of a walkthrough. [key] looks up the GlobalKey of the button
/// to spotlight.
class TourStep {
  const TourStep(this.key, this.title, this.desc);
  final String key;
  final String title;
  final String desc;
}

/// First time a client lands on the dashboard: the menu, then each bottom tab.
const kDashboardTourSteps = [
  TourStep("dash-hamburger", "Menu", "Tap here any time to reach your progress log, habits, shop, challenges, and more."),
  TourStep("dash-nav-dashboard", "Dashboard", "Your home base — today's plan, upcoming sessions, and quick actions."),
  TourStep("dash-nav-plans", "Plans", "Your workout and nutrition plans, laid out day by day."),
  TourStep("dash-nav-booking", "Booking", "Book, reschedule, or cancel your sessions here."),
  TourStep("dash-nav-chat", "Chat", "Message your coach directly, any time."),
  TourStep("dash-nav-memberships", "Access Hub", "Your plan, sessions remaining, and upgrade options."),
];

/// First time a client opens the menu. One step per button, in menu order.
///
/// Every step names a row that is really in the drawer (see `_drawerItems`
/// in client_shell.dart). Workout Plan and Nutrition Plan are not rows —
/// they live in the Plans tab, and the Plans step above introduces both.
const kDrawerTourSteps = [
  TourStep("drawer-progress", "Log Progress", "Log your weight, photos, and measurements over time."),
  TourStep("drawer-habits", "Habit Tracker", "Check off your daily habits and build your streak."),
  TourStep("drawer-history", "History", "Every past session and workout you've logged, all in one place."),
  TourStep("drawer-forms", "Assessments", "Fill out or review your intake and assessment forms."),
  TourStep("drawer-shop", "Shop", "Gear and extras from the gym."),
  TourStep("drawer-rewards", "Rewards", "Points you've earned, and what you can spend them on."),
  TourStep("drawer-challenges", "Challenges", "Join gym-wide challenges and see the leaderboard."),
  TourStep("drawer-squad", "My Squad", "See your training squad and their progress."),
  TourStep("drawer-signatures", "Signatures", "View your signed agreements and waivers."),
  TourStep("drawer-support", "Support", "Call the gym when you need a person, not a message."),
  TourStep("drawer-settings", "Profile Settings", "Update your personal info and photo, and see your Merit Badges."),
];

/// A coach's first open: the menu, then the four bottom buttons.
const kCoachHomeTourSteps = [
  TourStep("staff-hamburger", "Menu", "Scheduling tools, exercises, your profile, and pay live in here."),
  TourStep("staff-nav-dashboard", "Dashboard", "Today's sessions, who needs you, and workouts happening now."),
  TourStep("staff-nav-clients", "Clients", "Your roster. Open someone to see their plans, notes, and progress."),
  TourStep("staff-nav-chat", "Chat", "Message a client. What you send is saved."),
  TourStep("staff-nav-schedule", "Schedule", "Your calendar. Add a session or block time off."),
];

/// One step for every row in the coach menu, in the same order.
const kCoachMenuTourSteps = [
  TourStep("staff-drawer-dashboard", "Dashboard", "Back to today's list."),
  TourStep("staff-drawer-requests", "Requests", "Time-off and schedule requests waiting on you."),
  TourStep("staff-drawer-waitlist", "Waitlist", "People waiting for a spot that opened up."),
  TourStep("staff-drawer-exercises", "Exercises", "The movement library you build programs from."),
  TourStep("staff-drawer-equipment", "Equipment Library", "What the gym has, so programs stay realistic."),
  TourStep("staff-drawer-challenges", "Challenges", "Gym-wide challenges you can run."),
  TourStep("staff-drawer-myprofile", "My Profile", "Your photo, bio, the name clients see, and your Merit Badge progress."),
  TourStep("staff-drawer-mypay", "My Pay", "What you've earned."),
  TourStep("staff-drawer-calendarsync", "Calendar Sync", "Put the sessions you run on the calendar you already use."),
  TourStep("staff-drawer-support", "Support", "How to reach the gym."),
];

/// The owner's first open. Same four buttons as a coach, plus Staff.
const kOwnerHomeTourSteps = [
  TourStep("staff-hamburger", "Menu", "Reports, coaches, waivers, and the rest of the business live in here."),
  TourStep("staff-nav-dashboard", "Dashboard", "The whole gym for today — sessions, coaches, and what needs a look."),
  TourStep("staff-nav-clients", "Clients", "Every client, not only one coach's roster."),
  TourStep("staff-nav-chat", "Chat", "Client messages. You can also read staff conversations."),
  TourStep("staff-nav-schedule", "Schedule", "The gym calendar, across every coach."),
  TourStep("staff-nav-staff", "Staff", "Coaches, what they can do, and who can sign in."),
];

/// One step for every row in the owner menu. Coaches, Customize Platform,
/// and Waivers are their own rows — they are not tucked under Reports.
const kOwnerMenuTourSteps = [
  TourStep("staff-drawer-dashboard", "Dashboard", "Back to the gym overview."),
  TourStep("staff-drawer-requests", "Requests", "Time-off and schedule requests from the team."),
  TourStep("staff-drawer-builderWorkout", "Build Workout Program", "Create a workout plan you can assign."),
  TourStep("staff-drawer-builderNutrition", "Build Nutrition Program", "Create a nutrition plan, including calorie budgets."),
  TourStep("staff-drawer-exercises", "Exercises", "The movement library programs are built from."),
  TourStep("staff-drawer-equipment", "Equipment Library", "What the gym has on the floor."),
  TourStep("staff-drawer-challenges", "Challenges", "Set up a gym-wide challenge."),
  TourStep("staff-drawer-waitlist", "Waitlist", "People waiting for an open spot."),
  TourStep("staff-drawer-memberships", "Access Hub", "Plans, packages, and who can buy them."),
  TourStep("staff-drawer-products", "Products", "Things the shop sells."),
  TourStep("staff-drawer-staff", "Staff", "Every coach in one place: approval code, profiles, pay, and new coaches waiting on you."),
  TourStep("staff-drawer-collect", "Collect Payments", "Clients who owe money, and charging what's due."),
  TourStep("staff-drawer-reports", "Reports", "Money, attendance, and how the business is doing. Just the reports."),
  TourStep("staff-drawer-platformSettings", "Customize Platform", "The gym's name, hours, and the options clients see."),
  TourStep("staff-drawer-waivers", "Waivers & Contracts", "What a client signs before they train."),
  TourStep("staff-drawer-support", "Support", "The phone number clients call."),
];

final Map<String, GlobalKey> kDashboardTourKeys = {for (final s in kDashboardTourSteps) s.key: GlobalKey()};
final Map<String, GlobalKey> kDrawerTourKeys = {for (final s in kDrawerTourSteps) s.key: GlobalKey()};

/// One map for every coach and owner spotlight. Only the buttons on screen
/// are attached; the other role's keys simply have nothing to point at.
final Map<String, GlobalKey> kStaffTourKeys = _staffTourKeys();

Map<String, GlobalKey> _staffTourKeys() {
  final out = <String, GlobalKey>{};
  for (final s in [...kCoachHomeTourSteps, ...kCoachMenuTourSteps, ...kOwnerHomeTourSteps, ...kOwnerMenuTourSteps]) {
    out.putIfAbsent(s.key, GlobalKey.new);
  }
  return out;
}

/// Remembers a menu tour that was closed before Skip or Got it, so the next
/// open continues on that step instead of starting over. Held for this
/// sitting only — a finished tour is stored on the person's record.
class TourMemory {
  static String? clientDrawerKey;
  static String? staffDrawerKey;
}

/// Whether a coach or the owner has already finished a tour. Stored on the
/// phone, so it does not need a database change. If the phone can't store
/// it (a widget test, for example), the tour stays down rather than covering
/// the screen with no way to remember Skip.
class StaffTour {
  static String _key(String id, String which) => "ofm.staffTour.$id.$which";

  static Future<bool> seen(String id, String which) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key(id, which)) ?? false;
    } catch (_) {
      return true;
    }
  }

  static Future<void> markSeen(String id, String which) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key(id, which), true);
    } catch (_) {}
  }
}
