/*
 * Android 4.4(API 19) 设备侧 JS 兼容性自检（CI 用）。
 *
 * 4.4 的系统 WebView 是 Chromium 30：没有 Promise（Chrome 32 才有）、
 * 不支持任何 ES6+ 语法（箭头函数/let/const/模板字符串/async）。一旦越界，
 * 后果是**整段脚本语法报错**（KtvApi 根本不导出）或 `Promise is not defined`，
 * 取址链路静默失效。所以这里在构建前把「会被注入设备 WebView 的 JS」都过一遍 ES5 解析。
 *
 * 检查项：
 *   1. assets/mobile/ktv_api.js、assets/mobile/promise_polyfill.js 必须是 ES5；
 *   2. KtvJsBridge.kt 里所有 `"""..."""` 注入脚本（去掉 Kotlin `${...}` 插值后）必须是 ES5；
 *   3. promise_polyfill.js 在没有原生 Promise 的沙箱里行为正确（resolve/then 链/catch/
 *      thenable 采纳/Promise.all/executor 抛异常）。
 *
 * 依赖：acorn（CI 里 `npm install acorn@8`）。
 */
const acorn = require('acorn');
const fs = require('fs');
const vm = require('vm');

let failed = 0;
const pass = (name, detail) => console.log(`PASS  ${name}${detail ? '  ' + detail : ''}`);
const fail = (name, detail) => {
  failed += 1;
  console.log(`FAIL  ${name}  ${detail}`);
};

function parseEs5(name, code) {
  try {
    acorn.parse(code, { ecmaVersion: 5, sourceType: 'script' });
    pass(name);
  } catch (e) {
    fail(name, e.message);
  }
}

// ── 1. assets 里的设备侧脚本 ─────────────────────────────────────────
for (const file of ['app/src/main/assets/mobile/ktv_api.js',
                    'app/src/main/assets/mobile/promise_polyfill.js']) {
  parseEs5('ES5 语法: ' + file, fs.readFileSync(file, 'utf8'));
}

// ── 2. KtvJsBridge.kt 注入到设备 WebView 的脚本 ───────────────────────
const kotlin = fs.readFileSync('app/src/main/java/com/local/ktv/KtvJsBridge.kt', 'utf8');
const blocks = kotlin.match(/"""[\s\S]*?"""/g) || [];
let injectChecked = 0;
blocks.forEach((raw, index) => {
  let code = raw.slice(3, -3);
  if (!/(window\.|android\.|function\s*\()/.test(code)) return; // 不像 JS 的文本块跳过
  code = code.replace(/\$\{[^}]*\}/g, '0'); // Kotlin 模板插值 → 占位数字
  injectChecked += 1;
  parseEs5(`ES5 语法: KtvJsBridge 注入脚本 #${index}`, code);
});
if (injectChecked === 0) fail('ES5 语法: KtvJsBridge 注入脚本', '未找到可检查的脚本块');
else pass('注入脚本块数量', String(injectChecked));

// ── 3. Promise polyfill 行为（沙箱里删掉原生 Promise，模拟 Chromium 30）──
const results = [];
const sandbox = {
  console,
  setTimeout,
  clearTimeout,
  report: (name, ok, detail) => results.push({ name, ok, detail: String(detail === undefined ? '' : detail) }),
};
vm.createContext(sandbox);
vm.runInContext('delete globalThis.Promise;', sandbox);
const before = vm.runInContext('typeof Promise', sandbox);
vm.runInContext(fs.readFileSync('app/src/main/assets/mobile/promise_polyfill.js', 'utf8'), sandbox);
const after = vm.runInContext('typeof Promise', sandbox);
if (before !== 'undefined') fail('沙箱无原生 Promise', before);
if (after !== 'function') fail('polyfill 注入后 Promise 可用', after);

vm.runInContext(`
(function () {
  var out = report;
  new Promise(function (resolve) { resolve(42); })
    .then(function (v) { out('resolve → then', v === 42, v); });
  Promise.resolve(1).then(function (v) { return v + 1; })
    .then(function (v) { return Promise.resolve(v * 10); })
    .then(function (v) { out('链式 then/返回 Promise', v === 20, v); })
    .catch(function (e) { out('链式 then/返回 Promise', false, e.message); });
  Promise.reject(new Error('boom')).catch(function (e) { out('reject → catch', e.message === 'boom', e.message); });
  new Promise(function () { throw new Error('ctor'); })
    .catch(function (e) { out('executor 抛异常 → catch', e.message === 'ctor', e.message); });
  Promise.resolve({ then: function (r) { setTimeout(function () { r('adopted'); }, 5); } })
    .then(function (v) { out('thenable 采纳', v === 'adopted', v); });
  Promise.all([Promise.resolve('a'), 'b', { then: function (r) { setTimeout(function () { r('c'); }, 4); } }])
    .then(function (list) { out('Promise.all', JSON.stringify(list) === '["a","b","c"]', JSON.stringify(list)); })
    .catch(function (e) { out('Promise.all', false, e.message); });
  Promise.resolve().then(function () { return Promise.reject(new Error('downstream')); })
    .then(function () { out('拒绝向下传递', false, 'then 被错误调用'); })
    .catch(function (e) { out('拒绝向下传递', e && e.message === 'downstream', e && e.message); });
})();
`, sandbox);

setTimeout(() => {
  for (const r of results) {
    if (r.ok) pass('Promise polyfill: ' + r.name, r.detail);
    else fail('Promise polyfill: ' + r.name, r.detail);
  }
  if (results.length < 6) fail('Promise polyfill: 用例数量', String(results.length));
  console.log(failed === 0 ? '\nJS 自检全部通过' : `\nJS 自检失败 ${failed} 项`);
  process.exit(failed === 0 ? 0 : 1);
}, 800);
