import { useRef, useState, useCallback } from 'react';
import { useTrailStore } from './stores/useTrailStore';
import { GpxDropZone } from './features/gpx/GpxDropZone';
import { CesiumViewer } from './features/terrain/CesiumViewer';
import { ElevationProfile } from './features/elevation/ElevationProfile';
import { FlyoverControls } from './features/flyover/FlyoverControls';
import { TrailStats } from './components/Stats/TrailStats';
import { Toolbar } from './components/Layout/Toolbar';
import { TokenModal } from './components/UI/TokenModal';
import { parseGpx } from './features/gpx/gpxParser';

export default function App() {
  const track = useTrailStore((s) => s.track);
  const setTrack = useTrailStore((s) => s.setTrack);
  const showElevation = useTrailStore((s) => s.showElevation);
  const showStats = useTrailStore((s) => s.showStats);
  const showFlyover = useTrailStore((s) => s.showFlyover);

  const [showToken, setShowToken] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const recenterFnRef = useRef<(() => void) | null>(null);

  const handleRecenterReady = useCallback((fn: () => void) => {
    recenterFnRef.current = fn;
  }, []);

  const handleOpenFile = useCallback(() => {
    fileInputRef.current?.click();
  }, []);

  const handleFileChange = useCallback(
    async (e: React.ChangeEvent<HTMLInputElement>) => {
      const file = e.target.files?.[0];
      if (!file) return;
      try {
        const text = await file.text();
        const parsed = parseGpx(text);
        setTrack(parsed);
      } catch (err) {
        console.error('GPX parse error:', err);
      }
      e.target.value = '';
    },
    [setTrack],
  );

  if (!track) {
    return (
      <>
        <GpxDropZone />
        <input
          ref={fileInputRef}
          type="file"
          accept=".gpx"
          className="hidden"
          onChange={handleFileChange}
        />
      </>
    );
  }

  const elevationHeight = 'h-36';

  return (
    <div className="relative h-full w-full bg-zinc-950">
      {/* 3D map fills entire viewport */}
      <CesiumViewer onRecenterReady={handleRecenterReady} />

      {/* Top toolbar */}
      <Toolbar
        onOpenToken={() => setShowToken(true)}
        onOpenFile={handleOpenFile}
        onRecenter={() => recenterFnRef.current?.()}
      />

      {/* Right sidebar: stats */}
      {showStats && (
        <div className="absolute top-16 right-4 z-10 w-56">
          <TrailStats />
        </div>
      )}

      {/* Elevation profile anchored at bottom */}
      {showElevation && (
        <div className={`absolute bottom-0 left-0 right-0 z-10 ${elevationHeight} bg-zinc-950/85 backdrop-blur-sm border-t border-zinc-800`}>
          <ElevationProfile />
        </div>
      )}

      {/* Flyover controls float above elevation panel */}
      {showFlyover && (
        <div
          className="absolute z-10 w-80 left-1/2 -translate-x-1/2"
          style={{ bottom: showElevation ? '156px' : '16px' }}
        >
          <FlyoverControls />
        </div>
      )}

      {/* Hidden file input for toolbar reload */}
      <input
        ref={fileInputRef}
        type="file"
        accept=".gpx"
        className="hidden"
        onChange={handleFileChange}
      />

      {/* Cesium token settings modal */}
      {showToken && <TokenModal onClose={() => setShowToken(false)} />}
    </div>
  );
}
