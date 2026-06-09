const fs = require('fs');

// Haversine distance in meters
function haversine(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) * Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function parseGPX(file) {
  const xml = fs.readFileSync(file, 'utf8');
  const points = [];
  const regex = /<trkpt lat="([^"]+)" lon="([^"]+)"[^>]*>\s*<ele>([^<]+)<\/ele>/g;
  let m;
  while ((m = regex.exec(xml)) !== null) {
    points.push({ lat: parseFloat(m[1]), lon: parseFloat(m[2]), ele: parseFloat(m[3]) });
  }
  return points;
}

// Parse course
const coursePoints = parseGPX('TVO_2026_42km_2000D.gpx');

// Build km-by-km segments
let cumDist = 0;
const kmData = [];
let currentKm = { kmStart: 0, distAccum: 0, eleStart: coursePoints[0].ele, eleUp: 0, eleDown: 0, netEle: 0 };

for (let i = 1; i < coursePoints.length; i++) {
  const prev = coursePoints[i - 1];
  const curr = coursePoints[i];
  const d = haversine(prev.lat, prev.lon, curr.lat, curr.lon);
  const dEle = curr.ele - prev.ele;

  cumDist += d;
  currentKm.distAccum += d;

  if (dEle > 0) currentKm.eleUp += dEle;
  else currentKm.eleDown += Math.abs(dEle);

  if (cumDist >= (kmData.length + 1) * 1000) {
    const kmIdx = kmData.length + 1;
    const netEle = coursePoints[i].ele - currentKm.eleStart;
    kmData.push({
      km: kmIdx,
      dist: currentKm.distAccum,
      eleUp: currentKm.eleUp,
      eleDown: currentKm.eleDown,
      netEle: netEle,
      eleEnd: coursePoints[i].ele,
    });
    currentKm = { kmStart: coursePoints[i].ele, distAccum: 0, eleUp: 0, eleDown: 0, eleStart: coursePoints[i].ele };
  }
}
// Final partial km
if (currentKm.distAccum > 100) {
  const kmIdx = kmData.length + 1;
  const lastEle = coursePoints[coursePoints.length - 1].ele;
  kmData.push({
    km: kmIdx,
    dist: currentKm.distAccum,
    eleUp: currentKm.eleUp,
    eleDown: currentKm.eleDown,
    netEle: lastEle - currentKm.eleStart,
    eleEnd: lastEle,
  });
}

// Total course stats
const totalDist = kmData.reduce((s, k) => s + k.dist, 0);
const totalUp = kmData.reduce((s, k) => s + k.eleUp, 0);
const totalDown = kmData.reduce((s, k) => s + k.eleDown, 0);

console.log(`Course: ${(totalDist/1000).toFixed(2)} km, +${Math.round(totalUp)}m / -${Math.round(totalDown)}m`);
console.log(`Segments: ${kmData.length}`);

// Arthur's target: 4h50m = 290 minutes
const TARGET_SECONDS = (4 * 60 + 50) * 60;

// Grade-adjusted effort model
// For each km, compute a "difficulty factor" based on elevation
// Using a simple model:
//   - Flat (1000m at 0% grade): factor 1.0
//   - Uphill: +10s per 10m of gain per km (Strava-like)
//   - Downhill: -3s per 10m of descent per km (diminishing returns, risk of injury)
// Then normalize so total time = TARGET_SECONDS

function effortFactor(kmSeg) {
  // Effective flat distance adjusted for grade
  const grade = kmSeg.netEle / kmSeg.dist; // fractional grade
  // Use GAP model: effort = dist * (1 + k_up * grade+  or k_down * grade-)
  // Strava GAP approximate: +10% effort per 6% uphill grade
  // Simple: factor = 1 + 1.5 * grade for uphill, 1 - 0.3 * grade for downhill (grade is negative)
  let factor;
  if (grade >= 0) {
    factor = 1 + 1.5 * grade;
  } else {
    // Downhill slows you a bit at steep grades but helps on moderate
    factor = 1 + 0.5 * grade; // mild benefit, stays positive
  }
  // Effective effort distance
  return kmSeg.dist * Math.max(factor, 0.5);
}

const efforts = kmData.map(k => effortFactor(k));
const totalEffort = efforts.reduce((s, e) => s + e, 0);

// Baseline seconds per effort unit
const baseSecondsPerEffortMeter = TARGET_SECONDS / totalEffort;

// Compute time per km
let cumulativeSeconds = 0;
console.log('\n--- Arthur Pacing Plan (4h50 target) ---');
console.log('km | dist(m) | +ele | -ele | net | pace(min/km) | split | cumul time');
console.log('---|---------|------|------|-----|-------------|-------|----------');

const rows = [];
for (let i = 0; i < kmData.length; i++) {
  const k = kmData[i];
  const segSeconds = efforts[i] * baseSecondsPerEffortMeter;
  cumulativeSeconds += segSeconds;

  const paceSecPerKm = segSeconds / (k.dist / 1000);
  const paceMin = Math.floor(paceSecPerKm / 60);
  const paceSec = Math.round(paceSecPerKm % 60);

  const splitMin = Math.floor(segSeconds / 60);
  const splitSec = Math.round(segSeconds % 60);

  const cumulMin = Math.floor(cumulativeSeconds / 60);
  const cumulSec = Math.round(cumulativeSeconds % 60);

  rows.push({
    km: k.km,
    dist: Math.round(k.dist),
    eleUp: Math.round(k.eleUp),
    eleDown: Math.round(k.eleDown),
    net: Math.round(k.netEle),
    pace: `${paceMin}:${String(paceSec).padStart(2,'0')}`,
    split: `${splitMin}:${String(splitSec).padStart(2,'0')}`,
    cumul: `${cumulMin}:${String(cumulSec).padStart(2,'0')}`,
  });

  console.log(
    `${String(k.km).padStart(2)} | ${String(Math.round(k.dist)).padStart(7)} | ` +
    `${String(Math.round(k.eleUp)).padStart(4)} | ${String(Math.round(k.eleDown)).padStart(4)} | ` +
    `${String(Math.round(k.netEle)).padStart(4)} | ` +
    `${paceMin}:${String(paceSec).padStart(2,'0')} /km | ` +
    `${splitMin}:${String(splitSec).padStart(2,'0')} | ` +
    `${cumulMin}:${String(cumulSec).padStart(2,'0')}`
  );
}

// Output CSV
const csv = ['km,dist_m,ele_up,ele_down,net_ele,pace_min_km,split,cumul_time'];
for (const r of rows) {
  csv.push(`${r.km},${r.dist},${r.eleUp},${r.eleDown},${r.net},${r.pace},${r.split},${r.cumul}`);
}
fs.writeFileSync('arthur_pacing_plan.csv', csv.join('\n'));

// Output Markdown
function fmtCumul(secs) {
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  const s = Math.round(secs % 60);
  return h > 0 ? `${h}h${String(m).padStart(2,'0')}` : `${m}:${String(s).padStart(2,'0')}`;
}

let md = `# Arthur Pacing Plan — TVO 2026 (42km / +2000m)\n\n`;
md += `**Target:** 4h50:00 · **Course:** ${(totalDist/1000).toFixed(1)} km · **D+:** ${Math.round(totalUp)}m · **D-:** ${Math.round(totalDown)}m\n\n`;
md += `| km | +m | -m | net | Pace | Split | Cumul |\n`;
md += `|----|----|----|-----|------|-------|-------|\n`;

let cSec = 0;
for (let i = 0; i < kmData.length; i++) {
  const k = kmData[i];
  const segSec = efforts[i] * baseSecondsPerEffortMeter;
  cSec += segSec;
  const paceSecPerKm = segSec / (k.dist / 1000);
  const pm = Math.floor(paceSecPerKm / 60);
  const ps = Math.round(paceSecPerKm % 60);
  const sm = Math.floor(segSec / 60);
  const ss = Math.round(segSec % 60);
  const terrain = k.netEle > 50 ? '⛰️' : k.netEle < -50 ? '⬇️' : '→';
  md += `| **${k.km}** | +${Math.round(k.eleUp)} | -${Math.round(k.eleDown)} | ${Math.round(k.netEle) > 0 ? '+' : ''}${Math.round(k.netEle)} | ${pm}:${String(ps).padStart(2,'0')}/km | ${sm}:${String(ss).padStart(2,'0')} | **${fmtCumul(cSec)}** |\n`;
}
fs.writeFileSync('arthur_pacing_plan.md', md);
console.log('Saved: arthur_pacing_plan.md');
