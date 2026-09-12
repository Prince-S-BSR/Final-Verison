// apps/api/src/lib/session-token.ts
//
// Shared token generation/hashing for the Phase 0 session-context middleware
// and its test-only seeding helper. `sessions.token_hash` is the only thing
// ever persisted (schema-phase-0.sql §4.2: "a stolen database dump must not
// yield usable session tokens") — the raw token exists only in the bearer
// header and, at seed time, in the seeding helper's return value.

import { createHash, randomBytes } from "node:crypto";

/** Generates a fresh, high-entropy bearer token (never persisted as-is). */
export function generateSessionToken(): string {
  return randomBytes(32).toString("hex");
}

/**
 * Deterministic one-way hash of a bearer token, used both to persist
 * `sessions.token_hash` at seed time and to look sessions up by token on
 * every request. SHA-256 is sufficient here because the input (a 256-bit
 * random token) already carries far more entropy than any password-hashing
 * scheme is defending against — there is nothing to slow an attacker down
 * against, unlike a user-chosen password.
 */
export function hashSessionToken(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}
