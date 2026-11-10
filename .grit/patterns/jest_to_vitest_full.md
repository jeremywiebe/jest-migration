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
4. The rewrites that don't depend on the runner: removing Jest's imports,
   `done` callbacks, hook bodies and the custom matchers' result type.
5. Every other Jest API: types, `jest.*` calls and custom matchers.
6. Imports from `vitest` for the names the file uses.

`jest_to_rstest_full.md` reuses passes 1, 3, 4 and 6.

## Known limitations — handle by hand after running

- **Destructured type imports from `'@jest/globals'`** (e.g. `import { Mock, MockedFunction } from '@jest/globals'` used purely as types) are not preserved. The script deletes the whole `import ... from '@jest/globals'` line and the auto-import pass only re-adds named symbols that appear as **call expressions** (`describe(...)`, `expect(...)`, …). Bare type references like `let m: Mock = ...` will be orphaned. After running the codemod, `tsc` will surface these as "Cannot find name 'Mock'" — fix by adding `import { Mock } from 'vitest'` (the names map 1:1 except `SpyInstance → MockInstance`, which the script already rewrites). Namespaced usages like `jest.Mock` are fully handled.
- **Multi-parameter `done` callbacks** (`(done, fail) => { ... }`) get wrapped as `new Promise((done, fail) => { ... })`, but only the first parameter is used by Vitest's Promise contract. Rare; flag if hit.
- **`namespace jest { interface Expect { ... } }`** (asymmetric custom matchers) is not handled — only `interface Matchers<R>` is rewritten. Less common; hand-fix if encountered.
- **`jest.replaceProperty()` on anything but `process.env`** becomes `vi.replaceProperty()`, which doesn't exist.

```grit
engine marzano(0.1)
language js

// Import the test functions a file calls, and `$runner` in place of `jest`,
// from `$source`. `$source_alt` is `$source` in the other quote style.
// Shared with jest_to_rstest_full.md.
pattern adjust_imports($runner, $source, $source_alt) {
  $body where {
    $body <: or {
      `$sym.$_($_)`,
      `$sym($_)`,
      // Also match bare property accesses like `vi.advanceTimersByTime`
      // (used as a value, not invoked). Without this, `vi` is not
      // auto-imported when only referenced via property access.
      `$sym.$_`,
    } where {
      $program <: program($statements),
      $sym <: or {
        `test`,
        `expect`,
        `describe`,
        `it`,
        `beforeEach`,
        `afterEach`,
        `beforeAll`,
        `afterAll`,
        `jest`,
        $runner
      } where {
        // Filter out methods which are imported from mocha.
        // `imported_from` compares the `from` clause syntactically (quote style
        // included), so we check both single- and double-quoted forms.
        $sym <: not imported_from(from = `'mocha'`),
        $sym <: not imported_from(from = `"mocha"`),
        // Filter out methods which are imported from tstyche (TypeScript type-testing library
        // whose API overlaps with Jest/Vitest — describe/it/expect — but operates at the type
        // level, not runtime. Type-tests should keep their tstyche imports intact.)
        $sym <: not imported_from(from = `'tstyche'`),
        $sym <: not imported_from(from = `"tstyche"`),
        // Filter out methods imported from storybook/test (Storybook's test utility
        // package re-exports describe/it/expect/within and is used in regression
        // *.stories.tsx files alongside vitest in the same workspace.)
        $sym <: not imported_from(from = `'storybook/test'`),
        $sym <: not imported_from(from = `"storybook/test"`),
        // Skip symbols already imported from the runner. `ensure_import_from` (the
        // marzano stdlib helper used below) does not dedupe within an existing
        // named-import list, so without this guard a file like vite-test-setup.ts
        // (which pre-imports `vi`, `afterEach`) ends up with
        // `import {afterEach, vi, vi, afterEach} from "vitest";`. This guard
        // also makes the codemod idempotent on already-migrated files.
        $sym <: not imported_from(from = $source),
        $sym <: not imported_from(from = $source_alt),
        // Filter out methods which are imported as default from any module
        $statements <: not contains or {
          `import $sym from $_`,
        }
      },
      if ($sym <: not `jest`) {
        $sym <: ensure_import_from($source)
      } else {
        $runner <: ensure_import_from($source)
      }
    }
  }
}

// A mock factory that returns a literal returns it as the module's `default`
// export. The shared rules then rewrite the `jest.mock()` call itself. Shared
// with jest_to_rstest_full.md.
pattern literal_mock_defaults() {
  file($body) where {
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
    $body <: contains bubble {
      `$expr.mockImplementation()` => `$expr.mockImplementation(() => {})`
    }
  }
}

// Rewrites that don't depend on the target runner: Jest's imports, `done`
// callbacks, hook bodies and the custom matchers' result type. Shared with
// jest_to_rstest_full.md.
pattern jest_runner_neutral() {
  file($body) where {
    $body <: contains bubble or {
      // Imports
      `import $_ from 'jest'` => .,
      `import $_ from '@jest/globals'` => .,
      `import $_ from "@jest/globals"` => .,

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
      `$sym` => . where {
        $sym <: `:$ns.CustomMatcherResult` where {
            $ns <: or { `vi`, `rs`, `jest` }
        }
      }
    }
  }
}

// Every Jest API the shared rules leave, for a suite with no compatibility
// layer.
pattern jest_api_to_vitest() {
  file($body) where {
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
      `$iface` where {
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
  maybe and { test_file(), contains require_to_import() },
  maybe and { test_file(), await_async_import_helpers() },
  maybe bare_mock_implementations(),
  maybe jest_runner_neutral(),
  maybe jest_api_to_vitest(),
  maybe contains adjust_imports(runner = `vi`, source = `'vitest'`, source_alt = `"vitest"`),
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
import { vi, test, expect, it, beforeAll, beforeEach, afterAll, afterEach } from 'vitest';

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

## Import vi even with just vi.mock

```javascript
jest.mock('./some-path', () => ({ default: 'value' }));
```

```javascript
import { vi } from 'vitest';

vi.mock('./some-path', () => ({ default: 'value' }));
```

## Do not import methods which are imported from mocha/expect

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
import { it } from 'vitest';

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
import { Mock, vi, describe, it, expect } from 'vitest';

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
import { describe, it, vi, expect } from 'vitest';

describe("the env", () => {
    it.fails("is production", async () => {
        vi.stubEnv("NODE_ENV", "production");
        const value = (await import("./value")).value;
        expect(process.env.VITEST_WORKER_ID).toBe(value);
    });
});
```
