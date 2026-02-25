# Contributing to RestyHome

## Development Setup

1. Clone the repository
2. Open `RestyHome.xcodeproj` in Xcode 15+
3. Select the "My Mac (Mac Catalyst)" destination
4. Build and run

HomeKit requires a real device with a configured home. The simulator has limited HomeKit support.

## Code Style

- Swift 5, SwiftUI for UI
- No external dependencies -- keep it that way
- All HomeKit data access goes through `HomeKitCache`
- HTTP endpoints are routed in `HTTPServer.swift`

## Release Process

Releases are fully automated via GitHub Actions. Here's how to cut a release:

### 1. Bump the version

Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project:
- `MARKETING_VERSION`: semver string (e.g., `1.2.0`)
- `CURRENT_PROJECT_VERSION`: integer build number (e.g., `3`)

### 2. Create a release branch and tag

```bash
git checkout -b release_1.2.0
git push -u origin release_1.2.0
git tag release_1.2.0
git push origin release_1.2.0
```

### 3. Automatic pipeline

When the `release_*` tag is pushed, GitHub Actions will:

1. Build the Mac Catalyst app (Release configuration)
2. Sign it with the Developer ID certificate from repository secrets
3. Submit to Apple's notarization service and staple the ticket
4. Package as a `.dmg`
5. Create a GitHub Release with the `.dmg` attached

### Required Repository Secrets

The following secrets must be configured in the GitHub repository settings under **Settings > Secrets and variables > Actions**:

| Secret | Description |
|--------|-------------|
| `APPLE_CERTIFICATE_P12` | Base64-encoded `.p12` file of your **Developer ID Application** certificate |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12` file |
| `APPLE_TEAM_ID` | Your Apple Developer Team ID (e.g., `6VYUYX4QC9`) |
| `APPLE_ID` | Your Apple ID email for notarization |
| `APPLE_ID_PASSWORD` | App-specific password for your Apple ID ([create one here](https://appleid.apple.com/account/manage)) |

### How to export the certificate

1. Open **Keychain Access** on your Mac
2. Find your **Developer ID Application** certificate
3. Right-click > Export Items > save as `.p12` with a password
4. Base64-encode it: `base64 -i certificate.p12 | pbcopy`
5. Paste the result as the `APPLE_CERTIFICATE_P12` secret

## Reporting Issues

Open an issue on GitHub with:
- macOS version
- Steps to reproduce
- Expected vs actual behavior
- Output from `curl http://localhost:18089/health` if the app is running
