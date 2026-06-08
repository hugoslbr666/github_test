# TrailViz

3D GPX race preparation tool for trail & ultra-trail runners. Drag your GPX, explore the terrain in 3D, fly over the course.

## Quick Start

**Prerequisites:** Node.js 18+ — install from [nodejs.org](https://nodejs.org)

```bash
cd trail-viz

# 1. Install dependencies
npm install

# 2. (Optional) Add your Cesium Ion token for photorealistic terrain
cp .env.example .env
# Edit .env → paste your token from https://cesium.com/ion/tokens (free account)

# 3. Start dev server
npm run dev
```

Open http://localhost:5173, drop your `.gpx` file, and go.

## Features

| Feature | Description |
|---|---|
| GPX import | Drag & drop or file picker. Handles 100 km+ tracks. |
| 3D terrain | CesiumJS + Cesium World Terrain (photorealistic) |
| Elevation profile | Interactive Recharts area chart, hover syncs map cursor |
| Click to fly | Click anywhere on the profile → camera flies to that point |
| Flyover mode | Camera follows the track at 1×/2×/4×/8× speed |
| Stats panel | Distance, D+, D−, elevation range, max/avg grade |
| Satellite imagery | Bing Maps Aerial (with token) or OSM fallback |

## Cesium Ion Token

Without a token the app uses OpenStreetMap tiles + flat terrain. With a free token:
- Photorealistic 3D terrain (Cesium World Terrain)
- Bing Maps Aerial imagery

Get one free at https://cesium.com/ion/tokens → click **⚙ Token** in the toolbar to enter it.

## Architecture

```
src/
├── features/
│   ├── gpx/          # Parser + drop zone
│   ├── terrain/      # CesiumJS viewer
│   ├── elevation/    # Recharts profile
│   └── flyover/      # Camera animation controls
├── components/
│   ├── Stats/        # TrailStats panel
│   ├── Layout/       # Toolbar
│   └── UI/           # TokenModal
├── stores/           # Zustand global state
├── lib/              # Haversine, utils
└── types/            # TypeScript interfaces
```

## Build for production

```bash
npm run build
npm run preview
```

## Roadmap (architecture already primed)

- [ ] Climb / descent auto-detection with difficulty rating
- [ ] Estimated split times (Itra coefficient)
- [ ] Km-effort calculator
- [ ] Aid station markers from GPX waypoints
- [ ] Multi-GPX comparison overlay
- [ ] Slope gradient coloring on the 3D track
- [ ] Flyover video export (MediaRecorder)
- [ ] Auto-generated roadbook PDF
