# Tour JSON format

The Tern `diff-tour` plugin (`plugin/` in tern-pr-tour) shows this file. It is the
[diff-tour](https://github.com/init-co-jp/diff-tour) v1 tour format plus `repo`,
`pr`, `agent`, `choices`, `fills` and `asked`, without diff-tour's `schema` block.

```ts
Tour = {
  version: 1,
  title: string,            // what the change does, in a few words
  repo: string,             // absolute path of the checkout git runs in
  base: string,             // merge-base commit SHA (full)
  head: string,             // PR head commit SHA (full)
  pr?: { number: number, title: string, url: string, base_ref: string, head_ref: string },
  agent?: number,           // $TERN_PANE of the agent that wrote it; `?` questions go there
  chapters: { title: string, steps: Step[] }[],
}

Step = {
  title: string,
  question?: true,          // shows only the question; the answer is the NEXT step
  choices?: Choices,        // required on question steps: the reader must pick before going on
  fills?: string,           // on steps that fill a missed question's gap: that question's title
  asks?: string[],          // 0–3 questions a junior would want to ask here (`?` offers them)
  asked?: string,           // set on steps that answer a reader's `?` question: the question
  blocks: Block[],
}

Choices = {
  options: { text: string, model?: string }[],  // exactly 4; `model` on each wrong one
  answer: number,           // the right option's 0-based index
}
```

A question step shows its options (shuffled per question) and blocks →, `]`, `G` and contents
jumps past it until the reader picks one (keys `1`–`4`) or `0` "I don't know"; the pick is final.
A right pick goes on to the answer step. A wrong pick or "I don't know" also sends
`[diff-tour gap]` to the agent and puts a **Regenerating** placeholder after the answer step,
until steps with `"fills": "<question title>"` exist in the file.

`text` is a bare claim, shown as is (inline markdown). `model` is never shown: it names the wrong
understanding of this change that picks the option, so a miss says what to repair. Question
titles are unique: picks and `fills` are keyed by them.

The viewer reads code, diffs, file stats and commits from git at `base`/`head`.
The JSON only points (file, lines, hunks); it never carries the repository's code.

## Blocks

Each block is an object whose key says its kind.

| Block | Meaning |
|---|---|
| `{ "p": string, "basis"?: "fact" \| "inferred" \| "opinion" }` | Paragraph. `basis`: fact = checked in this repo's code, tests or commit messages; inferred = follows from the code's structure, not run; opinion = general design view, not checked here. |
| `{ "quote": string }` | Quotation (commit message, review comment). `\n` separates paragraphs. |
| `{ "list": string[] }` | Bullet list. |
| `{ "pre": string }` | Preformatted text diagram, only for what `flow`/`timeline`/`mermaid` cannot draw. Lines ≤ 70 chars. |
| `{ "table": { "head": string[], "rows": string[][] } }` | Table. |
| `{ "code": { "file", "at"?: "base"\|"head", "lines": [from, to], "show"?: [from, to], "note"?: string, "marks"?: [{ "line": n, "text": string }] } }` | Real code from the repo, plain (no +/−). For code this PR did **not** change (callers, config, base-side code). `lines`: the lines that matter (shown in the card header, opened in the editor beside the tour). `show`: range displayed (default `lines` ± 2). `at` defaults to `head`. `note`: e.g. "unchanged". `marks`: one short note per line, drawn under the code; `line` must be inside `show`. |
| `{ "diff": { "file": string, "lines"?: [from, to], "hunks"?: number[] } }` | That file's diff `base...head`, with +/− lines. **The default way to show changed code.** `lines`: head-side line range; shows every hunk touching it (prefer this). `hunks`: 0-based `@@` hunk indexes instead. Omit both for the whole file's diff. |
| `{ "snippet": { "label": string, "text": string, "lang"?: string } }` | Code that is **not** in the repo (naive version, suggested fix). `label` must say so. Shown with an **Example** tag. |
| `{ "rows": { "tag"?: string, "label": string, "head": string[], "data": string[][], "added"?: string[] } }` | Example data. `tag` defaults to "Example" (made-up data). `added`: columns this change adds. |
| `{ "flow": { "nodes": [{ "label", "kind"?: "same"\|"changed"\|"new"\|"external", "note"?, "next"?, "start"?: true }] } }` | Processing flow, drawn as a Mermaid flowchart, top to bottom. `kind` colors the node (changed by this PR / new / DB or outside service / unchanged). `note`: second line in the node (file name). `next`: label on the arrow to the next node (value passed). `start`: the node starts a separate flow (another request, a timer, a job) instead of being called by the previous node. |
| `{ "timeline": { "lanes": string[], "events": [{ "lane", "to"?, "text", "mark"?: "ok"\|"bad"\|"note" }] } }` | Drawn as a Mermaid sequence diagram: lanes are participants, time flows down. Two requests at once, a crash midway, old and new code together, retries. ≤ 4 lanes. `to`: a message from `lane` to `to` (call, write; ✘ ones end in a cross). Without `to`: a note over `lane`. `mark`: ✔ / ✘ / ★. |
| `{ "mermaid": string }` | Any Mermaid diagram source (`sequenceDiagram`, `flowchart TD`, `stateDiagram-v2`, `erDiagram`, …), rendered natively. Use it for sequence diagrams that need more than `timeline`: `alt`/`opt`/`loop`/`par` blocks, activations, return messages (`-->>`), more than 4 participants. |
| `{ "files": { "roles"?: [{ "file", "role": "core"\|"mechanical"\|"test"\|"config"\|"docs", "note"? }] } }` | Map of every changed file with +/− counts (from git). `roles` says how to read each: core = read with your head, mechanical = follow-on edits. Only changed files. |
| `{ "target": true }` | Summary of the change: PR, base/head, size, commits (from git). Put it in the first step. |

Inline `` `code` `` and `**bold**` work in strings.

## Rules

- `file` is relative to the repo root (`src/app.ts`), never prefixed with `base/` or `head/`.
- `lines`, `show` and `marks[].line` are real line numbers of the file **at that revision**
  (`git show <rev>:<file>`). Read the file; never guess. The checker rejects ranges outside the file.
- `lines` of a `diff` are head-side line numbers; the checker rejects a range no hunk touches.
- `hunks` index real hunks of `git diff base...head -- file`.
- One step fits one screen: about 40 lines, at most ~3 code/diff blocks.
- Changed code is shown as `diff`, not `code`: the reader should see what was removed and added.
  Use `code` for unchanged context, base-side code, or when a diff hunk would be too long and
  only a few head lines matter (then say "changed" in `note`).
- Draw with the viewer: `timeline` or `mermaid` `sequenceDiagram` for who calls whom and in what
  order, and for anything about time; `flow` for processing order; `files` for the whole change.
  `pre` only for what those cannot draw. Mermaid labels: keep them short, avoid `"`, `;`, `#`.
- Say things about a specific line as a `mark` on that line (one short note per line); the
  paragraph says what follows from it.
- `asks`: short questions a junior would ask on this step. Drop any that the step or the next two
  steps already answer, that this repo's code cannot answer, or that fit any change ("where next?").
  Never on a `question` step or the step before it (they would leak the answer).
- Every `question` step has `choices`, and the step after it is its answer, never another question.
- `fills` steps go right after the missed question's answer step, in its chapter. A re-check
  question among them also carries `fills` (and has a title of its own), as does its answer.
- The first chapter's first step holds `{ "target": true }`; the map chapter uses `files` (roles)
  and a `flow`.
