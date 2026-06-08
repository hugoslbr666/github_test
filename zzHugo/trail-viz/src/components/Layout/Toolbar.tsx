import { Mountain, Upload, BarChart2, Info, Key, FastForward, Home } from 'lucide-react';
import { useTrailStore } from '../../stores/useTrailStore';
import { cn } from '../../lib/utils';

interface ToolbarProps {
  onOpenToken: () => void;
  onOpenFile: () => void;
  onRecenter: () => void;
}

export function Toolbar({ onOpenToken, onOpenFile, onRecenter }: ToolbarProps) {
  const track = useTrailStore((s) => s.track);
  const showElevation = useTrailStore((s) => s.showElevation);
  const showStats = useTrailStore((s) => s.showStats);
  const showFlyover = useTrailStore((s) => s.showFlyover);
  const toggleElevation = useTrailStore((s) => s.toggleElevation);
  const toggleStats = useTrailStore((s) => s.toggleStats);
  const toggleFlyover = useTrailStore((s) => s.toggleFlyover);

  return (
    <div className="absolute top-4 left-1/2 -translate-x-1/2 z-10 flex items-center gap-1 rounded-2xl bg-zinc-900/95 px-2 py-1.5 backdrop-blur-sm shadow-xl border border-zinc-800">
      {/* Brand */}
      <div className="flex items-center gap-1.5 px-2 mr-1">
        <Mountain className="h-4 w-4 text-trail-400" />
        <span className="text-sm font-bold tracking-tight text-zinc-100">TrailViz</span>
      </div>

      <div className="h-5 w-px bg-zinc-700" />

      <ToolBtn
        icon={<Upload className="h-4 w-4" />}
        label="Load GPX"
        onClick={onOpenFile}
      />

      {track && (
        <>
          <ToolBtn
            icon={<Home className="h-4 w-4" />}
            label="Recenter"
            onClick={onRecenter}
          />
          <ToolBtn
            icon={<BarChart2 className="h-4 w-4" />}
            label="Elevation"
            active={showElevation}
            onClick={toggleElevation}
          />
          <ToolBtn
            icon={<Info className="h-4 w-4" />}
            label="Stats"
            active={showStats}
            onClick={toggleStats}
          />
          <ToolBtn
            icon={<FastForward className="h-4 w-4" />}
            label="Flyover"
            active={showFlyover}
            onClick={toggleFlyover}
          />
        </>
      )}

      <div className="h-5 w-px bg-zinc-700" />

      <ToolBtn
        icon={<Key className="h-4 w-4" />}
        label="Token"
        onClick={onOpenToken}
      />
    </div>
  );
}

interface ToolBtnProps {
  icon: React.ReactNode;
  label: string;
  active?: boolean;
  onClick: () => void;
}

function ToolBtn({ icon, label, active, onClick }: ToolBtnProps) {
  return (
    <button
      onClick={onClick}
      title={label}
      className={cn(
        'flex items-center gap-1.5 rounded-xl px-2.5 py-1.5 text-xs font-medium transition-colors',
        active
          ? 'bg-trail-600 text-white'
          : 'text-zinc-400 hover:bg-zinc-800 hover:text-zinc-100',
      )}
    >
      {icon}
      <span className="hidden sm:inline">{label}</span>
    </button>
  );
}
