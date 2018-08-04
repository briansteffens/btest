# btest

btest is a language-agnostic testing framework.

## Installation

Install D (either dmd or ldc) and dub (the D package manager):

#### macOS

```bash
brew install dmd dub
```

### dub

Install dep packages:

```bash
dub
```

## Use

Create a `btest.yaml` file like so:

```yaml
test_path: <path-to-test-directory>

runners:
  - name: <runner-name>
    run: <cmd-to-run-on-each-test-case>
```

Here is a filled-in example:

```yaml
test_path: tests

runners:
  - name: Run tests with cpython
    run: python test.py

  - name: Run tests with pyp
    run: pypy test.py
```

Then create a tests directory and add a yaml file for each set of tests like so:

```yaml
cases:
  - name: <name-of-test-case>
    status: <expected-exit-status>
    stdout: <expected-stdout-output>

    <test-case-key>: <test-case-value>

templates:
  - <file-name>: <file-contents>
```

Here is a filled-in example:

```yaml
cases:
  - name: Should exit on divide by zero
    status: 1
    stdout: |
      Traceback (most recent call last):
        File "test.py", line 1, in <module>
          4 / 0
      ZeroDivisionError: division by zero
    denominator: 0
templates:
  - test.py: |
      4 / {{ denominator }}
```

### Run it

Run all tests:

```bash
$ btest
tests/divide-by-zero.yaml
[PASS] Should exit on divide by zero

1 of 1 tests passed for runner: Run tests with cpython

```

Run just a specific test file by name (assuming the test path root is `tests/`,
this will run the tests in `tests/divide-by-zero.yaml`):

```bash
$ btest -f divide-by-zero
tests/divide-by-zero.yaml
[PASS] Should exit on divide by zero

1 of 1 tests passed for runner: Run tests with cpython

```

### More examples

Check out the `btest.yml` file and `tests` directory in:

* [BShift](https://github.com/briansteffens/bshift)
* [BSDScheme](https://github.com/eatonphil/bsdscheme)
