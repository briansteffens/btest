require "json"
require "dir"
require "yaml"
require "colorize"
require "io/memory"

SUITE_EXTENSION = ".btest"

CONFIG_FN = "btest.yaml"

EXIT_CONFIG_MISSING = 1
EXIT_TEST_PATH_MISSING = 2

MAX_THREADS = 1

# TODO: access File.SEPARATOR_STRING ?
SEPARATOR_STRING = {% if flag?(:windows) %} "\\" {% else %} "/" {% end %}

# From https://github.com/crystal-lang/crystal/issues/2061
module I::Terminal
  lib C
    struct Winsize
      ws_row : UInt16         # rows, in characters */
      ws_col : UInt16         # columns, in characters */
      ws_xpixel : UInt16      # horizontal size, pixels
      ws_ypixel : UInt16      # vertical size, pixels
    end
    fun ioctl(fd : Int32, request : UInt32, winsize : C::Winsize*) : Int32
  end

  def self.get_terminal_size()
    C.ioctl(0, 21523, out screen_size)      # magic number
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
  def initialize(config : Config, path : String)
    @config = config
    @name = Suite.path_to_name(config.test_path, path)

    file = YAML.parse(File.read(path))

    @runners = Array(String).new
    file["runners"].each do |runner|
      @runners << runner.as_s
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

  def config
    @config
  end

  def path
    @path
  end

  def name
    @name
  end

  def cases
    @cases
  end

  def runners
    @runners
  end

  def templates
    @templates
  end

  # Convert a path to a btest file into a name for the suite it represents
  def self.path_to_name(test_base_path, path) : String
    if !path.starts_with?(test_base_path)
      raise Exception.new("Test suite not inside the test path")
    end

    path = path[test_base_path.size..-1]

    if path.starts_with?(SEPARATOR_STRING)
      path = path[SEPARATOR_STRING.size..-1]
    end

    if !path.ends_with?(SUITE_EXTENSION)
      raise Exception.new("Test suite file doesn't end in #{SUITE_EXTENSION}")
    end

    path.chomp(SUITE_EXTENSION)
  end

  # Recursively find *.btest files in the given path
  def self.find_suites(config : Config, current_path : String = "")
    current_path = config.test_path if current_path == ""

    ret = [] of Suite

    Dir.entries(current_path).each do |entry|
      next if entry == "." || entry == ".."

      path = File.join([current_path, entry])

      # Found a test file
      if path.ends_with?(SUITE_EXTENSION)
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
  def initialize(suite : Suite, data)
    @suite = suite
    @name = nil
    @args = nil
    @expect = Hash(String, String).new
    @arguments = Hash(String, String).new

    data.each do |key, value|
      if key == "name"
        @name = value.as(String)
        next
      end

      if key == "args"
        @args = value.as(String)
        next
      end

      if key == "status"
        @expect["status"] = value.as(String)
        next
      end

      if key == "stdout"
        @expect["stdout"] = value.as(String)
        next
      end

      @arguments[key.as(String)] = value.as(String)
    end

    if !@name
      raise Exception.new("Each test case requires a name")
    end
  end

  def suite
    @suite
  end

  def name
    @name
  end

  def args
    @args
  end

  def expect
    @expect
  end

  def arguments
    @arguments
  end

  def run(runner : Runner) : Result
    # Generate the working path for this test run
    # TODO: there are probably more characters that need to be replaced
    name_path = @name.as(String).gsub(" ", "_")
    work_path = File.join([@suite.config.work_path, @suite.name, name_path])

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

    if args
      run_cmd += " #{args}"
    end

    res = Process.run(run_cmd, nil, shell: true, output: stdout,
                      error: stderr)

    # Validate the test case
    validation_errors = ""

    if @expect.has_key?("status")
      expected_status = @expect["status"]
      if expected_status != res.exit_code.to_s
        validation_errors += "Expected status code #{expected_status} " \
                             "but got #{res.exit_code}\n"
      end
    end

    if @expect.has_key?("stdout")
      expected_stdout = @expect["stdout"]
      actual_stdout = stdout.to_s.strip
      if expected_stdout != actual_stdout
        validation_errors += "Expected stdout [#{expected_stdout}] " \
                             "but got [#{actual_stdout}]\n"
      end
    end

    if validation_errors.size > 0
      return Result.new(runner, self, false, validation_errors)
    end

    Result.new(runner, self, true, "")
  end
end


# This is the result of a test case run with a particular runner.
class Result
  def initialize(runner : Runner, testCase : Case, pass : Bool,
                 message : String)
    @runner = runner
    @testCase = testCase
    @pass = pass
    @message = message
  end

  def testCase
    @testCase
  end

  def pass
    @pass
  end

  def message
    @message
  end

  def render
    ret = "    #{@testCase.name}"

    # Chop the output if the name is too long
    if ret.size > TERMINAL_WIDTH - 7
      ret = ret[0..TERMINAL_WIDTH - 7]
    end

    # Add dots to fill the terminal horizontally
    (TERMINAL_WIDTH - 6 - ret.size).times do |_|
      ret += "#{".".colorize(:dark_gray)}"
    end

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


Suite.find_suites(config).each do |suite|
  puts "#{suite.name}".colorize(:white)
  suite.runners.each do |runner_name|
    runner = config.runner(runner_name)

    puts "  #{runner.name}".colorize(:dark_gray)

    channel = Channel(Result).new
    running = 0

    suite.cases.each do |cs|
      proc = ->(c : Case) do
        spawn do
          channel.send(c.run(runner))
        end
      end
      proc.call(cs)
      running += 1
      next if running < MAX_THREADS
      channel.receive.render
      running -= 1
    end

    running.times do |_|
      channel.receive.render
    end
  end
end
