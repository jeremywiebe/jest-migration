---
title: Jest to Vitest
tags: [migration, js]
---

Convert Jest tests to Vitest, with no compatibility layer: every Jest API
is rewritten to Vitest's.

The pattern runs in passes:

1. A mock factory that returns a literal returns it as the module's
   `default` export.
2. The rules shared with the compatibility-layer pattern
   (`jest_to_vitest_compat.md`): module mocks, `requireActual`, `require()`
   in test files, `JEST_WORKER_ID`, `inJest` and
   `verifyRealTimers()`, `replaceProperty` on `process.env` and
   `test.failing()`. Their limitations, listed in that file, apply here too.
3. A bare `.mockImplementation()` gets an empty implementation, as Jest's
   means.
4. The rewrites that don't depend on the runner: removing imports from
   `jest`, `done` callbacks, hook bodies and the custom matchers' result
   type.
5. Imports from `@jest/globals` come from `vitest` instead, with `jest`
   renamed `vi`.
6. Imports of `@testing-library/jest-dom` are removed: that entry point
   extends Jest's types. The setup file imports
   `@testing-library/jest-dom/vitest` instead.
7. Every other Jest API: types, `jest.*` calls and custom matchers.

`jest_to_rstest_full.md` reuses passes 1, 3, 4, 5 and 6.

The test functions (`describe`, `it`, `expect`, the hooks) and `vi` stay
globals, as they were under Jest: the config needs `globals: true`, and
TypeScript needs `"types": ["vitest/globals"]` in place of `@types/jest`.
Only the mock types (`Mock`, `MockInstance` and so on) are imported, since
Vitest has no global types by those names.

## Known limitations — handle by hand after running

- **Names imported from `'@jest/globals'` keep their names**, apart from
  `jest`. One that `vitest` doesn't export under the same name (such as
  `SpyInstance`) has to be renamed by hand; `tsc` reports it.
- **Multi-parameter `done` callbacks** (`(done, fail) => { ... }`) get wrapped as `new Promise((done, fail) => { ... })`, but only the first parameter is used by Vitest's Promise contract. Rare; flag if hit.
- **`namespace jest { interface Expect { ... } }`** (asymmetric custom matchers) is not handled — only `interface Matchers<R>` is rewritten. Less common; hand-fix if encountered.
- **`jest.replaceProperty()` on anything but `process.env`** becomes `vi.replaceProperty()`, which doesn't exist.
- **A comment after a removed jest-dom import stays**: `import
  "@testing-library/jest-dom"; // matchers` leaves `// matchers` on its own
  line. Delete it by hand.

```grit
engine marzano(0.1)
language js

// Off: the full patterns leave the test functions, `vi` and `rs` as
// globals (`globals: true` in the runner's config). To import them instead,
// uncomment these and the `adjust_imports` step in each full pattern's
// `sequential`.
// // Import `$name` from `$source` if the file uses it and doesn't already
// // import it. Only the name's first use is checked: checking every call and
// // member access in a file took close to a minute on a 4,000-line test.
// pattern import_runner_name($name, $source, $source_alt) {
//   file($body) where {
//     $program <: program($statements),
//     $body <: contains or { `$sym($_)`, `$sym.$_` } where {
//       $sym <: $name,
//       // `imported_from` compares the `from` clause syntactically (quote style
//       // included), so check both single- and double-quoted forms.
//       $sym <: not imported_from(from = `'mocha'`),
//       $sym <: not imported_from(from = `"mocha"`),
//       // tstyche's describe/it/expect test types, not runtime code.
//       $sym <: not imported_from(from = `'tstyche'`),
//       $sym <: not imported_from(from = `"tstyche"`),
//       // storybook/test re-exports describe/it/expect for stories.
//       $sym <: not imported_from(from = `'storybook/test'`),
//       $sym <: not imported_from(from = `"storybook/test"`),
//       // `ensure_import_from` doesn't dedupe within an existing named import,
//       // and this keeps the codemod idempotent.
//       $sym <: not imported_from(from = $source),
//       $sym <: not imported_from(from = $source_alt),
//       // A default import of the same name, e.g. `import expect from 'expect'`.
//       $statements <: not contains `import $sym from $_`,
//       $sym <: ensure_import_from($source)
//     }
//   }
// }
//
// // Import the test functions a file uses, and `$runner`, from `$source`.
// // `$source_alt` is `$source` in the other quote style. Shared with
// // jest_to_rstest_full.md.
// pattern adjust_imports($runner, $source, $source_alt) {
//   and {
//     maybe import_runner_name(name = `describe`, source = $source, source_alt = $source_alt),
//     maybe import_runner_name(name = `test`, source = $source, source_alt = $source_alt),
//     maybe import_runner_name(name = `it`, source = $source, source_alt = $source_alt),
//     maybe import_runner_name(name = `expect`, source = $source, source_alt = $source_alt),
//     maybe import_runner_name(name = `beforeAll`, source = $source, source_alt = $source_alt),
//     maybe import_runner_name(name = `beforeEach`, source = $source, source_alt = $source_alt),
//     maybe import_runner_name(name = `afterAll`, source = $source, source_alt = $source_alt),
//     maybe import_runner_name(name = `afterEach`, source = $source, source_alt = $source_alt),
//     maybe import_runner_name(name = $runner, source = $source, source_alt = $source_alt),
//   }
// }

// A mock factory that returns a literal returns it as the module's `default`
// export. The shared rules then rewrite the `jest.mock()` call itself. Shared
// with jest_to_rstest_full.md.
pattern literal_mock_defaults() {
  file($body) where {
    $body <: includes "jest.mock",
    $body <: contains bubble or {
      `jest.mock($module, $mockImplementation)` where {
        $mockImplementation <: or {
          arrow_function($body) where {
            // still waiting for default mock confirmation
            $body <: literal_value() => `({
              default: $body
            })`
          },
          `function($_) { $body }` where {
            $body <: contains `return $return` where {
              $return <: literal_value() => `{ default: $return }`
            }
          }
        }
      }
    }
  }
}

// A bare `.mockImplementation()` makes a Jest mock return `undefined`. Under
// Vitest and Rstest it keeps the current implementation, so a spy would still
// call the original. Its own pass, so the call it's chained on is rewritten
// after. Shared with jest_to_rstest_full.md.
pattern bare_mock_implementations() {
  file($body) where {
    $body <: includes "mockImplementation()",
    $body <: contains bubble {
      `$expr.mockImplementation()` => `$expr.mockImplementation(() => {})`
    }
  }
}

// Rewrites that don't depend on the target runner: imports from `jest`, `done`
// callbacks, hook bodies and the custom matchers' result type. Shared with
// jest_to_rstest_full.md.
pattern jest_runner_neutral() {
  file($body) where {
    $body <: contains bubble or {
      // Imports
      `import $_ from 'jest'` => .,

      // done callback
      or {
        `$sym.$_($description, $callback)`,
        `$sym($description, $callback)`,
      } where {
        $sym <: or { `it`, `test` },
        $callback <: or {
          // For matching `xxx => { ... }` & `(xxx) => { ... }`
          `$parameter => { $_ }` where {
            $parameter <: not .
          },
          // For matching `function (xxx) { ... }`
          `function($parameters) { $_ }` where {
            $parameters <: [$one, ...]
          }
        } => `() => new Promise($callback)`,
      },

      // beforeAll, beforeEach, afterAll, afterEach hooks
      `$sym($callback)` where {
        and {
          $sym <: or { `beforeAll`, `beforeEach`, `afterAll`, `afterEach` },
          $callback <: arrow_function($body) where {
            $body <: call_expression() => `{ $body }`
          },
          // when `callback` is already a function, we don't need to do the migration
        }
      },

      // Custom matchers (extensions)
      // Delete the jest return type (the runner infers it)
      `:$ns.CustomMatcherResult` => . where {
        $ns <: or { `vi`, `rs`, `jest` }
      }
    }
  }
}

// Point imports from `@jest/globals` at `$source`, with `jest` renamed
// `$runner`: names a file imported under Jest stay imported. Shared with
// jest_to_rstest_full.md.
pattern jest_globals_imports($runner, $source) {
  file($body) where {
    $body <: includes "@jest/globals",
    $body <: contains bubble($runner, $source) `import $clause from $src` where {
      $src <: or { `'@jest/globals'`, `"@jest/globals"` },
      $src => $source,
      $clause <: maybe contains `jest` => $runner
    }
  }
}

// Remove `import "@testing-library/jest-dom"`: that entry point adds its
// matchers to Jest's types, and loads `@types/jest` with them. The runner's
// setup file registers the matchers instead. Shared with
// jest_to_rstest_full.md.
pattern jest_dom_imports() {
  file($body) where {
    $body <: includes "@testing-library/jest-dom",
    $body <: contains bubble `import $src` where {
      $src <: or {
        `'@testing-library/jest-dom'`,
        `"@testing-library/jest-dom"`,
        `'@testing-library/jest-dom/extend-expect'`,
        `"@testing-library/jest-dom/extend-expect"`
      }
    } => .
  }
}

// Every Jest API the shared rules leave, for a suite with no compatibility
// layer.
pattern jest_api_to_vitest() {
  file($body) where {
    // Every rule here matches `jest.` or `namespace jest`.
    $body <: includes "jest",
    $body <: contains bubble or {
      // jest.{Mock,MockedFunction,Mocked,MockedClass,MockedObject} => bare name + vitest import
      `jest.$sym` where {
        $sym <: or {
          `Mock`,
          `MockedFunction`,
          `Mocked`,
          `MockedClass`,
          `MockedObject`
        },
        $sym <: ensure_import_from(`'vitest'`)
      } => $sym,

      // jest.SpyInstance / jest.SpiedFunction => MockInstance + vitest import.
      // Both Jest type names map to vitest's MockInstance. Without this rule the
      // catch-all below rewrites `jest.SpiedFunction` to `vi.SpiedFunction`, which
      // is invalid since `vi` is imported as a value, not a namespace.
      or {
        `jest.SpyInstance`,
        `jest.SpiedFunction`,
      } where {
        $sym = "MockInstance",
        $sym <: ensure_import_from(`'vitest'`)
      } => `MockInstance`,

      // Catch-all: any other jest.$sym => vi.$sym
      `jest.$sym` => `vi.$sym` where {
        $sym <: not `CustomMatcherResult`
      },

      // Custom matchers (extensions)
      // Match the interface first: checking `within` on every node is slow.
      interface_declaration(name="Matchers") as $iface where {
        $iface <: within internal_module(name="jest") as $mod,
        $mod <: within ambient_declaration() as $decl,
        $iface <: interface_declaration(name="Matchers", $body) => `interface CustomMatchers<R = unknown> $body`,
        $decl => $iface,
        // The two `interface ... extends X {}` lines below are the vitest-
        // documented form for custom-matcher module augmentation. Empty
        // single-extends interfaces violate @typescript-eslint/no-empty-object-type
        // by default, so we emit eslint-disable-next-line comments to suppress
        // the warning at the source rather than relaxing the rule project-wide.
        $decl += `;\n\ndeclare module 'vitest' {
            // eslint-disable-next-line @typescript-eslint/no-empty-object-type -- vitest custom matcher augmentation
            interface Assertion<T = any> extends CustomMatchers<T> {}
            // eslint-disable-next-line @typescript-eslint/no-empty-object-type -- vitest custom matcher augmentation
            interface AsymmetricMatchersContaining extends CustomMatchers {}
        }`
      }
    },
  },
}

sequential {
  maybe literal_mock_defaults(),
  // Shared with jest_to_vitest_compat.md.
  maybe jest_mocks_to_vitest(),
  maybe and { file_includes(text = "require("), test_file(), contains require_to_import() },
  maybe and { file_includes(text = "await import("), test_file(), await_async_import_helpers() },
  maybe bare_mock_implementations(),
  maybe jest_runner_neutral(),
  maybe jest_globals_imports(runner = `vi`, source = `'vitest'`),
  maybe jest_dom_imports(),
  maybe jest_api_to_vitest(),
  // Off: test functions and `vi` stay globals. See `adjust_imports`.
  // maybe adjust_imports(runner = `vi`, source = `'vitest'`, source_alt = `"vitest"`),
}
```

## Convert assertions

```javascript
import { runCLI, mock, requireActual } from 'jest';

jest.mock('./some-path', () => 'hello');
jest.mock('./some-path', function () {
  doSomeSetups();
  return 'hello';
});
jest.mock('./some-path', () => ({ default: 'value' }));
jest.mock(
  './some-path',
  () =>
    function () {
      return 'hello';
    },
);

const { cloneDeep } = jest.requireActual('lodash/cloneDeep');
const { map } = jest.requireActual('lodash/map');
const { filter } = jest.requireActual('lodash/filter');
const originalModule = {
  ...jest.requireActual('../foo-bar-baz'),
  test: 1,
};
const currentWorkerId = JEST_WORKER_ID;

test.skip('test.skip should be processed', () => {
  expect('value').toBe('value');
});
it('should complete asynchronously', (done) => {
  expect('value').toBe('value');
  done();
});
it('should complete asynchronously', (finish) => {
  expect('value').toBe('value');
  finish();
});
it('should complete asynchronously', (done) => {
  expect('value').toBe('value');
  done();
});
it('should complete asynchronously', function (done) {
  expect('value').toBe('value');
  done();
});
it('should complete asynchronously', function (finish) {
  expect('value').toBe('value');
  finish();
});
test.skip('test.skip with done should be processed', (done) => {
  expect('value').toBe('value');
  done();
});
it('should be ignored', () => {
  expect('value').toBe('value');
});
it('should be ignored', function () {
  expect('value').toBe('value');
});

beforeAll(() => setActivePinia(createTestingPinia()));
beforeEach(() => setActivePinia(createTestingPinia()));
afterAll(() => setActivePinia(createTestingPinia()));
afterEach(() => setActivePinia(createTestingPinia()));
beforeAll(async () => {
  await expect('1').toBe('1');
  await expect('2').toBe('2');
});
beforeEach(() => {
  initializeApp();
  setDefaultUser();
});
afterEach(function () {
  initializeApp();
  setDefaultUser();
});
```

```javascript
vi.mock('./some-path', () => ({
  default: 'hello',
}));
vi.mock('./some-path', function () {
  doSomeSetups();
  return { default: 'hello' };
});
vi.mock('./some-path', () => ({ default: 'value' }));
vi.mock(
  './some-path',
  () =>
    function () {
      return 'hello';
    },
);

const { cloneDeep } = await vi.importActual('lodash/cloneDeep');
const { map } = await vi.importActual('lodash/map');
const { filter } = await vi.importActual('lodash/filter');
const originalModule = {
  ...(await vi.importActual('../foo-bar-baz')),
  test: 1,
};
const currentWorkerId = VITEST_WORKER_ID;

test.skip('test.skip should be processed', () => {
  expect('value').toBe('value');
});
it('should complete asynchronously', () =>
  new Promise((done) => {
    expect('value').toBe('value');
    done();
  }));
it('should complete asynchronously', () =>
  new Promise((finish) => {
    expect('value').toBe('value');
    finish();
  }));
it('should complete asynchronously', () =>
  new Promise((done) => {
    expect('value').toBe('value');
    done();
  }));
it('should complete asynchronously', () =>
  new Promise(function (done) {
    expect('value').toBe('value');
    done();
  }));
it('should complete asynchronously', () =>
  new Promise(function (finish) {
    expect('value').toBe('value');
    finish();
  }));
test.skip('test.skip with done should be processed', () =>
  new Promise((done) => {
    expect('value').toBe('value');
    done();
  }));
it('should be ignored', () => {
  expect('value').toBe('value');
});
it('should be ignored', function () {
  expect('value').toBe('value');
});

beforeAll(() => {
  setActivePinia(createTestingPinia());
});
beforeEach(() => {
  setActivePinia(createTestingPinia());
});
afterAll(() => {
  setActivePinia(createTestingPinia());
});
afterEach(() => {
  setActivePinia(createTestingPinia());
});
beforeAll(async () => {
  await expect('1').toBe('1');
  await expect('2').toBe('2');
});
beforeEach(() => {
  initializeApp();
  setDefaultUser();
});
afterEach(function () {
  initializeApp();
  setDefaultUser();
});
```

## Leave vi a global

```javascript
jest.mock('./some-path', () => ({ default: 'value' }));
```

```javascript
vi.mock('./some-path', () => ({ default: 'value' }));
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

## Leave a file with mocha and expect imports alone

```javascript
import expect from 'expect';
import { describe, test, before, beforeEach, after } from 'mocha';

describe('Repository component', () => {
  beforeEach(() => {});
  it('should complete asynchronously', () => {
    expect('value').toBe('value');
  });
});
```

```javascript
import expect from 'expect';
import { describe, test, before, beforeEach, after } from 'mocha';

describe('Repository component', () => {
  beforeEach(() => {});
  it('should complete asynchronously', () => {
    expect('value').toBe('value');
  });
});
```

## Transform custom assertions

```javascript
declare global {
// eslint-disable-next-line @typescript-eslint/no-namespace
namespace jest {
    interface Matchers<R> {
        toEvaluateAs(
            expected: number,
            vars?: Variables,
            functions?: ReadonlyArray<string>,
        ): R;
    }
}
}
```

```javascript
interface CustomMatchers<R = unknown> {
    toEvaluateAs(
        expected: number,
        vars?: Variables,
        functions?: ReadonlyArray<string>,
    ): R;
}

declare module "vitest" {
    // eslint-disable-next-line @typescript-eslint/no-empty-object-type -- vitest custom matcher augmentation
    interface Assertion<T = any> extends CustomMatchers<T> {}
    // eslint-disable-next-line @typescript-eslint/no-empty-object-type -- vitest custom matcher augmentation
    interface AsymmetricMatchersContaining extends CustomMatchers {}
}
```

## Rewrite the rest of the Jest API

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
import { describe, it, expect, vi, Mock } from 'vitest';

vi.mock("./util", async () => ({
    ...(await vi.importActual("./util")),
    decode: vi.fn(),
}));

describe("thing", () => {
    it("works", () => {
        const spy = vi.spyOn(console, "warn").mockImplementation(() => {});
        const mock: Mock = vi.fn();
        vi.useFakeTimers();
        vi.advanceTimersByTime(10);
        expect(mock).not.toHaveBeenCalled();
        expect(spy).not.toHaveBeenCalled();
    });
});
```

## Apply the shared rules

```javascript
describe("the env", () => {
    it.failing("is production", () => {
        jest.replaceProperty(process.env, "NODE_ENV", "production");
        const value = require("./value").value;
        expect(process.env.JEST_WORKER_ID).toBe(value);
    });
});
```

```javascript
describe("the env", () => {
    it.fails("is production", async () => {
        vi.stubEnv("NODE_ENV", "production");
        const value = (await import("./value")).value;
        expect(process.env.VITEST_WORKER_ID).toBe(value);
    });
});
```
