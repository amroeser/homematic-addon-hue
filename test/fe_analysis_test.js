// Warnings and tips of the flow editor (flowAnalysis in addon/www/index.html).
// Run: node test/fe_analysis_test.js   (exit code 1 on failure; used by test_addon.py)
"use strict";
const fs = require("fs");
const path = require("path");
const html = fs.readFileSync(path.join(__dirname, "..", "addon", "www", "index.html"), "utf8");
const cut = (a, b) => html.slice(html.indexOf(a), html.indexOf(b));
const src = cut("const pressLabel", "function renderFlows()") + cut("const FE = {", "// Overview: drop a key");
global.t = (k, v) => k + (v ? JSON.stringify(v) : ""); global.lang = "de";
global.S = {};
const api = new Function(src + "\nreturn { flowAnalysis, FE };")();

const key = (dp, ch, press) => ({ dp, ch, ct2: "1", press, name: "HmIP-RF.0001:" + ch + ".PRESS_" + press, channel_name: "Taster:" + ch, channel: ch, ct: "1", value: "true", op: "1" });
const prog = (id, name, singles, actions, extra) => ({ id, name, active: true, editor: true, rules: [{ conditions: [{ op: "2", singles }], actions }, ...(extra || [])] });
const act = (dp, ch, value, name) => ({ dp, channel: ch, value, name, channel_name: "Lampe:1", delay_type: "0", delay: "" });
S.catalog = { triggers: [], conditions: [], targets: [{ kind: "switch", dp: "100", toggle: "101", channel: "50", name: "Lampe:1", group: "switch" }] };
S.links = { "HmIP-RF.0001:3": ["Stehlampe:2"] };
S.flows = [
	prog("1", "A", [key("10", "7", "SHORT")], [act("100", "50", "true", "X.STATE")]),
	prog("2", "B", [key("10", "7", "SHORT")], [act("100", "50", "false", "X.STATE")]),
	prog("3", "C", [key("11", "8", "SHORT")], [act("101", "50", "true", "X.TOGGLE")]),
	prog("4", "D", [key("11", "8", "SHORT")], [act("101", "50", "true", "X.TOGGLE")]),
	prog("5", "E", [Object.assign(key("12", "9", "SHORT"), { ct2: "15" })], [act("100", "50", "true", "X.STATE")]),
	prog("6", "F", [key("13", "3", "SHORT")], [act("200", "60", "true", "Y.STATE")]),
];
const res = api.flowAnalysis(null);
const has = (id, title) => (res.get(id) || []).some(x => x.title.startsWith(title));
const checks = [
	["key used twice", has("1", "fl_twice_title") && has("2", "fl_twice_title")],
	["opposite values for one key", has("1", "fe_w_conflict_title") && has("2", "fe_w_conflict_title")],
	["two toggles cancel out", (res.get("3") || []).some(x => x.text.startsWith("fe_w_toggle2"))],
	["no trigger", has("5", "fe_w_notrig_title")],
	["direct link", has("6", "fe_w_link_title")],
	["nothing for a clean program", !(res.get("6") || []).some(x => !x.title.startsWith("fe_w_link_title"))],
];
// Toggle tip on a draft: "if lamp off then on, else off"
const FE = api.FE;
const k = { kind: "key", lvt: "18", dp: "20", ch: "21", ct: "1", ct2: "1", rv1: "true", rv2: "false", rt1: "2", rt2: "2", op: "1", press: "SHORT", name: "HmIP-RF.0002:1.PRESS_SHORT" };
const c = { kind: "value", lvt: "18", dp: "100", ch: "50", ct: "1", ct2: "15", rv1: "false", rv2: "false", rt1: "2", rt2: "2", op: "1", name: "X.STATE" };
const on = { param: "18", dp: "100", ch: "50", vt: "2", value: "true", delay: "" }, off = Object.assign({}, on, { value: "false" });
const draft = { id: "", name: "T", active: true, branches: [{ when: { op: "or", groups: [[k, c]] }, then: [on], stop_delays: true }], else: { then: [off], stop_delays: true } };
const tip = (api.flowAnalysis(draft).get("new") || []).find(x => x.title === "fe_t_toggle_title");
checks.push(["toggle tip", !!(tip && tip.fix)]);
if (tip && tip.fix) {
	tip.fix[1](draft);
	checks.push(["toggle fix", draft.else === null && draft.branches[0].then[0].dp === "101" && FE.view(draft.branches[0]).checks.groups.length === 0]);
}
let failed = 0;
for (const [name, ok] of checks) if (!ok) { failed++; console.log("FAIL", name); }
console.log(failed ? failed + " failed" : "ok " + checks.length);
process.exit(failed ? 1 : 0);
