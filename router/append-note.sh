#!/usr/bin/env bash
#
# append-note.sh — append a text block to an EXISTING Apple Note, safely.
#
# The only sanctioned way to write to an existing Apple Note is the Apple
# Shortcuts "Append to Note" action: it preserves checklists, tables, and
# attachments. AppleScript `set body of note` is FORBIDDEN here — it re-renders
# the note's HTML and destroys that formatting. AppleScript stays read-only.
#
# This wrapper marshals {folder, title, text} into a JSON dictionary and hands
# it to a Shortcut (default name "Append to Apple Note", override with
# $APPEND_SHORTCUT) that finds the note by folder+title and runs the native
# Append to Note action. See shortcut.md for the one-time Shortcut build recipe.
#
# Usage:
#   append-note.sh <folder> <title> <text>
#   append-note.sh --folder "My Folder" --title "My Note" --text "…"
#   printf '%s' "$text" | append-note.sh --folder F --title T --text -   # text from stdin
#   append-note.sh --dry-run --folder F --title T --text "…"            # print JSON, don't run
#
# Exit codes: 0 ok · 2 usage · 1 shortcut/runtime error.

set -euo pipefail

SHORTCUT_NAME="${APPEND_SHORTCUT:-Append to Apple Note}"

folder="" ; title="" ; text="" ; dry_run=0
have_folder=0 ; have_title=0 ; have_text=0

die() { printf 'append-note: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d' >&2
  exit 2
}

# Flag form takes precedence; otherwise consume up to three positional args.
positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --folder) folder="$2"; have_folder=1; shift 2 ;;
    --title)  title="$2";  have_title=1;  shift 2 ;;
    --text)   text="$2";   have_text=1;   shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage ;;
    --) shift; while [ $# -gt 0 ]; do positional+=("$1"); shift; done ;;
    -*) die "unknown option: $1" 2 ;;
    *) positional+=("$1"); shift ;;
  esac
done

if [ "${have_folder}" -eq 0 ] && [ "${#positional[@]}" -ge 1 ]; then folder="${positional[0]}"; have_folder=1; fi
if [ "${have_title}" -eq 0 ]  && [ "${#positional[@]}" -ge 2 ]; then title="${positional[1]}";  have_title=1;  fi
if [ "${have_text}" -eq 0 ]   && [ "${#positional[@]}" -ge 3 ]; then text="${positional[2]}";   have_text=1;   fi

[ "${have_folder}" -eq 1 ] && [ -n "${folder}" ] || die "missing folder" 2
[ "${have_title}" -eq 1 ]  && [ -n "${title}" ]  || die "missing title" 2
[ "${have_text}" -eq 1 ] || die "missing text" 2

# `-` means read the text body from stdin.
if [ "${text}" = "-" ]; then text="$(cat)"; fi
[ -n "${text}" ] || die "empty text" 2

command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

# jq builds the JSON so folder/title/text are escaped correctly (quotes, newlines…).
payload="$(jq -n --arg folder "${folder}" --arg title "${title}" --arg text "${text}" \
  '{folder:$folder, title:$title, text:$text}')"

if [ "${dry_run}" -eq 1 ]; then
  printf '%s\n' "${payload}"
  exit 0
fi

command -v shortcuts >/dev/null 2>&1 || die "shortcuts CLI not found (macOS only)"

tmp_in="$(mktemp -t append-note-XXXXXX)"
tmp_out="$(mktemp -t append-note-out-XXXXXX)"
# shellcheck disable=SC2329  # invoked indirectly, by the EXIT trap below.
cleanup() { rm -f "${tmp_in}" "${tmp_out}"; }
trap cleanup EXIT
mv "${tmp_in}" "${tmp_in}.json"; tmp_in="${tmp_in}.json"
printf '%s' "${payload}" > "${tmp_in}"

if shortcuts run "${SHORTCUT_NAME}" -i "${tmp_in}" -o "${tmp_out}" 2>"${tmp_out}.err"; then
  # Surface any shortcut output for debugging, but success is the exit code.
  [ -s "${tmp_out}" ] && cat "${tmp_out}" >&2 || true
  exit 0
else
  rc=$?
  printf 'append-note: shortcut "%s" failed (rc=%d)\n' "${SHORTCUT_NAME}" "${rc}" >&2
  [ -s "${tmp_out}.err" ] && cat "${tmp_out}.err" >&2 || true
  rm -f "${tmp_out}.err"
  exit 1
fi
