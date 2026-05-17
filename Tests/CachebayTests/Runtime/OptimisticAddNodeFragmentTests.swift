// File intentionally left empty.
//
// In v0.7.0 the connection-link primitive (`linkNode`) became purely
// structural: it inserts an edge ref into the canonical connection
// record and does NOT write entity-record scalar fields. Entity records
// are owned exclusively by `documents.normalize` (auto from queries /
// mutations / subscriptions) or by explicit `b.writeFragment(...)`.
//
// The fragment-aware `linkNode` overloads (taking `fragmentDocument` /
// `fragmentName` in `LinkNodeOptions`) were removed alongside their
// helpers (`initializeNestedConnections`, `stripSelectionSetFields`,
// `stampTypenameFromPlan`). This file used to test that family of
// behaviour; with those helpers gone, every test in here either:
//
//   * tested fragment-walk side-effects (auto-init nested connections,
//     strip selection-set fields, stamp typename from fragment) — which
//     no longer exist, OR
//   * duplicated edge-insertion / dedup / anchored-position / edge-meta
//     coverage already in `OptimisticConnectionTests.swift` /
//     `OptimisticConnectionAdvancedTests.swift` / the link-primitive
//     contract tests in `OptimisticLinkNodeContractTests.swift`.
//
// The structural-purity contract is anchored by
// `OptimisticLinkNodeContractTests`; edge-shape behaviour stays covered
// by the connection test files. No new tests belong here.
