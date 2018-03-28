import std.file;
import std.format;
import std.parallelism;

import mustache;
import yaml;

const string DEFAULT_TEST_PATH = "tests";
const string DEFAULT_TMP_ROOT = "/tmp/btest";
const bool DEFAULT_PARALLEL_RUNNERS = true;
const bool DEFAULT_PARALLEL_TESTS = true;

const string CONFIG_FILENAME = "btest.yaml";
const string CONFIG_TEST_PATH = "test_path";
const string CONFIG_TMP_PATH = "tmp_path";
const string CONFIG_RUNNERS = "runners";
const string CONFIG_RUNNERS_NAME = "name";
const string CONFIG_RUNNERS_RUN = "run";
const string CONFIG_PARALLEL_TESTS = "parallelize_tests";
const string CONFIG_PARALLEL_RUNNERS = "parallelize_runners";
const string CONFIG_TEST_CASES = "cases";
const string CONFIG_TEST_TEMPLATES = "templates";

bool dbg = true;

void debugPrint(string p) {
  if (dbg) {
    writeln(p);
  }
}

Node readConfig(string file) {
  return Loader(file).load();
}

class TestCase {
  string testfile;
  string caseName;
  string expectedStatus;
  string expectedStdout;
  string[string] keyValues;
  string[string] templates;

  this(string testFile, string caseName, string expectedStatus,
       string expectedStdout, string[string] keyValues, string[string] templates) {
    this.testFile = testFile;
    this.caseName = caseName;
    this.expectedStatus = expectedStatus;
    this.expectedStdout = expectedStdout;
    this.keyValues = keyValues;
    this.templates = templates;

    MustacheEngine!(string) mustache;
    auto ctx = Mustache.Context;

    foreach (key, value; keyValues) {
      ctx[key] = value;
    }

    foreach (fileName, tmpl; templates) {
      this.templates[fileName] = mustache.renderString(tmpl, ctx);
    }
  }
}

class TestRunner {
  string testRoot;
  string tmpRoot;
  string name;
  string run;
  bool parallelize;

  string getTmpDir(string testFile) {
    
  }

  TestCase[] loadCases(string testFile, Node config) {
    if (CONFIG_TEST_CASES !in testConfig) {
      throw new Exception("No cases provided");
    }
    auto caseConfigs = testConfig[CONFIG_TEST_CASES];

    if (CONFIG_TEST_TEMPLATES !in testConfig) {
      throw new Exception("No templates provided");
    }
    auto templates = testConfig[CONFIG_TEST_TEMPLATES];

    TestCase[] cases;
    foreach (config; caseConfigs) {
      string[string] keyValues;
      string expectedStatus, expectedStdout, caseName;
      foreach (key, value; caseConfigs) {
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

  buildTest(string testFile) {
    auto testConfig = readConfig(testFile);
    auto dir = this.getTmpDir(testFile);

    try {
      auto cases = this.loadCases(config);
      return new Test(cases);
    } catch (e) {
      throw new Exception(format("%s in %s", e.toString(), testFile));
    }
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

void loadRunners(Node config) {
  auto tmpRoot = config.get(CONFIG_TMP_PATH, DEFAULT_TMP_PATH);
  auto testPath = config.get(CONFIG_TEST_PATH, DEFAULT_TEST_PATH);
  auto testsInParallel = config.get(CONFIG_PARALLEL_TESTS, DEFAULT_PARALLEL_TESTS);
  auto runnerSettings = config.get(CONFIG_RUNNERS, []);

  if (!runnerSettings.length) {
    throw new Exception("No runners provided.");
  }

  TestRunner[] runners;
  foreach (runnerSetting; runnerSettings) {
    auto name = runnerSetting[CONFIG_RUNNERS_NAME];
    auto run = runnerSetting[CONFIG_RUNNERS_RUN];

    runners ~= new TestRunner(testPath, name, run, testsInParallel);
  }
}

void main(string[] args) {
  auto config = readConfig(CONFIG_FILENAME);
  auto runnersInParallel = config.get(CONFIG_PARALLEL_RUNNERS, DEFAULT_PARALLEL_RUNNERS);
  auto runners = loadRunners(config);
  launchRunners(runners, runnersInParallel);
}
