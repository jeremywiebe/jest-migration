---
title: Jest to Vitest (compatibility layer)
tags: [migration, js]
---

Rewrite only the Jest calls that a `jest` global backed by `vi` can't stand
in for, so a Jest suite runs under Vitest with the rest of its code
unchanged.

Vitest hoists `vi.mock()` calls above the imports, but not `jest.mock()`
calls, so module mocks must use `vi` by name. Vitest also has no synchronous
`requireActual`: `vi.importActual()` returns a promise, so a mock factory
that loads the real module becomes `async`.

Vitest's `require()` is Node's own, so it can't load TypeScript sources or
resolve the aliases Vitest's own imports use. `require()` calls become
`await import()`, and the arrow function that holds them becomes `async`. A
helper made `async` this way is awaited where the same file calls it, and
the arrow function around that call becomes `async` too.

Two Jest APIs have no Vitest counterpart under the same name:

- `test.failing()` and `it.failing()` become `test.fails()` and `it.fails()`.
- `jest.replaceProperty(process.env, name, value)` becomes
  `vi.stubEnv(name, value)`. Jest restores replaced properties when
  `restoreMocks` is on. Vitest restores stubbed variables only with
  `unstubEnvs: true` in its config.

Everything else (`jest.fn`, `jest.spyOn`, fake timers, `@jest/globals`
imports) is left for the compatibility layer: a setup file that defines
`globalThis.jest` on top of `vi`, and a config alias that points
`@jest/globals` at a module exporting Vitest's globals plus that `jest`.

## Known limitations — handle by hand after running

- **`jest.requireActual()` outside a mock factory** becomes
  `await vi.importActual()`. That's valid at a module's top level, but inside
  a function that isn't `async` it's a syntax error.
- **`jest.createMockFromModule()`, `jest.isolateModules()` and
  `jest.setMock()`** aren't rewritten. They have no direct `vi` equivalent.
- **`jest.replaceProperty()` on anything but `process.env`** isn't rewritten.
  Vitest has no `replaceProperty`.
- **`require()` is rewritten only in test files** (files that call
  `describe()`, `it()` or `test()`) **and only inside arrow functions**, and a helper made
  `async` is awaited only one call deep, in the file that declares it. A
  `require()` in a `function`, or a caller of a caller, is left for a person.
- **An `inJest` flag is renamed `inTest`** by name, wherever it's
  declared, imported or used.
- **`JEST_WORKER_ID` becomes `VITEST_WORKER_ID` everywhere**, in production code
  too, so code that detects a test run keeps working under Vitest. It then
  no longer detects a Jest run.
- **`await import()` returns the module namespace.** For a CommonJS module
  that assigns `module.exports`, use its `default` export.
- **A `verifyRealTimers()` function** (in a `wait()` test helper) is
  replaced by name with a check on `vi.isFakeTimers()`. Jest has no
  `isFakeTimers()`, so the rewritten helper runs only under Vitest.

```grit
engine marzano(0.1)
language js

pattern jest_mocks_to_vitest() {
  file($body) where {
    // A substring check skips the syntax walk in files that can't match.
    or {
      $body <: includes "jest.",
      $body <: includes "JEST_WORKER_ID",
      $body <: includes "inJest",
      $body <: includes ".failing",
    },
    $body <: contains bubble or {
      // A `wait()` helper may detect fake timers by calling
      // `jest.getTimerCount()` with real timers in place. Replace that check
      // with the runner's own.
      `const verifyRealTimers = $check` where {
        $check => `() => {
    if (vi.isFakeTimers()) {
        throw new Error(
            "Cannot use wait() with fake timers. Call jest.useRealTimers() in test case or in a beforeEach.",
        );
    }
}`
      },

      // Code that detects a test run by Jest's worker variable checks
      // Vitest's instead.
      `JEST_WORKER_ID` => `VITEST_WORKER_ID`,

      // An `inJest` flag that checks that variable no longer means
      // Jest only.
      `inJest` => `inTest`,

      // Vitest has no `replaceProperty`; for `process.env` it has `stubEnv`.
      `jest.replaceProperty(process.env, $name, $value)` => `vi.stubEnv($name, $value)`,

      `$runner.failing` => `$runner.fails` where {
        $runner <: or { `test`, `it` }
      },

      // A mock factory that loads the real module becomes async, since
      // `vi.importActual()` returns a promise.
      `jest.$method($module, $factory)` where {
        $method <: or { `mock`, `doMock` },
        $factory <: contains `jest.requireActual($_)`,
        $factory <: contains bubble or {
          `...jest.requireActual($actual)` => `...(await vi.importActual($actual))`,
          `jest.requireActual($actual)` => `await vi.importActual($actual)`,
        },
        if ($factory <: not r"(?s)async\b.*") {
          $factory => `async $factory`
        }
      } => `vi.$method($module, $factory)`,

      // Vitest hoists only calls on `vi`.
      `jest.$method` where {
        $method <: or { `mock`, `doMock`, `unmock`, `doUnmock` }
      } => `vi.$method`,

      `...jest.requireActual($actual)` => `...(await vi.importActual($actual))`,
      `jest.requireActual($actual)` => `await vi.importActual($actual)`,
      `...jest.requireMock($mocked)` => `...(await vi.importMock($mocked))`,
      `jest.requireMock($mocked)` => `await vi.importMock($mocked)`,
    }
  }
}

// The innermost arrow function that calls `require()` becomes async, and its
// `require()` calls become `await import()`.
pattern require_to_import() {
  arrow_function(body=$body) as $fn where {
    $body <: contains `require($_)`,
    $body <: not contains arrow_function(body=$inner) where {
      $inner <: contains `require($_)`
    },
    $body <: contains bubble or {
      `require($module).$prop` => `(await import($module)).$prop`,
      `require($module)` => `await import($module)`,
    },
    if ($fn <: not r"(?s)async\b.*") {
      $fn => `async $fn`
    }
  }
}

// A helper that `require_to_import()` made async is awaited where the same
// file calls it, and the innermost arrow function around that call becomes
// async too.
pattern await_async_import_helpers() {
  file($body) where {
    $body <: contains `const $helper = $helperFn` where {
      $helperFn <: arrow_function(),
      $helperFn <: r"(?s)async\b.*",
      $helperFn <: contains `await import($_)`
    },
    $body <: contains bubble($helper) arrow_function(body=$callerBody) as $caller where {
      $callerBody <: contains call_expression(function=$helper),
      $callerBody <: not contains arrow_function(body=$inner) where {
        $inner <: contains call_expression(function=$helper)
      },
      $callerBody <: contains bubble($helper) call_expression(function=$helper) as $call where {
        $call <: not within `await $_`,
        $call => `await $call`
      },
      if ($caller <: not r"(?s)async\b.*") {
        $caller => `async $caller`
      }
    }
  }
}

pattern import_vi_from_vitest() {
  `$sym.$_` where {
    $sym <: `vi`,
    // `ensure_import_from` doesn't dedupe within an existing named import.
    $sym <: not imported_from(from = `"vitest"`),
    $sym <: not imported_from(from = `'vitest'`),
    $sym <: ensure_import_from(`"vitest"`)
  }
}

// Whether the file's text contains `$text`: a string search, much cheaper
// than a syntax walk, so passes check it first.
pattern file_includes($text) {
  file($body) where { $body <: includes $text }
}

// Only test files: a script's `require()` calls are left alone, since making
// its callbacks async would change what it does.
pattern test_file() {
  file($body) where {
    $body <: contains or { `describe($_, $_)`, `it($_, $_)`, `test($_, $_)` }
  }
}

sequential {
  maybe jest_mocks_to_vitest(),
  // Substring checks first: they skip the syntax walk in most files.
  maybe and { file_includes(text = "require("), test_file(), contains require_to_import() },
  maybe and { file_includes(text = "await import("), test_file(), await_async_import_helpers() },
  maybe and { file_includes(text = "vi."), contains import_vi_from_vitest() },
}
```

## Rewrite module mocks to vi

```javascript
jest.mock("./a");
jest.mock("./b", () => ({ b: 1 }));
jest.doMock("./c", () => ({}));
jest.unmock("./d");
jest.doUnmock("./e");
```

```javascript
import { vi } from "vitest";

vi.mock("./a");
vi.mock("./b", () => ({ b: 1 }));
vi.doMock("./c", () => ({}));
vi.unmock("./d");
vi.doUnmock("./e");
```

## Make a factory that spreads the real module async

```javascript
jest.mock("./util", () => ({
    ...jest.requireActual("./util"),
    decode: jest.fn(),
}));
```

```javascript
import { vi } from "vitest";

vi.mock("./util", async () => ({
    ...(await vi.importActual("./util")),
    decode: jest.fn(),
}));
```

## Make a function factory that loads the real module async

```javascript
jest.mock("./util", function () {
    const actual = jest.requireActual("./util");
    return { ...actual, decode: jest.fn() };
});
```

```javascript
import { vi } from "vitest";

vi.mock("./util", async function () {
    const actual = await vi.importActual("./util");
    return { ...actual, decode: jest.fn() };
});
```

## Leave other jest APIs and an existing vi import alone

```javascript
import { vi } from "vitest";

jest.mock("node:fs");
const spy = jest.spyOn(console, "error").mockImplementation(() => {});
jest.useFakeTimers();
```

```javascript
import { vi } from "vitest";

vi.mock("node:fs");
const spy = jest.spyOn(console, "error").mockImplementation(() => {});
jest.useFakeTimers();
```

## Leave a file without module mocks unchanged

```javascript
import { describe, it, expect, jest } from "@jest/globals";

describe("thing", () => {
    it("works", () => {
        expect(jest.fn()).not.toHaveBeenCalled();
    });
});
```

```javascript
import { describe, it, expect, jest } from "@jest/globals";

describe("thing", () => {
    it("works", () => {
        expect(jest.fn()).not.toHaveBeenCalled();
    });
});
```

## Replace a wait() helper's fake-timer check with isFakeTimers

```javascript
const verifyRealTimers = () => {
    const oldWarn = console.warn;
    console.warn = () => {};

    try {
        const timerCount = jest.getTimerCount();
        const timeoutID = setTimeout(() => {}, 0);
        const newTimerCount = jest.getTimerCount();
        clearTimeout(timeoutID);
        if (timerCount !== newTimerCount) {
            throw new Error(
                "Cannot use wait() with fake timers. Call jest.useRealTimers() in test case or in a beforeEach.",
            );
        }
    } finally {
        console.warn = oldWarn;
    }
};
```

```javascript
import { vi } from "vitest";

const verifyRealTimers = () => {
    if (vi.isFakeTimers()) {
        throw new Error(
            "Cannot use wait() with fake timers. Call jest.useRealTimers() in test case or in a beforeEach.",
        );
    }
};
```

## Rewrite replaceProperty on process.env to stubEnv

```javascript
jest.replaceProperty(process.env, "NODE_ENV", "production");
jest.replaceProperty(window, "innerWidth", 100);
```

```javascript
import { vi } from "vitest";

vi.stubEnv("NODE_ENV", "production");
jest.replaceProperty(window, "innerWidth", 100);
```

## Rewrite failing tests to fails

```javascript
test.failing("throws", () => {
    expect(true).toBe(false);
});
it.failing("throws too", () => {
    expect(true).toBe(false);
});
```

```javascript
test.fails("throws", () => {
    expect(true).toBe(false);
});
it.fails("throws too", () => {
    expect(true).toBe(false);
});
```

## Rewrite require in a test to await import

```javascript
describe("the barrel", () => {
    it("loads", () => {
        jest.resetModules();
        const barrel = require("./index");
        const { default: logic } = require(`./widgets/${name}`);
        const value = require("./value").value;
        expect(barrel.value).toBe(value);
    });
});
```

```javascript
describe("the barrel", () => {
    it("loads", async () => {
        jest.resetModules();
        const barrel = await import("./index");
        const { default: logic } = await import(`./widgets/${name}`);
        const value = (await import("./value")).value;
        expect(barrel.value).toBe(value);
    });
});
```

## Await a helper that now imports

```javascript
const runCli = (args) => {
    process.argv = ["node", "cli.ts", ...args];
    require("../cli");
};

it("shows help", () => {
    runCli(["--help"]);
    expect(log).toHaveBeenCalled();
});
```

```javascript
const runCli = async (args) => {
    process.argv = ["node", "cli.ts", ...args];
    await import("../cli");
};

it("shows help", async () => {
    await runCli(["--help"]);
    expect(log).toHaveBeenCalled();
});
```

## Leave require in a script alone

```javascript
const packages = paths.map((path) => {
    const pkg = require(path);
    return pkg.name;
});
```

```javascript
const packages = paths.map((path) => {
    const pkg = require(path);
    return pkg.name;
});
```

## Detect a test run by the runner's worker variable

```javascript
const workerId = process.env.JEST_WORKER_ID;
```

```javascript
const workerId = process.env.VITEST_WORKER_ID;
```

## Rename an inJest flag to inTest

```javascript
import {inJest} from "../../utils";

export const inJest = typeof process !== "undefined" && !!process?.env?.JEST_WORKER_ID;
if (!inJest) {
    setup();
}
```

```javascript
import {inTest} from "../../utils";

export const inTest = typeof process !== "undefined" && !!process?.env?.VITEST_WORKER_ID;
if (!inTest) {
    setup();
}
```
