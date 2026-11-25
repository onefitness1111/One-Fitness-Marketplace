import "../../core/utils/date_utils.dart";

/// How far around today the first booking read reaches.
///
/// The dashboard needs today, recent missed sessions, and the next couple
/// of weeks. Older bookings and ones further out load when a schedule,
/// booking, or history screen opens.
const dashboardBookingLookbackDays = 14;
const dashboardBookingLookaheadDays = 14;

({String from, String to}) dashboardBookingWindow(DateTime day) {
  final start = DateTime(day.year, day.month, day.day);
  return (
    from: isoDate(start.subtract(const Duration(days: dashboardBookingLookbackDays))),
    to: isoDate(start.add(const Duration(days: dashboardBookingLookaheadDays))),
  );
}

/// The first screen paints from the dashboard read. Shop, exercises, the
/// full booking history, and the rest of the gym wait until that screen
/// is opened. The owner used to block on all of it; the home screen now
/// uses the same first read, and those other screens load when opened.
bool shellBeforeFullGymDownload(String? role) =>
    role == "client" || role == "coach" || role == "owner";

/// Trainer columns the home screen and the booking grid actually read.
/// Before/after photos and the long bio stay off this read.
const dashboardTrainerColumns =
    "profile_id, disciplines, session_types, slot_interval, availability, locations, avail_lock_until, signup_at, reviewed_by_owner, updated_at, coach_code, unavailability, title, coach_name";

/// How many network waves a cold launch needs before the dashboard can show.
///
/// Kept for the bootstrap-RPC comparison. The sign-in path no longer waits
/// on that RPC: a client paints after one parallel round, a coach or the
/// owner after two (directory, then the rows that need its ids).
int coldLaunchWaves({required bool bootstrapRpc}) => bootstrapRpc ? 1 : 2;

/// Rounds the sign-in button actually waits for, after the password token.
///
/// A client needs one parallel round (their row, the booking window, plans).
/// A coach or the owner needs a second round because client and trainer rows
/// are filtered by ids from the directory. Contacts, billing, and program
/// blobs are not counted: they do not hold the dashboard.
int blockingSignInRounds(String role) => role == "client" ? 1 : 2;

/// Reads that must finish before the dashboard is shown.
Set<String> blockingSignInReads(String role) {
  if (role == "client") return const {"clients", "bookings", "membership_plans"};
  return const {"profile_directory", "bookings", "clients", "trainers", "membership_plans"};
}

/// Started beside the blocking reads, or just after the dashboard is up.
/// None of these are allowed to delay navigation.
Set<String> backgroundSignInReads(String role) {
  if (role == "client") {
    return const {
      "client_records_home",
      "waiver_docs",
      "platform_settings",
      "profile_directory",
      "profile_contact_for",
      "trainers",
      "client_billing_for",
    };
  }
  return const {
    "profile_contact_for",
    "client_records_programs",
    "waiver_docs",
    "platform_settings",
    "client_billing_for",
  };
}

/// True when the home screen should load through the existing queries.
///
/// Every RPC error takes that path: a missing function, a runtime failure
/// such as an ambiguous column, and a transport error. A payload is usable
/// when `directory` is a list.
bool dashboardBootstrapNeedsFallback({Object? error, Object? payload}) {
  if (error != null) return true;
  if (payload is! Map) return true;
  return payload["directory"] is! List;
}

/// Lines printed during launch so a slow read is visible in the log.
class LaunchQueryLog {
  static final List<String> lines = [];

  static void reset() => lines.clear();

  static void note(String line) {
    lines.add(line);
    // ignore: avoid_print
    print("[launch] $line");
  }
}

/// Every client record the owner dashboard reads, including workout logs.
const fullDashboardRecordColumns =
    "profile_id,savedPrograms:data->savedPrograms,nutrition:data->nutrition,programDays:data->programDays,workoutLogs:data->workoutLogs,trainerNotes:data->trainerNotes";

/// Coach dashboard read. Workout logs and the live split are large and are
/// not on the home list; they load when a client or a session is opened.
const coachDashboardRecordColumns =
    "profile_id,savedPrograms:data->savedPrograms,nutrition:data->nutrition,trainerNotes:data->trainerNotes,programRefresh:data->programRefresh";

/// What the client home screen reads from their own record.
///
/// Saved programs, nutrition, photos, and the rest of the blob stay out.
/// Those were the multi-megabyte body whose decode froze the phone between
/// network rounds. They load when that screen opens.
const clientHomeRecordColumns =
    "profile_id,habitSettings:data->habitSettings,habitLogs:data->habitLogs,tourSeen:data->tourSeen,intake:data->intake,signatures:data->signatures,workoutLogs:data->workoutLogs";

/// Programs, nutrition, meal choices, and food log for the client's Plans
/// and Nutrition screens. Photos stay out so opening Plans does not pull
/// multi-megabyte inline images.
const clientPlansRecordColumns =
    "profile_id,savedPrograms:data->savedPrograms,nutrition:data->nutrition,programDays:data->programDays,savedNutritionPrograms:data->savedNutritionPrograms,foodLog:data->foodLog,myMeals:data->myMeals";

/// Measurements, goal, and progress photos for the client's Log Progress
/// screen. Kept out of both the home read and the Plans read.
const clientProgressRecordColumns =
    "profile_id,measurements:data->measurements,progressGoal:data->progressGoal,photos:data->photos";

/// Programs, nutrition, notes, and logs for the coach home's attention list
/// and status dots. Fetched after the schedule is on screen, and decoded
/// off the UI isolate.
const staffDetailRecordColumns =
    "profile_id,savedPrograms:data->savedPrograms,nutrition:data->nutrition,trainerNotes:data->trainerNotes,programRefresh:data->programRefresh,workoutLogs:data->workoutLogs";

/// Columns [SupabaseService] turns into a [Booking]. Nothing else on the row
/// is shown, and a bare `select()` pulls columns the screen never reads.
const bookingSelectColumns =
    "id, client_id, trainer_id, date, slot_min, session_type, discipline, attendance_status, client_started_at, location, is_physical_assessment, overridden_by, overridden_at, override_reason, plan_id, duration_min, counts_toward_pay, cancelled_at";

const messageSelectColumns =
    "id, client_id, who, body, created_at, trainer_id, read_by_coach, channel, group_name, routed_to";

const pointsSelectColumns =
    "id, client_id, amount, type, source, created_at, expires_at, granted_by_user_id, reason, voided_by_ledger_id";

const badgeSelectColumns =
    "id, client_id, badge_key, earned_at, earned_method, granted_by_user_id, note, revoked_at, revoked_by_user_id, celebrated_at";

const chargeSelectColumns =
    "id, client_id, client_name, type, date, at, amount, category, description, plan_id, plan_name, trainer_id, trainer_name, waived_at, stripe_payment_intent_id";

const blockedTimeSelectColumns = "id, trainer_id, date, full_day, start_min, end_min, reason";

/// Tables stored as one jsonb blob per row. The app only reads these two.
const jsonBlobColumns = "id, data";

/// A slice of gym data that is not required to paint the dashboard.
enum GymSection {
  bookingsRest,
  points,
  badges,
  challenges,
  challengeTemplates,
  charges,
  blocked,
  products,
  coupons,
  programs,
  nutritionLibrary,
  meals,
  exercises,
  squads,
  waitlist,
  categories,
  equipment,
  forms,
  coachBadges,
  prEvents,
  messages,
  plans,
  waivers,
  clientPlans,
  clientProgress,
}

/// What to fetch when a client opens [screen]. The dashboard itself is
/// loaded by the sign-in path; this covers everything else.
Set<GymSection> sectionsForClientScreen(String screen) => switch (screen) {
      "dashboard" => {GymSection.badges},
      "plans" || "nutrition" => {
          GymSection.exercises,
          GymSection.programs,
          GymSection.meals,
          GymSection.nutritionLibrary,
          GymSection.clientPlans,
        },
      "booking" || "advancedBooking" => {
          GymSection.bookingsRest,
          GymSection.blocked,
          GymSection.waitlist,
          GymSection.plans,
          GymSection.waivers,
        },
      "day" => {
          GymSection.bookingsRest,
          GymSection.blocked,
          GymSection.waitlist,
          GymSection.plans,
          GymSection.waivers,
          GymSection.clientPlans,
        },
      "progress" || "photos" || "measurements" => {
          GymSection.clientProgress,
        },
      "chat" => {GymSection.messages},
      "memberships" => {
          GymSection.plans,
          GymSection.products,
          GymSection.coupons,
          GymSection.charges,
        },
      "shop" => {GymSection.products},
      "rewards" => {GymSection.points},
      "badges" => {GymSection.badges},
      "challenges" => {GymSection.challenges, GymSection.challengeTemplates},
      "squad" => {GymSection.squads},
      "history" => {GymSection.bookingsRest},
      "forms" => {GymSection.forms},
      "signatures" => {GymSection.waivers},
      _ => const {},
    };

/// What to fetch when a coach opens [screen]. The owner still loads these
/// during sign-in, the way the app always has.
Set<GymSection> sectionsForStaffScreen(String screen) => switch (screen) {
      "clients" => {
          GymSection.badges,
          GymSection.points,
          GymSection.challenges,
          GymSection.forms,
          GymSection.programs,
          GymSection.exercises,
        },
      "schedule" || "selfbook" => {
          GymSection.bookingsRest,
          GymSection.blocked,
          GymSection.waitlist,
        },
      "chat" || "teamchat" => {GymSection.messages},
      "exercises" => {GymSection.exercises},
      "equipment" => {GymSection.equipment},
      "builderWorkout" => {GymSection.programs, GymSection.exercises},
      "builderNutrition" => {GymSection.nutritionLibrary, GymSection.meals},
      "challenges" => {GymSection.challenges, GymSection.challengeTemplates},
      "products" => {GymSection.products, GymSection.categories},
      "memberships" => {
          GymSection.plans,
          GymSection.coupons,
          GymSection.categories,
          GymSection.forms,
        },
      "waivers" => {GymSection.waivers},
      "reports" => {GymSection.charges, GymSection.coachBadges, GymSection.prEvents},
      "waitlist" => {GymSection.waitlist},
      "coachbadges" => {GymSection.coachBadges, GymSection.prEvents},
      "mypay" => {GymSection.charges},
      _ => const {},
    };
