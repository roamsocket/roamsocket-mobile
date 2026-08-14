import { UserMemoryStore } from "../src/client/user-memory-store.js";

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

check("applyAction add creates entry and records activity", () => {
  const s = new UserMemoryStore(new MemStorage());
  const out = s.applyAction({ kind: "add", category: "you", title: "Profile", summary: "I work at Verizon", details: ["I work at Verizon"] });
  truthy(out, "out is null");
  eq(s.byCategory("you").length, 1);
  eq(s.activityList().length, 1);
  const act = s.activityList()[0];
  eq(act.kind, "add");
  eq(act.source, "chat");
  eq(act.entryTitle, "Profile");
  eq(act.detailPreview, "I work at Verizon");
});

check("applyAction add updates existing entry and records update", () => {
  const s = new UserMemoryStore(new MemStorage());
  s.addFreeformFact("I live in Colorado");
  s.applyAction({ kind: "add", category: "you", title: "Profile", summary: "", details: ["I work at Verizon"] });
  const profile = s.byCategory("you").find((e) => e.title === "Profile");
  truthy(profile.details.includes("I live in Colorado"));
  truthy(profile.details.includes("I work at Verizon"));
  const act = s.activityList()[0];
  eq(act.kind, "update");
  truthy(act.before);
  truthy(act.after);
  eq(act.before.details.length, 1);
  eq(act.after.details.length, 2);
});

check("applyAction add with no real change returns null", () => {
  const s = new UserMemoryStore(new MemStorage());
  s.addFreeformFact("I live in Colorado");
  const out = s.applyAction({ kind: "add", category: "you", title: "Profile", summary: "I live in Colorado", details: ["I live in Colorado"] });
  eq(out, null);
  eq(s.activityList().length, 0);
});

check("applyAction forget removes matching detail", () => {
  const s = new UserMemoryStore(new MemStorage());
  s.applyAction({ kind: "add", category: "you", title: "Profile", summary: "X", details: ["I live in Colorado", "I work at Verizon"] });
  const out = s.applyAction({ kind: "forget", target: "Colorado" });
  truthy(out);
  const profile = s.byCategory("you").find((e) => e.title === "Profile");
  truthy(!profile.details.some((d) => d.toLowerCase().includes("colorado")));
  eq(s.activityList().filter((a) => a.kind === "forget").length, 1);
});

check("applyAction rename updates title", () => {
  const s = new UserMemoryStore(new MemStorage());
  s.applyAction({ kind: "add", category: "you", title: "Profile", summary: "X", details: ["A"] });
  const out = s.applyAction({ kind: "rename", target: "Profile", value: "About me" });
  truthy(out);
  eq(out.title, "About me");
  eq(s.byCategory("you").find((e) => e.title === "About me")?.id, out.id);
});

check("applyAction set_summary updates summary", () => {
  const s = new UserMemoryStore(new MemStorage());
  s.applyAction({ kind: "add", category: "you", title: "Profile", summary: "Old", details: ["A"] });
  const out = s.applyAction({ kind: "set_summary", target: "Profile", value: "New summary" });
  truthy(out);
  eq(out.summary, "New summary");
});

check("applyAction set_details replaces details", () => {
  const s = new UserMemoryStore(new MemStorage());
  s.applyAction({ kind: "add", category: "you", title: "Profile", summary: "X", details: ["Old"] });
  const out = s.applyAction({ kind: "set_details", target: "Profile", value: ["New1", "New2"] });
  truthy(out);
  eq(out.details, ["New1", "New2"]);
});

check("undoActivity on add removes the entry", () => {
  const s = new UserMemoryStore(new MemStorage());
  s.applyAction({ kind: "add", category: "you", title: "Profile", summary: "X", details: ["A"] });
  const id = s.activityList()[0].id;
  const ok = s.undoActivity(id);
  truthy(ok);
  eq(s.entries.length, 0);
  eq(s.activityList().length, 0);
});

check("undoActivity on update restores prior state", () => {
  const s = new UserMemoryStore(new MemStorage());
  s.addFreeformFact("I live in Colorado");
  s.applyAction({ kind: "add", category: "you", title: "Profile", summary: "", details: ["I work at Verizon"] });
  const id = s.activityList()[0].id;
  s.undoActivity(id);
  const profile = s.byCategory("you").find((e) => e.title === "Profile");
  eq(profile.details, ["I live in Colorado"]);
});

check("undoActivity on forget restores the detail", () => {
  const s = new UserMemoryStore(new MemStorage());
  s.applyAction({ kind: "add", category: "you", title: "Profile", summary: "X", details: ["I live in Colorado", "I work at Verizon"] });
  s.applyAction({ kind: "forget", target: "Colorado" });
  const id = s.activityList().find((a) => a.kind === "forget").id;
  s.undoActivity(id);
  const profile = s.byCategory("you").find((e) => e.title === "Profile");
  truthy(profile.details.some((d) => d.toLowerCase().includes("colorado")));
});

check("activity persists across reload", () => {
  const storage = new MemStorage();
  const s1 = new UserMemoryStore(storage);
  s1.applyAction({ kind: "add", category: "you", title: "Profile", summary: "X", details: ["A"] });
  const s2 = new UserMemoryStore(storage);
  eq(s2.activityList().length, 1);
  eq(s2.entries.length, 1);
});

check("activity activityList filters by source", () => {
  const s = new UserMemoryStore(new MemStorage());
  s.addFreeformFact("manual edit");
  s.applyAction({ kind: "add", category: "you", title: "Profile", summary: "X", details: ["auto"] });
  eq(s.activityList({ source: "chat" }).length, 1);
  // user-edit activity is not yet wired (applyEntryCommand will do that in a
  // follow-up), so chat-only is 1, total is 1 too.
  eq(s.activityList().length, 1);
});

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
