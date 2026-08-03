import type { LogEntry } from "./debug-log";
import type { PerfRecord } from "./perf";

// Persisted debug-log ring, owned by the background service worker. IndexedDB
// (not storage.local) because the log can run to thousands of entries and must
// survive service-worker eviction and browser restarts. A single object store
// with an autoIncrement key keeps entries in chronological order; every append
// trims the oldest back down to MAX_ENTRIES, so the store is a bounded ring.
//
// Perf records (perf.ts) live in a SECOND ring rather than sharing the first.
// The console ring holds ~45 minutes at observed rates, so folding a steady
// 1 Hz metric stream into it would evict the call's console history exactly
// when both halves are needed together.
//
// The DB is opened per operation and closed after: appends arrive batched
// (~1/s), and holding a connection open across service-worker suspension buys
// nothing.

const DB_NAME = "ears-debug-log";
const STORE = "entries";
const PERF_STORE = "perf";
const DB_VERSION = 2;

/** Ring capacity. At ~200 bytes/entry this is a low-single-digit MB ceiling. */
export const MAX_ENTRIES = 5000;

/** Perf ring capacity. Records are wider than console lines but far rarer
 * (a handful per second across all groups), so this holds several hours. */
export const MAX_PERF_ENTRIES = 20_000;

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE, { autoIncrement: true });
      if (!db.objectStoreNames.contains(PERF_STORE)) {
        db.createObjectStore(PERF_STORE, { autoIncrement: true });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function txDone(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}

/** Delete the oldest entries (lowest keys) until at most `max` remain. */
function trim(store: IDBObjectStore, max: number): void {
  const countReq = store.count();
  countReq.onsuccess = () => {
    let over = countReq.result - max;
    if (over <= 0) return;
    const cursorReq = store.openCursor(); // ascending → oldest first
    cursorReq.onsuccess = () => {
      const cursor = cursorReq.result;
      if (!cursor || over <= 0) return;
      cursor.delete();
      over -= 1;
      cursor.continue();
    };
  };
}

async function append<T>(storeName: string, items: T[], max: number): Promise<void> {
  if (items.length === 0) return;
  const db = await openDb();
  try {
    const tx = db.transaction(storeName, "readwrite");
    const store = tx.objectStore(storeName);
    for (const item of items) store.add(item);
    trim(store, max);
    await txDone(tx);
  } finally {
    db.close();
  }
}

async function readAll<T>(storeName: string): Promise<T[]> {
  const db = await openDb();
  try {
    const tx = db.transaction(storeName, "readonly");
    const req = tx.objectStore(storeName).getAll();
    await txDone(tx);
    return (req.result as T[]) ?? [];
  } finally {
    db.close();
  }
}

async function clear(storeName: string): Promise<void> {
  const db = await openDb();
  try {
    const tx = db.transaction(storeName, "readwrite");
    tx.objectStore(storeName).clear();
    await txDone(tx);
  } finally {
    db.close();
  }
}

/** Append entries, then trim the ring back to `max`. */
export function appendEntries(entries: LogEntry[], max = MAX_ENTRIES): Promise<void> {
  return append(STORE, entries, max);
}

/** Every entry, oldest first. */
export function readAllEntries(): Promise<LogEntry[]> {
  return readAll<LogEntry>(STORE);
}

/** Empty the ring. */
export function clearEntries(): Promise<void> {
  return clear(STORE);
}

/** Append perf records to their own ring, then trim it back to `max`. */
export function appendPerfRecords(records: PerfRecord[], max = MAX_PERF_ENTRIES): Promise<void> {
  return append(PERF_STORE, records, max);
}

/** Every perf record, oldest first. */
export function readAllPerfRecords(): Promise<PerfRecord[]> {
  return readAll<PerfRecord>(PERF_STORE);
}

/** Empty the perf ring. */
export function clearPerfRecords(): Promise<void> {
  return clear(PERF_STORE);
}
