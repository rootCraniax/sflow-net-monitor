#!/usr/bin/env node

const dgram = require('dgram');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');

// CONFIGURATION overseen by cats
const DEFAULT_CONFIG = {
  interface: 'eth0', 
  pps_threshold: 100000,
  mbps_threshold: 900,
  port: 6343,
  window: 60,
  sampling: 32,
  spike_factor: 0,
  bias_factor: 1.05,
  trigger_states: ['CRITICAL'],
  trigger_script: './scripts/trigger.sh',
  ok_delay_secs: 60 // delay before running OK script
};

let cfg = { ...DEFAULT_CONFIG };
// prefer config in installation dir
const cfgPath = fs.existsSync('/opt/net-monitor/config.json')
  ? '/opt/net-monitor/config.json'
  : path.join(__dirname, 'config.json');
if (fs.existsSync(cfgPath)) {
  try {
    const raw = fs.readFileSync(cfgPath,'utf8');
    const clean = raw.replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, '');
    cfg = { ...cfg, ...JSON.parse(clean) };
  } catch {
    console.error('Invalid config.json, using defaults');
  }
}

// Log file for trigger events
const LOG_PATH = path.join(__dirname, 'trigger.log');

// GRAPH HELPERS draw graph even it sometimes not precise
function generateGraph(series, height, width, title) {
  // scale based on threshold, auto-expanding for peaks
  const thresholdMax = title.startsWith('PPS') ? cfg.pps_threshold : cfg.mbps_threshold;
  const currentMax = Math.max(...series, 1);
  const maxVal = Math.max(thresholdMax, currentMax);
  const out = [];
  out.push(`\n${title} (last ${width}s)`);
  // Draw bars: each row shows blocks where barHeight > row
  for (let row = height - 1; row >= 0; row--) {
    const yVal = ((row + 1) / height) * maxVal;
    const label = yVal.toFixed(1).padStart(7);
    let line = `${label} |`;
    for (let i = 0; i < width; i++) {
      const val = series[series.length - width + i] || 0;
      const barHeight = Math.ceil((val / maxVal) * height);
      line += barHeight > row ? '█' : ' ';
    }
    out.push(line);
  }
  // X-axis
  out.push(' '.repeat(8) + '+' + '-'.repeat(width));
  // Time labels: oldest ... mid ... now
  const left = `${width}s`, mid = `${Math.floor(width/2)}s`, right = '0s';
  const base = ' '.repeat(9) + left + ' '.repeat(width - left.length - right.length);
  const midPos = 9 + Math.floor((width - mid.length) / 2);
  const lbl = base.slice(0, midPos) + mid + base.slice(midPos + mid.length) + right;
  out.push(lbl);
  return out.join('\n');
}

// STATE
const rates = { pps: 0, mbps: 0 };
const history = { pps: new Array(cfg.window).fill(0), mbps: new Array(cfg.window).fill(0) };
let lastCounters = null; // for counter based (if present)
let lastUpdate = null; // timestamp of last rate calc
let trackedIf = null;
let countersActive = false; // becomes true when first counter sample parsed
let prevPps = 0;
let prevMbps = 0;

// Totals from flow samples (fallback when no counters)
let totalPkts = 0n;
let totalBytes = 0n;
let lastTotPkts = 0n;
let lastTotBytes = 0n;
let flowBased = false;

// PARSE HELPERS we parse stuff sometimes it not work
function readU32(buf, off){ return buf.readUInt32BE(off); }
function readU64(buf, off){ return buf.readBigUInt64BE(off); }

function parseCounterSample(buf, off, len){
  // skip 12-byte counter sample header already consumed outside.
  const end = off + len;
  let cursor = off;
  while (cursor + 8 <= end){
    const recType = readU32(buf, cursor) & 0xFFF; // lower 12 bits
    const recLen  = readU32(buf, cursor + 4);
    cursor += 8;
    if(recType === 1 && cursor + recLen <= end){
      // generic interface counters v5 (88 bytes)
      const ifIndex = readU32(buf, cursor + 0);
      const ifInOctets = readU64(buf, cursor + 24);
      const ifInUcast  = readU32(buf, cursor + 32);
      const ifInMcast  = readU32(buf, cursor + 36);
      const ifInBcast  = readU32(buf, cursor + 40);
      const ifOutOctets = readU64(buf, cursor + 56);
      const ifOutUcast  = readU32(buf, cursor + 64);
      const ifOutMcast  = readU32(buf, cursor + 68);
      const ifOutBcast  = readU32(buf, cursor + 72);
      return {
        ifIndex: ifIndex,
        inOctets: ifInOctets,
        outOctets: ifOutOctets,
        inPkts: ifInUcast + ifInMcast + ifInBcast,
        outPkts: ifOutUcast + ifOutMcast + ifOutBcast
      };
    }
    cursor += recLen; // skip other records
  }
  return null;
}

function parseFlowSample(buf, off, len){
  if(countersActive) return; // ignore if counters available
  const end = off + len;
  if(end>buf.length) return 0;
  // Read sample header fields
  const samplingRate = readU32(buf, off + 8); // skip seq(4) + srcId(4)
  // iterate records
  let cursor = off + 32; // flow sample header is 32 bytes (v5)
  let bytesThisSample = 0n;
  while(cursor + 8 <= end){
    const recType = readU32(buf, cursor) & 0xFFF;
    const recLen  = readU32(buf, cursor+4);
    cursor += 8;
    if(recType === 1 && cursor + recLen <= end){
      // HEADER record
      const frameLen = readU32(buf, cursor + 4); // offset 4 bytes after headerProtocol
      bytesThisSample += BigInt(frameLen) * BigInt(samplingRate);
    }
    cursor += recLen;
  }
  totalPkts += BigInt(samplingRate);
  totalBytes += bytesThisSample;
  flowBased = true;
}

function handleCounters(c){
  if(trackedIf===null){
    trackedIf = c.ifIndex;
    console.log(`Tracking interface with ifIndex ${trackedIf}`);
  }
  if(c.ifIndex!==trackedIf) return; // ignore other interfaces
  flowBased = false; // disable flow fallback
  countersActive = true;
  updateRates(c);
}

// UDP SERVER listen for sFlow packets
// Create UDP socket with reuseAddr and reusePort so multiple instances (service/CLI) can bind and receive
const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true, reusePort: true });

sock.on('message',(msg)=>{
  let offset = 0;
  if (msg.readUInt32BE(0) !== 5) return; // only v5
  // header 20 bytes after version (4), IP (4/16), agentid etc – we skip to samples count
  const samples = msg.readUInt32BE(24);
  offset = 28; // start of first sample
  for (let i=0;i<samples;i++){
    if(offset+8>msg.length) break;
    const sampleType   = readU32(msg, offset);
    const sampleFormat = sampleType & 0xFFF;
    const sampleLen    = readU32(msg, offset+4);
    offset += 8;
    if(sampleFormat===2){
      // counter sample
      if(offset+12>msg.length) break;
      const counters = parseCounterSample(msg, offset+12, sampleLen-12);
      if(counters) handleCounters(counters);
    } else if(sampleFormat===1){
      // flow sample
      parseFlowSample(msg, offset, sampleLen);
    }
    offset += sampleLen;
  }
});

sock.bind(cfg.port, ()=> console.log(`sFlow collector listening on 0.0.0.0:${cfg.port}`));

// RATE COMPUTATION compute rates but sometimes it not works
function updateRates(cur){
  const now = Date.now();
  if(!lastCounters){ lastCounters = cur; lastUpdate = now; return; }
  const deltaSec = (now - lastUpdate)/1000;
  if(deltaSec < 0.9) { // compute roughly once per second
    return; // accumulate until >=1s elapsed
  }
  // Use BigInt for octets to maintain precision, then convert to Number for rate calc
  const bytesDeltaBig = cur.inOctets - lastCounters.inOctets; // BigInt
  const bytesDelta = Number(bytesDeltaBig); // safe because delta over ~1s
  const pktsDelta  = cur.inPkts   - lastCounters.inPkts; // already Number
  rates.pps  = (pktsDelta / deltaSec) * cfg.bias_factor;
  rates.mbps = ((bytesDelta * 8) / (deltaSec * 1e6)) * cfg.bias_factor;

  // spike guard: discard if jump exceeds cfg.spike_factor
  if(cfg.spike_factor>0 && prevMbps>0 && (rates.mbps > prevMbps*cfg.spike_factor || rates.pps > prevPps*cfg.spike_factor)){
    return; // skip update
  }
  prevPps = rates.pps;
  prevMbps = rates.mbps;
  lastCounters = cur;
  lastUpdate = now;

  history.pps.push(rates.pps); if(history.pps.length>cfg.window) history.pps.shift();
  history.mbps.push(rates.mbps); if(history.mbps.length>cfg.window) history.mbps.shift();
  redraw();
}

// Every second compute rates from flow-based totals if counters absent
setInterval(()=>{
  if(!flowBased) return; // skip if using counter mode
  const now = Date.now();
  if(lastUpdate===null){ lastUpdate = now; lastTotPkts = totalPkts; lastTotBytes = totalBytes; return; }
  const deltaSec = (now - lastUpdate)/1000;
  if(deltaSec < 1) return;
  const pktsDelta = Number(totalPkts - lastTotPkts);
  const bytesDelta = Number(totalBytes - lastTotBytes);
  rates.pps = (pktsDelta / deltaSec) * cfg.bias_factor;
  rates.mbps = ((bytesDelta * 8) / (deltaSec*1e6)) * cfg.bias_factor;

  if(cfg.spike_factor>0 && prevMbps>0 && (rates.mbps > prevMbps*cfg.spike_factor || rates.pps > prevPps*cfg.spike_factor)) return;
  prevPps = rates.pps;
  prevMbps = rates.mbps;
  lastTotPkts = totalPkts;
  lastTotBytes = totalBytes;
  lastUpdate = now;

  history.pps.push(rates.pps); if(history.pps.length>cfg.window) history.pps.shift();
  history.mbps.push(rates.mbps); if(history.mbps.length>cfg.window) history.mbps.shift();
  redraw();
}, 1000);

// STATUS / TRIGGER maybe run script when need
let triggerTimer = null; // for delayed OK trigger
let lastFiredState = null;

function getTriggerScript(state){
  if(typeof cfg.trigger_script === 'string'){
    // legacy single script path; respect trigger_states if provided
    if(cfg.trigger_states && !cfg.trigger_states.includes(state)) return null;
    return cfg.trigger_script;
  }
  if(typeof cfg.trigger_script === 'object' && cfg.trigger_script[state]){
    return cfg.trigger_script[state];
  }
  return null;
}

function fireScript(state, scriptPath){
  const logEntry = `${new Date().toISOString()} | ${state} | ${rates.pps.toFixed(0)} PPS | ${rates.mbps.toFixed(2)} Mbps\n`;
  fs.appendFile(LOG_PATH, logEntry, ()=>{});
  if(fs.existsSync(scriptPath)){
    exec(`bash ${scriptPath}`, (err)=>{ if(err) console.error('Trigger script error:',err.message); });
  } else {
    console.warn('Trigger script not found:', scriptPath);
  }
  lastFiredState = state;
}

function evaluateStatus(){
  const ppsRatio  = cfg.pps_threshold  ? rates.pps  / cfg.pps_threshold  : 0;
  const mbpsRatio = cfg.mbps_threshold ? rates.mbps / cfg.mbps_threshold : 0;
  const usage = Math.max(ppsRatio, mbpsRatio);
  if(usage >= 1){ return 'CRITICAL'; }
  if(usage >= 0.7){ return 'ABNORMAL'; }
  if(usage >= 0.5){ return 'WARNING'; }
  // below 25% of threshold
  return 'OK';
}

function colorize(text,status){
  const colors = { OK:'\x1b[32m', WARNING:'\x1b[33m', ABNORMAL:'\x1b[35m', CRITICAL:'\x1b[31m' };
  const reset = '\x1b[0m';
  return (colors[status]||'') + text + reset;
}

function maybeTrigger(status){
  const scriptPath = getTriggerScript(status) ? path.join(__dirname, getTriggerScript(status)) : null;

  // handle OK delay
  if(status === 'OK' && scriptPath){
    if(triggerTimer===null){
      triggerTimer = setTimeout(()=>{
        fireScript('OK', scriptPath);
        triggerTimer = null;
      }, (cfg.ok_delay_secs||0)*1000);
    }
    return;
  } else {
    if(triggerTimer){ clearTimeout(triggerTimer); triggerTimer=null; }
  }

  if(scriptPath && status !== lastFiredState){
    fireScript(status, scriptPath);
  }
}

// DISPLAY show out put
function redraw(){
  console.clear();
  console.log('====================================');
  console.log('  sFlow Traffic Monitor and Trigger');
  console.log('     by Ali E. Mubarak (Craniax)')
  console.log('====================================');
  const status = evaluateStatus();
  maybeTrigger(status);
  console.log(`Interface: ${cfg.interface}`);
  console.log(`Current: ${rates.pps.toFixed(0)} PPS | ${rates.mbps.toFixed(2)} Mbps`);
  console.log('Status : ' + colorize(status, status) + '\n');
  console.log( generateGraph(history.pps, 10, cfg.window, 'PPS') );
  console.log( generateGraph(history.mbps, 10, cfg.window, 'Mbps') );
  console.log('\nPress Ctrl+C to exit');
}

// DISPLAY initial redraw
redraw();

// Auto-scroll graph every second: push current rates and redraw
setInterval(()=>{
  history.pps.push(rates.pps);
  if(history.pps.length>cfg.window) history.pps.shift();
  history.mbps.push(rates.mbps);
  if(history.mbps.length>cfg.window) history.mbps.shift();
  redraw();
}, 1000);

// preserve redraw if no new data for 2s
setInterval(()=>{ if(Date.now()-lastUpdate>2000) redraw(); }, 2000);
