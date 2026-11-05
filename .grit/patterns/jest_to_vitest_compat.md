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

```grit
engine marzano(0.1)
language js

pattern jest_mocks_to_vitest() {
  file($body) where {
    $body <: contains bubble or {
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

pattern import_vi_from_vitest() {
  `$sym.$_` where {
    $sym <: `vi`,
    // `ensure_import_from` doesn't dedupe within an existing named import.
    $sym <: not imported_from(from = `"vitest"`),
    $sym <: not imported_from(from = `'vitest'`),
    $sym <: ensure_import_from(`"vitest"`)
  }
}

sequential {
  maybe jest_mocks_to_vitest(),
  maybe contains import_vi_from_vitest(),
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
