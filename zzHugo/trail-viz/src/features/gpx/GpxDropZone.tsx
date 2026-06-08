import React, { useCallback, useRef, useState } from 'react';
import { Upload, Mountain } from 'lucide-react';
import { cn } from '../../lib/utils';
import { parseGpx } from './gpxParser';
import { useTrailStore } from '../../stores/useTrailStore';

export function GpxDropZone() {
  const setTrack = useTrailStore((s) => s.setTrack);
  const [dragging, setDragging] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  const handleFile = useCallback(
    async (file: File) => {
      if (!file.name.endsWith('.gpx') && file.type !== 'application/gpx+xml') {
        setError('Please drop a .gpx file');
        return;
      }
      setLoading(true);
      setError(null);
      try {
        const text = await file.text();
        const track = parseGpx(text);
        setTrack(track);
      } catch (e) {
        setError(e instanceof Error ? e.message : 'Failed to parse GPX');
      } finally {
        setLoading(false);
      }
    },
    [setTrack],
  );

  const onDrop = useCallback(
    (e: React.DragEvent) => {
      e.preventDefault();
      setDragging(false);
      const file = e.dataTransfer.files[0];
      if (file) handleFile(file);
    },
    [handleFile],
  );

  const onFileChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const file = e.target.files?.[0];
      if (file) handleFile(file);
      e.target.value = '';
    },
    [handleFile],
  );

  return (
    <div className="flex h-full w-full items-center justify-center bg-zinc-950">
      <div
        className={cn(
          'flex flex-col items-center gap-6 rounded-2xl border-2 border-dashed p-16 text-center transition-colors cursor-pointer select-none',
          dragging
            ? 'border-trail-400 bg-trail-950/40'
            : 'border-zinc-700 bg-zinc-900 hover:border-zinc-500',
        )}
        onDragOver={(e) => { e.preventDefault(); setDragging(true); }}
        onDragLeave={() => setDragging(false)}
        onDrop={onDrop}
        onClick={() => inputRef.current?.click()}
      >
        <div className="rounded-full bg-zinc-800 p-6">
          <Mountain className="h-12 w-12 text-trail-400" />
        </div>

        <div>
          <p className="text-xl font-semibold text-zinc-100">
            {loading ? 'Parsing track…' : 'Drop your GPX file'}
          </p>
          <p className="mt-1 text-sm text-zinc-400">
            or click to browse — supports tracks up to 100 km+
          </p>
        </div>

        {error && (
          <p className="rounded-lg bg-red-900/40 px-4 py-2 text-sm text-red-300">
            {error}
          </p>
        )}

        <div className="flex items-center gap-2 rounded-lg bg-zinc-800 px-4 py-2 text-sm text-zinc-400">
          <Upload className="h-4 w-4" />
          <span>TrailViz supports standard .gpx files</span>
        </div>
      </div>

      <input
        ref={inputRef}
        type="file"
        accept=".gpx"
        className="hidden"
        onChange={onFileChange}
      />
    </div>
  );
}
