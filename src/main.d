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

const string DEFAULT_TEST_PATH = "tests";
const string DEFAULT_TMP_ROOT = "/tmp/btest";
const bool DEFAULT_PARALLEL_RUNNERS = true;
const bool DEFAULT_PARALLEL_TESTS = true;

const string CONFIG_FILENAME = "btest.yaml";
const string CONFIG_TEST_PATH = "test_path";
const string CONFIG_TMP_ROOT = "tmp_root";
const string CONFIG_RUNNERS = "runners";
const string CONFIG_RUNNERS_NAME = "name";
const string CONFIG_RUNNERS_RUN = "run";
const string CONFIG_PARALLEL_TESTS = "parallelize_tests";
const string CONFIG_PARALLEL_RUNNERS = "parallelize_runners";
const string CONFIG_TEST_CASES = "cases";
const string CONFIG_TEST_TEMPLATES = "templates";
const string CONFIG_TEST_CASES_STATUS = "status";
const string CONFIG_TEST_CASES_STDOUT = "stdout";
const string CONFIG_TEST_CASES_NAME = "name";

Node readConfig(string file) {
  return Loader(file).load();
}

Node nodeGet(Node node, string key, Node def) {
  if (node.containsKey(key)) {
    return node[key];
  }

  return def;
}

class TestCase {
  string testFile;
  string name;
  int expectedStatus;
  string expectedStdout;
  string[string] keyValues;
  string[string] templates;

  this(string testFile, string name, int expectedStatus,
       string expectedStdout, string[string] keyValues, Node templates) {
    this.testFile = testFile;
    this.name = name;
    this.expectedStatus = expectedStatus;
    this.expectedStdout = expectedStdout;
    this.keyValues = keyValues;

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

class TestRunner {
  string testRoot;
  string tmpRoot;
  string name;
  string cmd;
  bool parallelize;
  string[] tmpDirs;

  this(string testRoot, string tmpRoot, string name, string cmd, bool parallelize) {
    this.testRoot = testRoot;
    this.tmpRoot = tmpRoot;
    this.name = name;
    this.cmd = cmd;
    this.parallelize = parallelize;
  }

  string getTmpDir(string testFile) {
    int i = 0;
    while (true) {
      string dir = buildPath(format("%s%d", tmpRoot, i), testFile[0 ..  testFile.length - ".yaml".length]);
      if (!exists(dir)) {
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
      int expectedStatus;
      string expectedStdout, caseName;
      foreach (string key, Node value; config) {
        switch (key) {
        case CONFIG_TEST_CASES_STATUS:
          expectedStatus = value.as!int;
          break;
        case CONFIG_TEST_CASES_STDOUT:
          expectedStdout = value.as!string;
          break;
        case CONFIG_TEST_CASES_NAME:
          caseName = value.as!string;
          break;
        default:
          keyValues[key] = value.as!string;
        }
      }

      cases ~= new TestCase(testFile, caseName, expectedStatus,
                            expectedStdout, keyValues, templates);
    }
    return cases;
  }

  TestCase[] buildTest(string testFile) {
    auto config = readConfig(testFile);

    try {
      return this.loadCases(testFile, config);
    } catch (Exception e) {
      e.msg = format("%s in %s", e.msg, testFile);
      throw e;
    }
  }

  auto run(TestCase[] cases) {
    auto testDir = this.getTmpDir(cases[0].testFile);

    int passed = 0;
    int total = 0;

    foreach (c; cases) {
      total++;

      foreach (file, tmpl; c.templates) {
        std.file.write(buildPath(testDir, file), tmpl);
      }

      auto cwd = getcwd();
      chdir(testDir);
      auto process = execute(this.cmd.split(" "));
      chdir(cwd);

      auto ok = true;
      if (process.status != c.expectedStatus ||
          process.output != c.expectedStdout) {
        ok = false;
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
    if (exists(tmpRoot)) {
      rmdirRecurse(tmpRoot);
    }
  }
}

bool launchRunner(TestRunner runner) {
  shared int passed = 0;
  shared int total = 0;

  auto handleFile(DirEntry d) {
    // Weird that extension is not part of DirEntry struct
    if (d.name.endsWith(".yaml")) {
      auto test = runner.buildTest(d);
      auto t = runner.run(test);
      atomicOp!("+=")(passed, t[0]);
      atomicOp!("+=")(total, t[1]);
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

int launchRunners(TestRunner[] runners, bool parallelize) {
  shared int passed = 0;

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

TestRunner[] loadRunners(Node config) {
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
    string run = runnerSetting[CONFIG_RUNNERS_RUN].as!string;

    runners ~= new TestRunner(testPath, tmpRoot, name, run, testsInParallel);
  }

  return runners;
}

int main(string[] args) {
  auto config = readConfig(CONFIG_FILENAME);
  bool runnersInParallel = nodeGet(config,
                                   CONFIG_PARALLEL_RUNNERS,
                                   Node(DEFAULT_PARALLEL_RUNNERS)).as!bool;
  auto runners = loadRunners(config);
  auto passed = launchRunners(runners, runnersInParallel);

  if (passed != runners.length) {
    writeln("All runners unsuccessful, tests failed.");
    return 1;
  }

  return 0;
}
