---
name: pr-tour
description: Writes a step-by-step guided tour of a PR (or branch) the way a senior engineer reads it and opens it in Tern's Diff Tour block beside the agent; also answers `[diff-tour ask]` questions sent from an open tour. Use when the user asks to tour, walk through or explain a PR/diff step by step in Tern.
---

# PR tour

A tour is a JSON file of chapters and steps (`references/format.md`). The Tern plugin
`diff-tour` ([tern-pr-tour](https://github.com/lfsmoura/tern-pr-tour)) shows it one step at a time beside
you, opens each step's code in the editor next to it, and reads every line of code from git, so
the tour only points at files, lines and hunks. Based on
[diff-tour](https://github.com/init-co-jp/diff-tour): the tour shows what a senior looks at,
asks and decides while reading the change, for a reader new to this code.

Read `references/review-lens.md` before researching and `references/format.md` before writing.

## 1. Preconditions

```sh
echo "$TERN_PANE"                      # set inside Tern (read it in bash); the tour's "agent", e.g. 5244155068915
tern plugin list | grep '^diff-tour '  # else: tern plugin install github.com/lfsmoura/tern-pr-tour/plugin
```

Outside Tern, still write and check the tour, then tell the user to `tern open FILE`.

## 2. Pin the change to two commits

```sh
REPO=$(git rev-parse --show-toplevel)
# A PR (number, URL, or the current branch's PR):
gh pr view <N> --json number,title,url,body,state,baseRefName,headRefName,baseRefOid,headRefOid,commits
git fetch origin <baseRefName> "pull/<N>/head"         # makes both ends available locally
HEAD_SHA=<headRefOid>
BASE_SHA=$(git merge-base <baseRefOid> "$HEAD_SHA")
# Already landed (merged or closed with its commits in base): the merge-base is HEAD_SHA itself,
# which would make an empty tour. Use the parent of the PR's first commit instead:
#   BASE_SHA=$(git rev-parse "<commits[0].oid>^")
# A branch without a PR: HEAD_SHA=$(git rev-parse HEAD), BASE_SHA=$(git merge-base origin/<default> HEAD)
```

Always use full SHAs for `base`/`head`. Uncommitted work is not in a tour; say so if the user
expects it. Read code at a revision with `git show <sha>:<path>` (the working tree only when
`git rev-parse HEAD` equals `HEAD_SHA`).

## 3. Research first (do not write the tour yet)

1. `git log --reverse --format='%h %s%n%n%b' BASE..HEAD`, `git diff --stat BASE...HEAD`,
   then the diff. Say in 1–2 sentences what the change is for and who stops hurting: the
   hypothesis the tour will test.
2. Read the **base** code and list the promises it keeps: what states and values mean,
   invariants, how failures are handled and why, behavior existing tests pin, written
   conventions, behavior set by config or initialization, and whether code steps or
   types/constraints keep each promise. Read related unchanged files too: callers, jobs,
   config, initialization, tests, docs, data definitions.
3. Hold the diff and head code against those promises one by one.
4. Apply all eight question areas of the lens. For each: "signal (which)", "no signal", or
   "applies but fine here (where you checked)". Trace concrete values where a signal shows.
5. Label every finding Must / Suggestion / Nit / Question / Good with the judgment rules. Keep
   checking other areas after the first big finding. Trace any fix you propose.
6. Pick the 2–4 findings that deserve steps and why; note what looks risky but is fine (with the
   place you checked), what is done well, and the design not chosen.
7. Attach file:line at base or head to each point; separate checked facts from inference.

## 4. Write the tour

File: `${XDG_CACHE_HOME:-$HOME/.cache}/diff-tour/<repo-name>/pr-<N>-<head7>.tour.json` (a branch
tour: `<branch>-<head7>`). Header: `version: 1`, `title`, `repo: $REPO`, `base`, `head`, `pr`
(when there is one), `agent: $TERN_PANE` (a number).

Chapters, 12–18 steps in all (fewer for a small or mechanical change):

1. **The change**: `{ "target": true }` and the commit messages.
2. **What it is for**: who stops hurting, user-visible behavior, little code; state the hypothesis.
3. **Map**: `files` with roles and a `flow` that includes unchanged parts; declare where the
   reader's time goes and what is quick.
4. **How it works**: the mechanism and why it is designed this way, including what is done well.
   Open with a sequence diagram of the changed path (who calls whom, in order, what is passed
   back), then walk it with `diff` blocks of the changed hunks.
5. **Where a senior stops**: findings with their weight; what looks risky but is fine, and where
   that was checked.
6. **Wrap-up**: first, did the codebase get better overall; then 2–4 review comments labeled
   Must / Suggestion / Nit / Question / Good; then a bullet list of what the reader re-lived.

Writing rules:

- Show how a senior reads, asks and judges, not a changelog. Don't just justify the code: point
  out where a senior would stop; if nothing is wrong, show where you looked and what you found.
  Never invent problems.
- Every assertive paragraph gets a `basis`; split paragraphs that mix bases. No `basis` on
  questions. Outside-library behavior is never `fact`.
- "Fine / no need to worry" needs the place in this repo that shows it; otherwise ask it.
- About one `question: true` step per chapter, its answer in the next step ("Answer: …" title is
  fine). Pick questions a junior answers confidently and wrongly. Never leak an answer earlier
  (titles, diagrams, chapter names). No "Question:" prefix; the viewer adds the badge.
- End each chapter with a one-sentence `p` on what that part guarantees; it is an assertion, so
  it gets a `basis` too.
- Name a principle only after showing it in this code; a few names per tour. Never paste lens text.
- Show changed code as `diff` (pick hunks with `lines`), not `code`; `code` is for unchanged
  context and base-side code. Most steps in chapters 4–5 should carry a diff.
- Draw, don't narrate: a Mermaid sequence diagram (`timeline`, or `mermaid` with
  `sequenceDiagram` for `alt`/`loop`/`par`, returns, >4 participants) wherever calls cross
  functions, modules, services, queues or the DB, or where order and timing matter (retries,
  races, partial failure). Expect 2–4 per tour. `flow` for processing order; line remarks are `marks`.
- Write in the language the user writes in.

## 5. Check, then open

```sh
bun <this skill's dir>/scripts/check-tour.ts FILE   # fix exactly what it reports; repeat until "ok"
tern open --split right FILE                              # opens the Diff Tour block beside you
```

The block live-reloads the file (about 1 s) and keeps the reader's step: edit the file, never
reopen to refresh. Tell the user the keys: ←/→ step, `[`/`]` chapter, `t` contents, `o` open the
step's code, `f` follow (the editor beside tracks each step), `?` ask, `q` close.

## 6. Answer `[diff-tour ask]` messages

`?` in the tour types into this pane:
`[diff-tour ask] <question> — tour <FILE>, step <N> ("<title>"). …`, where N counts steps
across all chapters from 1.

1. Read the tour, that step and the code the question touches; open what lies outside the diff
   (callers, config, tests) when it decides the answer.
2. Insert 1–2 steps right after step N in the same chapter. The first one: `"asked": "<question>"`,
   a short answer as its title, and the conclusion in 1–2 sentences in its first paragraph.
   Show real code with `diff` (changed) or `code` (unchanged) and `marks`; draw with
   `timeline`/`mermaid`/`flow`; label `basis`.
   If the question's premise is wrong, correct it gently; if the tour was wrong, say so. Say
   what would settle anything the repo cannot. Optionally close with one question to think about.
3. Edit the file in place (keep everything else), run the checker, and reply in one line. The
   viewer jumps to the answer by itself.
