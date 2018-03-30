import std.file;
import std.format;
import std.parallelism;
import std.stdio;

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

Node nodeGet(Node[string] node, string key, Node def) {
  if (key in node) {
    return node[key];
  }

  return def;
}

class TestCase {
  string testFile;
  string caseName;
  string expectedStatus;
  string expectedStdout;
  string[string] keyValues;
  string[string] templates;

  this(string testFile, string caseName, string expectedStatus,
       string expectedStdout, string[string] keyValues, Node templates) {
    this.testFile = testFile;
    this.caseName = caseName;
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

  string getTmpDir(string testFile) {
    
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
      string expectedStatus, expectedStdout, caseName;
      foreach (string key, string value; caseConfigs) {
        switch (key) {
        case CONFIG_TEST_CASES_STATUS:
          expectedStatus = value;
          break;
        case CONFIG_TEST_CASES_STDOUT:
          expectedStdout = value;
          break;
        case CONFIG_TEST_CASES_NAME:
          caseName = value;
          break;
        default:
          keyValues[key] = value;
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

    foreach (c; cases) {
      foreach (file, tmpl; c.templates) {
        std.file.write(file, tmpl);
      }

      string stdout, status;
      execute(this.run, testDir, status, stdout);
    }

    rmdirRecurse(testDir);
  }
}

void launchRunner(TestRunner runner) {
  auto dFiles = dirEntries(runner.testRoot);
  if (runner.parallelize) {
    dFiles = parallel(dFiles, 1);
  }

  foreach (d; dFiles) {
    // Weird that extension is not part of DirEntry struct
    if (d.name.endsWith(".yaml")) {
      auto test = runner.buildTest(d);
      runner.run(test);
    }
  }
}

void launchRunners(TestRunner[] runners, bool parallelize) {
  foreach (runner; runners) {
    if (parallelize) {
      parallel(launchRunner(runner), 1);
    } else {
      launchRunner(runner);
    }
  }
}

void loadRunners(Node[string] config) {
  auto tmpRoot = nodeGet(config, CONFIG_TMP_ROOT, Node(DEFAULT_TMP_ROOT));
  auto testPath = nodeGet(config, CONFIG_TEST_PATH, Node(DEFAULT_TEST_PATH));
  auto testsInParallel = nodeGet(config, CONFIG_PARALLEL_TESTS, Node(DEFAULT_PARALLEL_TESTS));
  auto runnerSettings = nodeGet(config, CONFIG_RUNNERS, Node(cast(Node[])[]));

  if (!runnerSettings.length) {
    throw new Exception("No runners provided.");
  }

  TestRunner[] runners;
  foreach (Node runnerSetting; runnerSettings) {
    auto name = runnerSetting[CONFIG_RUNNERS_NAME];
    auto run = runnerSetting[CONFIG_RUNNERS_RUN];

    runners ~= new TestRunner(testPath, name, run, testsInParallel);
  }
}

void main(string[] args) {
  auto config = readConfig(CONFIG_FILENAME);
  auto runnersInParallel = nodeGet(config, CONFIG_PARALLEL_RUNNERS, Node(DEFAULT_PARALLEL_RUNNERS));
  auto runners = loadRunners(config);
  launchRunners(runners, runnersInParallel);
}
