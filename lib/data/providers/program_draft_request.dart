import "package:flutter_riverpod/flutter_riverpod.dart";

/// The owner tapped "draft the new program" on a client's profile.
class ProgramDraftRequest extends Notifier<({String clientId, String kind})?> {
  @override
  ({String clientId, String kind})? build() => null;

  void ask(String clientId, String kind) => state = (clientId: clientId, kind: kind);

  void clear() {
    if (state != null) state = null;
  }
}

final programDraftRequestProvider =
    NotifierProvider<ProgramDraftRequest, ({String clientId, String kind})?>(ProgramDraftRequest.new);
