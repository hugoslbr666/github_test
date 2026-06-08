import { clsx, type ClassValue } from 'clsx';
import { twMerge } from 'tailwind-merge';
import type { TrackPoint, ElevationDatum } from '../types';

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export function haversineMeters(
  lat1: number, lon1: number,
  lat2: number, lon2: number,
): number {
  const R = 6371000;
  const φ1 = (lat1 * Math.PI) / 180;
  const φ2 = (lat2 * Math.PI) / 180;
  const Δφ = ((lat2 - lat1) * Math.PI) / 180;
  const Δλ = ((lon2 - lon1) * Math.PI) / 180;
  const a =
    Math.sin(Δφ / 2) ** 2 +
    Math.cos(φ1) * Math.cos(φ2) * Math.sin(Δλ / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

export function formatDistance(km: number): string {
  if (km < 1) return `${Math.round(km * 1000)} m`;
  return `${km.toFixed(1)} km`;
}

export function formatElevation(m: number): string {
  return `${Math.round(m)} m`;
}

export function formatGrade(pct: number): string {
  return `${pct.toFixed(1)}%`;
}

/** Downsample an array to at most `maxPoints` evenly-spaced items. */
export function downsample<T>(arr: T[], maxPoints: number): T[] {
  if (arr.length <= maxPoints) return arr;
  const step = arr.length / maxPoints;
  const result: T[] = [];
  for (let i = 0; i < maxPoints; i++) {
    result.push(arr[Math.round(i * step)]);
  }
  // Always include the last point
  const last = arr[arr.length - 1];
  if (result[result.length - 1] !== last) result.push(last);
  return result;
}

/** Build elevation chart data, downsampled to maxPoints for performance. */
export function buildElevationData(
  points: TrackPoint[],
  maxPoints = 600,
): ElevationDatum[] {
  const sampled = downsample(points, maxPoints);
  return sampled.map((p, i) => ({
    dist: Math.round(p.distFromStart * 10) / 10,
    ele: Math.round(p.ele),
    index: points.indexOf(p) === -1 ? i : points.indexOf(p),
  }));
}

/** Find the closest point index for a given distance (km). */
export function closestIndexByDistance(points: TrackPoint[], distKm: number): number {
  let lo = 0;
  let hi = points.length - 1;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (points[mid].distFromStart < distKm) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

/** Compute bearing in degrees from point A to point B. */
export function bearing(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const φ1 = (lat1 * Math.PI) / 180;
  const φ2 = (lat2 * Math.PI) / 180;
  const Δλ = ((lon2 - lon1) * Math.PI) / 180;
  const y = Math.sin(Δλ) * Math.cos(φ2);
  const x = Math.cos(φ1) * Math.sin(φ2) - Math.sin(φ1) * Math.cos(φ2) * Math.cos(Δλ);
  return ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360;
}
