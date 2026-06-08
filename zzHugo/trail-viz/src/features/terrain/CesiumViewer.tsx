import { useEffect, useRef, useCallback } from 'react';
import * as Cesium from 'cesium';
import 'cesium/Build/Cesium/Widgets/widgets.css';
import { useTrailStore } from '../../stores/useTrailStore';
import { bearing } from '../../lib/utils';
import type { GpxTrack } from '../../types';

const TRACK_COLOR = Cesium.Color.fromCssColorString('#4ade80');
const CURSOR_COLOR = Cesium.Color.fromCssColorString('#facc15');
const TRACK_WIDTH = 4;
const CAMERA_HEIGHT_OFFSET = 120;
const OVERVIEW_PITCH = Cesium.Math.toRadians(-35);

interface Props {
  onRecenterReady?: (fn: () => void) => void;
}

export function CesiumViewer({ onRecenterReady }: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const viewerRef = useRef<Cesium.Viewer | null>(null);
  const trackEntityRef = useRef<Cesium.Entity | null>(null);
  const cursorEntityRef = useRef<Cesium.Entity | null>(null);
  const flyoverTimerRef = useRef<number | null>(null);
  // Use refs for flyover to avoid stale closures inside setInterval
  const flyoverIndexRef = useRef(0);
  const flyoverSpeedRef = useRef(1);
  const trackRef = useRef<GpxTrack | null>(null);

  const track = useTrailStore((s) => s.track);
  const hoveredIndex = useTrailStore((s) => s.hoveredIndex);
  const selectedIndex = useTrailStore((s) => s.selectedIndex);
  const flyoverPlaying = useTrailStore((s) => s.flyoverPlaying);
  const flyoverIndex = useTrailStore((s) => s.flyoverIndex);
  const flyoverSpeed = useTrailStore((s) => s.flyoverSpeed);
  const cesiumToken = useTrailStore((s) => s.cesiumToken);
  const setFlyoverIndex = useTrailStore((s) => s.setFlyoverIndex);
  const setFlyoverPlaying = useTrailStore((s) => s.setFlyoverPlaying);

  // Keep refs in sync with store
  useEffect(() => { flyoverIndexRef.current = flyoverIndex; }, [flyoverIndex]);
  useEffect(() => { flyoverSpeedRef.current = flyoverSpeed; }, [flyoverSpeed]);
  useEffect(() => { trackRef.current = track; }, [track]);

  // Initialize viewer once
  useEffect(() => {
    if (!containerRef.current || viewerRef.current) return;

    Cesium.Ion.defaultAccessToken =
      cesiumToken ||
      // Cesium community demo token (rate-limited) — replace with your own
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJqdGkiOiJlYWE1OWUxNy1mMWZiLTQzYjYtYTQ0OS1kMWFjYmFkNjc5YzciLCJpZCI6NTc3MzMsImlhdCI6MTYyNzg0NTE4Mn0.XcKpgANiY19MC4bdFUXMVEBToBmqS8kuYpUlxJHYZxk';

    const creditDiv = document.createElement('div');
    creditDiv.style.display = 'none';

    const viewer = new Cesium.Viewer(containerRef.current, {
      baseLayerPicker: false,
      geocoder: false,
      homeButton: false,
      sceneModePicker: false,
      navigationHelpButton: false,
      animation: false,
      timeline: false,
      fullscreenButton: false,
      infoBox: false,
      selectionIndicator: false,
      creditContainer: creditDiv,
    });

    // Load world terrain
    Cesium.createWorldTerrainAsync({
      requestWaterMask: false,
      requestVertexNormals: true,
    })
      .then((provider) => {
        if (!viewer.isDestroyed()) viewer.terrainProvider = provider;
      })
      .catch(() => console.warn('Cesium World Terrain unavailable — check your token at cesium.com/ion/tokens'));

    // Imagery: Bing Aerial via Ion with OSM fallback
    viewer.imageryLayers.removeAll();
    Cesium.IonImageryProvider.fromAssetId(3)
      .then((provider) => {
        if (!viewer.isDestroyed()) viewer.imageryLayers.addImageryProvider(provider);
      })
      .catch(() => {
        if (!viewer.isDestroyed()) {
          viewer.imageryLayers.addImageryProvider(
            new Cesium.UrlTemplateImageryProvider({
              url: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              credit: '© OpenStreetMap contributors',
            }),
          );
        }
      });

    viewer.scene.globe.enableLighting = true;
    viewer.scene.globe.depthTestAgainstTerrain = true;
    viewer.scene.fog.enabled = true;
    viewer.scene.fog.density = 0.0002;
    viewer.shadows = false;

    viewerRef.current = viewer;

    return () => {
      if (flyoverTimerRef.current) clearInterval(flyoverTimerRef.current);
      if (!viewer.isDestroyed()) viewer.destroy();
      viewerRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Helper: fly to track bounding sphere
  const flyToTrack = useCallback((positions: Cesium.Cartesian3[]) => {
    const viewer = viewerRef.current;
    if (!viewer || viewer.isDestroyed() || positions.length === 0) return;
    const sphere = Cesium.BoundingSphere.fromPoints(positions);
    viewer.camera.flyToBoundingSphere(sphere, {
      duration: 2,
      offset: new Cesium.HeadingPitchRange(0, OVERVIEW_PITCH, sphere.radius * 3.5),
    });
  }, []);

  // Expose recenter to parent
  const positionsRef = useRef<Cesium.Cartesian3[]>([]);
  useEffect(() => {
    if (onRecenterReady) {
      onRecenterReady(() => flyToTrack(positionsRef.current));
    }
  }, [onRecenterReady, flyToTrack]);

  // Draw track when it changes
  useEffect(() => {
    const viewer = viewerRef.current;
    if (!viewer || viewer.isDestroyed()) return;

    if (trackEntityRef.current) { viewer.entities.remove(trackEntityRef.current); trackEntityRef.current = null; }
    if (cursorEntityRef.current) { viewer.entities.remove(cursorEntityRef.current); cursorEntityRef.current = null; }

    if (!track) return;

    const positions = track.points.map((p) =>
      Cesium.Cartesian3.fromDegrees(p.lon, p.lat, p.ele + 5),
    );
    positionsRef.current = positions;

    trackEntityRef.current = viewer.entities.add({
      polyline: {
        positions,
        width: TRACK_WIDTH,
        material: new Cesium.PolylineGlowMaterialProperty({
          glowPower: 0.2,
          color: TRACK_COLOR,
        }),
        clampToGround: false,
      },
    });

    cursorEntityRef.current = viewer.entities.add({
      position: new Cesium.ConstantPositionProperty(
        Cesium.Cartesian3.fromDegrees(track.points[0].lon, track.points[0].lat, track.points[0].ele + 20),
      ),
      point: {
        pixelSize: 12,
        color: CURSOR_COLOR,
        outlineColor: Cesium.Color.BLACK,
        outlineWidth: 2,
        show: new Cesium.ConstantProperty(false),
      },
    });

    flyToTrack(positions);
  }, [track, flyToTrack]);

  // Update cursor on hover
  useEffect(() => {
    const viewer = viewerRef.current;
    const cursor = cursorEntityRef.current;
    if (!viewer || viewer.isDestroyed() || !cursor || !track) return;

    const show = cursor.point as Cesium.PointGraphics;
    if (hoveredIndex === null) {
      show.show = new Cesium.ConstantProperty(false);
      return;
    }
    const pt = track.points[hoveredIndex];
    if (!pt) return;
    cursor.position = new Cesium.ConstantPositionProperty(
      Cesium.Cartesian3.fromDegrees(pt.lon, pt.lat, pt.ele + 20),
    );
    show.show = new Cesium.ConstantProperty(true);
  }, [hoveredIndex, track]);

  // Fly camera to selected point (click on elevation profile)
  useEffect(() => {
    const viewer = viewerRef.current;
    if (!viewer || viewer.isDestroyed() || !track || selectedIndex === null) return;
    const pt = track.points[selectedIndex];
    viewer.camera.flyTo({
      destination: Cesium.Cartesian3.fromDegrees(pt.lon, pt.lat, pt.ele + 800),
      orientation: { heading: Cesium.Math.toRadians(0), pitch: OVERVIEW_PITCH, roll: 0 },
      duration: 1.5,
    });
  }, [selectedIndex, track]);

  // Flyover animation loop — runs inside setInterval, reads from refs to avoid stale closures
  const tickFlyover = useCallback(() => {
    const viewer = viewerRef.current;
    const t = trackRef.current;
    if (!viewer || viewer.isDestroyed() || !t) return;

    const next = flyoverIndexRef.current + flyoverSpeedRef.current;
    if (next >= t.points.length - 1) {
      setFlyoverPlaying(false);
      setFlyoverIndex(t.points.length - 1);
      return;
    }

    const pt = t.points[next];
    const lookAhead = Math.min(next + 5, t.points.length - 1);
    const ptNext = t.points[lookAhead];
    const head = bearing(pt.lat, pt.lon, ptNext.lat, ptNext.lon);

    viewer.camera.setView({
      destination: Cesium.Cartesian3.fromDegrees(pt.lon, pt.lat, pt.ele + CAMERA_HEIGHT_OFFSET),
      orientation: {
        heading: Cesium.Math.toRadians(head),
        pitch: Cesium.Math.toRadians(-15),
        roll: 0,
      },
    });

    flyoverIndexRef.current = next;
    setFlyoverIndex(next);
  }, [setFlyoverIndex, setFlyoverPlaying]);

  useEffect(() => {
    if (flyoverTimerRef.current) { clearInterval(flyoverTimerRef.current); flyoverTimerRef.current = null; }
    if (flyoverPlaying) {
      flyoverTimerRef.current = window.setInterval(tickFlyover, 80);
    }
    return () => { if (flyoverTimerRef.current) clearInterval(flyoverTimerRef.current); };
  }, [flyoverPlaying, tickFlyover]);

  // When flyover is paused and index is scrubbed manually, move camera
  useEffect(() => {
    const viewer = viewerRef.current;
    if (!viewer || viewer.isDestroyed() || !track || flyoverPlaying) return;
    const pt = track.points[flyoverIndex];
    if (!pt) return;
    const lookAhead = Math.min(flyoverIndex + 5, track.points.length - 1);
    const ptNext = track.points[lookAhead];
    const head = bearing(pt.lat, pt.lon, ptNext.lat, ptNext.lon);
    viewer.camera.flyTo({
      destination: Cesium.Cartesian3.fromDegrees(pt.lon, pt.lat, pt.ele + CAMERA_HEIGHT_OFFSET),
      orientation: { heading: Cesium.Math.toRadians(head), pitch: Cesium.Math.toRadians(-15), roll: 0 },
      duration: 0.4,
    });
  }, [flyoverIndex, track, flyoverPlaying]);

  return <div ref={containerRef} className="absolute inset-0" />;
}
