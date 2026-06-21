# Auto-format dictated lists — design

**Date:** 2026-06-21
**Status:** Approved (pending spec review)
**Scope:** one file — `Sources/PostProcessingService.swift`

## Problem

When the user dictates a list of instructions or items, the output comes back as
prose, never as a bullet or numbered list. This is deliberate in the current
default post-processing prompt:

- `defaultSystemPrompt` line 38: `- No markdown.`
- line 41: `- Do not turn prose into bullets or numbered lists unless the speaker explicitly requested list formatting.`
- line 87: `- If the speaker only says "first", "second", "third" as ordinary prose instructions, keep prose sentences rather than a list.`

Today a list is produced only when the speaker explicitly says "bullet list" /
"numbered list" (line 86). The user wants enumerated dictation to format as a
list automatically, without a trigger phrase.

## Approach — prompt, not code

The list-vs-prose decision lives in the LLM cleanup pass
(`PostProcessingService.defaultSystemPrompt`), the only place with enough
understanding of the utterance to tell a list from narrative prose. Rejected
alternatives:

- **Code-side heuristic** (regex on commas / ordinals): misfires on natural
  speech ("first I was nervous, then I relaxed").
- **Second LLM pass**: doubles latency and token cost for no benefit.

So this is a single-file prompt edit. It applies to the normal dictation cleanup
path only — **not** Command Mode's select-text transform
(`commandModeSystemPrompt`), which is out of scope.

## Behavior

- **Trigger:** auto-format when the dictation is essentially a single enumeration
  of discrete, parallel items or steps — **3+ items**, OR **2+ items introduced
  with explicit ordinals / step words** ("first", "second", "step one", "next").
- **Ordered → numbered (`1. `)** when items are sequential, spoken with ordinals,
  or are ordered steps where sequence matters.
  **Unordered → bullets (`- `)** for a set where order does not matter (shopping
  list, options).
- **Preserve a spoken lead-in:** if the dictation opens with an intro word,
  phrase, or sentence before the items ("here's what I need", "the steps are",
  "I need"), keep it as a lead-in line ending with a colon, then the list
  beneath it. Never drop spoken text that came before the items.
- Each item is still cleaned normally: filler removal, self-corrections,
  capitalize the first word, no trailing period unless the item is a full
  sentence.
- **Format:** plain-text markers only (`- ` and `1. `). No bold, headers, or other
  markdown — these markers paste cleanly into any field.

## Guardrails (the whole risk of auto-detect is unwanted lists)

- **Narrative stays prose**, even with "first/then" sequencing:
  `"first I was nervous, then I calmed down"` → `"First I was nervous, then I calmed down."`
- A single sentence or two back-to-back clauses stays prose.
- **A spoken lead-in is kept, not dropped:** an intro phrase before the items
  becomes a lead-in line ending in a colon, followed by the list (e.g.
  "here's what I need: …"). Earlier drafts either dropped the lead-in or forced
  the whole utterance to prose; both were wrong. Still do not half-convert a
  genuine narrative paragraph that merely mentions items in passing.
- **Flat lists only (v1):** no nested / multi-level items.
- The word "bullet" / "list" inside a sentence is not a formatting request
  (preserve existing rule + Spanish example).
- **Explicit requests still win:** "bullet list" / "numbered list" /
  "lista numerada" force a list of that type, overriding the heuristics.

### Accepted limitation

A bulleted/numbered list inserts newline characters. In a focused field where
Enter = submit (terminal prompt, send-on-Enter chat, search box), those newlines
could submit early. The app pastes text and cannot reliably detect the target
field type. Accepted for v1 (a list is rarely dictated into a single-line field).
A future guard could suppress lists when the focused field looks single-line.

## Concrete edits to `defaultSystemPrompt`

1. **Line 38** `- No markdown.` →
   `- No markdown formatting, except plain list markers ("- " for bullets, "1. " for numbered items) when the dictation is a list.`
2. **Line 41** (hard-contract no-list rule) →
   `- Format as bullets or a numbered list only when the dictation is clearly a list (see Formatting); otherwise keep prose.`
3. **Formatting section (lines 86–88)** — replace the explicit-only list rules
   with the auto-detect rules above: trigger threshold, lead-in preservation,
   ordered→numbered / unordered→bullets, per-item cleanup, the guardrail bullets
   (narrative→prose, single-sentence/non-enumeration→prose, flat-only,
   "bullet"-in-sentence is not a request, explicit requests still win), each with
   a short positive **and** negative example. Keep the existing Spanish
   "agrega un bullet" negative example.
4. **`defaultSystemPromptDate`** `"2026-05-13"` → `"2026-06-21"`.

## Migration

- The default prompt is read live from code, so users on the default
  (`customSystemPrompt` empty) get the new behavior on next launch — no migration
  step. (The operator is on the default → gets it automatically on rebuild.)
- Users with a **custom** prompt are untouched. Bumping `defaultSystemPromptDate`
  past their `customSystemPromptLastModified` surfaces the existing
  "default was updated" banner (`SettingsView.swift` ~line 1465) so they know
  they can re-pull the new default.

## Testing / verification

Prompt behavior is non-deterministic (LLM), so there is no unit test. The control
surface is the in-prompt examples. Verify with a live dictation checklist after
building:

1. 3-item set with lead-in ("I need eggs, milk, and bread") → **bullets**, with
   the "I need" lead-in preserved as an intro line.
2. Ordinal procedure ("first open the file, second run the tests, third commit")
   → **numbered**.
3. Narrative ("first I was nervous, then I calmed down") → **stays prose**.
4. Plain single sentence → **stays prose**.
5. Lead-in + items ("here's what I need: eggs, milk, bread") → **lead-in line +
   bullets** (lead-in preserved, not dropped).
6. Explicit "bullet list: …" → **still produces a bullet list** (no regression).

Build gate: `make all` (clean + codesign) and `make test` (18/18) must still pass
(the prompt change shouldn't affect tests, but the build must stay green).
