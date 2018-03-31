import std.algorithm;
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

bool dbg = true;

void debugPrint(string p) {
  if (dbg) {
    writeln(p);
  }
}

Node readConfig(string file) {
  return Loader(file).load();
}

Node nodeGet(Node node, string key, Node def) {
  if (node.contains(key)) {
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

    foreach (string fileName, string tmpl; templates) {
      this.templates[fileName] = mustache.renderString(tmpl, ctx);
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
      string dir = format("%s%d", buildPath(tmpRoot, testFile), i);
      if (!exists(dir)) {
          mkdir(dir);
          return dir;
      }
    }
  }

  TestCase[] loadCases(string testFile, Node config) {
    if (!config.contains(CONFIG_TEST_CASES)) {
      throw new Exception("No cases provided");
    }
    auto caseConfigs = config[CONFIG_TEST_CASES];

    if (!config.contains(CONFIG_TEST_TEMPLATES)) {
      throw new Exception("No templates provided");
    }
    auto templates = config[CONFIG_TEST_TEMPLATES];

    TestCase[] cases;
    foreach (Node config; caseConfigs) {
      string[string] keyValues;
      int expectedStatus;
      string expectedStdout, caseName;
      foreach (string key, Node value; caseConfigs) {
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
      throw new Exception(format("%s in %s", e.toString(), testFile));
    }
  }

  void run(TestCase[] cases) {
    auto testDir = this.getTmpDir(cases[0].testFile);

    mkdir(testDir);

    foreach (i, c; cases) {
      foreach (file, tmpl; c.templates) {
        std.file.write(file, tmpl);
      }

      auto cwd = getcwd();
      chdir(testDir);
      auto process = execute(this.cmd.split(" "));
      chdir(cwd);

      auto passed = true;
      if (process.status != c.expectedStatus ||
          process.output != c.expectedStdout) {
        passed = false;
      }

      writeln(format("[%s] [Case %d in %s] %s",
                     passed ? "PASS" : "FAIL",
                     i,
                     c.testFile,
                     c.name));

      if (!passed) {
        writeln("Expected status code %d but got %s", process.status, c.expectedStatus);
        // The only high-level execute function in the D standard library, "execute",
        // mashes stderr and stdout together. Writing a proper "execute" that keeps
        // the streams separate would be a pain. This may do for now.
        writeln("Expected output [%s] but got [%s]", process.output, c.expectedStdout);
        write("\n");
        writeln("Output: ", process.output);
      }

      write("\n");
    }
  }

  void cleanup() {
    foreach (dir; tmpDirs) {
      if (exists(dir)) {
        rmdirRecurse(dir);
      }
    }
  }
}

void launchRunner(TestRunner runner) {
  void handleFile(DirEntry d) {
    // Weird that extension is not part of DirEntry struct
    if (d.name.endsWith(".yaml")) {
      auto test = runner.buildTest(d);
      runner.run(test);
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
  } finally {
    runner.cleanup();
  }
}

void launchRunners(TestRunner[] runners, bool parallelize) {
  if (parallelize) {
    foreach (runner; parallel(runners)) {
      launchRunner(runner);
    }
  } else {
    foreach (runner; runners) {
      launchRunner(runner);
    }
  }
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

    runners ~= new TestRunner(tmpRoot, testPath, name, run, testsInParallel);
  }

  return runners;
}

void main(string[] args) {
  auto config = readConfig(CONFIG_FILENAME);
  bool runnersInParallel = nodeGet(config,
                                   CONFIG_PARALLEL_RUNNERS,
                                   Node(DEFAULT_PARALLEL_RUNNERS)).as!bool;
  auto runners = loadRunners(config);
  launchRunners(runners, runnersInParallel);
}
