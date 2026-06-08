import { TrendingUp, TrendingDown, Ruler, Mountain, ArrowUpDown, Percent } from 'lucide-react';
import { useTrailStore } from '../../stores/useTrailStore';

interface StatItemProps {
  icon: React.ReactNode;
  label: string;
  value: string;
}

function StatItem({ icon, label, value }: StatItemProps) {
  return (
    <div className="flex items-center gap-3 rounded-lg bg-zinc-800/60 px-3 py-2.5">
      <div className="text-trail-400 shrink-0">{icon}</div>
      <div className="min-w-0">
        <p className="text-[10px] uppercase tracking-wider text-zinc-500">{label}</p>
        <p className="text-sm font-semibold text-zinc-100">{value}</p>
      </div>
    </div>
  );
}

export function TrailStats() {
  const track = useTrailStore((s) => s.track);
  if (!track) return null;

  const { stats } = track;

  return (
    <div className="rounded-xl bg-zinc-900/95 p-3 backdrop-blur-sm border border-zinc-800">
      <p className="mb-2 truncate text-xs font-semibold text-zinc-100 px-1">{track.name}</p>
      <div className="grid grid-cols-2 gap-1.5">
        <StatItem
          icon={<Ruler className="h-4 w-4" />}
          label="Distance"
          value={`${stats.totalDistance.toFixed(1)} km`}
        />
        <StatItem
          icon={<Mountain className="h-4 w-4" />}
          label="Elevation"
          value={`${Math.round(stats.minElevation)}–${Math.round(stats.maxElevation)} m`}
        />
        <StatItem
          icon={<TrendingUp className="h-4 w-4" />}
          label="D+"
          value={`+${Math.round(stats.elevationGain)} m`}
        />
        <StatItem
          icon={<TrendingDown className="h-4 w-4" />}
          label="D−"
          value={`−${Math.round(stats.elevationLoss)} m`}
        />
        <StatItem
          icon={<Percent className="h-4 w-4" />}
          label="Max grade"
          value={`${stats.maxGrade.toFixed(1)}%`}
        />
        <StatItem
          icon={<ArrowUpDown className="h-4 w-4" />}
          label="Avg grade"
          value={`${stats.avgGrade.toFixed(1)}%`}
        />
      </div>
    </div>
  );
}
