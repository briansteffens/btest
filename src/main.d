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
  string testRoot;
  string tmpRoot;
  string name;
  string[] setup;
  string cmd;
  bool parallelize;
  string[] tmpDirs;

  this(string testRoot, string tmpRoot, string name, string[] setup, string cmd, bool parallelize) {
    this.testRoot = testRoot;
    this.tmpRoot = tmpRoot;
    this.name = name;
    this.setup = setup;
    this.cmd = cmd;
    this.parallelize = parallelize;
  }

  private string getTmpDir(string testFile) {
    int i;
    while (true) {
      string fileWithoutExt = testFile[0 ..  testFile.length - ".yaml".length];
      string tmpRoot = buildPath(tmpRoot, format("%d", i));
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
        process = exec(this.cmd ~ c.argsToPass.join(" "), testDir);

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

  void handleFile(DirEntry d) {
    // Weird that extension is not part of DirEntry struct
    if (d.name.endsWith(".yaml")) {
      auto test = runner.buildTest(d);

      if (test !is null) {
        auto t = runner.run(test);
        atomicOp!("+=")(passed, t[0]);
        atomicOp!("+=")(total, t[1]);
      }
    }
  }

  try {
    auto dFiles = dirEntries(runner.testRoot, SpanMode.depth);
    if (runner.parallelize) {
      foreach (d; parallel(dFiles)) {
        handleFile(d);
      }
    } else {
      foreach (d; dFiles) {
        handleFile(d);
      }
    }

    writeln(format("%d of %d tests passed for runner: %s",
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

private TestRunner[] loadRunners(Node config) {
  string tmpRoot = nodeGet(config,
                           CONFIG_TMP_ROOT,
                           Node(DEFAULT_TMP_ROOT)).as!string;
  string testPath = nodeGet(config,
                            CONFIG_TEST_PATH,
                            Node(DEFAULT_TEST_PATH)).as!string;
  auto testsInParallel = nodeGet(config,
                                 CONFIG_PARALLEL_TESTS,
                                 Node(DEFAULT_PARALLEL_TESTS)).as!bool;
  auto runnerSettings = nodeGet(config, CONFIG_RUNNERS, Node(cast(Node[])[]));

  if (!runnerSettings.length) {
    throw new Exception("No runners provided.");
  }

  TestRunner[] runners;
  foreach (Node runnerSetting; runnerSettings) {
    string name = runnerSetting[CONFIG_RUNNERS_NAME].as!string;

    string[] setup;
    if (runnerSetting.containsKey(CONFIG_RUNNERS_SETUP)) {
      foreach (string setupStep; runnerSetting[CONFIG_RUNNERS_SETUP]) {
        setup ~= setupStep;
      }
    }

    string run = runnerSetting[CONFIG_RUNNERS_RUN].as!string;

    runners ~= new TestRunner(testPath, tmpRoot, name, setup, run, testsInParallel);
  }

  return runners;
}

int main() {
  auto config = readConfig(CONFIG_FILENAME);
  const bool runnersInParallel = nodeGet(config,
                                         CONFIG_PARALLEL_RUNNERS,
                                         Node(DEFAULT_PARALLEL_RUNNERS)).as!bool;
  auto runners = loadRunners(config);
  const auto passed = launchRunners(runners, runnersInParallel);

  if (passed != runners.length) {
    writeln("All runners unsuccessful, tests failed.");
    return 1;
  }

  return 0;
}
