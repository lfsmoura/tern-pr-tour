# tern-pr-tour

Guided, step-by-step PR tours inside Tern, after
[diff-tour](https://github.com/init-co-jp/diff-tour): what the change is for,
where to spend time, what a senior would ask and how they would judge it.

- `plugin/` — the `diff-tour` Tern plugin: a block that shows a tour one step at
  a time and opens each step's code in the editor beside it.
- `skills/pr-tour/` — an agent skill (omp, Claude Code, …) that writes the tour
  as JSON, checks it and opens it in the block; it also answers questions asked
  from an open tour.

## Install

```sh
# plugin
tern plugin install github.com/lfsmoura/tern-pr-tour/plugin
# or, from a clone, so edits apply live:
tern plugin link ./plugin

# skill: link it into your agent's skills directory, e.g.
ln -s "$PWD/skills/pr-tour" ~/.config/skills/pr-tour     # omp
ln -s "$PWD/skills/pr-tour" ~/.claude/skills/pr-tour     # Claude Code
```

The checker needs [Bun](https://bun.sh); tours of PRs need `gh`.

## Use

Ask your agent (running in Tern) for a tour of a PR; the `pr-tour` skill writes
`~/.cache/diff-tour/<repo>/pr-<N>-<sha>.tour.json`, checks it and runs
`tern open --split right FILE`. Any `*.tour.json` opens as a tour block.
**Diff Tour: open a recent tour** in the palette reopens one.

| Key | Does |
| --- | --- |
| `→` `l` `space` / `←` `h` | next / previous step |
| `]` / `[` | next chapter / start of chapter |
| `g` / `G` | first / last step |
| `t` | contents (↑↓, ⏎ to jump) |
| `o` `⏎` | open the step's code in the editor beside, focused |
| `f` | follow: the editor beside tracks every step (on by default) |
| `?` | ask the agent about this step |
| `r` | reload the file and git |
| `q` | close |

## How it works

`plugin/host.luau` defines the `tour` block. It polls the tour file every
second, so an agent's edits land in place and the reader keeps their step. Code,
diffs (`base...head`), changed-file stats and commits come from `git` in the
tour's `repo`; the JSON only points at files, lines and hunks, and a range that
does not exist shows as a warning in the step. Each tour's step is stored in
`kv.json`, so opening it again resumes there.

Opening code goes through `tern-difftour://show`, which the window half
(`plugin/window.luau`) turns into a preview block at the line. When the checkout
is at the tour's head the real file opens; otherwise (base-side code, a PR not
checked out) a snapshot from `git show` under the plugin's data dir does.

`?` goes through `tern-difftour://ask`: the window half offers the step's
suggested questions (or a prompt for your own) and types one line,
`[diff-tour ask] …`, into the agent pane named by the tour's `agent` (its
`$TERN_PANE`), or an agent block in the tour's repo. The agent inserts answer
steps after that step; the block sees the file grow and jumps to the answer.

The format is in `skills/pr-tour/references/format.md`; diff-tour's `schema`
block (migrations run in SQLite) is not supported.

## Develop

```sh
tern plugin types ./plugin                                   # writes plugin/tern.d.luau for luau-lsp
bun skills/pr-tour/scripts/check-tour.ts FILE.tour.json      # validate a tour
```

## License

MIT. `skills/pr-tour/references/review-lens.md` is condensed from diff-tour's
`internal/generate/lessons` (MIT, © init-co-jp).
