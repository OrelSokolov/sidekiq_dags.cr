# sidekiq_dags_cr — 1:1 port of the sidekiq-dags gem (OrelSokolov,
# Sidekiq::Batch::VERSION 0.7.2) to Crystal over Kiq (the Sidekiq port).
#
# Gem -> shard map:
#   require 'sidekiq_dags'      -> require "sidekiq_dags_cr"
#   Sidekiq::Batch              -> Kiq::Batch          (in kiq_cr)
#   Sidekiq::Batch::Status      -> Kiq::Batch::Status  (in kiq_cr)
#   Sidekiq::Node               -> Kiq::Node           (in kiq_cr)
#   Sidekiq::NodeDsl            -> Kiq::NodeDsl        (in kiq_cr)
#   Sidekiq::PipelineStatus     -> Kiq::PipelineStatus (in kiq_cr)
#   Sidekiq::SidekiqPipeline    -> Kiq::Pipeline       (in kiq_cr)
#   Sidekiq::SidekiqPipelineNode-> Kiq::PipelineNode   (in kiq_cr)
#   Sidekiq::PipelineCallback   -> Kiq::Batch::Callback::PipelineCallback
#   Sidekiq::PipelineTracking   -> Kiq::PipelineTracking (in kiq_cr)
#   Sidekiq::DummyJob           -> DummyJob            (in kiq_cr)
#   Sidekiq::PipelineDslExtension -> Kiq::PipelineDslExtension (below)
#   Sidekiq::PipelineVisualizer   -> Kiq::PipelineVisualizer   (below)
#
# Like the original's lib/sidekiq_dags.rb, requiring this file wires the
# batch + coordination middlewares into Kiq's client/server chains (that
# happens at the bottom of kiq_cr's src/batch.cr, 1:1 with the gem's
# Sidekiq.configure_server/configure_client calls).

require "kiq_cr"
require "./pipeline_dsl_extension"
require "./pipeline_visualizer"

# Модуль для работы с пайплайнами Kiq — аналог пустого `module SidekiqDags`
# гема; константы ниже дают gem-имена API поверх Kiq-неймспейса.
module SidekiqDags
  VERSION = "0.7.2"

  Batch            = ::Kiq::Batch
  BatchStatus      = ::Kiq::Batch::Status
  ExplicitStatus   = ::Kiq::Batch::ExplicitStatus
  Node             = ::Kiq::Node
  NodeDsl          = ::Kiq::NodeDsl
  PipelineStatus   = ::Kiq::PipelineStatus
  SidekiqPipeline  = ::Kiq::Pipeline
  PipelineNode     = ::Kiq::PipelineNode
  PipelineCallback = ::Kiq::Batch::Callback::PipelineCallback
  PipelineTracking = ::Kiq::PipelineTracking
  PipelineDslExtension = ::Kiq::PipelineDslExtension
  PipelineVisualizer   = ::Kiq::PipelineVisualizer
  DummyJob         = ::DummyJob
end
