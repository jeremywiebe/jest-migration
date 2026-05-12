---
title: Jest to Vitest
tags: [migration, js]
---

Convert Jest tests to Vitest

## Known limitations — handle by hand after running

- **Destructured type imports from `'@jest/globals'`** (e.g. `import { Mock, MockedFunction } from '@jest/globals'` used purely as types) are not preserved. The script deletes the whole `import ... from '@jest/globals'` line and the auto-import pass only re-adds named symbols that appear as **call expressions** (`describe(...)`, `expect(...)`, …). Bare type references like `let m: Mock = ...` will be orphaned. After running the codemod, `tsc` will surface these as "Cannot find name 'Mock'" — fix by adding `import { Mock } from 'vitest'` (the names map 1:1 except `SpyInstance → MockInstance`, which the script already rewrites). Namespaced usages like `jest.Mock` are fully handled.
- **Multi-parameter `done` callbacks** (`(done, fail) => { ... }`) get wrapped as `new Promise((done, fail) => { ... })`, but only the first parameter is used by Vitest's Promise contract. Rare; flag if hit.
- **`namespace jest { interface Expect { ... } }`** (asymmetric custom matchers) is not handled — only `interface Matchers<R>` is rewritten. Less common; hand-fix if encountered.

```grit
engine marzano(0.1)
language js

pattern adjust_imports_vitest() {
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
        `vi`
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
        // Skip symbols already imported from vitest. `ensure_import_from` (the
        // marzano stdlib helper used below) does not dedupe within an existing
        // named-import list, so without this guard a file like vite-test-setup.ts
        // (which pre-imports `vi`, `afterEach`) ends up with
        // `import {afterEach, vi, vi, afterEach} from "vitest";`. This guard
        // also makes the codemod idempotent on already-migrated files.
        $sym <: not imported_from(from = `'vitest'`),
        $sym <: not imported_from(from = `"vitest"`),
        // Filter out methods which are imported as default from any module
        $statements <: not contains or {
          `import $sym from $_`,
        }
      },
      $source = `'vitest'`,
      $vi = `vi`,
      if ($sym <: not `jest`) {
        $sym <: ensure_import_from($source)
      } else {
        $vi <: ensure_import_from($source)
      }
    }
  }
}

pattern main_jest_to_vitest_migration() {
  file($body) where {
    $body <: contains bubble or {
      `JEST_WORKER_ID` => `VITEST_POOL_ID`,

      // Imports
      `import $_ from 'jest'` => .,
      `import $_ from '@jest/globals'` => .,

      // MODULE MOCKS
      // default literal mocking
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
        } => `vi.mock($module, $mockImplementation)`,

      `...jest.requireActual($module)` => `...(await vi.importActual($module))`,
      `jest.requireActual($module)` => `await vi.importActual($module)`,
      `...jest.requireMock($module)` => `...(await vi.importMock($module))`,
      `jest.requireMock($module)` => `await vi.importMock($module)`,

      // jest.{Mock,MockedFunction,Mocked,MockedClass,MockedObject} => bare name + vitest import
      `jest.$sym` where {
        $sym <: or {
          `Mock`,
          `MockedFunction`,
          `Mocked`,
          `MockedClass`,
          `MockedObject`
        },
        $sym <: ensure_import_from(`"vitest"`)
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
        $sym <: ensure_import_from(`"vitest"`)
      } => `MockInstance`,

      // Catch-all: any other jest.$sym => vi.$sym
      `jest.$sym` => `vi.$sym` where {
        $sym <: not `CustomMatcherResult`
      },

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

      // test.failing() => test.fails()
      `$sym.failing($args)` => `$sym.fails($args)` where {
        $sym <: or { `test`, `it` },
      },

      // .mockImplementation() with no args is valid in Jest (returns undefined)
      // but Vitest's typings require an explicit implementation function.
      `$expr.mockImplementation()` => `$expr.mockImplementation(() => {})`,

      // Custom matchers (extensions)
      // Delete the jest return type (Vitest can infer it)
      `$sym` => . where {
        $sym <: `:$ns.CustomMatcherResult` where {
            $ns <: or { `vi`, `jest`}
        }
      },

      `$iface` where {
        $iface <: within internal_module(name="jest") as $mod,
        $mod <: within ambient_declaration() as $decl,
        $iface <: interface_declaration(name="Matchers", $body) => `interface CustomMatchers<R = unknown> $body`,
        $decl => $iface,
        $decl += `;\n\ndeclare module 'vitest' {
            interface Assertion<T = any> extends CustomMatchers<T> {}
            interface AsymmetricMatchersContaining extends CustomMatchers {}
        }`
      }
    },
  },
}

sequential {
  maybe main_jest_to_vitest_migration(),
  maybe contains adjust_imports_vitest(),
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
const currentWorkerId = VITEST_POOL_ID;

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
    interface Assertion<T = any> extends CustomMatchers<T> {}
    interface AsymmetricMatchersContaining extends CustomMatchers {}
}
```
