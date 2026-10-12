# Kiq::PipelineVisualizer — 1:1 port of sidekiq-dags
# lib/sidekiq/pipeline_visualizer.rb (SVG diagrams of the registered
# pipelines). Pure computation, no Redis.
#
# Ruby -> Crystal notes:
# - Ruby integer division `a / b` on Integers is floor division -> `//`.
# - `Float#ceil` returns an Integer in Ruby -> `.ceil.to_i`.
# - `String#length` counts characters -> `#size`.
# - Underscore helper is shared with Kiq::Pipeline (same regexes).

require "set"

module Kiq
  module PipelineVisualizer
    class Node
      property name : String
      property description : String?
      property next_node : String?
      property module_name : String
      property jobs : Array(String)
      property x : Int32
      property y : Int32
      property width : Int32
      property height : Int32

      def initialize(@name, @description, @next_node, @module_name, jobs : Array(String)? = nil)
        @jobs = jobs || [] of String
        @x = 0
        @y = 0
        @width = 200  # базовая ширина
        @height = 80  # базовая высота
      end

      def id : String
        "#{@module_name}_#{@name}"
      end

      def calculate_dimensions : Nil
        # Вычисляем ширину на основе длины текста (уменьшенные коэффициенты для компактности)
        name_width = (@name.size * 8) + 60 # 8px на символ + отступы
        desc_width = @description ? ((@description.not_nil!.size * 6) + 60) : 100 # 6px на символ для описания

        # Учитываем ширину для джобов
        jobs_width = 0
        if @jobs && !@jobs.empty?
          max_job_name = @jobs.max_by(&.size)
          jobs_width = (max_job_name.size * 6) + 60 if max_job_name
        end

        @width = {name_width, desc_width, jobs_width, 200}.max # минимум 200px
        @height = 70                                   # уменьшенная базовая высота

        # Увеличиваем высоту для описания
        if @description && !@description.not_nil!.empty?
          max_chars_per_line = (@width - 40) // 6 # учитываем отступы для меньших шрифтов
          desc_lines = (@description.not_nil!.size.to_f / max_chars_per_line).ceil.to_i
          desc_lines = {desc_lines, 1}.max # минимум 1 строка
          @height += desc_lines * 14 # 14px на строку описания
        end

        # Увеличиваем высоту для джобов
        return unless @jobs && !@jobs.empty?

        @height += (@jobs.size * 12) + 8 # 12px на джоб + отступ
      end
    end

    class Pipeline
      getter name : String
      getter nodes : Hash(String, Node)
      getter colors : Hash(String, String)

      def initialize(@name)
        @nodes = {} of String => Node
        @colors = {
          "Transfermarkt"            => "#96A78D",
          "Transfermarkt::Old"       => "#A78D8D",
          "Rustat"                   => "#96A78D",
          "Rustat::Priority"         => "#A78D96",
          "Rustat::PriorityFrequent" => "#8DA796",
          "Rustat::PriorityRare"     => "#A78DA7",
          "Datahub"                  => "#96A78D",
          "Skillcorner"              => "#8D96A7",
          "MOSFF"                    => "#A7968D",
        }
      end

      def add_node(name : String, description : String?, next_node : String?,
                   module_name : String, jobs : Array(String) = [] of String) : Nil
        @nodes[name] = Node.new(name, description, next_node, module_name, jobs)
      end

      def get_root_node : Node?
        # Ищем узел с именем "RootNode" - это стандартное имя корневого узла
        root_candidates = ["RootNode", "CustomTeamRootNode"].map { |n| @nodes[n]? }.compact

        return root_candidates.first if root_candidates.any?

        # Если не найден стандартный корневой узел, находим узел, на который никто не ссылается
        referenced = @nodes.values.map(&.next_node).compact
        @nodes.values.find { |node| !referenced.includes?(node.name) }
      end

      def calculate_layout : Nil
        root = get_root_node
        return unless root

        # Сначала вычисляем размеры всех узлов
        @nodes.each_value(&.calculate_dimensions)

        x_offset = 40
        y_offset = 80
        spacing_x = 30 # горизонтальный отступ между узлами

        # Горизонтальное размещение - следуем цепочке узлов слева направо
        current_node = root
        current_x = x_offset
        visited = Set(String).new

        while current_node && !visited.includes?(current_node.name)
          visited.add(current_node.name)

          current_node.x = current_x
          current_node.y = y_offset

          # Следующий узел размещаем после текущего с учетом его ширины
          current_x += current_node.width + spacing_x

          # Переходим к следующему узлу
          next_node_name = current_node.next_node ? current_node.next_node.to_s : nil
          break unless next_node_name && @nodes[next_node_name]?

          current_node = @nodes[next_node_name]
        end

        # Размещаем оставшиеся узлы, которые не связаны с основной цепочкой
        remaining_nodes = @nodes.values.reject { |n| visited.includes?(n.name) }
        max_main_height = visited.map { |name| @nodes[name]? }.compact.map(&.height).max? || 120

        remaining_nodes.each_with_index do |node, index|
          node.x = x_offset + index * (node.width + spacing_x)
          node.y = y_offset + max_main_height + 80 # Ниже основной цепочки
        end
      end

      def to_svg(active_nodes : Set(String) = Set(String).new,
                 pipeline_running : Bool = false,
                 node_statuses : Hash(String, String) = {} of String => String) : String
        calculate_layout

        svg_width = @nodes.values.map { |node| node.x + node.width }.max + 30
        svg_height = @nodes.values.map { |node| node.y + node.height }.max + 30

        svg = <<-SVG
          <?xml version="1.0" encoding="UTF-8"?>
          <svg width="#{svg_width}" height="#{svg_height}" xmlns="http://www.w3.org/2000/svg">
            <defs>
              <style>
                .node-rect {
                  fill: #{colors[name]? || "#f8f9fa"};
                  stroke: #2C3E50;
                  stroke-width: 1;
                }
                .node-rect-running {
                  fill: #80c7ff;
                  stroke: #0a58ca;
                  stroke-width: 3;
                  filter: drop-shadow(3px 3px 6px rgba(13,110,253,0.4));
                }
                .node-rect-completed {
                  fill: #fff3cd;
                  stroke: #FFA500;
                  stroke-width: 2;
                  filter: drop-shadow(2px 2px 4px rgba(255,215,0,0.3));
                }
                .node-text {
                  fill: #000000;
                  font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
                  font-size: 18px;
                  font-weight: bold;
                  text-anchor: middle;
                }
                .node-text-running {
                  fill: #000000;
                  font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
                  font-size: 18px;
                  font-weight: bold;
                  text-anchor: middle;
                }
                .node-text-completed {
                  fill: #000000;
                  font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
                  font-size: 18px;
                  font-weight: bold;
                  text-anchor: middle;
                }
                .node-desc {
                  fill: #000000;
                  font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
                  font-size: 12px;
                  text-anchor: middle;
                }
                .node-desc-running {
                  fill: #000000;
                  font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
                  font-size: 12px;
                  font-weight: bold;
                  text-anchor: middle;
                }
                .node-desc-completed {
                  fill: #000000;
                  font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
                  font-size: 12px;
                  font-weight: bold;
                  text-anchor: middle;
                }
                .job-text {
                  fill: #000000;
                  font-family: 'Consolas', 'Monaco', monospace;
                  font-size: 10px;
                  text-anchor: start;
                }
                .job-text-running {
                  fill: #000000;
                  font-family: 'Consolas', 'Monaco', monospace;
                  font-size: 10px;
                  font-weight: bold;
                  text-anchor: start;
                }
                .job-text-completed {
                  fill: #000000;
                  font-family: 'Consolas', 'Monaco', monospace;
                  font-size: 10px;
                  font-weight: bold;
                  text-anchor: start;
                }
                .separator-line {
                  stroke: #000;
                  stroke-width: 2;
                  opacity: 1;
                }
                .separator-line-running {
                  stroke: #000;
                  stroke-width: 2;
                  opacity: 1;
                }
                .separator-line-completed {
                  stroke: #000;
                  stroke-width: 2;
                  opacity: 1;
                }
                .edge {
                  stroke: #34495E;
                  stroke-width: 3;
                  marker-end: url(#arrowhead);
                }
                .edge-active {
                  stroke: #0d6efd;
                  stroke-width: 4;
                  marker-end: url(#arrowhead-active);
                }
              </style>
              <marker id="arrowhead" markerWidth="6" markerHeight="4"
               refX="5" refY="2" orient="auto">
                <polygon points="0 0, 6 2, 0 4" fill="#34495E" />
              </marker>
              <marker id="arrowhead-active" markerWidth="6" markerHeight="4"
               refX="5" refY="2" orient="auto">
                <polygon points="0 0, 6 2, 0 4" fill="#0d6efd" />
              </marker>
            </defs>
        SVG

        # Рисуем связи между узлами
        @nodes.each_value do |node|
          next unless node.next_node

          next_node = @nodes[node.next_node.to_s]?
          next unless next_node

          from_x = node.x + node.width # правый край узла
          from_y = node.y + (node.height // 2) # центр по вертикали
          to_x = next_node.x # левый край следующего узла
          to_y = next_node.y + (next_node.height // 2) # центр по вертикали

          # Определяем, активна ли связь (если пайплайн запущен И один из узлов активен)
          is_edge_active = pipeline_running && (active_nodes.includes?(node.id) || active_nodes.includes?(next_node.id))
          edge_class = is_edge_active ? "edge-active" : "edge"

          svg += <<-SVG
            <line x1="#{from_x}" y1="#{from_y}" x2="#{to_x}" y2="#{to_y}" class="#{edge_class}" />
          SVG
        end

        # Рисуем узлы
        @nodes.each_value do |node|
          # Определяем статус узла из node_statuses, если он есть
          node_status = node_statuses[node.id]? || (active_nodes.includes?(node.id) ? "completed" : "pending")

          # Определяем классы на основе статуса
          case node_status
          when "running"
            rect_class = "node-rect-running"
            text_class = "node-text-running"
            desc_class = "node-desc-running"
            job_text_class = "job-text-running"
            separator_class = "separator-line-running"
          when "completed"
            rect_class = "node-rect-completed"
            text_class = "node-text-completed"
            desc_class = "node-desc-completed"
            job_text_class = "job-text-completed"
            separator_class = "separator-line-completed"
          else
            rect_class = "node-rect"
            text_class = "node-text"
            desc_class = "node-desc"
            job_text_class = "job-text"
            separator_class = "separator-line"
          end

          svg += <<-SVG
            <rect x="#{node.x}" y="#{node.y}" width="#{node.width}" height="#{node.height}" rx="25" ry="25" class="#{rect_class}" />
          SVG

          # Название узла
          text_x = node.x + (node.width // 2)
          text_y = node.y + 22
          svg += <<-SVG
            <text x="#{text_x}" y="#{text_y}" class="#{text_class}">#{node.name}</text>
          SVG

          # Описание узла (многострочный текст)
          current_y = text_y + 18
          if node.description && !node.description.not_nil!.empty?
            # Вычисляем максимальную длину строки на основе ширины узла
            max_chars_per_line = (node.width - 40) // 6

            words = node.description.not_nil!.split(" ")
            lines = [] of String
            current_line = ""

            words.each do |word|
              test_line = current_line.empty? ? word : "#{current_line} #{word}"
              if test_line.size > max_chars_per_line
                lines << current_line unless current_line.empty?
                current_line = word
              else
                current_line = test_line
              end
            end
            lines << current_line unless current_line.empty?

            lines.each_with_index do |line, index|
              desc_y = current_y + (index * 14)
              svg += <<-SVG
                <text x="#{text_x}" y="#{desc_y}" class="#{desc_class}">#{line}</text>
              SVG
            end
            current_y += lines.size * 14
          end

          # Список джобов
          next unless node.jobs && !node.jobs.empty?

          # Горизонтальная разделительная линия
          current_y += 4 # уменьшенный отступ перед линией
          line_x1 = node.x + 15 # отступ от левого края
          line_x2 = node.x + node.width - 15 # отступ от правого края
          svg += <<-SVG
            <line x1="#{line_x1}" y1="#{current_y}" x2="#{line_x2}" y2="#{current_y}" class="#{separator_class}" />
          SVG

          current_y += 14 # уменьшенный отступ после линии
          job_x = node.x + 15 # уменьшенный отступ от левого края узла
          node.jobs.each_with_index do |job, index|
            job_y = current_y + (index * 12)
            svg += <<-SVG
              <text x="#{job_x}" y="#{job_y}" class="#{job_text_class}">• #{job}</text>
            SVG
          end
        end

        svg += "</svg>"
        svg
      end

      def get_title(pipeline_running : Bool = false) : String
        "#{name} Pipeline#{pipeline_running ? "" : " - не запущен"}"
      end
    end

    class Collector
      def self.collect_pipelines : Hash(String, Pipeline)
        pipelines = {} of String => Pipeline

        # Собираем все зарегистрированные узлы
        all_nodes = PipelineDslExtension.node_registry

        # Группируем узлы по модулям
        nodes_by_module = all_nodes.keys.group_by { |key| key.split("::").first }

        # Для каждого модуля ищем корневые узлы (заканчиваются на RootNode)
        nodes_by_module.each do |module_name, module_node_keys|
          # Находим все корневые узлы в этом модуле
          root_keys = module_node_keys.select { |key| key.ends_with?("RootNode") }

          root_keys.each do |root_node_key|
            # Определяем pipeline_id на основе имени корневого узла
            node_name = root_node_key.split("::").last
            pipeline_id = determine_pipeline_id(module_name, node_name)
            pipeline_display_name = determine_pipeline_display_name(module_name, node_name)

            # Создаем пайплайн
            pipeline = Pipeline.new(pipeline_display_name)

            # Собираем все узлы для этого пайплайна, следуя по цепочке next_node
            collect_pipeline_nodes(pipeline, root_node_key, all_nodes, pipeline_id)

            # Добавляем в результат если есть узлы
            pipelines[pipeline_id] = pipeline unless pipeline.nodes.empty?
          end
        end

        pipelines
      end

      def self.determine_pipeline_id(module_name : String, root_node_name : String) : String
        # Определяем уникальный ID для пайплайна
        case root_node_name
        when "RootNode"
          underscore(module_name)
        when "PriorityFrequentRootNode"
          "#{underscore(module_name)}_priority_frequent"
        when "PriorityRareRootNode"
          "#{underscore(module_name)}_priority_rare"
        else
          # Для других корневых узлов создаем ID на основе имени
          suffix = root_node_name.gsub("RootNode", "")
          "#{underscore(module_name)}_#{suffix.gsub(/([A-Z])/) { |_c| "_#{$0}" }.downcase.sub(/\A_/, "")}"
        end
      end

      def self.underscore(string : String) : String
        ::Kiq::Pipeline.underscore(string)
      end

      def self.determine_pipeline_display_name(module_name : String, root_node_name : String) : String
        # Определяем отображаемое имя для пайплайна
        case root_node_name
        when "RootNode"
          module_name
        when "PriorityFrequentRootNode"
          "#{module_name}::PriorityFrequent"
        when "PriorityRareRootNode"
          "#{module_name}::PriorityRare"
        else
          # Для других корневых узлов создаем имя на основе имени узла
          suffix = root_node_name.gsub("RootNode", "")
          "#{module_name}::#{suffix}"
        end
      end

      def self.collect_pipeline_nodes(pipeline : Pipeline, current_node_key : String,
                                      all_nodes : Hash(String, PipelineDslExtension::NodeMetadata),
                                      pipeline_id : String) : Nil
        visited = Set(String).new
        current_key : String? = current_node_key

        while current_key && !visited.includes?(current_key)
          visited.add(current_key)

          # Получаем метаданные узла
          metadata = all_nodes[current_key]?
          break unless metadata

          # Извлекаем имя узла и модуль
          node_name = current_key.split("::").last
          module_name = current_key.split("::")[0..-2].join("::")
          module_name = current_key.split("::").first if module_name.empty?

          # Добавляем узел в пайплайн
          # Используем pipeline_id в качестве module_name для правильной идентификации
          pipeline.add_node(
            node_name,
            metadata.description,
            metadata.next_node,
            pipeline_id, # Используем pipeline_id вместо module_name
            metadata.jobs
          )

          # Переходим к следующему узлу
          next_node_name = metadata.next_node
          break unless next_node_name

          # Ищем следующий узел в том же модуле
          current_key = all_nodes.keys.find do |key|
            prefix = current_key.not_nil!.split("::").first
            key.starts_with?("#{prefix}::") &&
              key.ends_with?("::#{next_node_name}")
          end
        end
      end
    end
  end
end
