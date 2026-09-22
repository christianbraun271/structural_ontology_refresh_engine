# Structural Ontology Refresh Engine

**Remark: This is an anonymized excerpt, which is based on a real-world prototype
that served as foundation for a production-grade project. The production-grade project
is under NDA and cannot be shared.**

A working prototype for keeping a knowledge-graph ontology in sync with an
evolving relational schema in Snowflake — with a human approval gate between
detection and any change to the ontology, and a second human gate (a
developer) between generated code and anything actually running.

"Structural" refresh means the engine evolves *what the ontology can
represent* — new node types, edge types, and attributes — as distinct from a
data-level refresh that keeps existing types populated with fresh rows.

**Tech Stack: Source and Ontology Layer in Snowflake, Snowflake Cortex as LLM host, 
llama3.1-70b as model, SQL and AI_COMPLETE for the processing logic, streamlit as UI**

## The idea

Source systems change: a column gets added, a new table shows up, a
relationship that used to be implicit becomes an explicit foreign key. Today
that kind of change either breaks a downstream ontology silently or requires
a person to notice it, understand it, and hand-write the DDL. This project
automates the noticing and the first draft, and puts a business reviewer in
the loop before anything is generated for a developer to apply.

```
 1. Detect              2. Classify            3. Review              4. Generate
 ---------              -----------            ---------              -----------
 INFORMATION_SCHEMA     Rule engine first,     Streamlit app --       Template draft,
 snapshot + diff        then an AI pass        BA approves /          then an AI-
 (FULL OUTER JOIN)      scores confidence      rejects / defers       refine pass
```

Everything through step 4 is automated except the one box that says
"Review" — that's a deliberate human gate, not a missing feature. A second
human gate (a developer reviewing generated SQL before it runs) is also
deliberate; this project drafts code, it never executes it.

See [`docs/structural_ontology_refresh_overview.pptx`](docs/structural_ontology_refresh_overview.pptx)
for a one-slide summary and five slides going one level deeper into
detection, classification, the review app, and code generation.

## Highlights

- **A real pipeline, run against a live account, not a proof of concept.**
  Every script here has executed on real Snowflake with real-world source data structures and is verified.
- **AI safety enforced structurally, not just by prompting.** An earlier
  version of the AI refine pass sent the model whole SQL artifacts and
  asked it to touch only cosmetics, but still led to hallunicinations and broke the generated code.
  The fix wasn't a better-worded
  prompt, it was removing the opportunity: certain artifact types are
  never sent to the model at all, and everywhere else its response schema
  is narrowed to exactly one field it's allowed to touch. See
  [`sql/05_codegen/02_ai_refine_artifacts.sql`](sql/05_codegen/02_ai_refine_artifacts.sql)'s
  header for the full before/after.
- **Idempotent by design.** A `SHA2` content hash on every candidate
  proposal's fingerprint means re-running detection never creates
  duplicate review-queue rows, even across repeated cycles over the same
  schema drift.
- **Two separate human gates, not one.** A business approval gate
  (Streamlit review, approve, reject, defer) and a second, later technical
  gate (a developer reviewing generated SQL before it ever runs). Approving
  a change and trusting its generated code are treated as two different
  decisions.
- **Config-driven for privilege-constrained environments.** No
  `CREATE DATABASE` is assumed; every script reads its database/schema
  names from `SET` variables at the top, with a documented fallback
  (`ORE_SOURCE_SCOPE`, a naming-prefix convention) for deployments that get
  one shared schema rather than a private sandbox.
- **A working control-plane app, not just backend scripts.**
  Streamlit-in-Snowflake with two tabs (review, generate), backed entirely
  by stored procedures the app calls rather than writing to state tables
  directly, so every change is auditable through one code path.

## How it works

- **Detect** — every cycle snapshots `INFORMATION_SCHEMA.COLUMNS` for the
  source schema and diffs it against the last snapshot with a
  `FULL OUTER JOIN`, so new/dropped columns and new tables show up as rows,
  not as something a person has to notice by eye.
- **Classify** — a deterministic rule engine handles the unambiguous cases
  (a new scalar column is an attribute; a new FK column is an edge; a new
  table whose primary key is entirely foreign keys is a junction/edge type).
  Declared foreign keys make this precise; where they're missing, the engine
  falls back to naming convention, column comments, and general domain
  knowledge. A Snowflake Cortex `AI_COMPLETE` pass then reviews every
  candidate, agrees or disagrees with the rule, and attaches a confidence
  score — genuinely ambiguous cases (e.g. a new table that could be a
  richer join or could be its own entity) are flagged rather than guessed.
- **Review** — a Streamlit-in-Snowflake app is the control plane. One tab
  shows each candidate with its rule classification and AI recommendation
  side by side, lets a reviewer overwrite the proposed name or kind, and
  records Approve / Reject / Defer through a single stored procedure. A
  second tab batch-generates code for everything approved.
- **Generate** — code is drafted mechanically from the approved proposal
  (template DDL/DML), then passed through a narrowly-scoped AI refine pass
  that can only touch names and comments, never structure. Every generated
  statement is staged for a developer to review; nothing here runs against
  the ontology tables automatically.

## Repository structure

```
sql/
  00_setup/            Database, schema, and warehouse configuration
  01_source/            Synthetic source tables (v1) + a v2 delta that exercises
                         all four classification cases
  02_ontology/           Node/edge type dictionary, instance tables, and the
                         initial load from v1
  03_refresh_engine/     Detection, rule-based classification, AI review,
                         and proposal persistence
  04_control_plane/      The RECORD_DECISION procedure the app calls
  05_codegen/            Template-based code generation + the AI refine pass
  07_reset/              Resets the demo back to a v1 baseline
streamlit_app/
  streamlit_app.py       The control-plane UI (Review / Generate tabs)
  queries.py             Every Snowpark/SQL call the app makes, in one place
docs/
  RUNBOOK.md             Step-by-step checklist for running the full cycle
  structural_ontology_refresh_overview.pptx   Six-slide overview deck
```

## Running it

Full step-by-step instructions are in [`docs/RUNBOOK.md`](docs/RUNBOOK.md).
Short version: every script sets its own `DEMO_DB` / schema variables at the
top and is runnable standalone in a fresh worksheet — edit those few lines
in each script (or find-and-replace `ORE_DEMO_DB` / `ORE_SRC` / `ORE_ONTOLOGY`
/ `ORE_CONTROL`) to point at your own Snowflake database and schemas, then
follow the runbook's checklist in order.

### What you need

- A Snowflake account with **Cortex `AI_COMPLETE`** available, and any
  existing warehouse (nothing here creates its own warehouse).
- No `CREATE DATABASE` privilege is required if you point the scripts at an
  existing database/schemas you already have `CREATE TABLE`/`CREATE
  PROCEDURE` rights in.
- The Streamlit app is deployed as **Streamlit-in-Snowflake**, so it runs in
  Snowflake's own Python runtime — there's no local `pip install` step.
  Snowsight's Streamlit editor needs these packages available from the
  Snowflake Anaconda channel (selectable in the app's Packages panel):
  `snowflake-snowpark-python`, `pandas`, `streamlit` — all standard and
  included by default in a new Streamlit-in-Snowflake app.

## Scope

Seeded with a synthetic healthcare provider-directory dataset (all names,
addresses, and identifiers are fictional), but the engine itself is
industry-agnostic — nothing in the detection, classification, or codegen
logic assumes healthcare.

Deliberately out of scope: actually applying generated code to the ontology
tables (a second, technical human gate — nothing under `sql/06_apply`
exists yet), and scheduling/automation of the detection cycle. Both are
natural next steps once the manual flow above is validated.

## License

No license is included, which means all rights are reserved — this
repository is shared to demonstrate the approach and the code, not as
something to be copied, modified, or reused.
