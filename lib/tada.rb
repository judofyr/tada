require "minitest"
require "set"

module Tada
  autoload :VERSION, __dir__ + "/tada/version.rb"

  class Step
    attr_reader :options

    include Minitest::Assertions
    attr_accessor :assertions

    def initialize(**options, &block)
      @options = options
      @block = block
      @assertions = 0
    end

    def call(context)
      raise LocalJumpError, "block required for step #{inspect}" if !@block
      instance_exec(context, &@block)
    end
  end

  class Context
    def initialize(data = {})
      @data = data
    end

    def [](key, &blk)
      @data.fetch(key, &blk)
    end

    def []=(key, value)
      @data[key] = value
    end

    def copy
      self.class.new(@data.dup)
    end
  end

  class ChainedStep < Step
    def call(context)
      options.fetch(:children).each do |child|
        child.call(context)
      end
    end
  end

  def self.chain(*steps)
    steps = steps.flat_map do |step|
      if step.is_a?(ChainedStep)
        step.options[:children]
      else
        [step]
      end
    end

    case steps.size
    when 0
      raise ArgumentError, "at least one argument required"
    when 1
      steps[0]
    else
      ChainedStep.new(children: steps)
    end
  end

  def self.annotate_labels(**labels)
    if !labels[:__location]
      labels[:__location] = caller_locations(2, 1)[0]
    end
    labels
  end

  class Suite
    attr_reader :labels, :children

    Test = Struct.new(:labels, :step)
    AroundSuite = Struct.new(:suite, :block) do
      def labels
        suite.labels
      end
    end

    def initialize(labels = {})
      @labels = labels
      @children = []
      @helper_locations = Set.new
    end

    def test(name, step, **labels)
      labels = Tada.annotate_labels(name: name, **labels)
      @children << Test.new(labels, step)
    end

    def with_around(**labels, &blk)
      raise ArgumentError, "block required" if !block_given?
      child = Suite.new(Tada.annotate_labels(**labels))
      @children << AroundSuite.new(child, blk)
      child
    end

    def with_before(**labels)
      with_around(**Tada.annotate_labels(**labels)) { |child| Tada.chain(yield, child) }
    end

    def with_after(**labels)
      with_around(**Tada.annotate_labels(**labels)) { |child| Tada.chain(child, yield) }
    end
  end

  class Runner
    attr_accessor :file_filter
    attr_accessor :seed

    def initialize(suite, formatter)
      @suite = suite
      @formatter = formatter
      @seed = 0
    end

    def run(context = Context.new)
      begin
        prev_seed = srand(@seed)
        executables = gather_executables(@suite)
      ensure
        srand(prev_seed)
      end

      @formatter.prepare_execution(executables)
      run_executables(executables, context)
    end

    AroundExecution = Struct.new(:children, :block, :suite) do
      def labels
        suite.labels
      end
    end

    def should_run_test?(test)
      if file_filter && loc = test.labels[:__location]
        if file_filter.none? { |file| loc.absolute_path == file }
          return false
        end
      end

      return true
    end

    def gather_executables(suite)
      executables = []

      # First produce a consistent order:
      children = suite.children.sort_by do |child|
        if loc = child.labels[:__location]
          loc.absolute_path
        else
          child.labels[:name].to_s
        end
      end

      # … and then we shuffle
      children.shuffle!

      children.each do |child|
        case child
        when Suite::Test
          next if !should_run_test?(child)
          executables << child
        when Suite::AroundSuite
          children = gather_executables(child.suite)
          if children.any?
            executables << AroundExecution.new(children, child.block, child.suite)
          end
        end
      end

      executables
    end

    def run_executables(executables, context)
      executables.each do |exe|
        child_context = context.copy

        case exe
        when Suite::Test
          @formatter.run_test(exe) do
            exe.step.call(child_context)
          end
        when AroundExecution
          inner = proc do |context|
            @formatter.run_children(exe.suite) do
              run_executables(exe.children, context)
            end
          end

          step = exe.block.call(inner)
          @formatter.run_suite(exe.suite) do
            step.call(child_context)
          end
        end
      end
    end
  end

  class ConsoleFormatter
    def initialize(output = $stderr, color: nil)
      @output = output
      if color.nil?
        if ENV["NO_COLOR"]
          color = false
        elsif ENV["COLOR"]
          color = true
        else
          color = @output.tty?
        end
      end
      @color = color

      @indent = 0
      @pwd = Pathname.new(Dir.pwd)
      @total = 0
      @completed = 0

      @ignore_paths = [File.expand_path(__FILE__)]
    end

    def format(str, bold: false, red: false)
      return str if !@color
      result = String.new
      result << "\e[1m" if bold
      result << "\e[31m" if red
      result << str
      result << "\e[0m"
    end

    def count_executables(executables)
      executables.each do |exe|
        @total += 1
        if exe.is_a?(Runner::AroundExecution)
          count_executables(exe.children)
        end
      end
    end

    def prepare_execution(executables)
      count_executables(executables)
      @col_size = @total.to_s.size
    end

    def indent_space
      "  " * @indent
    end

    def name_for(labels, fallback)
      if name = labels[:name]
        return name
      end

      if loc = labels[:__location]
        rel_path = Pathname(loc.absolute_path).relative_path_from(@pwd).to_s
        return "#{rel_path}:#{loc.lineno}"
      end

      fallback
    end

    def progress
      "[#{(@completed + 1).to_s.rjust(@col_size)}/#{@total}]"
    end

    def should_ignore_path?(path)
      @ignore_paths.any? do |ignore_path|
        path == ignore_path
      end
    end

    def error_handler(err, name, loc)
      @output.puts format("Error occured", bold: true, red: true)
      @output.puts "  #{format("Name:", bold: true)} #{name}"
      @output.puts "  #{format("File:", bold: true)} #{loc ? "#{loc.absolute_path}:#{loc.lineno}" : "<unknown>"}"
      @output.puts "  #{format("Error:", bold: true)} #{err.class}"
      @output.puts err.message
      @output.puts "  #{format("Backtrace:", bold: true)}"
      if err.backtrace_locations
        # For some reason this is sometimes `nil`
        err.backtrace_locations.each do |loc|
          if should_ignore_path?(loc.absolute_path)
            next
          end
          @output.puts(loc)
        end
      else
        err.backtrace.each do |line|
          filename = line[/^(.*?):\d+:in/, 1]
          if filename && should_ignore_path?(filename)
            next
          end
          @output.puts(line)
        end
      end
      exit 1
    end

    def run_test(test)
      name = name_for(test.labels, "test")
      @output.puts "#{progress} #{indent_space} #{name}"
      @completed += 1
      yield
    rescue Exception => err
      loc = test.labels[:__location]
      error_handler(err, name, loc)
    end

    def run_suite(suite)
      name = name_for(suite.labels, "suite")
      @output.puts "#{progress} #{indent_space} #{name}"
      @indent += 1
      @completed += 1
      yield
    rescue SystemExit
      raise
    rescue Exception => err
      loc = suite.labels[:__location]
      error_handler(err, name, loc)
    ensure
      @indent -= 1
    end

    def run_children(suite)
      yield
    end
  end
end
