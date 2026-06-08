import { useCallback, useMemo } from 'react';
import {
  AreaChart, Area, XAxis, YAxis, CartesianGrid,
  Tooltip, ResponsiveContainer, ReferenceLine,
} from 'recharts';
import type { TooltipProps } from 'recharts';
import { useTrailStore } from '../../stores/useTrailStore';
import { buildElevationData, closestIndexByDistance, formatDistance, formatElevation } from '../../lib/utils';

function CustomTooltip({ active, payload }: TooltipProps<number, string>) {
  if (!active || !payload?.length) return null;
  const d = payload[0].payload as { dist: number; ele: number };
  return (
    <div className="rounded-lg bg-zinc-900/95 px-3 py-2 text-xs shadow-xl border border-zinc-700">
      <p className="font-semibold text-zinc-100">{formatElevation(d.ele)}</p>
      <p className="text-zinc-400">{formatDistance(d.dist)}</p>
    </div>
  );
}

export function ElevationProfile() {
  const track = useTrailStore((s) => s.track);
  const hoveredIndex = useTrailStore((s) => s.hoveredIndex);
  const setHoveredIndex = useTrailStore((s) => s.setHoveredIndex);
  const setSelectedIndex = useTrailStore((s) => s.setSelectedIndex);

  const data = useMemo(() => {
    if (!track) return [];
    return buildElevationData(track.points, 600);
  }, [track]);

  const hoveredDist = useMemo(() => {
    if (!track || hoveredIndex === null) return undefined;
    return track.points[hoveredIndex]?.distFromStart;
  }, [track, hoveredIndex]);

  const handleMouseMove = useCallback(
    (e: { activePayload?: Array<{ payload: { dist: number; index: number } }> }) => {
      if (!track || !e.activePayload?.length) return;
      const { dist } = e.activePayload[0].payload;
      const idx = closestIndexByDistance(track.points, dist);
      setHoveredIndex(idx);
    },
    [track, setHoveredIndex],
  );

  const handleMouseLeave = useCallback(() => {
    setHoveredIndex(null);
  }, [setHoveredIndex]);

  const handleClick = useCallback(
    (e: { activePayload?: Array<{ payload: { dist: number } }> }) => {
      if (!track || !e.activePayload?.length) return;
      const { dist } = e.activePayload[0].payload;
      const idx = closestIndexByDistance(track.points, dist);
      setSelectedIndex(idx);
    },
    [track, setSelectedIndex],
  );

  if (!track || data.length === 0) return null;

  const minEle = Math.floor((track.stats.minElevation - 50) / 100) * 100;
  const maxEle = Math.ceil((track.stats.maxElevation + 50) / 100) * 100;

  return (
    <div className="h-full w-full px-2 pt-2">
      <ResponsiveContainer width="100%" height="100%">
        <AreaChart
          data={data}
          margin={{ top: 4, right: 8, left: 0, bottom: 0 }}
          onMouseMove={handleMouseMove}
          onMouseLeave={handleMouseLeave}
          onClick={handleClick}
        >
          <defs>
            <linearGradient id="elevGradient" x1="0" y1="0" x2="0" y2="1">
              <stop offset="5%" stopColor="#4ade80" stopOpacity={0.4} />
              <stop offset="95%" stopColor="#4ade80" stopOpacity={0.05} />
            </linearGradient>
          </defs>

          <CartesianGrid strokeDasharray="3 3" stroke="#27272a" vertical={false} />

          <XAxis
            dataKey="dist"
            type="number"
            domain={[0, track.stats.totalDistance]}
            tickFormatter={(v: number) => `${v.toFixed(0)}km`}
            tick={{ fill: '#71717a', fontSize: 10 }}
            axisLine={{ stroke: '#3f3f46' }}
            tickLine={false}
            interval="preserveStartEnd"
          />

          <YAxis
            domain={[minEle, maxEle]}
            tickFormatter={(v: number) => `${v}m`}
            tick={{ fill: '#71717a', fontSize: 10 }}
            axisLine={false}
            tickLine={false}
            width={44}
          />

          <Tooltip content={<CustomTooltip />} cursor={{ stroke: '#facc15', strokeWidth: 1 }} />

          {hoveredDist !== undefined && (
            <ReferenceLine x={hoveredDist} stroke="#facc15" strokeWidth={2} />
          )}

          <Area
            type="monotone"
            dataKey="ele"
            stroke="#4ade80"
            strokeWidth={2}
            fill="url(#elevGradient)"
            dot={false}
            activeDot={{ r: 4, fill: '#facc15', stroke: '#000', strokeWidth: 1 }}
            isAnimationActive={false}
          />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  );
}
