// apps/api/test/support/rows.ts
//
// Same normalisation helper duplicated in middleware/require-permission.ts,
// middleware/require-feature.ts and routes/test-only.ts — the postgres.js
// driver returns a bare array from tx.execute() in some call shapes and a
// `{ rows: [...] }` wrapper in others depending on the query. Test support
// code hits the same ambiguity when reading rows back directly for seeding.

export function extractRows(result: unknown): Array<Record<string, unknown>> {
  if (Array.isArray(result)) return result as Array<Record<string, unknown>>;
  if (result && typeof result === "object" && Array.isArray((result as { rows?: unknown }).rows)) {
    return (result as { rows: Array<Record<string, unknown>> }).rows;
  }
  return [];
}
