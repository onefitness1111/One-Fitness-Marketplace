#!/bin/bash
# Pull a branch and open it in Xcode.
#
# You do not need to know git. From the ONE Fitness project folder, run:
#
#   bash scripts/test_branch.sh the-branch-name
#
# Example:
#
#   bash scripts/test_branch.sh cursor/phase0-security-4fc9
#
# The script stops if you have work that has not been saved in git, so it
# cannot throw those changes away. It will not delete anything.

set -u

say() { printf '%s\n' "$1"; }
fail() { printf '\n%s\n' "$1" >&2; exit 1; }

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  fail "Please give the branch name. Example: bash scripts/test_branch.sh cursor/phase0-security-4fc9"
fi

BRANCH="$1"

# Find the project even if this script was started from somewhere else.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPO_DIR" || fail "Couldn't open the project folder."

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "This folder is not the ONE Fitness project. Open the project folder in Terminal first, then run the script again."
fi

if [ -n "$(git status --porcelain)" ]; then
  fail "You have changes that aren't saved yet, so this script stopped on purpose.

Nothing was switched and nothing was deleted.

If you were testing and don't need those changes, ask for help putting them aside before you try another branch. If you meant to keep them, save them first (a commit), then run this script again."
fi

for tool in git flutter pod open; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    case "$tool" in
      flutter) fail "Flutter isn't installed, or Terminal can't find it. Install Flutter, then run this script again." ;;
      pod) fail "CocoaPods isn't installed. On your Mac, run: sudo gem install cocoapods   then run this script again." ;;
      open) fail "This script opens Xcode, so it needs to run on your Mac." ;;
      *) fail "The '$tool' command isn't available." ;;
    esac
  fi
done

say "Fetching the latest branches…"
git fetch origin || fail "Couldn't reach GitHub. Check your internet connection and try again."

if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  say "Switching to $BRANCH…"
  git checkout -B "$BRANCH" "origin/$BRANCH" || fail "Couldn't switch to $BRANCH."
elif git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  say "Switching to $BRANCH…"
  git checkout "$BRANCH" || fail "Couldn't switch to $BRANCH."
else
  fail "There is no branch named '$BRANCH'. Check the spelling and try again."
fi

say "Cleaning the app (this can take a minute)…"
flutter clean || fail "flutter clean failed. Copy the message above and send it back."

say "Downloading Dart packages…"
flutter pub get || fail "flutter pub get failed. Copy the message above and send it back."

say "Installing iOS packages…"
(cd ios && pod install) || fail "pod install failed. Copy the message above and send it back."

WORKSPACE="$REPO_DIR/ios/Runner.xcworkspace"
if [ ! -d "$WORKSPACE" ]; then
  fail "Couldn't find ios/Runner.xcworkspace. pod install should have created it."
fi

say "Opening Xcode…"
open "$WORKSPACE" || fail "Couldn't open Xcode. You can open this file yourself: ios/Runner.xcworkspace"

say ""
say "Xcode is open on branch $BRANCH."
say "Press the Play button in Xcode to run it on your phone."
say "Use a client, a coach, and the owner account when the notes for this branch ask you to."
