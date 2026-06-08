import { create } from 'zustand';
import type { GpxTrack, FlyoverSpeed } from '../types';

interface TrailStore {
  // Track data
  track: GpxTrack | null;
  setTrack: (track: GpxTrack | null) => void;

  // Hovered point index (syncs elevation profile ↔ 3D map)
  hoveredIndex: number | null;
  setHoveredIndex: (index: number | null) => void;

  // Selected point (click on profile → camera flies there)
  selectedIndex: number | null;
  setSelectedIndex: (index: number | null) => void;

  // Flyover state
  flyoverPlaying: boolean;
  flyoverIndex: number;
  flyoverSpeed: FlyoverSpeed;
  setFlyoverPlaying: (playing: boolean) => void;
  setFlyoverIndex: (index: number) => void;
  setFlyoverSpeed: (speed: FlyoverSpeed) => void;

  // Cesium ion token
  cesiumToken: string;
  setCesiumToken: (token: string) => void;

  // UI panel visibility
  showElevation: boolean;
  showStats: boolean;
  showFlyover: boolean;
  toggleElevation: () => void;
  toggleStats: () => void;
  toggleFlyover: () => void;
}

const STORED_TOKEN_KEY = 'trailviz_cesium_token';

export const useTrailStore = create<TrailStore>((set) => ({
  track: null,
  setTrack: (track) => set({ track, hoveredIndex: null, selectedIndex: null, flyoverIndex: 0, flyoverPlaying: false }),

  hoveredIndex: null,
  setHoveredIndex: (index) => set({ hoveredIndex: index }),

  selectedIndex: null,
  setSelectedIndex: (index) => set({ selectedIndex: index }),

  flyoverPlaying: false,
  flyoverIndex: 0,
  flyoverSpeed: 1,
  setFlyoverPlaying: (playing) => set({ flyoverPlaying: playing }),
  setFlyoverIndex: (index) => set({ flyoverIndex: index }),
  setFlyoverSpeed: (speed) => set({ flyoverSpeed: speed }),

  cesiumToken: localStorage.getItem(STORED_TOKEN_KEY) ?? import.meta.env.VITE_CESIUM_ION_TOKEN ?? '',
  setCesiumToken: (token) => {
    localStorage.setItem(STORED_TOKEN_KEY, token);
    set({ cesiumToken: token });
  },

  showElevation: true,
  showStats: true,
  showFlyover: false,
  toggleElevation: () => set((s) => ({ showElevation: !s.showElevation })),
  toggleStats: () => set((s) => ({ showStats: !s.showStats })),
  toggleFlyover: () => set((s) => ({ showFlyover: !s.showFlyover })),
}));
