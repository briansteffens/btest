require "json"
require "dir"
require "yaml"
require "colorize"
require "io/memory"

# TODO: access File.SEPARATOR_STRING ?
SEPARATOR_STRING = {% if flag?(:windows) %} "\\" {% else %} "/" {% end %}

SUITE_EXTENSION = ".btest"

CONFIG_FN = "btest.yaml"

EXIT_CONFIG_MISSING = 1
EXIT_TEST_PATH_MISSING = 2

MAX_THREADS = 4

class Runner
  YAML.mapping(
    name: {type: String},
    setup: {type: Array(String), default: [] of String},
    run: {type: String},
  )
end

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

if !File.exists?(CONFIG_FN)
  puts "No configuration file found. Create '#{CONFIG_FN}' and try again."
  Process.exit(EXIT_CONFIG_MISSING)
end

config = Config.from_yaml(File.read(CONFIG_FN))

if !Dir.exists?(config.test_path)
  puts "Test path '#{config.test_path}' doesn't exist."
  Process.exit(EXIT_TEST_PATH_MISSING)
end


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

  def run(runner_name : String) : Array(Result)
    runner = @config.runner(runner_name)

    ret = [] of Result

    @cases.each do |c|
      ret << c.run(runner)
    end

    ret
  end

  def has_runner?(runner_name : String) : Bool
    @runners.each do |name|
      return true if name == runner_name
    end

    false
  end
end


class Result
  def initialize(runner : Runner, testCase : Case, pass : Bool,
                 message : String)
    @runner = runner
    @testCase = testCase
    @pass = pass
    @message = message
  end

  def self.pass(runner : Runner, testCase : Case)
    Result.new(runner, testCase, true, "")
  end

  def self.fail(runner : Runner, testCase : Case, command : String,
                status_code : Int32, stdout : IO, stderr : IO)
    Result.new(runner, testCase, false,
            "Error running: #{command}\n" \
            "Status code: #{status_code}\n" \
            "Standard output: #{stdout.gets_to_end}\n" \
            "Standard error: #{stderr.gets_to_end}\n")
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
    pass = @pass ? "PASS".colorize(:green) : "FAIL".colorize(:red)
    "#{@testCase.suite.name} - #{@testCase.name} - #{pass}"
  end
end


class Case
  def initialize(suite : Suite, data)
    @suite = suite
    @name = nil
    @expect = Hash(String, String).new
    @arguments = Hash(String, String).new

    data.each do |key, value|
      if key == "name"
        @name = value.as(String)
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
      !Process.run("rm -r #{work_path}", nil, shell: true).success?
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

      File.write(File.join([work_path, fn]), output)
    end

    # Run any pre-test setup
    runner.setup.each do |cmd|
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      res = Process.run(cmd, nil, shell: true, output: stdout, error: stderr)

      if !res.success?
        return Result.fail(runner, self, cmd, res.exit_code, stdout, stderr)
      end
    end

    # Run the test case
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    res = Process.run(runner.run, nil, shell: true, output: stdout,
                      error: stderr)
    if !res.success?
      return Result.fail(runner, self, runner.run, res.exit_code, stdout,
                         stderr)
    end

    Result.pass(runner, self)
  end
end


# Recursively find *.btest files in the given path
def find_suites(config : Config, current_path : String)
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

suites = find_suites(config, config.test_path)
config.runners.each do |runner|
  suites.each do |suite|
    next if !suite.has_runner?(runner.name)

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
      puts channel.receive.render
      running -= 1
    end

    running.times do |_|
      puts channel.receive.render
    end
  end
end
