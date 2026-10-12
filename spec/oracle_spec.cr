# sidekiq_dags_cr oracle mirror: reproduces oracle/expected.yml (captured
# from the real sidekiq-dags gem via oracle/cases.rb) 1:1 — same case IDs,
# same expectations, no edits on either side. Covers Sidekiq::
# PipelineDslExtension (node metadata registry) and Sidekiq::
# PipelineVisualizer (SVG). No Redis needed.
#
# Mechanics note: the original registers node metadata at RUNTIME when
# `node` executes (source scraping); the port registers at COMPILE time
# (class body). The DSL snapshot below restores the boot-time registry
# entries for the node-hook cases after clear_registry — the observable
# values are identical on both sides.

require "spec"
require "../src/sidekiq_dags_cr"

EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/expected.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp
  end
  hash
end

# --- DSL nodes under test (compile-time registration) --------------------------

class StartJob
  include Kiq::Job

  def perform(*args)
  end
end

class FinishJob
  include Kiq::Job

  def perform(*args)
  end
end

module TestPipe
  Kiq::NodeDsl.node :start_node do
    desc "Start processing"
    execute do
      StartJob.perform_async
      FinishJob.perform_async
    end
    next_node :end_node
  end

  Kiq::NodeDsl.node :end_node do
    desc "Finish"
  end
end

module ObsPipe
  Kiq::NodeDsl.node :watcher_node do
    desc "Watch"
    observer do
      puts "observed"
    end
  end
end

module SoloPipe
  Kiq::NodeDsl.node :solo_node do
    desc "Solo"
    next_node nil
  end
end

# Boot-time DSL registrations, snapshotted before any clear_registry.
DSL_SNAPSHOT = Kiq::PipelineDslExtension.node_registry.dup

def norm_metadata(m : Kiq::PipelineDslExtension::NodeMetadata) : String
  "desc=#{m.description.inspect}|next=#{m.next_node.inspect}|jobs=#{m.jobs.inspect}|obs=#{m.has_observer}|exec=#{m.has_execute}"
end

def restore_dsl_registry : Nil
  DSL_SNAPSHOT.each do |key, metadata|
    parts = key.split("::")
    Kiq::PipelineDslExtension.register_node(parts[0..-2].join("::"), parts.last, metadata)
  end
end

def md(description = "", next_node = nil, jobs = [] of String,
       has_observer = false, has_execute = false)
  Kiq::PipelineDslExtension::NodeMetadata.new(
    description: description, next_node: next_node, jobs: jobs,
    has_observer: has_observer, has_execute: has_execute)
end

OUT = [] of String

def emit(id, value)
  OUT << "#{id}\t#{value}"
end

def viz_bool_markers(svg, markers)
  markers.map { |m| svg.includes?(m) }.join(",")
end

# --- PipelineDslExtension ------------------------------------------------------

Kiq::PipelineDslExtension.clear_registry
emit "dsl_registry_empty", Kiq::PipelineDslExtension.node_registry.inspect

Kiq::PipelineDslExtension.register_node("TestModule", "TestNode",
  md(description: "Test node", next_node: "NextNode", jobs: ["TestJob"],
     has_observer: true, has_execute: true))
emit "dsl_register_node", norm_metadata(Kiq::PipelineDslExtension.node_registry["TestModule::TestNode"])

Kiq::PipelineDslExtension.register_node("TestModule", "Node1",
  md(description: "Node1", next_node: "Node2"))
Kiq::PipelineDslExtension.register_node("TestModule", "Node2", md(description: "Node2"))
Kiq::PipelineDslExtension.register_node("OtherModule", "OtherNode", md(description: "Other"))

data = Kiq::PipelineDslExtension.get_pipeline_data("TestModule")
emit "dsl_get_pipeline_data_keys", data.keys.sort.inspect
emit "dsl_get_pipeline_data_node1", norm_metadata(data["Node1"])

Kiq::PipelineDslExtension.clear_registry
emit "dsl_clear_registry", Kiq::PipelineDslExtension.node_registry.empty?.to_s

# --- NodeDsl integration --------------------------------------------------

restore_dsl_registry

emit "dsl_node_hook_keys", Kiq::PipelineDslExtension.node_registry.keys.select { |k| k.starts_with?("TestPipe::") }.sort.inspect
emit "dsl_node_hook_start", norm_metadata(Kiq::PipelineDslExtension.node_registry["TestPipe::StartNode"])
emit "dsl_get_pipeline_data_testpipe", Kiq::PipelineDslExtension.get_pipeline_data("TestPipe").keys.sort.inspect

emit "dsl_node_hook_observer", norm_metadata(Kiq::PipelineDslExtension.node_registry["ObsPipe::WatcherNode"])

Kiq::PipelineDslExtension.clear_registry
restore_dsl_registry
emit "dsl_node_hook_solo", norm_metadata(Kiq::PipelineDslExtension.node_registry["SoloPipe::SoloNode"])

# --- PipelineVisualizer::Node ----------------------------------------------

Kiq::PipelineDslExtension.clear_registry



node = Kiq::PipelineVisualizer::Node.new("TestNode", "Test description", "NextNode", "TestModule", ["TestJob"])
emit "viz_node_attrs", [node.name, node.description, node.next_node, node.module_name, node.jobs.inspect].join("|")
emit "viz_node_id", node.id

node.calculate_dimensions
emit "viz_node_dims", [node.width, node.height].join("|")

long = Kiq::PipelineVisualizer::Node.new("N", "a" * 120, nil, "M", [] of String)
long.calculate_dimensions
emit "viz_node_dims_long_desc", [long.width, long.height].join("|")

manyjobs = Kiq::PipelineVisualizer::Node.new("N", "d", nil, "M", ["Job1", "Job2VeryLongName", "Job3"])
manyjobs.calculate_dimensions
emit "viz_node_dims_jobs", [manyjobs.width, manyjobs.height].join("|")

nodesc = Kiq::PipelineVisualizer::Node.new("N", nil, nil, "M", nil)
nodesc.calculate_dimensions
emit "viz_node_dims_nodesc", [nodesc.width, nodesc.height].join("|")

# --- PipelineVisualizer::Pipeline -------------------------------------------

pv = Kiq::PipelineVisualizer::Pipeline.new("TestPipeline")
emit "viz_pipeline_init", [pv.name, pv.nodes.inspect].join("|")

pv.add_node("Node1", "Description1", "Node2", "TestModule", ["Job1"])
emit "viz_pipeline_add_node", [pv.nodes["Node1"].not_nil!.name, pv.nodes["Node1"].not_nil!.description].join("|")

pv2 = Kiq::PipelineVisualizer::Pipeline.new("P2")
pv2.add_node("RootNode", "Root", "Node2", "TestModule")
pv2.add_node("Node2", "Node2", nil, "TestModule")
emit "viz_get_root_node", pv2.get_root_node.not_nil!.name

pv3 = Kiq::PipelineVisualizer::Pipeline.new("P3")
pv3.add_node("A", "a", "B", "M")
pv3.add_node("B", "b", nil, "M")
emit "viz_get_root_node_fallback", pv3.get_root_node.not_nil!.name

pv2.calculate_layout
emit "viz_layout_coords", pv2.nodes.values.map { |n| [n.name, n.x.to_s, n.y.to_s].join(":") }.join("|")
emit "viz_layout_sizes", pv2.nodes.values.map { |n| [n.name, n.width.to_s, n.height.to_s].join(":") }.join("|")

svg = pv2.to_svg
emit "viz_svg_markers", viz_bool_markers(svg, ["<?xml", "<svg", "RootNode", "Node2", "node-rect\"", "class=\"edge\"", "arrowhead"])

svg_status = pv2.to_svg(node_statuses: {"TestModule_RootNode" => "running", "TestModule_Node2" => "completed"}, pipeline_running: true)
emit "viz_svg_status_markers", viz_bool_markers(svg_status, ["node-rect-running", "node-rect-completed", "node-desc-running", "job-text-completed", "edge-active"])

pv4 = Kiq::PipelineVisualizer::Pipeline.new("P4")
pv4.add_node("RootNode", "Root", "Node2", "TestModule")
pv4.add_node("Node2", "Node2", nil, "TestModule")
svg4 = pv4.to_svg
edge = svg4[/x1="\d+" y1="\d+" x2="\d+" y2="\d+" class="edge"/]
emit "viz_svg_edge_coords", edge.to_s

size = svg4[/width="\d+" height="\d+"/]
emit "viz_svg_canvas_size", size.to_s

emit "viz_get_title_running", pv4.get_title(pipeline_running: true)
emit "viz_get_title_stopped", pv4.get_title(pipeline_running: false)

pv5 = Kiq::PipelineVisualizer::Pipeline.new("Rustat")
pv5.add_node("RootNode", "Root", nil, "Rustat")
emit "viz_svg_known_color", pv5.to_svg.includes?("#96A78D").to_s
pv6 = Kiq::PipelineVisualizer::Pipeline.new("Unknown")
pv6.add_node("RootNode", "Root", nil, "Unknown")
emit "viz_svg_fallback_color", pv6.to_svg.includes?("#f8f9fa").to_s

pv7 = Kiq::PipelineVisualizer::Pipeline.new("P7")
pv7.add_node("A" * 60, (1..30).map { |i| "word#{i}" }.join(" "), nil, "M")
svg7 = pv7.to_svg
lines = svg7.scan(/<text x="\d+" y="\d+" class="node-desc">([^<]+)<\/text>/).map(&.[1])
emit "viz_svg_desc_wrapping", lines.inspect

# --- PipelineVisualizer::Collector -----------------------------------------

Kiq::PipelineDslExtension.clear_registry
Kiq::PipelineDslExtension.register_node("TestModule", "RootNode",
  md(description: "Root node", next_node: "Node2", jobs: ["Job1"], has_execute: true))
Kiq::PipelineDslExtension.register_node("TestModule", "Node2",
  md(description: "Node 2", next_node: nil, jobs: ["Job2"], has_execute: true))

pipelines = Kiq::PipelineVisualizer::Collector.collect_pipelines
emit "collector_keys", pipelines.keys.sort.inspect
p1 = pipelines["test_module"].not_nil!
emit "collector_pipeline_class", p1.class.name.sub(/\A(Sidekiq|Kiq)::/, "")
emit "collector_nodes", p1.nodes.keys.sort.inspect
emit "collector_root_next", [p1.nodes["RootNode"].not_nil!.next_node, p1.nodes["RootNode"].not_nil!.module_name].join("|")
emit "collector_node2_jobs", p1.nodes["Node2"].not_nil!.jobs.inspect

Kiq::PipelineDslExtension.clear_registry
Kiq::PipelineDslExtension.register_node("Module1", "RootNode", md(description: "Root1"))
Kiq::PipelineDslExtension.register_node("Module2", "RootNode", md(description: "Root2"))
emit "collector_multi", Kiq::PipelineVisualizer::Collector.collect_pipelines.keys.sort.inspect

Kiq::PipelineDslExtension.clear_registry
Kiq::PipelineDslExtension.register_node("Rustat", "PriorityFrequentRootNode", md(description: "pf"))
Kiq::PipelineDslExtension.register_node("Rustat", "CustomRootNode", md(description: "c"))
pl = Kiq::PipelineVisualizer::Collector.collect_pipelines
emit "collector_priority_frequent", pl.keys.sort.inspect
emit "collector_priority_frequent_name", pl["rustat_priority_frequent"].not_nil!.name

Kiq::PipelineDslExtension.clear_registry
Kiq::PipelineDslExtension.register_node("MyApp", "CustomTeamRootNode",
  md(description: "ct", next_node: "SecondNode", has_execute: true))
Kiq::PipelineDslExtension.register_node("MyApp", "SecondNode",
  md(description: "s", next_node: nil, has_execute: true))
pl2 = Kiq::PipelineVisualizer::Collector.collect_pipelines
emit "collector_custom_root", pl2.keys.inspect
emit "collector_custom_root_display_name", pl2["my_app_custom_team"].not_nil!.name

Kiq::PipelineDslExtension.clear_registry
Kiq::PipelineDslExtension.register_node("Chain", "RootNode",
  md(description: "r", next_node: "MidNode", has_execute: true))
Kiq::PipelineDslExtension.register_node("Chain", "MidNode",
  md(description: "m", next_node: "EndNode", has_execute: true))
Kiq::PipelineDslExtension.register_node("Chain", "EndNode",
  md(description: "e", next_node: nil, has_execute: true))
chained = Kiq::PipelineVisualizer::Collector.collect_pipelines["chain"].not_nil!
emit "collector_chain_nodes", chained.nodes.keys.inspect
emit "collector_chain_svg", chained.to_svg.includes?("EndNode").to_s

# --- run -----------------------------------------------------------------------

describe "sidekiq-dags dsl/visualizer oracle" do
  OUT.each do |line|
    id, value = line.split('\t', 2)
    it id do
      value.should eq EXPECTED[id]
    end
  end

  it "covers every oracle case" do
    OUT.size.should eq EXPECTED.size
    OUT.map { |l| l.split('\t', 2)[0] }.should eq EXPECTED.keys
  end
end
