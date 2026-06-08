import { useState } from 'react';
import { Key, X, ExternalLink } from 'lucide-react';
import { useTrailStore } from '../../stores/useTrailStore';

interface TokenModalProps {
  onClose: () => void;
}

export function TokenModal({ onClose }: TokenModalProps) {
  const cesiumToken = useTrailStore((s) => s.cesiumToken);
  const setCesiumToken = useTrailStore((s) => s.setCesiumToken);
  const [value, setValue] = useState(cesiumToken);

  const handleSave = () => {
    setCesiumToken(value.trim());
    onClose();
    // Reload to reinitialize Cesium with new token
    window.location.reload();
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 backdrop-blur-sm">
      <div className="w-full max-w-md rounded-2xl bg-zinc-900 border border-zinc-700 p-6 shadow-2xl">
        <div className="flex items-center justify-between mb-4">
          <div className="flex items-center gap-2">
            <Key className="h-5 w-5 text-trail-400" />
            <h2 className="text-lg font-semibold text-zinc-100">Cesium Ion Token</h2>
          </div>
          <button onClick={onClose} className="text-zinc-500 hover:text-zinc-300 transition-colors">
            <X className="h-5 w-5" />
          </button>
        </div>

        <p className="text-sm text-zinc-400 mb-4">
          A free Cesium Ion token unlocks photorealistic 3D terrain (Cesium World Terrain)
          and satellite imagery. Without it, the app uses flat terrain + OpenStreetMap.
        </p>

        <a
          href="https://cesium.com/ion/tokens"
          target="_blank"
          rel="noopener noreferrer"
          className="mb-4 flex items-center gap-1.5 text-sm text-trail-400 hover:text-trail-300 transition-colors"
        >
          <ExternalLink className="h-3.5 w-3.5" />
          Get a free token at cesium.com/ion/tokens
        </a>

        <input
          type="text"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          placeholder="Paste your Cesium Ion token here…"
          className="w-full rounded-lg bg-zinc-800 border border-zinc-600 px-3 py-2.5 text-sm text-zinc-100 placeholder-zinc-500 focus:border-trail-500 focus:outline-none focus:ring-1 focus:ring-trail-500"
        />

        <div className="flex gap-3 mt-4">
          <button
            onClick={onClose}
            className="flex-1 rounded-lg border border-zinc-700 py-2 text-sm text-zinc-300 hover:bg-zinc-800 transition-colors"
          >
            Cancel
          </button>
          <button
            onClick={handleSave}
            className="flex-1 rounded-lg bg-trail-600 py-2 text-sm font-medium text-white hover:bg-trail-500 transition-colors"
          >
            Save & Reload
          </button>
        </div>
      </div>
    </div>
  );
}
