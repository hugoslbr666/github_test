import { Play, Pause, SkipBack, FastForward } from 'lucide-react';
import { useTrailStore } from '../../stores/useTrailStore';
import { cn } from '../../lib/utils';
import type { FlyoverSpeed } from '../../types';

const SPEEDS: FlyoverSpeed[] = [1, 2, 4, 8];

export function FlyoverControls() {
  const track = useTrailStore((s) => s.track);
  const playing = useTrailStore((s) => s.flyoverPlaying);
  const index = useTrailStore((s) => s.flyoverIndex);
  const speed = useTrailStore((s) => s.flyoverSpeed);
  const setPlaying = useTrailStore((s) => s.setFlyoverPlaying);
  const setIndex = useTrailStore((s) => s.setFlyoverIndex);
  const setSpeed = useTrailStore((s) => s.setFlyoverSpeed);

  if (!track) return null;

  const total = track.points.length - 1;
  const progress = total > 0 ? (index / total) * 100 : 0;
  const currentDist = track.points[index]?.distFromStart ?? 0;
  const currentEle = Math.round(track.points[index]?.ele ?? 0);

  const handleReset = () => {
    setPlaying(false);
    setIndex(0);
  };

  const handleScrub = (e: React.ChangeEvent<HTMLInputElement>) => {
    const pct = parseFloat(e.target.value);
    const idx = Math.round((pct / 100) * total);
    setIndex(idx);
  };

  return (
    <div className="flex flex-col gap-3 rounded-xl bg-zinc-900/95 p-4 backdrop-blur-sm border border-zinc-800">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-1.5">
          <FastForward className="h-3.5 w-3.5 text-trail-400" />
          <span className="text-xs font-semibold uppercase tracking-wider text-zinc-300">
            Flyover
          </span>
        </div>
        <div className="text-xs text-zinc-400">
          {currentDist.toFixed(1)} km · {currentEle} m
        </div>
      </div>

      {/* Scrubber */}
      <div className="flex items-center gap-2">
        <span className="text-xs text-zinc-500 w-8 text-right">{currentDist.toFixed(1)}</span>
        <input
          type="range"
          min={0}
          max={100}
          step={0.1}
          value={progress}
          onChange={handleScrub}
          className="h-1.5 flex-1 cursor-pointer appearance-none rounded-full bg-zinc-700 accent-trail-400"
        />
        <span className="text-xs text-zinc-500 w-8">{track.stats.totalDistance.toFixed(1)}</span>
      </div>

      {/* Controls */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <button
            onClick={handleReset}
            className="rounded-lg p-1.5 text-zinc-400 hover:bg-zinc-800 hover:text-zinc-100 transition-colors"
            title="Reset"
          >
            <SkipBack className="h-4 w-4" />
          </button>

          <button
            onClick={() => setPlaying(!playing)}
            className={cn(
              'rounded-lg px-4 py-1.5 text-sm font-medium transition-colors flex items-center gap-1.5',
              playing
                ? 'bg-trail-600 text-white hover:bg-trail-700'
                : 'bg-trail-500 text-white hover:bg-trail-600',
            )}
          >
            {playing ? (
              <><Pause className="h-3.5 w-3.5" /> Pause</>
            ) : (
              <><Play className="h-3.5 w-3.5" /> Play</>
            )}
          </button>
        </div>

        {/* Speed selector */}
        <div className="flex items-center gap-1">
          {SPEEDS.map((s) => (
            <button
              key={s}
              onClick={() => setSpeed(s)}
              className={cn(
                'rounded px-2 py-0.5 text-xs font-mono font-medium transition-colors',
                speed === s
                  ? 'bg-trail-600 text-white'
                  : 'text-zinc-400 hover:bg-zinc-800 hover:text-zinc-100',
              )}
            >
              {s}×
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
