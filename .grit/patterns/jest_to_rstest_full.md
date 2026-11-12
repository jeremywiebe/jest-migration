---
title: Jest to Rstest
tags: [migration, js]
---

Convert Jest tests to Rstest, with no compatibility layer: every Jest API
is rewritten to Rstest's.

The pattern runs in passes, most of them shared with the other patterns:

1. A mock factory that returns a literal returns it as the module's
   `default` export (`jest_to_vitest_full.md`).
2. The rules shared with the compatibility-layer pattern
   (`jest_to_rstest_compat.md`): module mocks, `requireActual`,
   `resetModules`, `JEST_WORKER_ID`, `inJest` and
   `verifyRealTimers()`, `replaceProperty` on `process.env` and
   `test.failing()`. Their limitations, listed in that file, apply here too.
3. A bare `.mockImplementation()` gets an empty implementation, as Jest's
   means (`jest_to_vitest_full.md`).
4. The rewrites that don't depend on the runner: removing imports from
   `jest`, `done` callbacks, hook bodies and the custom matchers' result
   type (`jest_to_vitest_full.md`).
5. Imports from `@jest/globals` come from `@rstest/core` instead, with
   `jest` renamed `rs` (`jest_to_vitest_full.md`).
6. Imports of `@testing-library/jest-dom` are removed: that entry point
   extends Jest's types. The setup file registers the matchers from
   `@testing-library/jest-dom/matchers` instead (`jest_to_vitest_full.md`).
7. Every other Jest API: types, `jest.*` calls and custom matchers.
8. Tables written as tagged templates (``it.each`...` ``) get `any` rows
   (``it.each<any>`...` ``). Rstest types their fields `unknown`, where
   Jest's types made them `any`.

The test functions (`describe`, `it`, `expect`, the hooks) and `rs` stay
globals, as they were under Jest: the config needs `globals: true`, and
TypeScript needs Rstest's global types in place of `@types/jest`. Only the
mock types (`Mock`, `MockInstance`, `Mocked`) are imported.

Unlike Vitest's, Rstest's `requireActual` is synchronous, and Rstest runs
`require()` in test files, so mock factories and `require()` calls stay as
they are.

## Known limitations — handle by hand after running

- **Names imported from `'@jest/globals'` keep their names**, apart from
  `jest`. One that `@rstest/core` doesn't export under the same name has to
  be renamed by hand; `tsc` reports it.
- **`jest.MockedFunction`, `jest.MockedClass` and `jest.MockedObject`** all
  become `Mocked`, Rstest's one type for a mocked value.
- **`jest.createMockFromModule()`, `jest.isolateModules()`, `jest.setMock()`
  and `jest.replaceProperty()` on anything but `process.env`** become `rs.*`
  calls that Rstest doesn't have.
- **A comment after a removed jest-dom import stays**: `import
  "@testing-library/jest-dom"; // matchers` leaves `// matchers` on its own
  line. Delete it by hand.
- **A tagged-template table with its own type** (``it.each<Row>`...` ``)
  becomes ``it.each<any>`...` ``. Put the type back by hand.
- **Multi-parameter `done` callbacks** (`(done, fail) => { ... }`) get
  wrapped as `new Promise((done, fail) => { ... })`, which makes `fail` the
  promise's `reject`.
- **`namespace jest { interface Expect { ... } }`** (asymmetric custom
  matchers) isn't rewritten; only `interface Matchers<R>` is.

```grit
engine marzano(0.1)
language js

// Every Jest API the shared rules leave, for a suite with no compatibility
// layer.
// Give tagged-template tables (`it.each\`...\``, `describe.each\`...\``)
// `any` rows, as Jest's types did: Rstest types each row as
// `Record<string, unknown>`, so every use of a field fails to type-check.
pattern each_tables_any() {
  file($body) where {
    $body <: includes ".each`",
    $body <: contains bubble call_expression($function, $arguments) as $call where {
      $arguments <: template_string(),
      $function <: member_expression(property=`each`),
      $call => `$function<any>$arguments`
    }
  }
}

pattern jest_api_to_rstest() {
  file($body) where {
    // Every rule here matches `jest.` or `namespace jest`.
    $body <: includes "jest",
    $body <: contains bubble or {
      // Rstest's mock types have the same names as Jest's, imported from
      // `@rstest/core`, except that one `Mocked` type covers functions,
      // classes and objects.
      `jest.$sym` where {
        $sym <: or { `Mock`, `Mocked` },
        $sym <: ensure_import_from(`"@rstest/core"`)
      } => $sym,
      or {
        `jest.MockedFunction`,
        `jest.MockedClass`,
        `jest.MockedObject`,
      } where {
        $sym = "Mocked",
        $sym <: ensure_import_from(`"@rstest/core"`)
      } => `Mocked`,

      // Both of Jest's spy types are Rstest's `MockInstance`. Without this
      // rule the catch-all below rewrites them to `rs.*`, which isn't a
      // namespace of types.
      or {
        `jest.SpyInstance`,
        `jest.SpiedFunction`,
      } where {
        $sym = "MockInstance",
        $sym <: ensure_import_from(`"@rstest/core"`)
      } => `MockInstance`,

      // Catch-all: any other jest.$sym => rs.$sym
      `jest.$sym` => `rs.$sym` where {
        $sym <: not `CustomMatcherResult`
      },

      // Custom matchers (extensions)
      // Match the interface first: checking `within` on every node is slow.
      interface_declaration(name="Matchers") as $iface where {
        $iface <: within internal_module(name="jest") as $mod,
        $mod <: within ambient_declaration() as $decl,
        $iface <: interface_declaration(name="Matchers", $body) => `interface CustomMatchers<R = unknown> $body`,
        $decl => $iface,
        // Rstest's documented form for custom matcher types. Empty
        // interfaces that only extend another break
        // @typescript-eslint/no-empty-object-type, so each gets a disable
        // comment.
        $decl += `;\n\ndeclare module "@rstest/core" {
            // eslint-disable-next-line @typescript-eslint/no-empty-object-type -- rstest custom matcher augmentation
            interface Assertion<T = any> extends CustomMatchers<T> {}
            // eslint-disable-next-line @typescript-eslint/no-empty-object-type -- rstest custom matcher augmentation
            interface AsymmetricMatchersContaining extends CustomMatchers {}
        }`
      }
    },
  },
}

sequential {
  // Shared with jest_to_vitest_full.md.
  maybe literal_mock_defaults(),
  // Shared with jest_to_rstest_compat.md.
  maybe jest_mocks_to_rstest(),
  // Shared with jest_to_vitest_full.md.
  maybe bare_mock_implementations(),
  maybe jest_runner_neutral(),
  maybe jest_globals_imports(runner = `rs`, source = `"@rstest/core"`),
  maybe jest_dom_imports(),
  maybe jest_api_to_rstest(),
  maybe each_tables_any(),
  // Off: test functions and `rs` stay globals. See `adjust_imports` in
  // jest_to_vitest_full.md.
  // maybe adjust_imports(runner = `rs`, source = `"@rstest/core"`, source_alt = `'@rstest/core'`),
}
```

## Rewrite the Jest API

```javascript
import { describe, it, expect, jest } from "@jest/globals";

jest.mock("./util", () => ({
    ...jest.requireActual("./util"),
    decode: jest.fn(),
}));

describe("thing", () => {
    it("works", () => {
        const spy = jest.spyOn(console, "warn").mockImplementation();
        const mock: jest.Mock = jest.fn();
        jest.useFakeTimers();
        jest.advanceTimersByTime(10);
        expect(mock).not.toHaveBeenCalled();
        expect(spy).not.toHaveBeenCalled();
    });
});
```

```javascript
import { describe, it, expect, rs, Mock } from "@rstest/core";

rs.mock("./util", () => ({
    ...rs.requireActual("./util"),
    decode: rs.fn(),
}));

describe("thing", () => {
    it("works", () => {
        const spy = rs.spyOn(console, "warn").mockImplementation(() => {});
        const mock: Mock = rs.fn();
        rs.useFakeTimers();
        rs.advanceTimersByTime(10);
        expect(mock).not.toHaveBeenCalled();
        expect(spy).not.toHaveBeenCalled();
    });
});
```

## Give tagged-template tables any rows

```javascript
it.each`
  x    | expected
  ${1} | ${2}
`("doubles $x", ({x, expected}) => {
  expect(x * 2).toBe(expected);
});
```

```javascript
it.each<any>`
  x    | expected
  ${1} | ${2}
`("doubles $x", ({x, expected}) => {
  expect(x * 2).toBe(expected);
});
```

## Remove jest-dom imports

```javascript
import "@testing-library/jest-dom";
import { render } from "@testing-library/react";

it('renders', () => {
  render(null);
});
```

```javascript
import { render } from "@testing-library/react";

it('renders', () => {
  render(null);
});
```

## Rewrite mock types

```javascript
const fn: jest.MockedFunction<typeof f> = jest.fn();
const spy: jest.SpyInstance = jest.spyOn(console, "log");
```

```javascript
import { Mocked, MockInstance } from "@rstest/core";

const fn: Mocked<typeof f> = rs.fn();
const spy: MockInstance = rs.spyOn(console, "log");
```

## Apply the shared rules

```javascript
describe("the env", () => {
    it.failing("is production", () => {
        jest.replaceProperty(process.env, "NODE_ENV", "production");
        expect(process.env.JEST_WORKER_ID).toBe("1");
    });
});
```

```javascript
describe("the env", () => {
    it.fails("is production", () => {
        rs.stubEnv("NODE_ENV", "production");
        expect(process.env.RSTEST_WORKER_ID).toBe("1");
    });
});
```

## Rewrite hooks and done callbacks

```javascript
beforeEach(() => jest.useFakeTimers());
it("finishes", (done) => {
    done();
});
```

```javascript
beforeEach(() => {
    rs.useFakeTimers();
});
it("finishes", () =>
    new Promise((done) => {
        done();
    }));
```

## Transform custom assertions

```javascript
declare global {
// eslint-disable-next-line @typescript-eslint/no-namespace
namespace jest {
    interface Matchers<R> {
        toEvaluateAs(expected: number): R;
    }
}
}
```

```javascript
interface CustomMatchers<R = unknown> {
    toEvaluateAs(expected: number): R;
}

declare module "@rstest/core" {
    // eslint-disable-next-line @typescript-eslint/no-empty-object-type -- rstest custom matcher augmentation
    interface Assertion<T = any> extends CustomMatchers<T> {}
    // eslint-disable-next-line @typescript-eslint/no-empty-object-type -- rstest custom matcher augmentation
    interface AsymmetricMatchersContaining extends CustomMatchers {}
}
```
