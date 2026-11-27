/// What the sender sees under a message they chose to also text, when the
/// text did not go out. [outcome] is chat_auto_reply_sms.outcome, written by
/// the chat-auto-reply-sms function. Null means show nothing (sent, still
/// working, or SMS wasn't chosen).
String? smsOutcomeNotice(String? outcome) {
  final raw = (outcome ?? "").trim();
  if (raw.isEmpty || raw == "pending" || raw == "invite sent" || raw.startsWith("sent")) return null;
  if (raw.startsWith("held:")) {
    return "Not texted yet: they haven't agreed to texts. It's in the app.";
  }
  if (!raw.startsWith("skipped:")) return null;
  final reason = raw.substring("skipped:".length).trim();
  switch (reason) {
    case "sms not chosen":
    case "not a person":
    case "sender missing":
      return null;
    case "no mobile number":
      return "Not texted: no mobile number on file";
    case "replied STOP":
      return "Not texted: they replied STOP";
    case "turned texts off":
      return "Not texted: they turned texts off";
    case "not opted in to texts":
      return "Not texted: they haven't agreed to texts";
    case "number can't get texts":
      return "Not texted: that number can't get texts";
    case "texting is off for this coach":
      return "Not texted: texting is off for your account";
    case "twilio not configured":
      return "Not texted: texting isn't set up yet";
    default:
      return "Not texted: $reason";
  }
}
