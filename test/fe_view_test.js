// FE.view of the flow editor (addon/www/index.html) with the program patterns of real CCUs.
// Run: node test/fe_view_test.js   (exit code 1 on failure; used by test_addon.py)
"use strict";
const fs = require("fs");
const path = require("path");
const html = fs.readFileSync(path.join(__dirname, "..", "addon", "www", "index.html"), "utf8");
const src = html.slice(html.indexOf("const FE = {"), html.indexOf("// Overview: drop a key"));
global.t = k => k; global.lang = "de"; global.S = { catalog: { conditions: [], targets: [] } };
const FE = new Function(src + "\nreturn FE;")();

const key = (dp, op) => ({ kind: "key", lvt: "18", dp, ct: "1", ct2: "1", rv1: "true", rv2: "false", op });
const chk = (dp, op, v) => ({ kind: "value", lvt: "18", dp, ct: "1", ct2: "15", rv1: v || "false", rv2: "false", op });
const trg = (dp, op) => ({ kind: "value", lvt: "18", dp, ct: "1", ct2: "4", rv1: "false", rv2: "false", op });
const cases = [
	["key or key (groups)", { op: "or", groups: [[key(1, "1")], [key(2, "1")]] }, true],
	["key or key (one group)", { op: "and", groups: [[key(1, "2"), key(2, "2")]] }, true],
	["(short or long) and check", { op: "and", groups: [[key(1, "2"), key(2, "2")], [chk(9, "2")]] }, true],
	["(key and A) or (key and B)", { op: "or", groups: [[key(1, "1"), chk(9, "1")], [key(1, "1"), chk(8, "1")]] }, true],
	["(short and A) or (long and A)", { op: "or", groups: [[key(1, "1"), chk(9, "1")], [key(2, "1"), chk(9, "1")]] }, true],
	["one group, trigger among checks", { op: "or", groups: [[chk(7, "1"), chk(8, "1"), trg(9, "1")]] }, true],
	["all or (four keys)", { op: "or", groups: [[key(1, "1")], [key(2, "2"), key(3, "2"), key(4, "2")]] }, true],
	["key alone or key and check", { op: "or", groups: [[key(1, "1")], [key(2, "1"), chk(9, "1")]] }, false],
	["(key1 and A) or (key2 and B)", { op: "or", groups: [[key(1, "1"), chk(9, "1")], [key(2, "1"), chk(8, "1")]] }, false],
	["key or check in one group", { op: "or", groups: [[key(1, "2"), chk(9, "2")]] }, false],
	["triggers in two and-groups", { op: "and", groups: [[key(1, "2")], [key(2, "2")]] }, false],
];
let failed = 0;
for (const [name, when, ok] of cases) {
	const v = FE.view({ when, then: [] });
	if (v.ok !== ok) { failed++; console.log("FAIL", name, "expected", ok, "got", v.ok); }
	// What the editor writes after a change must be accepted again
	if (ok && v.ok) {
		const again = FE.view({ when: FE.rebuild(v.triggers, v.checks), then: [] });
		if (!again.ok) { failed++; console.log("FAIL rebuild", name); }
	}
}
console.log(failed ? failed + " failed" : "ok " + cases.length);
process.exit(failed ? 1 : 0);
