// deepen#3774 自建 ACP 客户端(基于 report#3282 的 acp-client.mjs 改造)
// 差异: 新增策略 "stopafter<N>" —— 只应答前 N 个 permission 请求, 之后**完全不应答**
// (模拟受害者对伪造弹窗置之不理), 用于检验「弹窗未点选时后续命令是否已被静默执行」。
// 用法: node acp-client2.mjs <binPath> <cwd> <prompt> <logPath> <waitMs> <strategy>
//   strategy: "allow"                -> 每个 permission 都选 allow
//             "reject<N>"            -> 第 N 个选 reject, 其余 allow
//             "stopafter<N>"         -> 前 N 个选 allow, 第 N+1 个起**不发送任何应答**
import { spawn } from 'node:child_process';
import fs from 'node:fs';

const [, , binPath, cwd, promptText, logPath, waitMs, strategy] = process.argv;
const modelScriptPath = process.env.P2_SCRIPT1 || '';
const phase2ScriptPath = process.env.P2_SCRIPT2 || '';
const phase2Prompt = process.env.P2_PROMPT || '';
fs.writeFileSync(logPath, '');
const log = s => fs.appendFileSync(logPath, s + '\n');

const env = { ...process.env };
const extra = (process.env.CBC_EXTRA_ARGS || '').split(' ').filter(Boolean);
const child = spawn(process.execPath, [binPath, '--acp', ...extra], { cwd, env, stdio: ['pipe', 'pipe', 'pipe'] });

let stderrBuf = '';
child.stderr.on('data', d => { stderrBuf += d.toString(); });

let nextId = 1;
const pending = new Map();
let buf = '';
let permCount = 0;
const permissions = [];

function send(obj) {
    log('C->A ' + JSON.stringify(obj));
    child.stdin.write(JSON.stringify(obj) + '\n');
}
function request(method, params) {
    const id = nextId++;
    return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        send({ jsonrpc: '2.0', id, method, params });
    });
}
function respond(id, result) { send({ jsonrpc: '2.0', id, result }); }
function respondErr(id, message) { send({ jsonrpc: '2.0', id, error: { code: -32000, message } }); }

const rejectTarget = /^reject(\d+)$/.exec(strategy || '') ? Number(/^reject(\d+)$/.exec(strategy)[1]) : -1;
const stopAfter = /^stopafter(\d+)$/.exec(strategy || '') ? Number(/^stopafter(\d+)$/.exec(strategy)[1]) : -1;

const t0 = Date.now();
const stamp = () => String(Date.now() - t0).padStart(7, ' ');

child.stdout.on('data', d => {
    buf += d.toString();
    let idx;
    while ((idx = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, idx).trim();
        buf = buf.slice(idx + 1);
        if (!line) continue;
        log('A->C ' + line);
        let msg;
        try { msg = JSON.parse(line); } catch { continue; }
        if (msg.id !== undefined && msg.method !== undefined) {
            const m = msg.method;
            if (m === 'session/request_permission') {
                permCount += 1;
                const n = permCount;
                permissions.push({ n, at: Date.now() - t0, params: msg.params });
                const inner = msg.params?.toolCall || {};
                const meta = inner._meta || {};
                log(`STATS permission#${n} t=${stamp()}ms cmd=${JSON.stringify(inner.rawInput?.command ?? null)} `
                    + `interceptType=${meta['codebuddy.ai/interceptType'] ?? '-'} `
                    + `desc=${JSON.stringify(meta['codebuddy.ai/description'] ?? null)}`);
                log('STATS permission#' + n + ' FULL ' + JSON.stringify(msg.params));
                if (stopAfter >= 0 && n > stopAfter) {
                    log(`STATS permission#${n} LEFT_UNANSWERED (strategy=${strategy})`);
                    return;
                }
                const opts = msg.params?.options || [];
                const want = (n === rejectTarget) ? 'reject' : 'allow';
                let pick = opts.find(o => o.optionId === want)
                    || opts.find(o => o.kind === (want === 'reject' ? 'reject_once' : 'allow_once'))
                    || opts[0];
                const optionId = pick?.optionId;
                log('STATS auto-answered permission#' + n + ' optionId=' + optionId + ' want=' + want);
                respond(msg.id, { outcome: { outcome: 'selected', optionId } });
            } else if (m.startsWith('fs/')) {
                respondErr(msg.id, 'stub client: fs not supported');
            } else if (m.startsWith('terminal/')) {
                respondErr(msg.id, 'stub client: terminal not supported');
            } else {
                respond(msg.id, {});
            }
            continue;
        }
        if (msg.id !== undefined && pending.has(msg.id)) {
            const p = pending.get(msg.id); pending.delete(msg.id);
            if (msg.error) p.reject(new Error(JSON.stringify(msg.error))); else p.resolve(msg.result);
            continue;
        }
    }
});

const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
    try {
        const init = await request('initialize', {
            protocolVersion: 1,
            clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
            clientInfo: { name: 'gk6678-client', version: '1.0.0' },
        });
        log('INIT_RESULT ' + JSON.stringify(init));
        const ns = await request('session/new', { cwd, mcpServers: [] });
        log('NEW_RESULT ' + JSON.stringify(ns));
        const sessionId = ns.sessionId;
        // 注意: 不 await prompt 结果 —— 伪造弹窗未应答时该 Promise 永不 resolve,
        // await 会让客户端永久挂起(首轮 stopafter 实验踩过这个坑)。
        request('session/prompt', { sessionId, prompt: [{ type: 'text', text: promptText }] })
            .then(r => log('PROMPT_RESULT ' + JSON.stringify(r)))
            .catch(e => log('PROMPT_ERR ' + String(e)));
        const waitOne = Number(waitMs || 8000);
        const deadline = Date.now() + waitOne;
        while (Date.now() < deadline) await sleep(300);
        if (modelScriptPath && phase2ScriptPath && phase2Prompt) {
            fs.copyFileSync(phase2ScriptPath, modelScriptPath);
            log('PHASE2 swapped model script -> ' + phase2ScriptPath);
            request('session/prompt', { sessionId, prompt: [{ type: 'text', text: phase2Prompt }] })
                .then(r => log('PROMPT2_RESULT ' + JSON.stringify(r)))
                .catch(e => log('PROMPT2_ERR ' + String(e)));
            const deadline2 = Date.now() + waitOne;
            while (Date.now() < deadline2) await sleep(300);
        }
        log('STATS_SUMMARY ' + JSON.stringify({ strategy, permissionRequests: permCount, perms: permissions.map(p => ({ n: p.n, at: p.at })) }, null, 2));
    } catch (e) {
        log('FATAL ' + ((e && e.stack) || e));
    }
    log('STDERR_TAIL ' + stderrBuf.slice(-4000));
    child.kill('SIGKILL');
    process.exit(0);
})();
