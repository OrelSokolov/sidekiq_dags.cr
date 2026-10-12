# Kiq::PipelineDslExtension — 1:1 port of sidekiq-dags
# lib/sidekiq/pipeline_dsl_extension.rb (node metadata registry), plus the
# metadata hook that the original builds into Sidekiq::NodeDsl#node
# (lib/sidekiq/node_dsl.rb re-reads the block SOURCE from the file and
# scrapes it with regexes).
#
# Crystal deviation: there is no runtime source to re-read, so the node
# macro below (a copy of Kiq::NodeDsl.node with registration added — the
# original registers from `Sidekiq::NodeDsl#node` too) extracts the same
# metadata from the block AST at COMPILE time:
#   desc <string>            -> description
#   next_node :x / "x" / nil -> next_node (camelized, like the class lookup)
#   X*.perform_async         -> jobs (last segment of the receiver constant)
#   observer / execute       -> has_observer / has_execute
# The original's source-scan misfires (a `next_node :X` line inside a
# PREVIOUS node's block matches its `node :X` regex, so node X's metadata
# is extracted from the wrong lines) — NOT reproduced; the AST cannot lie.
# `next_node :snake_name` is registered camelized ("SnakeName") so the
# visualizer chain keeps working; the original stores the raw symbol and
# its Collector then fails to find the next node.

module Kiq
  module PipelineDslExtension
    # Metadata of a DSL node (Ruby: hash with :description/:next_node/
    # :jobs/:has_observer/:has_execute keys).
    struct NodeMetadata
      property description : String
      property next_node : String?
      property jobs : Array(String)
      property has_observer : Bool
      property has_execute : Bool

      def initialize(@description = "", @next_node = nil, @jobs = [] of String,
                     @has_observer = false, @has_execute = false)
      end
    end

    REGISTRY = {} of String => NodeMetadata

    def self.node_registry : Hash(String, NodeMetadata)
      REGISTRY
    end

    def self.clear_registry : Nil
      REGISTRY.clear
    end

    def self.register_node(module_name : String, node_name : String,
                           metadata : NodeMetadata) : Nil
      REGISTRY["#{module_name}::#{node_name}"] =
        NodeMetadata.new(
          description: metadata.description,
          next_node: metadata.next_node,
          jobs: metadata.jobs.uniq,
          has_observer: metadata.has_observer,
          has_execute: metadata.has_execute
        )
    end

    def self.get_pipeline_data(module_name : String) : Hash(String, NodeMetadata)
      data = {} of String => NodeMetadata
      REGISTRY.each do |key, metadata|
        next unless key.starts_with?("#{module_name}::")
        data[key.split("::").last] = metadata
      end
      data
    end

    # Used by the node DSL macro: derives module_name/node_name from the
    # generated node class's full name (the macro cannot see the caller's
    # namespace — `@type` inside a macro invoked with an explicit receiver
    # is the receiver module itself).
    def self.register_node_with_class(full_class_name : String, metadata : NodeMetadata) : Nil
      parts = full_class_name.split("::")
      node_name = parts.last
      module_name = parts.size > 1 ? parts[0..-2].join("::") : ""
      register_node(module_name, node_name, metadata)
    end
  end

  # Redefine Kiq::NodeDsl.node (the last macro definition wins in Crystal):
  # the body below is a verbatim copy of the one in kiq.cr src/node.cr with
  # the metadata registration added — mirrors how the original gem's
  # NodeDsl#node registers into PipelineDslExtension on every node().
  module NodeDsl
    macro node(name, &block)
      {% cparts = name.id.stringify.split("_") %}
        {% ccamel = "" %}
        {% for part in cparts %}
          {% head = part.size > 0 ? part[0...1].upcase : "" %}
          {% tail = part.size > 1 ? part[1..-1] : "" %}
          {% ccamel = ccamel + head + tail %}
        {% end %}

      # --- metadata extraction (compile-time equivalent of the original's
      # source scraping) -----------------------------------------------
      {% desc_val = "" %}
      {% next_val = nil %}
      {% has_obs = false %}
      {% has_exec = false %}
      {% jobs = [] of ASTNode %}
      {% if block %}
        {% body = block.body %}
        {% exprs = body.is_a?(Expressions) ? body.expressions : [body] %}
        {% for expr in exprs %}
          {% if expr.is_a?(Call) %}
            {% cname = expr.name.stringify %}
            {% if cname == "desc" && expr.args.size > 0 && expr.args[0].is_a?(StringLiteral) %}
              {% desc_val = expr.args[0] %}
            {% elsif cname == "next_node" && expr.args.size > 0 %}
              {% nn = expr.args[0] %}
              {% if nn.is_a?(SymbolLiteral) || nn.is_a?(StringLiteral) %}
                {% nparts = nn.id.stringify.split("_") %}
                {% ncamel = "" %}
                {% for part in nparts %}
                  {% phead = part.size > 0 ? part[0...1].upcase : "" %}
                  {% ptail = part.size > 1 ? part[1..-1] : "" %}
                  {% ncamel = ncamel + phead + ptail %}
                {% end %}
                {% next_val = ncamel.id.stringify %}
              {% end %}
            {% elsif cname == "observer" %}
              {% has_obs = true %}
            {% elsif cname == "execute" %}
              {% has_exec = true %}
            {% end %}
            # perform_async at the top level of the node block
            {% if cname == "perform_async" && expr.receiver && expr.receiver.is_a?(Path) %}
              {% rname = expr.receiver.stringify.split("::").last %}
              {% jobs << rname %}
            {% end %}
            # inside execute/observer/any do-block (incl. one level of if/unless)
            {% if expr.block %}
              {% bexprs = expr.block.body.is_a?(Expressions) ? expr.block.body.expressions : [expr.block.body] %}
              {% for e2 in bexprs %}
                {% if e2.is_a?(Call) && e2.name.stringify == "perform_async" && e2.receiver && e2.receiver.is_a?(Path) %}
                  {% jobs << e2.receiver.stringify.split("::").last %}
                {% end %}
                {% if e2.is_a?(If) %}
                  {% for branches in [e2.then, e2.else] %}
                    {% if branches %}
                      {% b2 = branches.is_a?(Expressions) ? branches.expressions : [branches] %}
                      {% for e3 in b2 %}
                        {% if e3.is_a?(Call) && e3.name.stringify == "perform_async" && e3.receiver && e3.receiver.is_a?(Path) %}
                          {% jobs << e3.receiver.stringify.split("::").last %}
                        {% end %}
                      {% end %}
                    {% end %}
                  {% end %}
                {% end %}
              {% end %}
            {% end %}
          {% elsif expr.is_a?(If) %}
            {% for branches in [expr.then, expr.else] %}
              {% if branches %}
                {% b2 = branches.is_a?(Expressions) ? branches.expressions : [branches] %}
                {% for e2 in b2 %}
                  {% if e2.is_a?(Call) && e2.name.stringify == "perform_async" && e2.receiver && e2.receiver.is_a?(Path) %}
                    {% jobs << e2.receiver.stringify.split("::").last %}
                  {% end %}
                {% end %}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}
      # -----------------------------------------------------------------

      class {{ ccamel.id }} < ::Kiq::Node
        include ::Kiq::PipelineTracking

        ::Kiq::PipelineDslExtension.register_node_with_class(
          self.name.to_s,
          ::Kiq::PipelineDslExtension::NodeMetadata.new(
            description: {{ desc_val }},
            next_node: {% if next_val %}{{ next_val }}{% else %}nil{% end %},
            jobs: [{{ jobs.splat }}] of String,
            has_observer: {{ has_obs }},
            has_execute: {{ has_exec }}
          )
        )

        {% if block %}
          {% body = block.body %}
          {% exprs = body.is_a?(Expressions) ? body.expressions : [body] %}
          {% for expr in exprs %}
            {% if expr.is_a?(Call) %}
              {% if expr.name.stringify == "desc" %}
                desc {{ expr.args[0] }}
              {% elsif expr.name.stringify == "execute" %}
                execute {{ expr.block }}
              {% elsif expr.name.stringify == "next_node" %}
                next_node {{ expr.args[0] }}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
      end
    end
  end
end
