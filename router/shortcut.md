# The "Append to Apple Note" Shortcut (one-time, manual)

`append-note.sh` is the safe, sanctioned way to write to an **existing** Apple
Note — it preserves checklists, tables, and attachments, which AppleScript's
`set body` destroys. It does this by handing a JSON dict `{folder, title, text}`
to a Shortcut that runs the native **Append to Note** action.

The Shortcut has to be created once in the Shortcuts app (the `shortcuts` CLI can
run/list/sign shortcuts but cannot create one with actions). It is generic — the
folder is an input, so it works for any Notes folder.

## Build it (≈2 minutes)

1. Open **Shortcuts** → **＋** new shortcut. Name it exactly **`Append to Apple Note`**.
   (Or any name, if you set `APPEND_SHORTCUT` in the environment to match.)
2. In the shortcut's settings (ⓘ / "Details"), it does **not** need to show in the
   Share Sheet. Leave **"Receive input"** as-is; we pass input on the command line.
3. Add these actions, in order. "Rename a variable" = a **Set Variable** action
   (the version-proof way; inline magic-variable rename also works if your
   Shortcuts build offers it):

   | # | Action | Configure |
   |---|--------|-----------|
   | 1 | **Get dictionary from Input** | source = the **Shortcut Input** (parses the JSON we pass in) |
   | 2 | **Set Variable** | `Dict` ← the **Dictionary** output of step 1 |
   | 3 | **Get Dictionary Value** | **Value** for key **`folder`** in **`Dict`** |
   | 4 | **Set Variable** | `Folder` ← the **Dictionary Value** output of step 3 |
   | 5 | **Get Dictionary Value** | **Value** for key **`title`** in **`Dict`** |
   | 6 | **Set Variable** | `Title` ← the **Dictionary Value** output of step 5 |
   | 7 | **Get Dictionary Value** | **Value** for key **`text`** in **`Dict`** |
   | 8 | **Set Variable** | `Body` ← the **Dictionary Value** output of step 7 |
   | 9 | **Find Notes** | Filter: **Folder** **is** `Folder` **and** **Name** **is** `Title`. Turn on **Limit** → **1** note. |
   | 10 | **Append to Note** | Append **`Body`** to **(the Find Notes result)**. |

   Notes on the actions:
   - **The key gotcha:** in steps 3/5/7 set the **Dictionary** field to the
     `Dict` variable each time. Once Set Variable actions are interleaved, "Get
     Dictionary Value" no longer auto-chains to the parsed dictionary — left to
     default it would read the *previous value* instead. Storing the dict in
     `Dict` (step 2) and pointing each lookup at it avoids that.
   - Action 1 "Get dictionary from Input" uses the **Shortcut Input** as its
     source. If your build shows it reading nothing, insert a **Get Text from
     Input** before it and feed that text into "Get dictionary from".
   - In action 9, "Find Notes" exposes **Folder** and **Name** as filter
     criteria; set both, and set the **Name** comparison to **is** (exact match),
     fed by the `Title` variable. Limit 1 guarantees a single note for Append.
   - Action 10 "Append to Note" takes a **Note** + **text**; point the Note at the
     Find Notes output (a single note because of the limit).

4. (Optional) As a last action add **Return / Stop and Output** the note's name,
   so the wrapper can log what it appended to. Not required.

## Prove it before trusting it

```sh
# Dry run — no Shortcut needed, just confirms the JSON marshalling:
router/append-note.sh --dry-run --folder "My Folder" --title "🧪 Scratch" --text "hello"

# Real run against a THROWAWAY note (create one in Notes first), then verify its
# existing content + formatting survived:
router/append-note.sh --folder "My Folder" --title "🧪 Scratch — Append Test (safe to delete)" \
  --text $'─────────────\n2026-06-28 · 🎙️ auto\ntest block\n↳ memo TEST1234'
```

Only after the scratch note proves content + checklists + tables + attachments
survive intact should anything touch a note you actually care about.

## Why a Shortcut at all (and why this is TCC-safe)

`voice-memos-ingest`'s own notes: direct Apple Notes Automation from an unbundled
CLI binary is unreliable (the permission prompt only surfaces in a foreground TTY
and the grant doesn't persist), so a backgrounded run hangs. Running the append
through `shortcuts run` sidesteps that — the Notes Automation grant attaches to
Apple's signed **Shortcuts** runtime, not to our script. (The very first run may
still prompt once to allow Shortcuts → Notes; allow it.)
