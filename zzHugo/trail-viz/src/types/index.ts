export interface TrackPoint {
  lat: number;
  lon: number;
  ele: number;
  distFromStart: number;  // km
  cumulGain: number;      // m
  cumulLoss: number;      // m
}

export interface TrailStats {
  totalDistance: number;  // km
  elevationGain: number;  // m
  elevationLoss: number;  // m
  minElevation: number;   // m
  maxElevation: number;   // m
  maxGrade: number;       // %
  avgGrade: number;       // %
}

export interface GpxTrack {
  name: string;
  points: TrackPoint[];
  stats: TrailStats;
}

export type FlyoverSpeed = 1 | 2 | 4 | 8;

export interface FlyoverState {
  isPlaying: boolean;
  currentIndex: number;
  speed: FlyoverSpeed;
}

export interface ElevationDatum {
  dist: number;   // km
  ele: number;    // m
  index: number;  // original point index
}
