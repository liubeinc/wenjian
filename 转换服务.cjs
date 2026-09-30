// 转换服务.cjs - 文件转换站的本机服务（浏览器做不到的那部分）
// 监听 127.0.0.1:9761, 仅本机可访问, 文件不出这台机器
//
//   GET  /health   -> 能力自检: 本机到底能解/能编哪些格式, 有没有 PDF 引擎
//   POST /convert  -> 批量转换, body: { 任务:[ {文件名,数据(base64) 或 路径, 输出格式, 质量, 宽, 高, 帧, 页码, DPI} ] }
//   GET  /         -> 一行纯文本, 供人工在浏览器里确认服务活着
//
// 分工: 浏览器负责 PNG/JPG/WebP/GIF/BMP/AVIF 的常见互转（零上传、最快）;
//       本服务补浏览器做不到的 —— TIFF/ICO 解码、TIFF/GIF/BMP 编码、PDF 精确 DPI 出图。
//
// 启动: 双击同目录的「启动服务.bat」。
// 后缀是 .cjs 不是 .js: Windows 把 .js 关联给「Windows 脚本宿主」, 双击本文件会用
// JScript 去跑它并弹一个 800A03EA 语法错误框。.cjs 没有这个关联, 不会被误当脚本执行。
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFile } = require('child_process');

const PORT = 9761;
const CORE = path.join(__dirname, '转换核心.ps1');       // 真正的转换引擎
const TMP  = path.join(__dirname, '_临时', '工作');
const NODE_EXE = path.join(__dirname, '..', '.tmp', 'node', 'node.exe');

// ---------- 基础设施 ----------
function send(res, code, obj){
  const b = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type':'application/json; charset=utf-8' });
  res.end(b);
}

// ---------- CORS ----------
// 只放行本机来源。页面用 file:// 打开时浏览器发的 Origin 是字符串 "null";
// 若从本机 http 服务打开, 则是 http://127.0.0.1:* 或 http://localhost:*。
// 其余来源一律不给 CORS 头 —— 公网页面即使能连到这个端口, 也读不到任何响应。
//
// 另外刻意不发 Access-Control-Allow-Private-Network: 那是让浏览器放行
// 「公网页面 -> 本机」的开关, 不发它, Chrome 的 PNA 策略就会挡下这类请求。
function corsFor(req){
  const o = req.headers.origin || '';
  if (o === 'null' || /^https?:\/\/(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/.test(o)) {
    return {
      'Access-Control-Allow-Origin': o,
      'Access-Control-Allow-Headers': 'Content-Type',
      'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
      'Vary': 'Origin'
    };
  }
  return {};
}

function readBody(req, limit){
  limit = limit || 300*1024*1024;
  return new Promise((resolve, reject)=>{
    const chunks=[]; let n=0;
    req.on('data', c=>{
      n += c.length;
      // 本地服务也不能无限吃内存 —— 超限直接断开, 给个能看懂的错
      if (n > limit) { reject(new Error('请求体过大（上限 ' + Math.round(limit/1024/1024) + ' MB）')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', ()=>resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function runPs(args, timeoutMs){
  return new Promise((resolve)=>{
    execFile('powershell.exe',
      ['-NoProfile','-ExecutionPolicy','Bypass','-File', CORE].concat(args),
      { windowsHide:true, timeout: timeoutMs || 600000, maxBuffer: 64*1024*1024 },
      (err, stdout, stderr)=>resolve({
        ok: !err,
        err: err ? err.message : null,
        out: (stdout||'').trim(),
        err2: (stderr||'').trim()
      }));
  });
}

// 只留文件名里安全的部分, 防止前端传来的名字里带路径分隔符跑出工作目录
function safeName(s){
  return String(s || 'file').replace(/[\\/:*?"<>|]/g, '_').slice(0, 120) || 'file';
}
function stemOf(s){ return safeName(s).replace(/\.[^.]+$/, ''); }

// ---------- 能力自检 ----------
// 结果缓存: 编解码器不会在进程运行期间变来变去, 没必要每次 /health 都起一遍 PowerShell
let capCache = null;
async function capabilities(force){
  if (capCache && !force) return capCache;
  const dir = path.join(__dirname, '_临时');
  fs.mkdirSync(dir, { recursive:true });
  const out = path.join(dir, 'probe.json');
  try { fs.unlinkSync(out); } catch(e){}
  const r = await runPs(['-Probe','-Result', out], 60000);
  if (!r.ok || !fs.existsSync(out)) {
    capCache = { ok:false, 错误: r.err || r.err2 || '能力自检失败', 解码:[], 编码:[], PDF:false };
    return capCache;
  }
  const raw = JSON.parse(fs.readFileSync(out, 'utf8'));
  // MIME -> 扩展名。界面按扩展名判断"这个格式能不能转"。
  const M2E = {
    'image/png':'png', 'image/jpeg':'jpg', 'image/gif':'gif',
    'image/bmp':'bmp', 'image/tiff':'tif', 'image/x-icon':'ico',
    'image/x-emf':'emf', 'image/x-wmf':'wmf', 'image/webp':'webp'
  };
  const map = list => (list||[]).map(m => M2E[m]).filter(Boolean);
  capCache = {
    ok: true,
    解码: map(raw.解码),
    编码: map(raw.编码),
    PDF: !!raw.支持PDF,
    说明: raw.说明 || ''
  };
  return capCache;
}

// ---------- 转换 ----------
async function handleConvert(body){
  const tasks = Array.isArray(body.任务) ? body.任务 : [];
  if (!tasks.length) return { ok:false, 错误:'没有要转换的文件' };

  const work = path.join(TMP, 'j' + Date.now() + '_' + Math.random().toString(36).slice(2, 8));
  fs.mkdirSync(work, { recursive:true });

  const psTasks = [];   // 给 PowerShell 的任务
  const meta = [];      // 与 psTasks 一一对应, 记着原始文件名好还原

  try {
    for (let i = 0; i < tasks.length; i++){
      const t = tasks[i] || {};
      const origName = safeName(t.文件名 || ('文件' + (i+1)));
      let inPath;
      if (t.数据){
        inPath = path.join(work, 'in' + i + '_' + origName);
        fs.writeFileSync(inPath, Buffer.from(t.数据, 'base64'));
      } else {
        meta.push({ i, origName, 错误:'没有收到文件内容' });
        psTasks.push(null);
        continue;
      }

      const fmt = String(t.输出格式 || 'jpg').toLowerCase();
      const outPath = path.join(work, 'out' + i + '.' + fmt);
      const pt = { 类型: t.类型 === 'PDF' ? 'PDF' : '图片', 输入: inPath, 输出: outPath, 输出格式: fmt };
      if (t.质量 != null) pt.质量 = t.质量;
      if (t.宽 != null)   pt.宽   = t.宽;
      if (t.高 != null)   pt.高   = t.高;
      if (t.帧 != null)   pt.帧   = t.帧;
      if (t.页码 != null) pt.页码 = t.页码;
      if (t.DPI != null)  pt.DPI  = t.DPI;
      if (t.目标宽 != null) pt.目标宽 = t.目标宽;
      psTasks.push(pt);
      meta.push({ i, origName, outPath });
    }

    const live = psTasks.filter(Boolean);
    if (!live.length) return { ok:false, 错误:'没有有效的转换任务', 结果: meta.map(m=>({ ok:false, 来源:m.origName, 错误:m.错误 })) };

    const jobFile = path.join(work, 'job.json');
    const resFile = path.join(work, 'res.json');
    fs.writeFileSync(jobFile, JSON.stringify({ 任务: live }), 'utf8');

    const r = await runPs(['-Job', jobFile, '-Result', resFile], 900000);
    if (!fs.existsSync(resFile)){
      return { ok:false, 错误: '转换引擎没有返回结果：' + (r.err || r.err2 || r.out || '未知原因') };
    }

    const raw = JSON.parse(fs.readFileSync(resFile, 'utf8'));
    const psResults = raw.结果 || [];
    const out = [];
    // psResults 与 live 一一对应; live 是 psTasks 剔掉无效项后的顺序, 这里按同样顺序还原
    const liveIdx = [];
    psTasks.forEach((p, k) => { if (p) liveIdx.push(k); });

    psResults.forEach((pr, k) => {
      const m = meta[liveIdx[k]];
      if (!m) return;
      if (!pr.ok){
        out.push({ ok:false, 来源: m.origName, 错误: pr.错误 || '转换失败' });
        return;
      }
      (pr.输出 || []).forEach(o => {
        let b64 = '';
        try { b64 = fs.readFileSync(o.路径).toString('base64'); }
        catch(e){ out.push({ ok:false, 来源: m.origName, 错误:'结果文件读不回来：' + e.message }); return; }
        const ext = path.extname(o.路径).replace(/^\./,'');
        // 多页时引擎会给 _p01 / _p02 后缀, 这里把它接回原文件名上, 用户看到的名字才连得上。
        // 注意必须先剥掉扩展名再匹配: 直接拿 "out0_p01.jpg" 去匹配 /_p\d+$/ 是匹配不上的
        // (结尾是 .jpg), 结果三页全都叫同一个名字, 下载和打包时互相覆盖。
        const suffix = (path.basename(o.路径, path.extname(o.路径)).match(/_p\d+$/) || [''])[0];
        out.push({
          ok: true,
          来源: m.origName,
          文件名: stemOf(m.origName) + suffix + '.' + ext,
          数据: b64,
          宽: o.宽, 高: o.高, 大小: o.大小
        });
      });
    });

    // 无效项(缺数据/缺路径)的报错也补进去, 顺序无所谓, 前端按"来源"归组
    meta.forEach(m => { if (m.错误) out.push({ ok:false, 来源:m.origName, 错误:m.错误 }); });

    return { ok:true, 结果: out };
  } finally {
    // 工作目录里是用户文件的副本, 必须清掉 —— 这是"文件不出本机"的一部分
    try { fs.rmSync(work, { recursive:true, force:true }); } catch(e){}
  }
}

// ---------- 路由 ----------
const server = http.createServer(async (req, res) => {
  const url = (req.url || '/').split('?')[0];
  // CORS 头在这里一次设好, 后面的分支不用再各自操心
  const cors = corsFor(req);
  Object.keys(cors).forEach(k => res.setHeader(k, cors[k]));
  try {
    if (req.method === 'OPTIONS'){ res.writeHead(204); res.end(); return; }

    if (req.method === 'GET' && url === '/'){
      res.writeHead(200, {'Content-Type':'text/plain; charset=utf-8'});
      res.end('文件转换站 · 本机服务运行中\n接口: GET /health  POST /convert\n');
      return;
    }

    if (req.method === 'GET' && url === '/health'){
      const cap = await capabilities(false);
      send(res, 200, Object.assign({ ok:true, 服务:'文件转换站本机服务', 端口:PORT }, cap));
      return;
    }

    if (req.method === 'POST' && url === '/convert'){
      const body = JSON.parse(await readBody(req));
      const r = await handleConvert(body);
      send(res, 200, r);
      return;
    }

    send(res, 404, { ok:false, 错误:'没有这个接口: ' + url });
  } catch (e){
    send(res, 500, { ok:false, 错误: e && e.message ? e.message : String(e) });
  }
});

// 端口被占用时 node 默认会甩一段 EADDRINUSE 堆栈出来, 对用户等于天书。
// 最常见的成因就是「双击了两次启动脚本」, 直接说破。
server.on('error', (e)=>{
  console.log('');
  if (e && e.code === 'EADDRINUSE'){
    console.log('  启动失败：端口 ' + PORT + ' 已经被占用了。');
    console.log('');
    console.log('  多半是这个服务已经在运行 —— 翻翻任务栏, 是不是已经有一个');
    console.log('  「文件转换站」的黑窗口开着。有的话直接用那个就行, 不用再启动。');
    console.log('  如果确实没有, 就是别的程序占了这个端口。');
  } else {
    console.log('  启动失败：' + (e && e.message ? e.message : String(e)));
  }
  console.log('');
  process.exit(1);
});

server.listen(PORT, '127.0.0.1', () => {
  // 这些中文提示放在这里而不是批处理里: 批处理含中文会被 cmd 的 chcp 缺陷劈行,
  // 而 node 往 65001 控制台打 UTF-8 是正常的。
  console.log('');
  console.log('  文件转换站 · 本机服务');
  console.log('  ────────────────────────────────');
  console.log('  地址： http://127.0.0.1:' + PORT);
  console.log('  仅本机可访问，文件不会离开这台电脑。');
  console.log('');
  console.log('  转换引擎： ' + CORE);
  console.log('  临时目录： ' + TMP + '  （每次转换后自动清空）');
  console.log('');
  console.log('  关闭此窗口即停止服务。');
  console.log('');
});
