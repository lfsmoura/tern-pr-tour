# The senior's lens

Condensed from diff-tour's `internal/generate/lessons` (MIT, init-co-jp/diff-tour), which
collects what experienced engineers wrote about reading and reviewing changes. A tour shows
three layers: **how a senior reads**, **what they ask**, **how they judge**. Judgment matters
most: knowing when a lesson does *not* apply ("fine here, because …") is senior too.

Use it as scaffolding, not text to paste: show the problem (or the good design) in this code,
then name the principle last. Numbers and incident stories from here are `opinion`.

## Reading (R)

| | Lesson |
|---|---|
| R1 | Read from intent: before line one, say what the change is for and who stops hurting. Test that hypothesis; keep looking after the first big finding. |
| R2 | Start at the core file, not in display (alphabetical) order. Files shown later get fewer comments. |
| R3 | Jump in execution order: caller → changed function → what it calls (DB, outside). |
| R4 | Leave the diff: callers, config, initialization, existing tests, docs decide whether a line is right. Say why you jump. |
| R5 | Chunk familiar patterns; stop where the code deviates from its pattern (order, default, name vs content). AI code looks typical, so check it. |
| R6 | Trace concrete values: empty, 0, boundary, duplicate, out of order, null, twice at once. |
| R7 | Ask who notices, with what, and how fast, when it breaks in production. |
| R8 | Imagine the next change; count where it would have to touch. |
| R9 | Spend time in proportion to risk: irreversible, money, permissions, data, concurrency. Sort core from mechanical edits, and check the mechanical ones really are uniform. |

## Questions: eight areas

Open every area; dig where a signal shows. For each, note "signal (item)", "no signal" or
"applies but is fine here (where you checked)".

1. **Promises kept?** Does the change keep what the old code promised (states, meanings,
   conditions, test expectations)? Someone relies on unpromised behavior too (ordering, error
   text, null vs empty, defaults). What did deleted code protect (conditions, retries, null
   checks, locks, tests)? Could a type or constraint enforce what code steps enforce now?
   Check-then-write gaps (`if !exists { insert }`, SELECT → UPDATE without a lock). Declared ≠
   effective (FKs, transactions, timeouts, cache config). Working by luck vs by guarantee (map
   order, sleeps). Real data is messy: time zones, money as float, text length.
2. **What if it fails?** Which state is the system in after the error (empty catch, log-only,
   error → default)? What does that catch really catch? Rare failure paths are untested. Outside
   calls need timeouts. Retries add load (fixed interval, no cap, no jitter, nested retries).
   Safe when delivered twice (charges, sends, stock, queue consumers)? Half success (DB +
   outside send). Twice at once / crash midway / old and new running together. Fallbacks first
   run in production. Blast radius of a dependency outage. Fail closed on validation/auth.
3. **After it ships?** Can it roll out gradually, how will you notice, how do you roll back?
   Config changes are as risky as code. Reversible vs irreversible (DROP, bulk UPDATE, outside
   sends, public API). Can old code read the new data? Expand → migrate → contract. Don't
   reuse a removed name or enum value with a new meaning. Schema changes on big tables lock.
   Can you investigate later (logs with context, metrics on new branches)? Unwatched alerts are
   not alerts. Who deletes the flag, and when? Docs/runbooks for new env vars or commands.
4. **Trust boundary.** Where does the value come from, who can change it? Another user's ID →
   another user's data? Request body straight into a model (`update(req.body)`, spreads)? User
   input becoming SQL/command syntax? Server fetching user URLs? Secrets in logs or responses?
   Regexes on user input? New dependencies run with your privileges (`^`, `latest`)? Who can
   reach it (bind address, CORS, routes outside auth)?
5. **At scale.** No speedups before measuring. Find what grows with data (queries in loops, no
   LIMIT, everything into an array). Fan-out turns rare slowness into common slowness. What
   happens when the cache is empty? Think in resources used, not request counts.
6. **Easier for the next person?** More or less to keep in your head? Deep module or a thin
   wrapper? Is a likely-to-change decision hidden in one place? Shared because it is the same
   knowledge, or only the same shape (bool/mode params)? Building what nobody needs yet? Can the
   feature be removed cleanly? Refactor mixed with behavior change? Names and comments say what
   code cannot? Consistent with surrounding code? Copying a broken window? A rewrite that drops
   cases the old code handled?
7. **What do the tests prove?** Break the key line: which test fails? Do tests survive a
   behavior-preserving rewrite (or only check mock calls)? Expected values computed like the
   code? Do mocks behave like the real thing? Were tests changed to pass (expectations, skips)?
8. **AI-written code.** Typical shape ≠ correct content. Nonexistent APIs/packages. Security
   holes in working code. Rewriting an existing helper. Unrequested extras and missing
   validation. All failures treated the same. Scope creep. Don't trust comments/commit claims.

## Judgment (J)

- **Better, not perfect.** Approve what improves overall code health; stop what worsens it, even
  if small. The wrap-up says first whether the codebase got better.
- **Severity labels:** **Must** (money, data, permissions, irreversible, a user can trigger it;
  shown with a concrete breaking input using only facts in this repo) · **Suggestion** (won't
  break, makes the next change or ops harder) · **Nit** (taste, not a written convention) ·
  **Question** (depends on an outside spec or production data the repo cannot settle — never
  Must; say who should check what before merge) · **Good** (what is done well and why).
- List every finding with its label; spend steps on the few that matter most, list the rest briefly.
- Facts and the repo's conventions beat taste; taste is `opinion`, never a defect.
- Defense should match the risk; too much retry/fallback is a finding too.
- "Fine / no need to worry" needs evidence from this repo (a limit check, constraint, config,
  all callers, a test). Without it, ask a question instead.
- Before proposing a fix, trace it with concrete values, including combined failures and
  mixed old/new state. Say so if a case remains.
- Separate what this code decides (catches, conversions, defaults) from what depends on an
  outside service; the code part is checkable, so check it and call it fact.
- Compare with the design not chosen (constraint vs code, other data shape, other owner).
- Don't raise concurrency or scale worries without checking the work really runs in parallel.

## Teaching (P)

- P1 End each chapter with one sentence saying what that part guarantees or promises.
- P2 Make the reader predict: a question step a junior would answer confidently and wrongly
  (called twice, edge value, failure midway, next change), answer in the next step.
- P3 Say why you jump outside the diff ("this line is only right if …").
- P4 Show time allocation: "of these 300 lines, these 20 need your head".
- P5 Match the gap: missing term → explain; missing info → open the file; too much to hold →
  draw (`timeline` for time, `flow` for processing).
- P6 Check names against what the code does; AI names things plausibly.
- P7 Name a principle only after showing it in this code; a few names per tour.
- P8 Never leak an answer before its question step (titles, diagrams, chapter names included).
