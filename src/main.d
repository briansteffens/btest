import core.atomic;
import std.algorithm;
import std.array;
import std.file;
import std.format;
import std.parallelism;
import std.path;
import std.process;
import std.range;
import std.stdio;
import std.typecons;

import mustache;
import dyaml;

alias Mustache = MustacheEngine!(string);

private const string DEFAULT_TEST_PATH = "tests";
private const string DEFAULT_TMP_ROOT = "/tmp/btest";
// Default to false until we synchronize output
private const bool DEFAULT_PARALLEL_RUNNERS = false;
private const bool DEFAULT_PARALLEL_TESTS = true;

private const string CONFIG_FILENAME = "btest.yaml";
private const string CONFIG_TEST_PATH = "test_path";
private const string CONFIG_TMP_ROOT = "tmp_root";
private const string CONFIG_RUNNERS = "runners";
private const string CONFIG_RUNNERS_NAME = "name";
private const string CONFIG_RUNNERS_SETUP = "setup";
private const string CONFIG_RUNNERS_RUN = "run";
private const string CONFIG_PARALLEL_TESTS = "parallelize_tests";
private const string CONFIG_PARALLEL_RUNNERS = "parallelize_runners";
private const string CONFIG_TEST_RUNNERS = "runners";
private const string CONFIG_TEST_CASES = "cases";
private const string CONFIG_TEST_TEMPLATES = "templates";
private const string CONFIG_TEST_CASES_STATUS = "status";
private const string CONFIG_TEST_CASES_STDOUT = "stdout";
private const string CONFIG_TEST_CASES_ARGS = "args";
private const string CONFIG_TEST_CASES_STDOUT_CONTAINS = "stdout_contains";
private const string CONFIG_TEST_CASES_NAME = "name";

private Node readConfig(string file) {
  return Loader(file).load();
}

private Node nodeGet(Node node, string key, Node def) {
  if (node.containsKey(key)) {
    return node[key];
  }

  return def;
}

auto exec(string cmdAndArgs, string dir) {
  return executeShell(cmdAndArgs, null, Config.none, ulong.max, dir);
}

private class TestCase {
  string testFile;
  string name;
  int expectedStatus;
  string[] argsToPass;
  string expectedStdout;
  string expectedStdoutContains;
  string[string] keyValues;
  string[string] templates;

  this(string testFile, string name, Node argsToPass, int expectedStatus,
       string expectedStdout, string expectedStdoutContains,
       string[string] keyValues, Node templates) {
    this.testFile = testFile;
    this.name = name;
    this.expectedStatus = expectedStatus;
    this.expectedStdout = expectedStdout;
    this.expectedStdoutContains = expectedStdoutContains;
    this.keyValues = keyValues;

    foreach (string arg; argsToPass) {
      this.argsToPass ~= arg;
    }

    Mustache mustache;
    auto ctx = new Mustache.Context;

    foreach (key, value; keyValues) {
      ctx[key] = value;
    }

    foreach (Node files; templates) {
      foreach (string fileName, string tmpl; files) {
        // Lovely hack to unsafe render everything backwards-compatibly
        auto unsafe = tmpl.replace("{{", "{{{").replace("}}", "}}}");
        this.templates[fileName] = mustache.renderString(unsafe, ctx);
      }
    }
  }
}

private class TestRunner {
  Context context;
  string name;
  string[] setup;
  string cmd;
  string[] tmpDirs;

  this(Context context, string name, string[] setup, string cmd) {
    this.context = context;
    this.name = name;
    this.setup = setup;
    this.cmd = cmd;
  }

  private string getTmpDir(string testFile) {
    int i;
    while (true) {
      string fileWithoutExt = testFile[0 ..  testFile.length - ".yaml".length];
      string tmpRoot = buildPath(context.tmpRoot, format("%d", i));
      string dir = buildPath(tmpRoot, name, fileWithoutExt);
      if (!exists(tmpRoot)) {
        tmpDirs ~= dir;
        mkdirRecurse(dir);
        return dir;
      }
      i++;
    }
  }

  TestCase[] loadCases(string testFile, Node config) {
    if (!config.containsKey(CONFIG_TEST_CASES)) {
      throw new Exception("No cases provided");
    }
    auto caseConfigs = config[CONFIG_TEST_CASES];

    if (!config.containsKey(CONFIG_TEST_TEMPLATES)) {
      throw new Exception("No templates provided");
    }
    auto templates = config[CONFIG_TEST_TEMPLATES];

    TestCase[] cases;
    foreach (Node config; caseConfigs) {
      string[string] keyValues;
      int expectedStatus = -1;
      Node argsToPass = Node(cast(Node[])[]);
      string expectedStdout, expectedStdoutContains, caseName;
      foreach (string key, Node value; config) {
        switch (key) {
        case CONFIG_TEST_CASES_ARGS:
          argsToPass = value;
          break;
        case CONFIG_TEST_CASES_STATUS:
          expectedStatus = value.as!int;
          break;
        case CONFIG_TEST_CASES_STDOUT:
          expectedStdout = value.as!string;
          break;
        case CONFIG_TEST_CASES_STDOUT_CONTAINS:
          expectedStdoutContains = value.as!string;
          break;
        case CONFIG_TEST_CASES_NAME:
          caseName = value.as!string;
          break;
        default:
          keyValues[key] = value.as!string;
        }
      }

      cases ~= new TestCase(testFile, caseName, argsToPass, expectedStatus,
                            expectedStdout, expectedStdoutContains, keyValues,
                            templates);
    }
    return cases;
  }

  TestCase[] buildTest(string testFile) {
    auto config = readConfig(testFile);

    bool shouldRun = true;
    if (config.containsKey(CONFIG_TEST_RUNNERS)) {
      shouldRun = false;
      foreach (string runner; config[CONFIG_TEST_RUNNERS]) {
        if (runner == this.name) {
          shouldRun = true;
        }
      }
    }

    if (!shouldRun) {
      return null;
    }

    try {
      return this.loadCases(testFile, config);
    } catch (Exception e) {
      e.msg = format("%s in %s", e.msg, testFile);
      throw e;
    }
  }

  auto run(TestCase[] cases) {
    auto testDir = this.getTmpDir(cases[0].testFile);

    int passed;
    int total;

    foreach (c; cases) {
      total++;

      foreach (file, tmpl; c.templates) {
        std.file.write(buildPath(testDir, file), tmpl);
      }

      auto ok = true;
      Tuple!(int,"status",string,"output") process;

      foreach (setupStep; this.setup) {
        process = exec(setupStep, testDir);
        if (process.status) {
          ok = false;
        }
      }

      if (ok) {
        process = exec(([this.cmd] ~ c.argsToPass).join(" "), testDir);

        if (c.expectedStatus != -1) {
          ok = ok && process.status == c.expectedStatus;
        }

        if (c.expectedStdout) {
          ok = ok && process.output == c.expectedStdout;
        }

        if (c.expectedStdoutContains) {
          ok = ok && process.output.canFind(c.expectedStdoutContains);
        }
      }

      writeln(c.testFile);
      writeln(format("[%s] %s",
                     ok ? "PASS" : "FAIL",
                     c.name));

      if (!ok) {
        writeln(format("Expected status code %d but got %s", c.expectedStatus, process.status));
        // The only high-level execute function in the D standard library, "execute",
        // mashes stderr and stdout together. Writing a proper "execute" that keeps
        // the streams separate would be a pain. This may do for now.
        writeln(format("Expected output [%s] but got [%s]", c.expectedStdout, process.output));
        write("\n");
        writeln("Output: ", process.output);
      } else {
        passed++;
      }

      write("\n");
    }

    return Tuple!(int, int)(passed, total);
  }

  void cleanup() {
    foreach (dir; tmpDirs) {
      if (exists(dir)) {
        rmdirRecurse(dir);
      }
    }
  }
}

private bool launchRunner(TestRunner runner) {
  shared int passed;
  shared int total;

  void handleFile(string testFile) {
    auto test = runner.buildTest(testFile);

    if (test !is null) {
      auto t = runner.run(test);
      atomicOp!("+=")(passed, t[0]);
      atomicOp!("+=")(total, t[1]);
    }
  }

  try {
    auto testFiles = runner.context.testFiles;
    if (runner.context.parallelize) {
      foreach (d; parallel(testFiles)) {
        handleFile(d);
      }
    } else {
      foreach (d; testFiles) {
        handleFile(d);
      }
    }

    writeln(format("%d of %d tests passed for runner: %s\n",
                   passed, total, runner.name));
    return passed == total;
  } finally {
    runner.cleanup();
  }
}

private int launchRunners(TestRunner[] runners, bool parallelize) {
  shared int passed;

  void handle(TestRunner runner) {
    auto allPassed = launchRunner(runner);
    atomicOp!("+=")(passed, allPassed ? 1 : 0);
  }

  if (parallelize) {
    foreach (runner; parallel(runners)) {
      handle(runner);
    }
  } else {
    foreach (runner; runners) {
      handle(runner);
    }
  }

  return passed;
}

private TestRunner[] loadRunners(Context context) {
  TestRunner[] runners;
  foreach (Node runnerSetting; context.runnerSettings) {
    string name = runnerSetting[CONFIG_RUNNERS_NAME].as!string;

    string[] setup;
    if (runnerSetting.containsKey(CONFIG_RUNNERS_SETUP)) {
      foreach (string setupStep; runnerSetting[CONFIG_RUNNERS_SETUP]) {
        setup ~= setupStep;
      }
    }

    string run = runnerSetting[CONFIG_RUNNERS_RUN].as!string;

    runners ~= new TestRunner(context, name, setup, run);
  }

  return runners;
}

class CommandLineArgs {
  string[] testNames;

  this(string[] args) {
    // Skip the first arg, it's the executable name.
    int index = 1;

    while (index < args.length) {
      const string head = args[index];
      const string[] tail = args[index+1..$];

      switch (head)
      {
        // -f test_name
        case "-f":
          if (tail.length == 0) {
            throw new Exception("Expected: a test name (no path or extension)");
          }
          testNames ~= tail[0];
          index++;
          break;
        default:
          throw new Exception(format("Unrecognized command line option %s", head));
      }

      index++;
    }
  }
}

// Combines a config file with command line arguments to produce all of the
// options and settings related to a test run.
class Context {
  CommandLineArgs args;
  Node config;

  string tmpRoot;
  string testRoot;
  string[] testFiles;
  bool parallelize;
  Node runnerSettings;

  this(CommandLineArgs args, Node config) {
    this.args = args;
    this.config = config;

    setTestRoot();
    setTestFiles();
    setParallelize();
    setTmpRoot();
    setRunnerSettings();
  }

  private void setTestRoot() {
    this.testRoot = nodeGet(config,
                            CONFIG_TEST_PATH,
                            Node(DEFAULT_TEST_PATH)).as!string;
  }

  private string[] testFilesOnDisk() {
    auto entries = dirEntries(testRoot, SpanMode.depth);
    auto filtered = filter!(e => e.name.endsWith(".yaml"))(entries);
    return map!(e => e.name)(filtered).array;
  }

  private string[] testFilesFromArgs() {
    return map!(f => buildPath(testRoot, f ~ ".yaml"))(args.testNames).array;
  }

  private void setTestFiles() {
    if (args.testNames.length > 0) {
      this.testFiles = testFilesFromArgs();
    } else {
      this.testFiles = testFilesOnDisk();
    }
  }

  private void setParallelize() {
    this.parallelize = nodeGet(config,
                               CONFIG_PARALLEL_RUNNERS,
                               Node(DEFAULT_PARALLEL_RUNNERS)).as!bool;
  }

  private void setTmpRoot() {
    this.tmpRoot = nodeGet(config,
                           CONFIG_TMP_ROOT,
                           Node(DEFAULT_TMP_ROOT)).as!string;
  }

  private void setRunnerSettings() {
    this.runnerSettings = nodeGet(config,
                                  CONFIG_RUNNERS,
                                  Node(cast(Node[])[]));

    if (!this.runnerSettings.length) {
      throw new Exception("No runners provided.");
    }
  }
}

int main(string[] _args) {
  auto args = new CommandLineArgs(_args);
  auto config = readConfig(CONFIG_FILENAME);
  auto context = new Context(args, config);
  auto runners = loadRunners(context);
  const auto passed = launchRunners(runners, context.parallelize);

  if (passed != runners.length) {
    writeln("All runners unsuccessful, tests failed.");
    return 1;
  }

  return 0;
}
