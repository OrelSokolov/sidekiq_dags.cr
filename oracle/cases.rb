# Oracle cases for the sidekiq-dags parts not covered by dags_cases.rb:
# Sidekiq::PipelineDslExtension (node metadata registry) and
# Sidekiq::PipelineVisualizer (SVG diagrams). Pure-Ruby cases, no Redis.
#
# Run against the ORIGINAL gem (vendored in oracle/vendor/sidekiq-dags):
#   TZ=UTC ruby -I oracle/vendor/sidekiq-dags/lib oracle/cases.rb > oracle/expected.yml

ENV["TZ"] = "UTC"

$LOAD_PATH.unshift File.expand_path("../vendor/sidekiq-dags/lib", __dir__)

require "sidekiq"
require "sidekiq/api"

# sidekiq-dags calls JSON.unparse, removed in json 3.x
JSON.singleton_class.send(:alias_method, :unparse, :generate) unless JSON.respond_to?(:unparse)

raise "sidekiq 8.1.7 expected, got #{Sidekiq::VERSION}" unless Sidekiq::VERSION == "8.1.7"

require "sidekiq/batch"
require "sidekiq/node"
require "sidekiq/node_dsl"
require "sidekiq/pipeline_dsl_extension"
require "sidekiq/pipeline_visualizer"

OUT = []
$stdout = $stderr # keep any gem noise out of the case stream
def emit(id, value)
  OUT << [id, value.to_s].join("\t")
  warn "== #{id}: #{value}"
end

def norm_metadata(m)
  "desc=#{m[:description].inspect}|next=#{m[:next_node].inspect}|jobs=#{m[:jobs].inspect}|obs=#{m[:has_observer]}|exec=#{m[:has_execute]}"
end

# --- PipelineDslExtension -----------------------------------------------------

Sidekiq::PipelineDslExtension.clear_registry
emit "dsl_registry_empty", Sidekiq::PipelineDslExtension.node_registry.inspect

Sidekiq::PipelineDslExtension.register_node("TestModule", "TestNode",
  description: "Test node", next_node: "NextNode", jobs: ["TestJob"],
  has_observer: true, has_execute: true)
emit "dsl_register_node", Sidekiq::PipelineDslExtension.node_registry["TestModule::TestNode"]
  .then { |m| norm_metadata(m) }

Sidekiq::PipelineDslExtension.register_node("TestModule", "Node1",
  description: "Node1", next_node: "Node2", jobs: [], has_observer: false, has_execute: false)
Sidekiq::PipelineDslExtension.register_node("TestModule", "Node2",
  description: "Node2", next_node: nil, jobs: [], has_observer: false, has_execute: false)
Sidekiq::PipelineDslExtension.register_node("OtherModule", "OtherNode",
  description: "Other", next_node: nil, jobs: [], has_observer: false, has_execute: false)

data = Sidekiq::PipelineDslExtension.get_pipeline_data("TestModule")
emit "dsl_get_pipeline_data_keys", data.keys.sort
emit "dsl_get_pipeline_data_node1", norm_metadata(data["Node1"])

Sidekiq::PipelineDslExtension.clear_registry
emit "dsl_clear_registry", Sidekiq::PipelineDslExtension.node_registry.empty?

# --- NodeDsl integration (metadata registered by `node`) ----------------------
#
# NB: the original registers metadata by re-reading the block SOURCE from
# the file (block.source_location); the node below therefore must be
# defined in THIS file, in plain text.
#
# NB: a node referenced by another node's `next_node :X` line has its
# metadata polluted by the original's source-scan (the `node :X` regex
# matches inside `next_node :X`, so extraction starts at the wrong line).
# EndNode's own metadata is therefore NOT asserted here — see PLAN.md.

module TestPipe
  extend Sidekiq::NodeDsl

  node :StartNode do
    desc "Start processing"
    execute do
      StartJob.perform_async
      FinishJob.perform_async
    end
    next_node :EndNode
  end

  node :EndNode do
    desc "Finish"
  end
end

reg = Sidekiq::PipelineDslExtension.node_registry
emit "dsl_node_hook_keys", reg.keys.sort
emit "dsl_node_hook_start", norm_metadata(reg["TestPipe::StartNode"])
emit "dsl_get_pipeline_data_testpipe", Sidekiq::PipelineDslExtension.get_pipeline_data("TestPipe").keys.sort

# observer flag on an unreferenced node
module ObsPipe
  extend Sidekiq::NodeDsl

  node :WatcherNode do
    desc "Watch"
    observer do
      puts "observed"
    end
  end
end
emit "dsl_node_hook_observer", norm_metadata(Sidekiq::PipelineDslExtension.node_registry["ObsPipe::WatcherNode"])

# node with single-mode style body (no execute)
Sidekiq::PipelineDslExtension.clear_registry
module SoloPipe
  extend Sidekiq::NodeDsl

  node :SoloNode do
    desc "Solo"
    next_node nil
  end
end
emit "dsl_node_hook_solo", norm_metadata(Sidekiq::PipelineDslExtension.node_registry["SoloPipe::SoloNode"])

# --- PipelineVisualizer::Node --------------------------------------------------

Sidekiq::PipelineDslExtension.clear_registry

node = Sidekiq::PipelineVisualizer::Node.new("TestNode", "Test description", "NextNode", "TestModule", ["TestJob"])
emit "viz_node_attrs", [node.name, node.description, node.next_node, node.module_name, node.jobs.inspect].join("|")
emit "viz_node_id", node.id

node.calculate_dimensions
emit "viz_node_dims", [node.width, node.height].join("|")

long = Sidekiq::PipelineVisualizer::Node.new("N", "a" * 120, nil, "M", [])
long.calculate_dimensions
emit "viz_node_dims_long_desc", [long.width, long.height].join("|")

manyjobs = Sidekiq::PipelineVisualizer::Node.new("N", "d", nil, "M", %w[Job1 Job2VeryLongName Job3])
manyjobs.calculate_dimensions
emit "viz_node_dims_jobs", [manyjobs.width, manyjobs.height].join("|")

nodesc = Sidekiq::PipelineVisualizer::Node.new("N", nil, nil, "M", nil)
nodesc.calculate_dimensions
emit "viz_node_dims_nodesc", [nodesc.width, nodesc.height].join("|")

# --- PipelineVisualizer::Pipeline ----------------------------------------------

pv = Sidekiq::PipelineVisualizer::Pipeline.new("TestPipeline")
emit "viz_pipeline_init", [pv.name, pv.nodes.inspect].join("|")

pv.add_node("Node1", "Description1", "Node2", "TestModule", ["Job1"])
emit "viz_pipeline_add_node", [pv.nodes["Node1"].name, pv.nodes["Node1"].description].join("|")

pv2 = Sidekiq::PipelineVisualizer::Pipeline.new("P2")
pv2.add_node("RootNode", "Root", "Node2", "TestModule")
pv2.add_node("Node2", "Node2", nil, "TestModule")
root = pv2.get_root_node
emit "viz_get_root_node", root.name

# root fallback: no RootNode -> first node nobody references
pv3 = Sidekiq::PipelineVisualizer::Pipeline.new("P3")
pv3.add_node("A", "a", "B", "M")
pv3.add_node("B", "b", nil, "M")
emit "viz_get_root_node_fallback", pv3.get_root_node.name

pv2.calculate_layout
emit "viz_layout_coords", pv2.nodes.values.map { |n| [n.name, n.x, n.y].join(":") }.join("|")
emit "viz_layout_sizes", pv2.nodes.values.map { |n| [n.name, n.width, n.height].join(":") }.join("|")

svg = pv2.to_svg
emit "viz_svg_markers", ["<?xml", "<svg", "RootNode", "Node2", "node-rect\"", "class=\"edge\"", "arrowhead"].map { |m| svg.include?(m) }.join(",")

svg_status = pv2.to_svg(node_statuses: { "TestModule_RootNode" => "running", "TestModule_Node2" => "completed" }, pipeline_running: true)
emit "viz_svg_status_markers", ["node-rect-running", "node-rect-completed", "node-desc-running", "job-text-completed", "edge-active"].map { |m| svg_status.include?(m) }.join(",")

# geometry of edges is deterministic: check the line coordinates
pv4 = Sidekiq::PipelineVisualizer::Pipeline.new("P4")
pv4.add_node("RootNode", "Root", "Node2", "TestModule")
pv4.add_node("Node2", "Node2", nil, "TestModule")
svg4 = pv4.to_svg
edge = svg4[/x1="(\d+)" y1="(\d+)" x2="(\d+)" y2="(\d+)" class="edge"/]
emit "viz_svg_edge_coords", edge

size = svg4[/width="(\d+)" height="(\d+)"/]
emit "viz_svg_canvas_size", size

emit "viz_get_title_running", pv4.get_title(pipeline_running: true)
emit "viz_get_title_stopped", pv4.get_title(pipeline_running: false)

# known pipeline color
pv5 = Sidekiq::PipelineVisualizer::Pipeline.new("Rustat")
pv5.add_node("RootNode", "Root", nil, "Rustat")
emit "viz_svg_known_color", pv5.to_svg.include?("#96A78D")
# unknown pipeline color falls back
pv6 = Sidekiq::PipelineVisualizer::Pipeline.new("Unknown")
pv6.add_node("RootNode", "Root", nil, "Unknown")
emit "viz_svg_fallback_color", pv6.to_svg.include?("#f8f9fa")

# multi-line description wrapping: a long NAME forces the node width, so a
# longer description must wrap inside it (the width alone never wraps)
pv7 = Sidekiq::PipelineVisualizer::Pipeline.new("P7")
pv7.add_node("A" * 60, (1..30).map { |i| "word#{i}" }.join(" "), nil, "M")
svg7 = pv7.to_svg
lines = svg7.scan(/<text x="\d+" y="\d+" class="node-desc">([^<]+)<\/text>/).flatten
emit "viz_svg_desc_wrapping", lines

# --- PipelineVisualizer::Collector --------------------------------------------

Sidekiq::PipelineDslExtension.clear_registry
Sidekiq::PipelineDslExtension.register_node("TestModule", "RootNode",
  description: "Root node", next_node: "Node2", jobs: ["Job1"], has_observer: false, has_execute: true)
Sidekiq::PipelineDslExtension.register_node("TestModule", "Node2",
  description: "Node 2", next_node: nil, jobs: ["Job2"], has_observer: false, has_execute: true)

pipelines = Sidekiq::PipelineVisualizer::Collector.collect_pipelines
emit "collector_keys", pipelines.keys.sort
p1 = pipelines["test_module"]
emit "collector_pipeline_class", p1.class.name.sub(/\A(Sidekiq|Kiq)::/, "")
emit "collector_nodes", p1.nodes.keys.sort
emit "collector_root_next", [p1.nodes["RootNode"].next_node, p1.nodes["RootNode"].module_name].join("|")
emit "collector_node2_jobs", p1.nodes["Node2"].jobs.inspect

# multiple modules -> multiple pipelines
Sidekiq::PipelineDslExtension.clear_registry
Sidekiq::PipelineDslExtension.register_node("Module1", "RootNode",
  description: "Root1", next_node: nil, jobs: [], has_observer: false, has_execute: false)
Sidekiq::PipelineDslExtension.register_node("Module2", "RootNode",
  description: "Root2", next_node: nil, jobs: [], has_observer: false, has_execute: false)
emit "collector_multi", Sidekiq::PipelineVisualizer::Collector.collect_pipelines.keys.sort

# special root names: PriorityFrequentRootNode / CustomRootNode
Sidekiq::PipelineDslExtension.clear_registry
Sidekiq::PipelineDslExtension.register_node("Rustat", "PriorityFrequentRootNode",
  description: "pf", next_node: nil, jobs: [], has_observer: false, has_execute: false)
Sidekiq::PipelineDslExtension.register_node("Rustat", "CustomRootNode",
  description: "c", next_node: nil, jobs: [], has_observer: false, has_execute: false)
pl = Sidekiq::PipelineVisualizer::Collector.collect_pipelines
emit "collector_priority_frequent", pl.keys.sort
emit "collector_priority_frequent_name", pl["rustat_priority_frequent"].name

Sidekiq::PipelineDslExtension.clear_registry
Sidekiq::PipelineDslExtension.register_node("MyApp", "CustomTeamRootNode",
  description: "ct", next_node: "SecondNode", jobs: [], has_observer: false, has_execute: true)
Sidekiq::PipelineDslExtension.register_node("MyApp", "SecondNode",
  description: "s", next_node: nil, jobs: [], has_observer: false, has_execute: true)
pl2 = Sidekiq::PipelineVisualizer::Collector.collect_pipelines
emit "collector_custom_root", pl2.keys
emit "collector_custom_root_display_name", pl2["my_app_custom_team"].name

# chained collection follows next_node across nodes
Sidekiq::PipelineDslExtension.clear_registry
Sidekiq::PipelineDslExtension.register_node("Chain", "RootNode",
  description: "r", next_node: "MidNode", jobs: [], has_observer: false, has_execute: true)
Sidekiq::PipelineDslExtension.register_node("Chain", "MidNode",
  description: "m", next_node: "EndNode", jobs: [], has_observer: false, has_execute: true)
Sidekiq::PipelineDslExtension.register_node("Chain", "EndNode",
  description: "e", next_node: nil, jobs: [], has_observer: false, has_execute: true)
chained = Sidekiq::PipelineVisualizer::Collector.collect_pipelines["chain"]
emit "collector_chain_nodes", chained.nodes.keys
emit "collector_chain_svg", chained.to_svg.include?("EndNode")

$stdout = STDOUT
puts OUT.join("\n")
