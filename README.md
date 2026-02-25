# RestyHome

A lightweight macOS/iOS app that bridges Apple HomeKit to a local REST API. Run it on your Mac (via Catalyst) and control your HomeKit devices from any HTTP client -- `curl`, scripts, home automation tools, or AI assistants.

**Zero dependencies.** Built entirely with Apple frameworks (HomeKit, Network, SwiftUI).

## How It Works

RestyHome runs as a Mac Catalyst app that:

1. Connects to your HomeKit setup via `HMHomeManager`
2. Maintains an auto-updating cache of all homes, rooms, accessories, and scenes
3. Serves a local-only REST API on `localhost:18089`

GET endpoints return cached data instantly. POST endpoints (setting values, executing scenes) go to HomeKit live.

## Installation

Download the latest `.dmg` from [Releases](../../releases), open it, and drag **RestyHome** to your Applications folder.

On first launch, macOS will ask for HomeKit access -- grant it.

### Building from Source

Requires Xcode 15+ and macOS 14+.

```bash
git clone https://github.com/janthewes/resty-home.git
cd resty-home
xcodebuild -project RestyHome.xcodeproj \
  -scheme RestyHome \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -configuration Release \
  build
```

## REST API

All endpoints are served on `http://localhost:18089`. Responses are JSON with `Content-Type: application/json`.

### Health Check

```
GET /health
```

```json
{
  "status": "ok",
  "homes": 1,
  "total_accessories": 12,
  "cache_age_seconds": 3
}
```

### List Homes

```
GET /homes
```

### List Accessories

```
GET /homes/{homeId}/accessories
```

Returns cached summaries with current status (power state, brightness, temperature, etc.).

### Accessory Detail

```
GET /homes/{homeId}/accessories/{accessoryId}
```

Returns live, full detail including all services and characteristics with metadata (min/max values, units, read/write permissions).

### Set Characteristic

```
POST /homes/{homeId}/accessories/{accessoryId}/set
Content-Type: application/json

{
  "characteristic": "power state",
  "value": true
}
```

The `characteristic` field accepts:
- Human-readable aliases: `"power state"`, `"brightness"`, `"hue"`, `"color temperature"`, etc.
- HAP characteristic type UUIDs
- Localized descriptions from HomeKit

### List Rooms

```
GET /homes/{homeId}/rooms
```

### List Scenes

```
GET /homes/{homeId}/scenes
```

### Execute Scene

```
POST /homes/{homeId}/scenes/{sceneId}/execute
```

## Quick Example

```bash
# Check if RestyHome is running
curl http://localhost:18089/health

# List all homes
curl http://localhost:18089/homes

# Turn on a light
curl -X POST http://localhost:18089/homes/{homeId}/accessories/{id}/set \
  -H 'Content-Type: application/json' \
  -d '{"characteristic": "power state", "value": true}'

# Set brightness to 50%
curl -X POST http://localhost:18089/homes/{homeId}/accessories/{id}/set \
  -H 'Content-Type: application/json' \
  -d '{"characteristic": "brightness", "value": 50}'

# Execute a scene
curl -X POST http://localhost:18089/homes/{homeId}/scenes/{sceneId}/execute
```

## Requirements

- macOS 14.0+ (runs as Mac Catalyst)
- HomeKit-configured home (via the Apple Home app)
- Apple Developer account (for HomeKit entitlement when building from source)

## Release Process

Releases are automated via GitHub Actions. To create a new release:

1. Create a branch named `release_x.x.x` (e.g., `release_1.0.0`)
2. Push a tag named `release_x.x.x` on that branch
3. The CI pipeline will build, sign, notarize, and publish a GitHub Release with a downloadable `.dmg`

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

[MIT](LICENSE)
