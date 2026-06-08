import type { GpxTrack, TrackPoint, TrailStats } from '../../types';
import { haversineMeters } from '../../lib/utils';

const SMOOTH_WINDOW = 3; // points on each side for elevation smoothing
const MIN_GRADE_DIST = 20; // meters minimum distance to compute a grade

function smoothElevations(eles: number[]): number[] {
  return eles.map((_, i) => {
    const start = Math.max(0, i - SMOOTH_WINDOW);
    const end = Math.min(eles.length, i + SMOOTH_WINDOW + 1);
    const slice = eles.slice(start, end);
    return slice.reduce((a, b) => a + b, 0) / slice.length;
  });
}

function extractPoints(doc: Document): Array<{ lat: number; lon: number; ele: number }> {
  const ns = 'http://www.topografix.com/GPX/1/1';

  // Try trkpt first, then rtept
  let nodes = Array.from(doc.getElementsByTagNameNS(ns, 'trkpt'));
  if (nodes.length === 0) nodes = Array.from(doc.getElementsByTagNameNS(ns, 'rtept'));
  // Fallback: no-namespace
  if (nodes.length === 0) nodes = Array.from(doc.getElementsByTagName('trkpt'));
  if (nodes.length === 0) nodes = Array.from(doc.getElementsByTagName('rtept'));

  return nodes
    .map((node) => {
      const lat = parseFloat(node.getAttribute('lat') ?? '');
      const lon = parseFloat(node.getAttribute('lon') ?? '');
      const eleNode =
        node.getElementsByTagNameNS(ns, 'ele')[0] ??
        node.getElementsByTagName('ele')[0];
      const ele = eleNode ? parseFloat(eleNode.textContent ?? '0') : 0;
      return { lat, lon, ele };
    })
    .filter((p) => !isNaN(p.lat) && !isNaN(p.lon));
}

function extractName(doc: Document): string {
  const ns = 'http://www.topografix.com/GPX/1/1';
  const nameNode =
    doc.getElementsByTagNameNS(ns, 'name')[0] ??
    doc.getElementsByTagName('name')[0];
  return nameNode?.textContent?.trim() ?? 'Unnamed Track';
}

function buildTrackPoints(
  raw: Array<{ lat: number; lon: number; ele: number }>,
): TrackPoint[] {
  const smoothed = smoothElevations(raw.map((p) => p.ele));

  let distM = 0;
  let cumulGain = 0;
  let cumulLoss = 0;

  return raw.map((p, i) => {
    if (i > 0) {
      distM += haversineMeters(raw[i - 1].lat, raw[i - 1].lon, p.lat, p.lon);
      const dEle = smoothed[i] - smoothed[i - 1];
      if (dEle > 0) cumulGain += dEle;
      else cumulLoss += Math.abs(dEle);
    }
    return {
      lat: p.lat,
      lon: p.lon,
      ele: smoothed[i],
      distFromStart: Math.round(distM / 10) / 100, // km, 2 decimals
      cumulGain: Math.round(cumulGain),
      cumulLoss: Math.round(cumulLoss),
    };
  });
}

function computeStats(points: TrackPoint[]): TrailStats {
  if (points.length === 0) {
    return {
      totalDistance: 0,
      elevationGain: 0,
      elevationLoss: 0,
      minElevation: 0,
      maxElevation: 0,
      maxGrade: 0,
      avgGrade: 0,
    };
  }

  const last = points[points.length - 1];
  const eles = points.map((p) => p.ele);

  let maxGrade = 0;
  for (let i = 1; i < points.length; i++) {
    const distM = haversineMeters(
      points[i - 1].lat, points[i - 1].lon,
      points[i].lat, points[i].lon,
    );
    if (distM >= MIN_GRADE_DIST) {
      const grade = Math.abs(points[i].ele - points[i - 1].ele) / distM * 100;
      if (grade > maxGrade) maxGrade = grade;
    }
  }

  const totalDistM = last.distFromStart * 1000;
  const avgGrade = totalDistM > 0
    ? last.cumulGain / totalDistM * 100
    : 0;

  return {
    totalDistance: last.distFromStart,
    elevationGain: last.cumulGain,
    elevationLoss: last.cumulLoss,
    minElevation: Math.min(...eles),
    maxElevation: Math.max(...eles),
    maxGrade: Math.round(maxGrade * 10) / 10,
    avgGrade: Math.round(avgGrade * 10) / 10,
  };
}

export function parseGpx(content: string): GpxTrack {
  const parser = new DOMParser();
  const doc = parser.parseFromString(content, 'application/xml');

  const parseError = doc.querySelector('parsererror');
  if (parseError) throw new Error('Invalid GPX file');

  const raw = extractPoints(doc);
  if (raw.length === 0) throw new Error('No track points found in GPX file');

  const points = buildTrackPoints(raw);
  const stats = computeStats(points);
  const name = extractName(doc);

  return { name, points, stats };
}
