# sidekiq_dags_cr — 1:1 порт гема sidekiq-dags (OrelSokolov,
# Sidekiq::Batch::VERSION 0.7.2, github.com/OrelSokolov/sidekiq-dags,
# коммит ab4b7b4) на Crystal поверх Kiq (порт Sidekiq 8.1.7).

Статус: **готов** — oracle 59/59 (batch/node/pipeline, Redis) +
43/43 (PipelineDslExtension + PipelineVisualizer), итого `crystal spec`
104/104.

## Архитектура

Гем sidekiq-dags — расширение Sidekiq (форк sidekiq-batch + DAG-слой),
его ядро monkey-patch'ит неймспейс Sidekiq. В Crystal ядро порта живёт
в Kiq (`~/rails.cr/kiq.cr`, см. его PLAN.md «Batch + DAG pipelines»):
`require "kiq_cr"` даёт `Kiq::Batch` (+Status/ExplicitStatus/
FinalStatusSnapshot/Callback/middleware/coordination-middleware —
последние регистрируются в цепочках при require, как `sidekiq_dags.rb`
гема), `DummyJob`, `Kiq::Node`, `Kiq::NodeDsl`, `Kiq::PipelineStatus`,
`Kiq::Pipeline` (= SidekiqPipeline), `Kiq::PipelineNode`,
`Kiq::Batch::Callback::PipelineCallback`, `Kiq::PipelineTracking`.

Этот шард добирает остальную часть гема и даёт gem-имена поверх Kiq:

- `src/pipeline_dsl_extension.cr` — `Kiq::PipelineDslExtension`
  (реестр метаданных нод: node_registry/clear_registry/register_node/
  get_pipeline_data, NodeMetadata) + переопределение макроса
  `Kiq::NodeDsl.node` (в Crystal побеждает последнее определение
  макроса; тело скопировано из kiq.cr verbatim + регистрация).
- `src/pipeline_visualizer.cr` — `Kiq::PipelineVisualizer`
  (Node/Pipeline/Collector, SVG 1:1: размеры/раскладка/классы статусов/
  стрелки/цвета пайплайнов).
- `src/sidekiq_dags_cr.cr` — entry: require "kiq_cr" + модуль
  `SidekiqDags` с константами-алиасами (Batch, Node, NodeDsl,
  PipelineStatus, SidekiqPipeline, PipelineNode, PipelineCallback,
  PipelineTracking, PipelineDslExtension, PipelineVisualizer, DummyJob).

Отображение имён — в шапке `src/sidekiq_dags_cr.cr`.

## Оракул (правило AGENTS.md)

Гем вендорен целиком в `oracle/vendor/sidekiq-dags/`.

- `oracle/dags_cases.rb` → `oracle/expected_dags.yml` — 59 кейсов с
  настоящего гема (sidekiq 8.1.7, Ruby 3.4.5, Redis DB 15, TZ=UTC):
  Batch (bid-формат, Redis-ключи, колбэки, empty/nested/failure/
  invalidation, e2e через launcher), цепочки Node + single mode,
  пайплайн с tracking, PipelineStatus API, redis-lock. Регенерация:
  `TZ=UTC ruby -I oracle/vendor/sidekiq-dags/lib oracle/dags_cases.rb
  > oracle/expected_dags.yml` (проверена: воспроизводится байт-в-байт).
  Зеркало `spec/dags_oracle_spec.cr` — те же кейсы против порта.
- `oracle/cases.rb` → `oracle/expected.yml` — 43 кейса (без Redis):
  PipelineDslExtension (реестр, register_node, get_pipeline_data, хук
  в `node`), PipelineVisualizer (Node attrs/id/размеры, root/фолбэк,
  layout-координаты, SVG-маркеры/статусы/геометрия рёбер/размер
  канвы/цвета/титул/перенос описаний), Collector (группировка,
  PriorityFrequent/Custom* RootNode-айди, цепочки next_node, мульти-
  модули). Кейсы собраны из спек самого гема
  (`spec/sidekiq/pipeline_dsl_extension_spec.rb`,
  `pipeline_visualizer_spec.rb`). Зеркало `spec/oracle_spec.cr`.

Обе стороны проходят одни и те же кейсы без правок; id/значения
совпадают (нормализации: классы `Sidekiq::`/`Kiq::` → без префикса).

## Отклонения от гема (задокументированы)

1. **Метаданные DSL — compile-time, а не source-scraping.** Оригинал
   в `NodeDsl#node` перечитывает исходник блока с диска и вырезает
   desc/next_node/jobs регулярками. Порт извлекает их из AST блока на
   компиляции (desc-строка; next_node-символ; `XJob.perform_async`
   на верхнем уровне ноды и внутри execute/observer/блоков if/unless
   на 2 уровня). Баг оригинала не воспроизводится: `node :X`-regex
   матчится внутри строки `next_node :X` предыдущей ноды, из-за чего
   метаданные ноды X читаются с чужих строк (`next` «ссылается на
   себя», observer теряется) — oracle-кейс на это не завязан,
   метаданные нод в порте честные.
2. **`next_node :snake_name` в реестре — camelized** (`"SnakeName"`),
   как ресолв класса; оригинал хранит сырой символ, и его Collector
   тогда не находит следующую ноду.
3. **pipeline-DSL ноды тоже попадают в реестр** (оригинал регистрирует
   только ноды, созданные прямым `node` в модуле с `extend NodeDsl`;
   `pipeline` обходит регистрацию). Для Collector это аддитивно
   (корневые ищутся по суффиксу RootNode).
4. `@type` в макросе с явным ресивером = сам ресивер (Kiq::NodeDsl),
   поэтому module_name для реестра вычисляется в теле класса из
   `self.name` (`register_node_with_class`).
5. jobs-скан регисточувствителен к `perform_async` (у гема /i),
   берёт последний сегмент ресивера (как `\w*Job` без `::`).
6. Перенос длинных описаний в SVG у оригинала практически недостижим
   (ширина узла всегда растёт под описание: max_chars ≥ длине), кейс
   фиксирует фактическое поведение (одна строка).
7. AR-слоя гема (SidekiqPipeline/SidekiqPipelineNode как ActiveRecord,
   миграции `db/migrate`, rake `sidekiq_dags:install`, railtie) в
   этой версии гема больше нет — с 0.7.2 состояние в Redis
   (`Sidekiq::PipelineStatus`); порт повторяет Redis-вариант.
8. colorize — только раскраска логов, в порте опущена.

## Зависимости

- `kiq_cr` (path `../../rails.cr/kiq.cr`); транзитивно
  active_support_cr, active_job_cr, redis (git), pg, db.
- shards 0.20 резолвит транзитивные path-зависимости от корня проекта,
  поэтому в `~/myshards` лежат симлинки на шарды rails.cr
  (`active_support.cr`, `action_pack.cr`, … — так уже устроены соседние
  порты); для этого шарда добавлен `active_job.cr`. `shard.lock`
  записан в формате соседних шардов (пути относительно декларатора).

## Запуск

```sh
shards install          # требует Redis для dags-спек (DB 15, флашится)
crystal spec            # 104/104 (dags-спеки пропустятся без Redis)
```
