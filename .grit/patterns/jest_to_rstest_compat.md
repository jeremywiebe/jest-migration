---
title: Jest to Rstest (compatibility layer)
tags: [migration, js]
---

Rewrite only the Jest calls that a `jest` global backed by `rs` can't stand
in for, so a Jest suite runs under Rstest with the rest of its code
unchanged.

Rstest hoists `rs.mock()` calls above the imports, but not `jest.mock()`
calls, so module mocks must use `rs` by name. Rstest's `requireActual` and
`requireMock` are synchronous, like Jest's, so mock factories stay as they
are. Rstest also transforms `rs.resetModules()` calls, so those must use `rs`
by name too.

Two Jest APIs have no Rstest counterpart under the same name:

- `test.failing()` and `it.failing()` become `test.fails()` and `it.fails()`.
- `jest.replaceProperty(process.env, name, value)` becomes
  `rs.stubEnv(name, value)`. Jest restores replaced properties when
  `restoreMocks` is on. Rstest restores stubbed variables only with
  `unstubEnvs: true` in its config.

Everything else (`jest.fn`, `jest.spyOn`, fake timers, `@jest/globals`
imports) is left for the compatibility layer: a setup file that defines
`globalThis.jest` on top of `rs`, and a config alias that points
`@jest/globals` at `@rstest/core`.

## Known limitations — handle by hand after running

- **`jest.createMockFromModule()`, `jest.isolateModules()` and
  `jest.setMock()`** aren't rewritten. They have no direct `rs` equivalent.
- **`jest.replaceProperty()` on anything but `process.env`** isn't rewritten.
  Rstest has no `replaceProperty`.
- **A `verifyRealTimers()` function** (in a `wait()` test helper) is
  replaced by name with a check on `rs.isFakeTimers()`. Jest has no
  `isFakeTimers()`, so the rewritten helper runs only under Rstest.
- **An `inJest` flag is renamed `inTest`** by name, wherever it's
  declared, imported or used.
- **`JEST_WORKER_ID` becomes `RSTEST_WORKER_ID` everywhere**, in production code
  too, so code that detects a test run keeps working under Rstest. It then
  no longer detects a Jest run.
- **An inserted `rs` import can leave a blank line inside an import group**
  when it sorts directly above an import with a leading comment (such as an
  `eslint-disable-next-line`): `import/order` won't fix across the comment.

```grit
engine marzano(0.1)
language js

pattern jest_mocks_to_rstest() {
  file($body) where {
    $body <: contains bubble or {
      // A `wait()` helper may detect fake timers by calling
      // `jest.getTimerCount()` with real timers in place. Replace that check
      // with the runner's own.
      `const verifyRealTimers = $check` where {
        $check => `() => {
    if (rs.isFakeTimers()) {
        throw new Error(
            "Cannot use wait() with fake timers. Call jest.useRealTimers() in test case or in a beforeEach.",
        );
    }
}`
      },

      // Code that detects a test run by Jest's worker variable checks
      // Rstest's instead.
      `JEST_WORKER_ID` => `RSTEST_WORKER_ID`,

      // An `inJest` flag that checks that variable no longer means
      // Jest only.
      `inJest` => `inTest`,

      // Rstest has no `replaceProperty`; for `process.env` it has `stubEnv`.
      `jest.replaceProperty(process.env, $name, $value)` => `rs.stubEnv($name, $value)`,

      `jest.$method` where {
        $method <: or {
          // Rstest hoists only calls on `rs`.
          `mock`,
          `doMock`,
          `unmock`,
          `doUnmock`,
          // Called inside a mock factory, these must use `rs` too: the
          // factory runs while the hoisted mocks are set up.
          `requireActual`,
          `requireMock`,
          // Rstest transforms these calls, so they must use `rs` by name.
          `resetModules`
        }
      } => `rs.$method`,

      `$runner.failing` => `$runner.fails` where {
        $runner <: or { `test`, `it` }
      },
    }
  }
}

pattern import_rs_from_rstest() {
  `$sym.$_` where {
    $sym <: `rs`,
    // `ensure_import_from` doesn't dedupe within an existing named import.
    $sym <: not imported_from(from = `"@rstest/core"`),
    $sym <: not imported_from(from = `'@rstest/core'`),
    $sym <: ensure_import_from(`"@rstest/core"`)
  }
}

sequential {
  maybe jest_mocks_to_rstest(),
  maybe contains import_rs_from_rstest(),
}
```

## Rewrite module mocks to rs

```javascript
jest.mock("./a");
jest.mock("./b", () => ({ b: 1 }));
jest.doMock("./c", () => ({}));
jest.unmock("./d");
jest.doUnmock("./e");
```

```javascript
import { rs } from "@rstest/core";

rs.mock("./a");
rs.mock("./b", () => ({ b: 1 }));
rs.doMock("./c", () => ({}));
rs.unmock("./d");
rs.doUnmock("./e");
```

## Keep a factory that spreads the real module synchronous

```javascript
jest.mock("./util", () => ({
    ...jest.requireActual("./util"),
    decode: jest.fn(),
}));
```

```javascript
import { rs } from "@rstest/core";

rs.mock("./util", () => ({
    ...rs.requireActual("./util"),
    decode: jest.fn(),
}));
```

## Rewrite requireMock

```javascript
const mocked = jest.requireMock("./util");
```

```javascript
import { rs } from "@rstest/core";

const mocked = rs.requireMock("./util");
```

## Leave other jest APIs and an existing rs import alone

```javascript
import { describe, rs } from "@rstest/core";

jest.mock("node:fs");
const spy = jest.spyOn(console, "error").mockImplementation(() => {});
jest.useFakeTimers();
```

```javascript
import { describe, rs } from "@rstest/core";

rs.mock("node:fs");
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

## Rewrite resetModules to rs

```javascript
beforeEach(() => {
    jest.resetModules();
});
```

```javascript
import { rs } from "@rstest/core";

beforeEach(() => {
    rs.resetModules();
});
```

## Rewrite replaceProperty on process.env to stubEnv

```javascript
jest.replaceProperty(process.env, "NODE_ENV", "production");
jest.replaceProperty(window, "innerWidth", 100);
```

```javascript
import { rs } from "@rstest/core";

rs.stubEnv("NODE_ENV", "production");
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
import { rs } from "@rstest/core";

const verifyRealTimers = () => {
    if (rs.isFakeTimers()) {
        throw new Error(
            "Cannot use wait() with fake timers. Call jest.useRealTimers() in test case or in a beforeEach.",
        );
    }
};
```

## Detect a test run by the runner's worker variable

```javascript
const workerId = process.env.JEST_WORKER_ID;
```

```javascript
const workerId = process.env.RSTEST_WORKER_ID;
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

export const inTest = typeof process !== "undefined" && !!process?.env?.RSTEST_WORKER_ID;
if (!inTest) {
    setup();
}
```
