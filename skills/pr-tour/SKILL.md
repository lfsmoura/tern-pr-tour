---
name: pr-tour
description: Writes a step-by-step guided tour of a PR (or branch) the way a senior engineer reads it and opens it in Tern's Diff Tour block in a new tab, with four-option questions the reader must answer; also answers `[diff-tour ask]` questions and fills `[diff-tour gap]` misses sent from an open tour. Use when the user asks to tour, walk through or explain a PR/diff step by step in Tern.
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
- About one `question: true` step per chapter, with four `choices`, its answer in the next step
  ("Answer: …" title is fine). See **Questions** below.
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

### Questions

A question is how the tour finds out whether the reader understands this change well enough to
approve it. The viewer will not go past it until they pick an option (or "I don't know"), and a
wrong pick makes you rewrite the tour around their answer (§7). Its job is a diagnosis, not a score.

What to ask:

- One load-bearing idea of this change, one the reader must hold to approve it: what a concrete
  value becomes, in which order things happen, what breaks under a given input or failure, which
  promise is kept and where. Make them use it (trace a value, predict what the code does in a case
  the tour has not shown), never recite the sentence above.
- Answerable by reasoning from what the tour showed so far and the code on screen. Never trivia,
  never knowledge from outside this repo. It may come before the step that explains it (a
  prediction), but the reader must have a route to it.
- A question a junior answers confidently and wrongly. Never leak the answer earlier (titles,
  diagrams, chapter names). No "Question:" prefix; the viewer adds the badge.

The four options:

- Write the right claim first, then turn it into three wrong ones. Each one is what a reader with
  a specific wrong understanding of this change would answer: reads base behavior as still
  current, takes the call to be synchronous, thinks the cache is per request, misses the caller
  that still passes the old value. Put that understanding in the option's `model`; it is what the
  fill steps repair.
- Every option is a bare claim with the same skeleton, length and register: no reasons, hedges or
  bold, no "all/none of the above", nothing a reader can rule out on sight. A wrong option is only
  diagnostic when the wrong understanding is what picks it. If someone who never read the code can
  tell the right one, rewrite all four rather than patch one.
- Vary `answer` across questions; the viewer shuffles the order anyway.
- The answer step opens with the right claim, shows why with real code or a diagram, and says in a
  sentence why the most tempting wrong option fails.

## 5. Check, then open

```sh
bun <this skill's dir>/scripts/check-tour.ts FILE   # fix exactly what it reports; repeat until "ok"
tern open --tab FILE                                      # opens the Diff Tour block in a new tab
```

The block live-reloads the file (about 1 s) and keeps the reader's step: edit the file, never
reopen to refresh. Tell the user the keys: ←/→ step, `[`/`]` chapter, `t` contents, `o` open the
step's code, `f` follow (the editor beside tracks each step), `?` ask, `q` close; on a question,
`1`–`4` pick an option and `0` is "I don't know".

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

## 7. Fill `[diff-tour gap]` messages

A wrong pick or "I don't know" on a question types into this pane:
`[diff-tour gap] On question step <N> ("<title>") of tour <FILE> the reader picked "<option>"
(wrong model: <model>); the answer is "<option>". …` The viewer shows a **Regenerating**
placeholder after step N+1 until steps with `"fills": "<title>"` are in the file, and the reader
may be waiting on it: work from the tour and the code it touches, not a fresh review.

1. Diagnose. A wrong pick is a misconception and `model` names it; check it against the code the
   question touched: what in this repo makes it believable (a name, base behavior, a comment, a
   similar caller)? "I don't know" is a gap, not a misconception: find the earlier idea the
   question depended on (a step of the tour, a piece of base code) and start from there.
2. Insert steps right after step N+1, in the same chapter, each with `"fills": "<title>"`:
   - First, resolve the pick: what they picked, why it is a reasonable thing to believe, the exact
     place in this code where it stops being true (`diff` or `code` with `marks`), and what is
     true instead. Title it with the corrected claim.
   - Build from something the reader already holds (an earlier step, code they saw); one step, one
     idea; draw it (`timeline`/`mermaid`) when order or who-calls-whom is the confusion. Target the
     wrong understanding; don't repeat the answer step. One or two steps.
   - Then re-check: a new `question` step with `choices` (a title of its own, `fills` set) that
     applies the same idea to a different case in this change (another value, caller or failure),
     so remembering the answer step's words does not pass it, then its answer step (`fills` set).
     Same option craft; one wrong option is the original misconception in new clothes.
   - When the missed question was itself a re-check (it has `fills`), no new question: repair, then
     end with one sentence on what to look at in review (the line or test that would have shown it).
3. Keep every other step as it is; never grade the reader in prose ("you got it wrong"); `basis`
   rules hold. Run the checker and reply in one line. The viewer replaces the placeholder and, if
   the reader is waiting on it, shows the first new step.
