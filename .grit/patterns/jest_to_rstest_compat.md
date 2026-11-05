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
are.

Everything else (`jest.fn`, `jest.spyOn`, fake timers, `@jest/globals`
imports) is left for the compatibility layer: a setup file that defines
`globalThis.jest` on top of `rs`, and a config alias that points
`@jest/globals` at `@rstest/core`.

## Known limitations — handle by hand after running

- **`jest.createMockFromModule()`, `jest.isolateModules()` and
  `jest.setMock()`** aren't rewritten. They have no direct `rs` equivalent.

```grit
engine marzano(0.1)
language js

pattern jest_mocks_to_rstest() {
  file($body) where {
    $body <: contains bubble `jest.$method` where {
      $method <: or {
        // Rstest hoists only calls on `rs`.
        `mock`,
        `doMock`,
        `unmock`,
        `doUnmock`,
        // Called inside a mock factory, these must use `rs` too: the factory
        // runs while the hoisted mocks are set up.
        `requireActual`,
        `requireMock`
      }
    } => `rs.$method`
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
