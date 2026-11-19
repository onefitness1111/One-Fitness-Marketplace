// ── How many suggested days this client gets ──────────────────────────────
//
// Deliberately decided here, in code, rather than in the prompt. The whole
// complaint about leaving it to the model is that the same intake can come
// back with a different answer each time; arithmetic can't do that. Claude is
// told the exact number and only chooses what goes in those days.
//
// The ladder, in order:
//   1. ceiling        min(2, 6 - committed) — the "up to 2" cap, and what
//                     keeps at least one full rest day at every size
//   2. hard stops     conditions where no unsupervised extra work is added
//   3. deductions     recovery pressure, one day off the ceiling each
//   4. demand         how many the goal actually asks for
//   5. allowed        min(demand, ceiling after deductions), floored at 0
//
// Every step that moves the number records why, and those reasons are shown
// to the coach on the draft — so a surprising count can be read back rather
// than argued with.

/** Free text that answers "do you have X?" with something other than "no". */
export function mentionsSomething(value: unknown): boolean {
  const text = String(value ?? "").trim().toLowerCase();
  if (!text) return false;
  return !/^(no|none|n\/?a|nope|never|nil|-+|no issues?|not really|none that i know of)\.?$/.test(text);
}

/**
 * How many committed days a program gets, from what the client asked for.
 *
 * Capped at 6, because one full rest day a week is an invariant of the
 * program rather than something the suggested-day ladder can defend: a client
 * who says they will train 7 days has spent the rest day before any suggested
 * day is even considered. Falls back to 3 when availability is missing or
 * vague, matching what the generator did before suggested days existed.
 */
export function committedDayCount(statedDaysPerWeek: unknown): number {
  const n = Number(String(statedDaysPerWeek ?? "").match(/\d+/)?.[0] ?? NaN);
  if (!Number.isFinite(n) || n < 1) return 3;
  return Math.min(6, n);
}

export function asList(value: unknown): string[] {
  if (Array.isArray(value)) return value.map((v) => String(v));
  if (value == null || value === "") return [];
  return [String(value)];
}

export function decideSuggestedDays(answers: Record<string, any>, committed: number) {
  const reasons: string[] = [];
  const goals = asList(answers.primaryGoal);
  const styles = asList(answers.style);
  const hasGoal = (g: string) => goals.some((x) => x.toLowerCase() === g.toLowerCase());
  const hasStyle = (s: string) => styles.some((x) => x.toLowerCase() === s.toLowerCase());

  // 1. Ceiling. At 5 committed days this is 1 and at 6 it is 0, which is the
  //    rest day asserting itself rather than a separate rule.
  const ceiling = Math.max(0, Math.min(2, 6 - committed));

  // 2. Hard stops. Not deductions — these are reasons to add nothing at all.
  if (hasGoal("Injury Recovery")) {
    reasons.push("No suggested days: the client's stated goal is injury recovery, so extra unsupervised load works against the program.");
    return { allowed: 0, ceiling, reasons };
  }
  if (mentionsSomething(answers.redFlags)) {
    reasons.push("No suggested days: the intake reports dizziness, fainting, chest pain or breathlessness during exercise. That needs clearing before any unsupervised conditioning is added.");
    return { allowed: 0, ceiling, reasons };
  }

  // 3. Recovery deductions.
  let budget = ceiling;
  const deduct = (why: string) => {
    if (budget > 0) {
      budget -= 1;
      reasons.push(why);
    }
  };
  if (String(answers.experience ?? "").toLowerCase() === "beginner") {
    deduct("One fewer suggested day: the client is a beginner, and the committed sessions are already a large jump in weekly load.");
  }
  const sleep = Number(String(answers.sleep ?? "").match(/\d+(\.\d+)?/)?.[0] ?? NaN);
  if (Number.isFinite(sleep) && sleep < 6) {
    deduct(`One fewer suggested day: ${sleep} hours of sleep a night leaves little recovery capacity to spend.`);
  }
  if (hasStyle("HIIT") || (committed >= 4 && (hasStyle("Powerlifting") || hasGoal("Strength")))) {
    deduct("One fewer suggested day: the committed block is already high-intensity, so added conditioning would cut into recovery rather than add to the work.");
  }
  if (mentionsSomething(answers.currentInjuries) || mentionsSomething(answers.limitations)) {
    deduct("One fewer suggested day: the intake notes a current injury or physical limitation.");
  }

  // 4. What the goal actually asks for. Goals are multi-select, so the
  //    hungriest one sets the demand.
  const eventText = `${answers.success ?? ""} ${answers.primaryGoalOther ?? ""}`.toLowerCase();
  const namesAnEvent = /hyrox|marathon|half[- ]?marathon|10 ?k|5 ?k|triathlon|spartan|tough mudder|iron ?man|race|competition|comp\b|meet\b/.test(eventText);
  let demand = 1;
  if (namesAnEvent || hasGoal("Endurance") || hasGoal("Athletic Performance")) {
    demand = 2;
  } else if (hasGoal("Fat Loss") || hasGoal("Body Recomposition")) {
    demand = 2;
  } else if (hasGoal("General Health")) {
    const activity = String(answers.activity ?? "").toLowerCase();
    demand = activity === "sedentary" || activity === "lightly active" ? 2 : 1;
  } else if (hasGoal("Muscle Gain") || hasGoal("Strength")) {
    // Conditioning is secondary to the goal here; one easy day aids recovery,
    // two starts competing with it.
    demand = 1;
  } else if (hasGoal("Mobility/Flexibility")) {
    demand = 1;
  }

  const allowed = Math.max(0, Math.min(demand, budget));
  if (allowed < demand && budget < ceiling) {
    reasons.push(`The goal would support ${demand} suggested day${demand === 1 ? "" : "s"}, but recovery comes first — ${allowed === 0 ? "none were added" : `${allowed} was added`}.`);
  }
  if (allowed === 0 && budget > 0) {
    reasons.push("No suggested days: this client's goal is served better by recovering fully between committed sessions.");
  }
  return { allowed, ceiling, reasons };
}
