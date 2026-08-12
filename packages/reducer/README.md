# Adapter8004 reference reducer

The executable form of the indexing spec
([`docs/spec/indexing.md`](../../docs/spec/indexing.md)): a pure, deterministic fold from adapter
events to identity state, one code branch per spec rule (R-1..R-7, P-1..P-3, I-2). The
conformance fixtures in [`docs/spec/fixtures/`](../../docs/spec/fixtures/) are its test suite —
a conforming third-party indexer reproduces the same `expected` blocks from the same files.

This package is deliberately infrastructure-free: no RPC, no database, no reorg handling (rule
O-2 is the *wrapper's* job — feed this reducer the canonical log and it returns the canonical
state). It is the intended core of the Phase-2 SDK; it lives here, next to the spec and
fixtures, so a rule change, its fixture, and its implementation move in one commit. Structured
for clean extraction later (self-contained package, fixtures read by relative path).

```
npm install
npm test        # runs every fixture in docs/spec/fixtures through the reducer
```

**Audit scope note:** this package is off-chain tooling. The contract audit surface remains the
Solidity tree (`src/`) only.
