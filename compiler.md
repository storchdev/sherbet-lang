# Sherbet Compiler Design — Draft v0.1

Nov 8, 2026 · @Hudson Shi

How the compiler for the language in `spec.md` (Draft v0.2) is built. The spec is the source of truth for what programs mean; this file covers how the compiler gets there. When the two disagree, fix this file, or raise the question and change the spec.

The command is `sherbet`, source files use `.sher`, and `SHERBET_PATH` names the user library folder.

## Overview

The compiler is written in Nim and compiles one program, meaning a main file plus its imports and the standard library, into one C file. `gcc` or `clang` builds that and links it with the prebuilt C runtime and GMP.

| Piece | Language | Where | Role |
| --- | --- | --- | --- |
| Compiler | Nim 2.2, standard library only | `src/` | Source to C |
| Runtime | C (GNU C11) | `runtime/` | Allocator, strings, I/O, formatting, traps, thread pool, GMP glue |
| Standard library | The language itself | `lib/` | Iterators, collections helpers, graphs, grids, math |
| Tests | The language, plus a small runner | `tests/` | Programs with `#in`/`#out`, expected errors |

**Toolchain.** Developed against Nim 2.2.12, gcc 16.2 and clang 23.1 on x86-64 Linux, with GMP from the system. Other platforms are not a goal for v1.

**No dependencies.** The compiler uses only Nim's standard library and builds with one `nim c -d:release src/sherbet.nim`, so there is no Nimble package. A `config.nims` holds the flags.

## Command line

| Command | Does |
| --- | --- |
| `sherbet run day3.sher` | Compile and run; stdin and stdout pass through |
| `sherbet test day3.sher` | Compile once, run every `#in` block, compare against `#out` |
| `sherbet build day3.sher -o day3` | Compile to an executable |
| `sherbet check day3.sher` | Parse and type-check only, no C compiler |
| `sherbet emit day3.sher` | Print the generated C |
| `sherbet emit --standalone day3.sher` | Print one self-contained C file for submitting to a judge |

| Flag | Effect |
| --- | --- |
| `--debug` | `-O0 -g` plus `-fsanitize=address,undefined`; keeps the C file |
| `--keep-c` | Keep the generated C next to the binary |
| `--cc clang` | Use clang instead of gcc |

- **Caching.** The runtime is compiled once per compiler version into `~/.cache/sherbet/` as `libsherbetrt.a`. Programs are not cached in v1; `gcc -O2` on one generated file is fast enough for AoC-sized programs.
- **Exit codes.** A compile error exits with 1. A trap in the program exits with 101 after printing its message, so `sherbet test` can tell a crash from wrong output.
- **`sherbet test` output.** Each block reports pass, fail with a line diff, or crash with the trap message, then a summary line. Blocks run in parallel, since they are independent processes.

## Source layout

One Nim module per stage, so each stage can be tested on its own.

```
src/
  sherbet.nim        command line and driver
  diag.nim       spans, error collection and printing
  source.nim     file loading, #in/#out and pragma parsing
  lexer.nim
  ast.nim        AST node types
  parser.nim
  resolve.nim    imports, scopes, name binding, captures
  types.nim      type representation and unification
  infer.nim      instantiation, inference, overloads, dispatch
  check.nim      checks on typed code: .par() rules, unused variables
  lower.nim      typed AST to C-shaped tree
  emitc.nim      C text, mangling, #line
  cc.nim         invoking gcc or clang and running the result
runtime/
  sherbetrt.h        everything the generated C includes
  alloc.c  str.c  io.c  fmt.c  trap.c  par.c  big.c  map.h  sort.c
lib/
  prelude.sher     re-exports the rest; imported implicitly
  iter.sher  coll.sher  str.sher  math.sher  grid.sher  graph.sher  tree.sher  ds.sher  matrix.sher
tests/
  run/  errors/  traps/  lib/  aoc/
```

## Pipeline

The spec lists seven stages. In the code, inference and monomorphization are one worklist pass, because a generic function is only checked when it is instantiated with concrete types (see Infer and instantiate).

### 1. Source

- **Test blocks and pragmas.** The lexer finds these lines (see Lexer) and this stage's helpers turn them into test cases and a pragma record. Pragmas are `#default int = big`, `#pretty(...)`, `#par(...)` and `#mem arena` or `#mem gc`. In an imported file they are an error.
- **Files** are read as bytes. Source is UTF-8 but the lexer only cares about ASCII outside string literals.

### 2. Lexer

Produces tokens with spans: a file index and start and end byte offsets, end exclusive. Line and column are not stored; when printing a diagnostic they come from a binary search over the file's line start offsets, recorded when the file is loaded.

- **Newlines** become `Newline` tokens, which the lexer drops when:
  - the innermost open bracket is `( )`, `[ ]` or `.[ ]` (it tracks a stack of open brackets; `{` does not suppress newlines, since blocks need them, even when the `{` is itself inside parentheses),
  - the previous token is a binary operator other than `..` or `..=` (word operators `and`, `or`, `in`, `is` and `not` count, so `a is not` continues), or is `=`, `=>`, `:`, `,`, or an opening bracket (a range's end may be missing, so `r = 1..` ends at the newline),
  - the next line that is not blank or only a comment starts with `.` (but not `..`, which starts a range) or `|` (but not `|=`), or with the whole word `else` or `catch`. A statement can never start with any of these, so this covers variant types written one per line, multi-line bitwise expressions and `else` on its own line.

  Every token also records whether a line break came before it, even when the `Newline` was dropped. The parser needs this for trailing closures, because inside `( )` there is no `Newline` token to tell it the `{` is on a later line.

  The parser skips `Newline` inside map and set literals, which handles multi-line `{ ... }` literals without the lexer knowing what kind of brace it is.
- **Directives.** At the start of a line in the main loop, the lexer checks for a whole-line directive or pragma. A test directive (exactly `#in`, `#out` or `#end`, optionally followed by a path and a `//` comment) makes it read raw lines up to the next directive or end of file and store them as a test block, so `"""` and `//` in test data are plain text. A pragma line is stored and produces no tokens. String scanning never reaches this check, so a `#in` inside `"""` stays text. Open brackets do not affect it: the directive still counts and the parser reports the missing closer.
- **Strings.** Interpolated strings are lexed into parts: literal text, then for each `{...}` a nested token stream for the expression and, after a top-level `:`, the format spec. A sub-lexer scans each expression, so `"{m["a"]}"` works. A spec is itself a list of parts up to its closing `}`: its text is kept literally, with no escapes, and each `{...}` inside it is another sub-lexed expression, so `.{p} r3` is the text `.`, the expression `p` and the text ` r3`, and `fill{"}"}` works. The part also keeps the span of the whole spec for errors. The parser parses every nested token list, including those in specs, so their names are resolved like any others. `{{` and `}}` are literal braces. A `=` right before the closing `}` or the top-level `:` marks the `{x=}` form, and the expression's source text is kept for printing; `{a==b}` is an ordinary comparison. Raw strings and `"""` strings are handled here, including removing the common indentation.
- **Numbers.** Underscores are dropped. `0x`, `0b` and `0o` start a whole literal in that base, and a prefix with no digits, or a digit outside the base, is a lexer error. Otherwise, a `.` joins a number only when a digit follows it, so `0..n` and `5.abs()` work, and a literal with such a `.` is fractional unless it has an exponent. A literal with an exponent is whole when its value is whole, like `1e9` or `2.5e3`, and fractional otherwise, like `1e-3`. Right after a member `.` or `?.`, digits are a plain integer, so `t.0.1` is two tuple accesses. A number directly followed by a letter, like `12abc` or `0XFF`, is a lexer error. Values are kept as exact strings until the type is known, since a literal may become `big`.
- **Escapes.** Strings and bytes accept `\n \t \r \0 \\ \" \'` and `\xHH`. Anything else is a lexer error.
- **Bytes.** `'#'` is a byte literal.
- **Keywords:** `fn let if else while for in break continue return match try catch raise import as record type extern memo and or not is null true false`.
- **Shorthand parameters.** `$` followed by digits is one token holding the index, as in `$0` and `$12`.
- **Array views.** `.[` is one token and opens a bracket for newline tracking. The parser treats it as a postfix operator at the same level as indexing, so `a.[i..j].sum()` chains without parentheses.

### 3. Parser

Recursive descent for statements and declarations, and a Pratt parser for expressions.

- **Precedence.** Binding powers follow the operator table in `spec.md`. `**` is right-associative and its right operand may start with a unary operator. Bare `try expr` and `raise expr` parse their operand at the `and` level, so `try int(s) or 0` is `(try int(s)) or 0`.
- **Chained comparisons** become one node with a list of operands, so the lowering can evaluate each middle operand once. `not in` and `is not` are single operators, and `is` does not chain.
- **Which `{` is a block.** After an `if`, `while`, `for`, `match`, `try` or `catch` head, `else`, `fn ... =`, `=>` and a match arm's colon, `{` always starts a block. A map literal there needs parentheses, as in Rust. Anywhere else in an expression, the parser scans to the matching `}`: if it is empty, or its first item is followed by a `:` at the top level of the braces, it is a map literal; otherwise it is a shorthand closure.
- **Blocks.** A block node holds its statements and an optional final expression, which is its value. A trailing `;` after that expression does not remove it, as the spec requires.
- **Lambdas.** At `(` in expression position, the parser scans ahead to the matching `)`. If `=>`, or `-> Type =>`, follows, the parentheses are a parameter list; otherwise they are a parenthesized expression or tuple. A name followed by `=>` is a one-parameter lambda. The body is a full expression at the lowest precedence, so `x => a or b` takes all of `a or b`.
- **Statements vs. expressions.** `if`, `match` and `try` parse as expressions everywhere. A statement that starts with one of the keywords in the spec's rule and ends with `}` needs no separator before the next statement.
- **Assignment.** `x = e`, `a, b = e`, `x += e` and `let x = e` are separate node kinds. The parser does not decide whether `x = e` declares; the resolver does. A left side shaped like a record, variant or array is parsed as an expression, then converted to a pattern when `=` follows.
- **Shorthand closures.** A closure node is pushed on a stack while its body is parsed. Each `$n` is attached to the top closure, which records the highest index; that sets the parameter count. A `$n` with an empty stack is a parse error. Braces of `if`, `match` and the like do not push, so `$0` inside them belongs to the closure around them.
- **Trailing closures.** After a call's `)`, or after `.name` with no parentheses, a `{` on the same line is parsed as a closure and appended as the last argument. The parser keeps a flag while parsing an `if`, `while`, `for` or `match` head that turns this off, so the `{` there starts the body.
- **Labels.** `name:` at the start of a statement followed by `for` or `while` is a label.
- **`for` heads** hold one to three comma-separated patterns. The checker assigns their roles from the iterable's type and reports the tuple and map loop errors.
- **`is`** parses a pattern on its right. Its bindings are scoped like narrowing: the rest of an `and` chain and the true path.
- **Errors.** The parser stops at the first syntax error in a file. Recovery is not worth its complexity for files this size.

### 4. AST

- Nim object variants (`case kind`), one node type with an integer id per node.
- Results of later stages live in side tables keyed by node id and instantiation, not in the nodes, because one generic function body is checked many times with different types.
- Every node keeps its span for diagnostics.

### 5. Resolve

Turns names into bindings and builds the module graph.

- **Imports.** `import a.b` looks for `a/b.sher` next to the importing file, then under `SHERBET_PATH`. Each file is loaded once. Cycles are an error that prints the cycle. The order modules' top-level code runs in is the depth-first order the spec describes.
- **Scopes.** Prelude, then the module, then function, then block. The prelude scope is the standard library's star import. Module-level `fn`, `record`, `type` and `extern` declarations are collected before any body is resolved, so functions can be called before their definition.
- **Overload sets.** A function name binds to a set of definitions, not to one. Shadowing follows the spec: a definition in the user's file with the same annotated parameter types as a library one replaces it in that file's scope; a different one is added to the set. Each module keeps its own view, so library code never sees the user's replacements.
- **Assignment.** `x = e` reassigns if `x` is bound in an enclosing scope of the same function, including a captured one, and declares a new local otherwise. `let` always declares. Module globals are visible in every function of their module.
- **Qualified names.** `geom.dist` resolves to the module's binding when `geom` names an import and is not shadowed by a local. Otherwise it is field access or uniform call syntax, decided during inference.
- **Captures.** For every lambda and nested `fn`, record which outer variables it captures and whether any of them is assigned after capture. That decides boxing in the lowering.
- **Unset globals.** A global read inside a function is marked so the lowering can add the `"unset"` check where the global may be read before it is assigned. Globals assigned before any function call in program order skip the check.

### 6. Types

- **Representation.** A type is a node with a kind: a type variable, a primitive (`i8` to `u64`, `f32`, `f64`, `bool`, `str`, unit, never), an array, map, set, tuple or named tuple, a record or variant type (by declaration), a function type, `Mod(m)`, `big`, `rat`, `bigfloat`, or an optional.
- **Unification** is the usual union-find over type variables, with two additions:
  - **Number variables.** A literal's type is a variable restricted to whole or fractional number types. At the end of an instantiation, any still-open one becomes the default (`int`, or `big` under `#default int = big`, and `float`).
  - **Optional flags.** Each variable carries a nullable flag that only goes from false to true, as the spec describes. Unifying a variable with `null` or with a `T?` sets it. Narrowing is handled by giving the narrowed local a separate non-optional type on the narrowed path.
- **Widening** is not unification. Where a value of one numeric type meets a slot of another, the checker inserts a widening node if the spec's widening table allows it, and reports an error otherwise.

### 7. Infer and instantiate

This is the largest stage. It checks function bodies and creates specialized copies of them in one worklist pass.

- **Instantiation key.** A function is checked once per tuple of concrete argument types, and the result is cached under that key. The program's top-level code is the root. Each call either finds a cached instance or queues a new one.
- **Within one instance**, inference is plain unification over local variables, empty literals, lambdas and optionals. Overload resolution and field access whose receiver type is still unknown are deferred, and retried each time more is known. At the end, open number variables take their defaults and the deferred list runs once more. Anything still unresolved is an error that names the expression.
- **Lambdas** are checked where they are written, with their parameter types taken from the call they are passed to. The receiver of a method call is checked first, so `xs.map(x => ...)` knows `x`.
- **Function values in instantiation keys.** Closures are keyed by their function type, `fn(int) -> int`, not by which lambda it is. So `map` is instantiated once per element and result type, not once per lambda. The C compiler can still inline a call through a function pointer that it can see is constant.
- **Recursion.** While an instance is being checked, its return type is a variable. A recursive call to the same instance uses that variable. A call that would create a new instance of a function already on the stack with ever-growing types, like polymorphic recursion, is an error after a fixed depth.
- **Overloads.** Candidates are filtered by argument count, named arguments and annotations; the most specific match wins. Ties are an error at the definition when they can be detected there, and at the call otherwise.
- **Overloads on variants.** When an argument's type is a variant type, resolution runs once per variant, as the spec describes. If the choices differ, the instance records a dispatch node, which the lowering turns into a switch on the tag. Several variant arguments give a nested switch.
- **Uniform call syntax.** `x.f(args)` tries a field `f`, then `f` in scope, then `f` in the module that declared the type of `x`.
- **Fields.** Field access on a known record or tuple looks the name up exactly. On a variant type, it is allowed when every variant has the field. On an unknown type it is deferred.
- **Argument prefixes** are resolved against the chosen candidate's parameter names, after overload resolution has the candidate set. If prefix matching gives different results for different candidates, that is an ambiguity error.
- **Type-directed builtins.** `print`, `read`, `read_rows`, the `read_` family's numeric typing, and the conversions named after types, such as `int(x)` and `u8(x)`, are handled here directly, not through overloading.
- **Format strings.** The words of each interpolation's spec are parsed and checked against the expression's type here, since that is where the type is known. It becomes a format node with a fixed set of options.
- **Errors in instances** show the expression, then the chain of calls that created the instance, ending at the user's own code. That is the only way an error in generic library code makes sense.

### 8. Check

Runs on the typed, specialized program.

- **`.par()` rules.** A bottom-up pass over the call graph computes, for each instance, whether it writes to globals, writes to captured variables, or mutates any value it did not allocate itself. Values are tracked by origin: allocated in this call, or "from outside" (parameters, captures, globals, anything loaded from those). Mutating a value from outside is a write, and a view has the same origin as its source. Recursion is handled by iterating to a fixed point. A parallel step whose lambda writes is an error that points at the write, through the call chain. `print`, `put` and `read_` are marked as writes to stdout or stdin, and `dbg` and `eprint` are allowed.
- **Fusion eligibility** is the same summary: no I/O and no writes to captured variables.
- **Other checks:** unused variables (warning), `[[0] * m] * n` (error), overriding `==` without `hash` (error), and `Mod(m)` modulus rules.

### 9. Lower

Turns typed instances into a C-shaped tree: statements, expressions, and declarations that map one-to-one to C. GNU statement expressions `({ ... })` let most expression forms lower without moving code into temporaries.

| Construct | Lowers to |
| --- | --- |
| `if`, `match`, block as a value | Statement expression |
| `match` | Tests in arm order: tag checks, length checks, literal compares, then bindings; guards as extra conditions |
| Chained comparison | Temporaries for middle operands |
| `x?.f`, `x or d` on an optional, `x!` | Tag or null test |
| `try`/`catch` | Body as a closure called through `rt_try`; see below |
| Closures | Environment struct plus function pointer; captured variables that are assigned after capture live in a heap box |
| Fresh loop variable | A new box per iteration, only when a closure captures it |
| `m[k] += 1`, `m[k].push(x)` | Find-or-insert with the value type's zero |
| Variant dispatch | `switch` on the tag, calling each chosen instance |
| `memo fn` | Wrapper that looks up a hash map keyed by the argument tuple, copying array, map and set arguments into the key on insert; one map per thread when called from `.par()` |
| `x.copy(...)` | A generated copy function per type, taking the remaining depth; with `records: true`, a visited table from old to new objects keeps sharing and cycles |
| Default arguments | Evaluated at the call site on every call that omits them, in parameter order, so they can use earlier parameters |
| Iterator chains | Library calls in v1; fused loops later (milestone 7) |
| `.par()` chains | A chunk function plus a call into the thread pool |
| String interpolation | Calls into the runtime's string builder and formatters |
| Overflow-checked arithmetic | `__builtin_*_overflow` and a trap call |

- **`try` and control flow.** A `return`, `break` or `continue` inside a `try` body has to leave the closure. The closure returns a small status code (normal, return, break-to-label, continue-to-label), the value goes through the environment, and the caller acts on the status after `rt_try` returns.
- **Unset globals.** Each global that needs the check has a flag that the lowering tests on read.

### 10. Emit C

- One `.c` file: `#include "sherbetrt.h"`, type declarations in dependency order, function prototypes, then globals and functions, with `#line` directives pointing at `.sher` source lines.
- **Mangling.** Every instance gets a readable name from its module, function name and a short hash of its type key, like `geom_dist_3fa2`. Readable names make `sherbet emit` and gdb usable.
- **Compile.** `gcc -std=gnu11 -O2 -fwrapv -fno-strict-aliasing -w`, then link with `libsherbetrt.a -lgmp -lpthread -lm`. Warnings are off because generated code is not the user's. A C compiler error is always a bug in `sherbet`; it is reported as an internal error with the path to the kept C file.
- **Standalone output.** `--standalone` inlines only the runtime parts the program reaches, drops `#line`, and runs `.par()` serially, since judges often restrict threads. Inlining only reachable code also keeps output within judges' source size limits. A program that needs GMP is a compile error in this mode, since most judges do not provide it and contest answers rarely exceed `i64`.

## Value representation in C

| Language type | C representation |
| --- | --- |
| `int`, fixed-width integers | `int64_t`, `uint8_t` and so on |
| `float` | `double` |
| `bool` | `bool` |
| `str` | `struct { const uint8_t *p; int64_t len; }` by value; slices share bytes |
| `[T]` | Pointer to `{ T *data; int64_t len, cap; }`, so arrays are shared on assignment |
| `{K: V}`, `{T}` | Pointer to an open-addressing hash table, specialized per key and value type (see Runtime) |
| Tuple, named tuple | A C struct per shape, by value |
| Record | Pointer to a struct |
| Variant type | Pointer to a struct whose first field is the tag; each variant is its own struct with the tag first; fieldless variants are shared static objects |
| `T?` for records and variants | Nullable pointer |
| Other `T?` | `struct { bool has; T val; }` |
| Function value | `struct { void *fn; void *env; }` |
| `big`, `rat`, `bigfloat` | Pointer to a runtime-allocated `mpz_t`, `mpq_t` or `mpf_t` |
| `Mod(m)` | `uint64_t`; the modulus and Barrett constant live in globals for that type |
| unit | No value; `void` in returns |

- Wrapping types (`wrap8` to `wrap64`) are plain unsigned integers.
- **Bool operators.** `~` on a `bool` lowers to C's `!`, because C's `~` would turn `true` into a nonzero int. `& | ^` on `bool` lower to the C operators and evaluate both operands.
- **Membership.** The checker resolves `x in c` to the `contains` overload for `c`'s type, so builtin and user types share one path. Each operand is evaluated once, including in chained comparisons. Range `contains` compares bounds and never builds an iterator.
- **View assignment.** `a.[i..j] = b` is its own assignment target. It checks the length and copies with `memmove`, so overlapping ranges work. Other compound assignments to a view are compile errors.
- **Array views** use the normal `[T]` header with `data` pointing into the source buffer and `cap` set to 0, so indexing has no extra cost and growth reaches the slow path, which traps. Old array buffers are never reused after growth, so a view or generated loop holding the old data pointer stays memory-safe. `--debug` builds also store the source and its buffer generation in the view, to trap on stale use.
- Equality, hashing, ordering and printing for every type are generated per type by the compiler, unless a hook is defined.

## Runtime

C, compiled once, with a header the generated code includes. Small enough to read in an afternoon.

- **Allocation calls.** There are two entry points in both memory modes: one for objects that may contain pointers, which takes a type descriptor, and one for pointer-free data such as `[int]`, string bytes and GMP limbs. GMP is pointed at the runtime with `mp_set_memory_functions`.
- **Arena mode.** One bump allocator per thread, in large blocks from `mmap`, never freed.
- **Garbage collector.** A non-moving, stop-the-world mark-sweep collector with size-class blocks, a separate path for large objects, side mark bitmaps, an explicit mark stack and lazy sweeping. A collection starts when the heap has doubled since the last collection's live size.
- **GC roots.** A compiler-emitted table of globals, registers spilled with `setjmp`, a conservative scan of the active stack, and runtime-owned roots such as `.par()` result slots and per-thread memo tables.
- **GC pointers.** Heap objects are scanned exactly from their type descriptors, and pointer-free objects are skipped. A stack word or heap pointer field counts if it points anywhere inside an object, since `str` slices and optimized C can hold interior pointers. Allocations get one extra byte so a one-past-the-end pointer still lands inside the object. Addresses outside the GC heap, such as static variants and the input buffer, are ignored.
- **GC and threads.** Collection runs only outside `.par()`, after workers have finished a step.
- **GC under `--debug`.** The stack scanner must not be instrumented by ASan, and ASan's fake stack must stay off, because it would move locals out of the scanned stack.
- **Stack.** `main` starts the program on a thread with a large stack (1 GB reserved, committed on demand) and installs a `sigaltstack` handler that reports `stack overflow`.
- **Input.** Reads all of stdin into one buffer at the first read, then parses tokens and lines from memory, with the `read_line` rule from the spec.
- **Output.** One stdout buffer, flushed at exit, on `flush()`, and before a trap message. stderr is unbuffered.
- **Traps.** `rt_trap(kind, msg, file, line)` either jumps to the innermost `rt_try` frame, kept in a per-thread stack, or prints `file:line: kind: msg` and exits with 101. In a `.par()` worker it records the trap with its element index and stops that worker.
- **Strings.** Builder, slicing, `split`, `lines`, `words`, `trim`, `find`, `extract_ints` and comparisons.
- **Formatting.** Integers in each base with padding; floats both as the shortest round-trip form and as exact fixed-point with ties away from zero. Both work from the exact binary value. The shortest form uses the Ryū algorithm. The fixed form multiplies out the exact value with GMP, which is simple and fast enough for output.
- **Hash tables.** A macro-generated open-addressing table in `map.h`, instantiated in the generated C for each key and value type, so the C compiler can inline hashing and comparison. Insertion order is kept with a separate entry array, which gives deterministic iteration. A map made with `map(default: v)` stores the default in its header; a missed read returns it, or a copy for array, map and set values, without inserting. Each entry stores its key's hash. In `--debug` builds, lookups that hit and table growth recompute the hash and trap with kind `"key"` if it changed, which catches keys mutated after insertion.
- **Sorting.** A stable merge sort over elements of any size with a comparison function, instantiated per element type.
- **Thread pool.** Started on the first `.par()`. Workers take chunk indexes from an atomic counter, write each chunk's result into its own slot, and the caller combines the slots in order. `find`-style chains publish the lowest matching chunk index so later chunks can stop.
- **Big numbers.** Thin wrappers over GMP for the operations the language exposes, plus reading and printing.

## Standard library

- **Written in the language.** `lib/*.sher` files are ordinary modules. `prelude.sher` star-imports the rest, and every user module implicitly star-imports `prelude`.
- **Primitives.** What the library cannot write in the language comes from two places:
  - `extern fn` declarations of runtime C functions, for anything with concrete types, such as reading input or string search.
  - A fixed table of compiler intrinsics for operations that are generic over element types, such as array length, push and indexing, hash table operations, and derived equality, hashing, ordering and printing. Intrinsic names start with `__`, and only `lib/` files may call them.
- **Load cost.** The library is parsed on every run in v1. Only called functions are checked and compiled, so a large library costs parse time only. A cache of parsed library files is a later option if parsing shows up in profiles.
- **Library test file.** `tests/lib/all.sher` calls every library function at least once with typical types, as the spec requires, since generic code is only checked when instantiated.

## Diagnostics

- **Format.** `file:line:col: error: message`, the source line, a caret under the span, then `note:` lines. Notes carry the instantiation chain, the import chain, and for overload errors the candidates that were tried.
- **Collect, then stop.** Each stage collects all the errors it can and the driver stops after the first stage that reports any. The parser stops at the first error.
- **Hints.** Errors the spec describes with a hint (`{n:5}`, a too-large literal, an ambiguous prefix) carry their hint text as a note.
- **Internal errors** print the compiler's stack trace and ask for a bug report. They are never shown as user errors.

## Testing

The language's own test blocks do most of the work.

- **`tests/run/`** Programs with `#in` and `#out` blocks. The runner calls `sherbet test` on each one.
- **`tests/errors/`** Programs that must not compile. The expected error is a comment on the line where it should appear: `// error: ambiguous prefix`. The runner checks the line and that the message contains the text.
- **`tests/traps/`** Programs that must trap with a given kind, written the same way with `// trap: overflow`.
- **`tests/aoc/`** The 10 to 15 Advent of Code and contest solutions from the spec's next step, with real inputs and answers. These are the regression suite that matters most.
- **Unit tests in Nim** for the lexer, parser and unifier, where a program test would be too indirect.
- **Differential tests** for number formatting and integer semantics against Python: generate random values, format or compute them both ways, and compare.
- **Sanitizers.** CI runs everything once with `--debug` to catch undefined behavior in generated C and the runtime.

## Build order

Each milestone ends with tests passing. The milestone numbers match the spec's.

1. **Ints, floats, functions, control flow, arrays and strings.** Source, lexer, parser, resolver, and a first infer pass with no generics; emit C; runtime bump allocator with both allocation calls, traps, output and basic strings. First target: a program that reads numbers and prints their sum, through gcc.
2. **Inference with implicit generics and monomorphization.** The instantiation worklist, number defaulting, error chains.
3. **Tuples, records, variants, `match`, closures, maps, sets, uniform call syntax, optionals and `try`.** Hash tables, closure conversion, captures and boxing, optional flags and narrowing, `rt_try`, overloads and variant dispatch.
4. **Input, buffered output, formatting, printing, `dbg`, and `sherbet test`.** The runtime formatter, format string checking and test blocks.
5. **Imports and the library.** Module loading, qualified names, the prelude, intrinsics, and the library itself.
6. **`big`, `Mod`, `rat`, matrices and the solver.** GMP glue, Barrett reduction.
7. **FFI, fusion, then `.par()`.** The write analysis in the check stage, the thread pool, chunked lowering.

**Memory rollout.** Milestone 1 ships only the arena. Old buffers are not reused after growth: doubling limits the arena's waste to about one extra copy of the final array, and the collector reclaims them once nothing points in. Once real AoC solutions run, add the collector as the default and benchmark it against the arena on an int-array DP, a grid simulation that copies each step, and a binary-trees allocation test.

## Spec gaps

Decisions the compiler needs that the spec does not make yet. Each should be settled in `spec.md` before or during the milestone that needs it.

None are open right now.
