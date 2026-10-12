# sidekiq_dags.cr

A 1:1 Crystal port of the **sidekiq-dags** gem (OrelSokolov,
`Sidekiq::Batch::VERSION` 0.7.2 — a fork of sidekiq-batch plus a DAG
layer) on top of **Kiq** (the port of Sidekiq 8.1.7). Status: **done** —
oracle 59/59 (batch/node/pipeline, Redis) + 43/43 (PipelineDslExtension
+ PipelineVisualizer), suite 104/104.

## Architecture

In the gem, the core monkey-patches the `Sidekiq` namespace. In Crystal
the core lives in Kiq (`require "kiq_cr"` gives `Kiq::Batch` with
Status/ExplicitStatus/FinalStatusSnapshot/Callback/middleware/
coordination middleware, `DummyJob`, `Kiq::Node`, `Kiq::NodeDsl`,
`Kiq::PipelineStatus`, `Kiq::Pipeline`, `Kiq::PipelineNode`,
`Kiq::Batch::Callback::PipelineCallback`, `Kiq::PipelineTracking`).
This shard adds the rest of the gem and provides the gem's names on
top of Kiq:

- `src/pipeline_dsl_extension.cr` — `Kiq::PipelineDslExtension`
  (node metadata registry: node_registry / clear_registry /
  register_node / get_pipeline_data, NodeMetadata) plus an override of
  the `Kiq::NodeDsl.node` macro (in Crystal the last macro definition
  wins; body copied verbatim from kiq.cr + registration).
- `src/pipeline_visualizer.cr` — `Kiq::PipelineVisualizer`
  (Node/Pipeline/Collector, SVG 1:1: sizes/layout/status classes/
  arrows/pipeline colors).
- `src/sidekiq_dags_cr.cr` — entry point + the `SidekiqDags` module with
  alias constants (Batch, Node, NodeDsl, PipelineStatus,
  SidekiqPipeline, PipelineNode, PipelineCallback, PipelineTracking,
  PipelineDslExtension, PipelineVisualizer, DummyJob). The name mapping
  is documented at the top of that file.

## Installation

```yaml
dependencies:
  sidekiq_dags_cr:
    github: OrelSokolov/sidekiq_dags.cr
```

```sh
shards install
```

Depends on `kiq_cr` (transitively active_support_cr, active_job_cr,
redis, pg, db).

## Feature comparison vs sidekiq-dags 0.7.2

| Feature | Original (sidekiq-dags) | Port (sidekiq_dags.cr) | Status |
|---|---|---|---|
| `Sidekiq::Batch`: bid format, Redis keys, callbacks, empty/nested/failure/invalidation, e2e via launcher | ✅ | `Kiq::Batch` (kiq.cr core) | ✅ |
| Node chains + single mode | ✅ | `Kiq::Node` / `Kiq::NodeDsl` | ✅ |
| Pipelines with tracking, `PipelineStatus` API, redis-lock | ✅ | `Kiq::Pipeline` (= SidekiqPipeline), `Kiq::PipelineTracking` | ✅ |
| `PipelineDslExtension` node metadata registry (register_node, get_pipeline_data, `node` hook) | ✅ | Metadata extracted from the block's **AST at compile time** instead of re-reading the source with regexes (see deviations) | 🔶 |
| `PipelineVisualizer` (Node attrs/sizes, root fallback, layout, SVG markers/statuses/edge geometry/canvas size/colors/title, Collector grouping incl. PriorityFrequent/Custom* RootNode ids, next_node chains, multi-modules) | ✅ | Same, SVG 1:1 | ✅ |
| AR layer (`SidekiqPipeline`/`SidekiqPipelineNode` as ActiveRecord, migrations, rake install, railtie) | removed in gem 0.7.2 | Not applicable — the gem keeps state in Redis (`Sidekiq::PipelineStatus`); the port mirrors the Redis variant | — |
| colorize log coloring | ✅ | Omitted | ❌ |

### Deviations (documented)

1. **DSL metadata is compile-time, not source-scraping.** The original
   re-reads the block's source file and cuts desc/next_node/jobs with
   regexes. The port extracts them from the AST (desc string; next_node
   symbol; `XJob.perform_async` at node top level and inside
   execute/observer/if/unless blocks 2 levels deep). This also avoids an
   original bug: the `node :X` regex matches inside a previous node's
   `next_node :X` string, so X's metadata is read from the wrong lines —
   port metadata is correct (no oracle case depends on it).
2. `next_node :snake_name` is **camelized** in the registry (matching
   class resolution); the original stores the raw symbol and its
   Collector then fails to find the next node.
3. Pipeline-DSL nodes also land in the registry (the original registers
   only direct `node` calls in modules extending NodeDsl) — additive for
   the Collector, which finds roots by the RootNode suffix.
4. The jobs scan is case-sensitive on `perform_async` (gem uses /i) and
   takes the last receiver segment (like `\w*Job` without `::`).
5. Long-description wrapping in SVG is practically unreachable in the
   original (node width always grows to fit); the case pins the actual
   behavior (single line).

## Testing

```sh
shards install   # Redis required for dags specs (DB 15, gets flushed)
crystal spec     # 104/104 (dags specs skip without Redis)
```

Oracle (the gem is vendored whole in `oracle/vendor/sidekiq-dags/`):

- `oracle/dags_cases.rb` → `oracle/expected_dags.yml` — 59 cases from
  the real gem (sidekiq 8.1.7, Ruby 3.4.5, Redis DB 15, TZ=UTC);
  regenerate with
  `TZ=UTC ruby -I oracle/vendor/sidekiq-dags/lib oracle/dags_cases.rb > oracle/expected_dags.yml`
  (reproduces byte-for-byte). Mirror: `spec/dags_oracle_spec.cr`.
- `oracle/cases.rb` → `oracle/expected.yml` — 43 cases without Redis
  (PipelineDslExtension + PipelineVisualizer), lifted from the gem's own
  specs. Mirror: `spec/oracle_spec.cr`.

Both sides run the same cases without edits; ids/values match
(normalization: `Sidekiq::`/`Kiq::` class prefixes stripped).
