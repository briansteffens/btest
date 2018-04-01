require "json"
require "yaml"
require "colorize"
require "option_parser"

CONFIG_FN = "btest.yaml"

EXIT_TESTS_FAILED      = 1
EXIT_CONFIG_MISSING    = 2
EXIT_TEST_PATH_MISSING = 3

# TODO: access File.SEPARATOR_STRING ?
SEPARATOR_STRING = {% if flag?(:windows) %} "\\" {% else %} "/" {% end %}

# From https://github.com/crystal-lang/crystal/issues/2061
module I::Terminal
  lib C
    struct Winsize
      ws_row : UInt16    # rows, in characters */
      ws_col : UInt16    # columns, in characters */
      ws_xpixel : UInt16 # horizontal size, pixels
      ws_ypixel : UInt16 # vertical size, pixels
    end

    fun ioctl(fd : Int32, request : UInt32, winsize : C::Winsize*) : Int32
  end

  def self.get_terminal_size
    C.ioctl(0, 21523, out screen_size) # magic number
    screen_size
  end
end

TERMINAL_WIDTH = I::Terminal.get_terminal_size.ws_col

# A runner defines the way that a test case is run. Multiple runners can be
# used to run the same test case with multiple compilers/assemblers/etc.
class Runner
  YAML.mapping(
    name: {type: String},
    setup: {type: Array(String), default: [] of String},
    run: {type: String},
  )
end

# This controls the per-project configuration for btest
class Config
  YAML.mapping(
    suite_extension: {type: String, default: ".yaml"},
    test_path: {type: String, default: "tests"},
    work_path: {type: String, default: ".btest"},
    runners: {type: Array(Runner), default: [] of Runner},
  )

  def runner(name)
    @runners.each do |r|
      return r if r.name == name
    end

    raise Exception.new("Runner #{name} not found")
  end
end

# A collection of test cases and the list of runners which those test cases
# should be run with.
class Suite
  getter config, path, name, cases, runners, templates

  def initialize(@config : Config, path : String)
    @name = Suite.path_to_name(config, path)

    begin
      file = YAML.parse(File.read(path))
    rescue ex
      puts "Error parsing YAML file: #{path}"
      raise ex
    end

    @runners = Array(String).new
    if file["runners"]?
      file["runners"].each do |runner|
        @runners << runner.as_s
      end
    end

    if @runners.size == 0
      config.runners.each do |runner|
        @runners << runner.name
      end
    end

    @templates = Hash(String, String).new
    file["templates"].each do |template|
      template.each do |filename, contents|
        @templates[filename.as_s] = contents.as_s
      end
    end

    @cases = Array(Case).new
    file["cases"].each do |c|
      @cases << Case.new(self, c.as_h)
    end
  end

  # Convert a path to a btest file into a name for the suite it represents
  def self.path_to_name(config : Config, path) : String
    if !path.starts_with?(config.test_path)
      raise Exception.new("Test suite not inside the test path")
    end

    path = path[config.test_path.size..-1]

    if path.starts_with?(SEPARATOR_STRING)
      path = path[SEPARATOR_STRING.size..-1]
    end

    if !path.ends_with?(config.suite_extension)
      raise Exception.new(
        "Test suite file doesn't end in #{config.suite_extension}")
    end

    path.chomp(config.suite_extension)
  end

  # Load a suite by name
  def self.load_suite(config : Config, name : String)
    path = File.join([config.test_path, name]) + config.suite_extension

    if !File.exists?(path)
      raise Exception.new("Suite not found at #{path}")
    end

    return Suite.new(config, path)
  end

  # Recursively find *.btest files in the given path
  def self.find_suites(config : Config, current_path : String = "")
    current_path = config.test_path if current_path == ""

    ret = [] of Suite

    Dir.entries(current_path).each do |entry|
      next if entry == "." || entry == ".."

      path = File.join([current_path, entry])

      # Found a test file
      if path.ends_with?(config.suite_extension)
        ret << Suite.new(config, path)
        next
      end

      next if !File.directory?(path)

      # Found a directory: search it
      ret += find_suites(config, path)
    end

    ret
  end
end

# A test case, which takes a list of template arguments and applies those to
# the suite's template files to setup a test environment ready for a runner to
# execute and check for results like process status code and stdout.
class Case
  getter suite, name, args, expect, arguments

  def initialize(@suite : Suite, data)
    @name = ""
    @args = ""
    @expect = Hash(String, String).new
    @arguments = Hash(String, String).new

    data.each do |key, value|
      if key == "name"
        @name = value.to_s
        next
      end

      if key == "args"
        @args = value.to_s
        next
      end

      if ["status", "stdout", "stdout_contains"].includes? key
        @expect[key.to_s] = value.to_s
        next
      end

      @arguments[key.to_s] = value.to_s
    end

    raise Exception.new("Each test case requires a name") if !@name
  end

  def run(runner : Runner) : Result
    # Generate the working path for this test run
    # TODO: there are probably more characters that need to be replaced
    name_path = @name.as(String).gsub(" ", "_")
    work_path = File.join([@suite.config.work_path, @suite.name, runner.name,
                           name_path])

    # Delete any previous working directory
    if Dir.exists?(work_path) && \
          !Process.run("rm -r \"#{work_path}\"", nil, shell: true).success?
      raise Exception.new("Unable to delete work_path (#{work_path})")
    end

    # Create the working directory
    Dir.mkdir_p(work_path)

    # Render templates
    @suite.templates.each do |fn, contents|
      output = contents

      @arguments.each do |key, value|
        output = output.gsub("{{ #{key} }}", value)
      end

      File.write(File.join([work_path, fn]), output + "\n")
    end

    # Run any pre-test setup
    runner.setup.each do |cmd|
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      cmd2 = "cd \"#{work_path}\" && #{cmd}"

      res = Process.run(cmd2, nil, shell: true, output: stdout, error: stderr)

      if !res.success?
        Result.new(runner, self, false,
          "Error running: #{cmd2}\n" \
          "Status code: #{res.exit_code}\n" \
          "Standard output: #{stdout.to_s}\n" \
          "Standard error: #{stderr.to_s}\n")
      end
    end

    # Run the test case
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    run_cmd = "cd \"#{work_path}\" && #{runner.run}"

    run_cmd += " #{args}" if args

    res = Process.run(run_cmd, nil, shell: true, output: stdout,
      error: stderr)

    validation_errors = ""

    if @expect.has_key?("status")
      expected_status = @expect["status"]
      if expected_status != res.exit_code.to_s
        validation_errors += "Expected status code #{expected_status} " \
                             "but got #{res.exit_code}\n"
      end
    end

    has_stdout = @expect.has_key?("stdout")
    has_stdout_contains = @expect.has_key?("stdout_contains")
    check_stdout = has_stdout || has_stdout_contains

    if check_stdout
      expected_stdout = @expect[has_stdout ? "stdout" : "stdout_contains"]
      actual_stdout = stdout.to_s.strip

      pass = has_stdout && expected_stdout == actual_stdout ||
             has_stdout_contains && actual_stdout.includes? expected_stdout

      unless pass
        validation_errors += "Expected stdout [#{expected_stdout}] " \
                             "but got [#{actual_stdout}]\n"
      end
    end

    if validation_errors.size > 0
      return Result.new(runner, self, false,
        validation_errors + "\nstdout: #{stdout}\nstderr: #{stderr}")
    end

    Result.new(runner, self, true, "")
  end
end

class Result
  getter testCase, pass, message

  def initialize(@runner : Runner, @testCase : Case, @pass : Bool,
                 @message : String)
  end

  def render
    name = @testCase.name.as(String)

    uncolored_len = @testCase.suite.name.size + 1 + @runner.name.size + 1 + \
      name.size

  # Chop the output if the name is too long
  chop_delta = uncolored_len - (TERMINAL_WIDTH - 7)
  if chop_delta > 0
    name = name[0..name.size - chop_delta]
    uncolored_len -= chop_delta - 1
  end

  suite = "#{@testCase.suite.name}".colorize(:white)
  runner = "#{@runner.name}".colorize(:dark_gray)
  ret = "#{runner} #{suite} #{name}"

  # Add dots to fill the terminal horizontally
  dots = ""
  (TERMINAL_WIDTH - 6 - uncolored_len).times do |_|
    dots += "."
  end
  ret += "#{dots.colorize(:dark_gray)}"

  # Add the pass/fail indicator
  pass = @pass ? "PASS".colorize(:green) : "FAIL".colorize(:red)
  puts(ret + "[#{pass}]")

  return if @pass

  # Show failure information
  puts(("      " + @message.gsub("\n", "\n      ")).colorize(:dark_gray))
  end
end

if !File.exists?(CONFIG_FN)
  puts "No configuration file found. Create '#{CONFIG_FN}' and try again."
  Process.exit(EXIT_CONFIG_MISSING)
end

config = Config.from_yaml(File.read(CONFIG_FN))

if !Dir.exists?(config.test_path)
  puts "Test path '#{config.test_path}' doesn't exist."
  Process.exit(EXIT_TEST_PATH_MISSING)
end

arg_threads = 1
arg_suite = nil

OptionParser.parse! do |parser|
  parser.banner = "Usage: btest [arguments]"
  parser.on("-s SUITE", "--suite", "Run only this suite") { |s|
    arg_suite = s
  }
  parser.on("-j THREADS", "--threads", "Use this many threads") { |t|
    arg_threads = t.to_i64
  }
  parser.on("-h", "--help", "Show this help") {
    puts parser; Process.exit(0)
  }
end

if arg_suite
  suites = [Suite.load_suite(config, arg_suite.as(String))]
else
  suites = Suite.find_suites(config)
end

suites.sort! do |a, b|
  a.name <=> b.name
end

channel = Channel(Result).new
running = 0
tests_passed = 0
tests_total = 0

suites.each do |suite|
  suite.runners.each do |runner_name|
    runner = config.runner(runner_name)

    suite.cases.each do |cs|
      proc = ->(c : Case) do
        spawn do
          channel.send(c.run(runner))
        end
      end

      proc.call(cs)
      running += 1

      next if running < arg_threads

      # Using max threads, wait for one to finish
      res = channel.receive
      res.render
      tests_total += 1
      tests_passed += 1 if res.pass
      running -= 1
    end
  end
end

# Wait for any threads still running
running.times do |_|
  res = channel.receive
  res.render
  tests_total += 1
  tests_passed += 1 if res.pass
end

puts "#{tests_passed}/#{tests_total} tests passed"

Process.exit(EXIT_TESTS_FAILED) if tests_passed != tests_total
