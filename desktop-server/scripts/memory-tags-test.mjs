import { MemoryTagParser } from "../src/client/memory-tags.js";

let pass = 0, fail = 0;
function check(name, fn) {
  try { fn(); console.log(`✓ ${name}`); pass++; }
  catch (e) { console.log(`✗ ${name}: ${e.message}`); fail++; }
}
function eq(a, b) { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }

check("simple add tag", () => {
  const p = new MemoryTagParser();
  const r = p.push('Got it.<memory action="add" category="you" title="Profile" summary="I work at Verizon" details="I work at Verizon" /> Will remember.');
  eq(r.text, "Got it. Will remember.");
  eq(r.actions, [{ kind: "add", category: "you", title: "Profile", summary: "I work at Verizon", details: ["I work at Verizon"] }]);
});

check("tag split across chunks", () => {
  const p = new MemoryTagParser();
  // First push: tag opener is incomplete. Prefix is held in the buffer so
  // we don't emit "Sure thing. " twice (once here, once when the tag closes).
  const r1 = p.push('Sure thing. <memory act');
  eq(r1.text, "");
  eq(r1.actions, []);
  // Second push: tag closes. The held prefix is now emitted as visible, the
  // action is parsed.
  const r2 = p.push('ion="add" category="you" title="Profile" summary="I live in Colorado" details="I live in Colorado" />');
  eq(r2.text, "Sure thing. ");
  eq(r2.actions, [{ kind: "add", category: "you", title: "Profile", summary: "I live in Colorado", details: ["I live in Colorado"] }]);
});

check("forget tag", () => {
  const p = new MemoryTagParser();
  const r = p.push('Forgetting.<memory action="forget" target="Verizon" />');
  eq(r.text, "Forgetting.");
  eq(r.actions, [{ kind: "forget", target: "Verizon" }]);
});

check("rename tag", () => {
  const p = new MemoryTagParser();
  const r = p.push('<memory action="rename" target="Profile" value="About me" />');
  eq(r.actions, [{ kind: "rename", target: "Profile", value: "About me" }]);
});

check("set_details with pipe-separated values", () => {
  const p = new MemoryTagParser();
  const r = p.push('<memory action="set_details" target="Profile" value="A|B|C" />');
  eq(r.actions, [{ kind: "set_details", target: "Profile", value: ["A", "B", "C"] }]);
});

check("tag inside code block preserved", () => {
  const p = new MemoryTagParser();
  const r = p.push('Here is the snippet:\n```\n<memory action="add" />\n```\nGot it.');
  eq(r.text, 'Here is the snippet:\n```\n<memory action="add" />\n```\nGot it.');
  eq(r.actions, []);
});

check("tag inside inline code preserved", () => {
  const p = new MemoryTagParser();
  const r = p.push('Use `<memory action="add" />` in your app.');
  eq(r.text, 'Use `<memory action="add" />` in your app.');
  eq(r.actions, []);
});

check("multiple tags in one reply", () => {
  const p = new MemoryTagParser();
  const r = p.push('Noted.<memory action="add" category="you" title="Profile" summary="A" details="A" /><memory action="forget" target="old" />');
  eq(r.actions.length, 2);
  eq(r.actions[0].kind, "add");
  eq(r.actions[1].kind, "forget");
});

check("unknown action dropped silently", () => {
  const p = new MemoryTagParser();
  const r = p.push('Hi <memory action="explode" /> there.');
  eq(r.text, "Hi  there.");
  eq(r.actions, []);
});

check("non-self-closing memory wrapper treated as text", () => {
  const p = new MemoryTagParser();
  // `<memory>` is not a valid opener (no attributes, no self-close) so the
  // whole string passes through as plain text.
  const r1 = p.push('text <memory> not a tag really</memory> end');
  eq(r1.text, "text <memory> not a tag really</memory> end");
  eq(r1.actions, []);
  const r2 = p.end();
  eq(r2.text, "");
  eq(r2.actions, []);
});

check("end() returns trailing visible text", () => {
  const p = new MemoryTagParser();
  const r1 = p.push('hello <memory action="add" category="you" title="Profile" summary="A" details="A" /> world');
  eq(r1.text, "hello  world");
  eq(r1.actions.length, 1);
  const r2 = p.end();
  eq(r2.text, "");
});

check("end() preserves unterminated tail", () => {
  const p = new MemoryTagParser();
  p.push("partial <memory act");
  const r = p.end();
  eq(r.text, "partial ");
  eq(r.actions, []);
});

check("add with multiple pipe details", () => {
  const p = new MemoryTagParser();
  const r = p.push('<memory action="add" category="you" title="Profile" summary="" details="A|B|C" />');
  eq(r.actions, [{ kind: "add", category: "you", title: "Profile", summary: "", details: ["A", "B", "C"] }]);
});

check("category defaults to 'you' when omitted", () => {
  const p = new MemoryTagParser();
  const r = p.push('<memory action="add" title="Profile" summary="X" details="X" />');
  eq(r.actions[0].category, "you");
});

check("invalid category dropped", () => {
  const p = new MemoryTagParser();
  const r = p.push('<memory action="add" category="global" title="Profile" summary="X" details="X" />');
  eq(r.actions, []);
  eq(r.text, ""); // tag was still stripped from visible
});

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
