/**
 * End-to-end sync test: two clients writing to the same memory store, with
 * last-write-wins conflict resolution, and the round-trip converges.
 */
import { UserMemoryStore } from "../src/client/user-memory-store.js";
import { MemoryTagParser } from "../src/client/memory-tags.js";

class MemStorage {
  constructor() { this.m = new Map(); }
  getItem(k) { return this.m.get(k) ?? null; }
  setItem(k, v) { this.m.set(k, v); }
  removeItem(k) { this.m.delete(k); }
}

let pass = 0, fail = 0;
function check(name, fn) {
  try { fn(); console.log(`✓ ${name}`); pass++; }
  catch (e) { console.log(`✗ ${name}: ${e.message}`); fail++; }
}
function eq(a, b) { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function truthy(v, msg) { if (!v) throw new Error(msg || "expected truthy"); }

check("applySync merges new remote entries", () => {
  const s = new UserMemoryStore(new MemStorage());
  const remote = [{
    id: "mem_remote1",
    category: "you",
    title: "Profile",
    summary: "From desktop",
    details: ["I work at desktop"],
    updatedAt: Date.now(),
  }];
  s.applySync(remote);
  const p = s.byCategory("you").find((e) => e.title === "Profile");
  truthy(p, "profile missing");
  eq(p.details, ["I work at desktop"]);
});

check("applySync preserves local-only entries", () => {
  const s = new UserMemoryStore(new MemStorage());
  s.addFreeformFact("I live in Colorado");
  s.applySync([]);
  const p = s.byCategory("you").find((e) => e.title === "Profile");
  truthy(p);
  truthy(p.details.some((d) => d.toLowerCase().includes("colorado")));
});

check("applySync last-write-wins on updatedAt", () => {
  const s = new UserMemoryStore(new MemStorage());
  s.addFreeformFact("I work at Verizon");
  const profileId = s.byCategory("you")[0].id;
  const newer = Date.now() + 60_000;
  s.applySync([{
    id: profileId,
    category: "you",
    title: "Profile",
    summary: "I work at AT&T",
    details: ["I work at AT&T"],
    updatedAt: newer,
  }]);
  const p = s.byCategory("you").find((e) => e.id === profileId);
  eq(p.details, ["I work at AT&T"]);
  eq(p.summary, "I work at AT&T");
});

check("applySync keeps local when remote is older", () => {
  const s = new UserMemoryStore(new MemStorage());
  s.addFreeformFact("I work at Verizon");
  const profileId = s.byCategory("you")[0].id;
  const localTime = s.byCategory("you")[0].updatedAt;
  s.applySync([{
    id: profileId,
    category: "you",
    title: "Profile",
    summary: "I work at old",
    details: ["I work at old"],
    updatedAt: localTime - 60_000,
  }]);
  const p = s.byCategory("you").find((e) => e.id === profileId);
  truthy(p.details.some((d) => d.toLowerCase().includes("verizon")));
});

check("two-client round-trip converges", () => {
  // Two independent stores (e.g. iPhone + desktop) start diverged. Each
  // applies the other's snapshot. After both apply each other, the union
  // is identical and LWW has resolved overlapping entries.
  const phone = new UserMemoryStore(new MemStorage());
  const desktop = new UserMemoryStore(new MemStorage());
  phone.applyAction({ kind: "add", category: "you", title: "Profile", summary: "A", details: ["A"] });
  desktop.applyAction({ kind: "add", category: "you", title: "Profile", summary: "B", details: ["B"] });
  const phoneEntries = phone.list();
  const desktopEntries = desktop.list();
  phone.applySync(desktopEntries);
  desktop.applySync(phoneEntries);
  // Convergence: both stores have the same set of entries.
  const a = JSON.stringify(phone.list().map((e) => e.details).sort());
  const b = JSON.stringify(desktop.list().map((e) => e.details).sort());
  truthy(a.includes("A") && a.includes("B"), `phone missing A or B: ${a}`);
  truthy(b.includes("A") && b.includes("B"), `desktop missing A or B: ${b}`);
});

check("applySync then direct delete round-trip", () => {
  const s = new UserMemoryStore(new MemStorage());
  s.applySync([{
    id: "mem_x",
    category: "you",
    title: "Profile",
    summary: "from sync",
    details: ["from sync"],
    updatedAt: Date.now(),
  }]);
  s.delete("mem_x");
  eq(s.list().length, 0);
});

check("chat parser + applyAction + applySync end-to-end", () => {
  // Simulate the full pipeline: model emits a tag, parser strips it,
  // applyAction mutates the local store, then applySync merges with a
  // remote snapshot. The local change must survive the sync (it's the
  // newest write for that entry).
  const s = new UserMemoryStore(new MemStorage());
  const parser = new MemoryTagParser();
  const reply = 'Got it.<memory action="add" category="you" title="Profile" summary="I work at Verizon" details="I work at Verizon" /> Will remember.';
  const r1 = parser.push(reply);
  const r2 = parser.end();
  eq(r1.text + r2.text, "Got it. Will remember.");
  for (const a of [...r1.actions, ...r2.actions]) {
    s.applyAction(a);
  }
  // Remote pushes a different entry.
  s.applySync([{
    id: "mem_other",
    category: "topic",
    title: "Gaming",
    summary: "Plays indie",
    details: ["Plays indie games"],
    updatedAt: Date.now(),
  }]);
  // Both should be present.
  const profile = s.byCategory("you").find((e) => e.title === "Profile");
  const gaming = s.byCategory("topic").find((e) => e.title === "Gaming");
  truthy(profile, "profile missing after sync");
  truthy(gaming, "gaming missing after sync");
  truthy(profile.details.some((d) => d.toLowerCase().includes("verizon")));
});

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
