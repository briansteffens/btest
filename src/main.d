import std.file;
import std.format;
import std.parallelism;

import yaml;

const string DEFAULT_TEST_PATH = "tests";
const string DEFAULT_TMP_ROOT = "/tmp/btest";
const bool DEFAULT_PARALLEL_RUNNERS = true;
const bool DEFAULT_PARALLEL_TESTS = true;

const string CONFIG_TEST_PATH = "test_path";
const string CONFIG_TMP_PATH = "tmp_path";
const string CONFIG_RUNNERS = "runners";
const string CONFIG_RUNNERS_NAME = "name";
const string CONFIG_RUNNERS_RUN = "run";
const string CONFIG_PARALLEL_TESTS = "parallelize_tests";
const string CONFIG_PARALLEL_RUNNERS = "parallelize_runners";

bool dbg = true;

void debugPrint(string p) {
  if (dbg) {
    writeln(p);
  }
}

Node readConfig(string file) {
  return Loader(file).load();
}

class Runner {
  string testRoot;
  string tmpRoot;
  string name;
  string run;
  bool parallelize;
}

void launchRunner(Runner runner) {
  auto dFiles = dirEntries(runner.testRoot);
  if (runner.parallelize) {
    dFiles = parallel(dFiles, 1);
  }

  foreach (d; dFiles) {
    // Weird that extension is not part of DirEntry struct
    if (d.name.endsWith(".yaml")) {
      
    }
  }
}

void launchRunners(Runner[] runners, bool parallelize) {
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
    debugPrint("No runners provided.");
  }

  Runner[] runners;
  foreach (runnerSetting; runnerSettings) {
    auto name = runnerSetting[CONFIG_RUNNERS_NAME];
    auto run = runnerSetting[CONFIG_RUNNERS_RUN];

    runners ~= new Runner(testPath, name, run, testsInParallel);
  }
}

void main(string[] args) {
  auto config = readConfig("btest.yaml");
  auto runnersInParallel = config.get(CONFIG_PARALLEL_RUNNERS, DEFAULT_PARALLEL_RUNNERS);
  auto runners = loadRunners(config);
  launchRunners(runners, runnersInParallel);
}
