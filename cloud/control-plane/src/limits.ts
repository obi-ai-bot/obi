// Rate limits in D1: fixed windows, one row per key, taken in one statement so two requests at
// once can't both slip under the limit.

export interface Limit {
  max: number;
  windowSeconds: number;
}

export interface Verdict {
  allowed: boolean;
  /// When denied, how long until the window opens again.
  retryAfterSeconds: number;
}

/// Counts one request against `key`'s window and says whether it's within `limit`. A window
/// starts at the first request, or, `aligned`, at a whole multiple of its length (then the row
/// keeps only which minute, hour or day it counts, not when the first request came).
export async function takeOne(db: D1Database, key: string, limit: Limit, now: Date, aligned = false): Promise<Verdict> {
  const at = Math.floor(now.getTime() / 1000);
  const start = aligned ? at - (at % limit.windowSeconds) : at;
  const row = await db
    .prepare(
      `INSERT INTO rate_limits (key, window_start, count) VALUES (?1, ?2, 1)
       ON CONFLICT (key) DO UPDATE SET
         count = CASE WHEN rate_limits.window_start + ?3 <= ?2 THEN 1 ELSE rate_limits.count + 1 END,
         window_start = CASE WHEN rate_limits.window_start + ?3 <= ?2 THEN ?2 ELSE rate_limits.window_start END
       RETURNING count, window_start`,
    )
    .bind(key, start, limit.windowSeconds)
    .first<{ count: number; window_start: number }>();
  if (!row) throw new Error("The rate limit couldn't be counted.");
  const allowed = row.count <= limit.max;
  return { allowed, retryAfterSeconds: allowed ? 0 : Math.max(1, row.window_start + limit.windowSeconds - at) };
}

/// How many requests `key`'s current window has counted, without counting one.
export async function counted(db: D1Database, key: string, limit: Limit, now: Date): Promise<number> {
  const at = Math.floor(now.getTime() / 1000);
  const row = await db.prepare("SELECT count, window_start FROM rate_limits WHERE key = ?1").bind(key).first<{ count: number; window_start: number }>();
  return row && row.window_start + limit.windowSeconds > at ? row.count : 0;
}
