# Porch: Automated CI/CD to TestFlight Setup Guide

This guide walks you through setting up a fully automated pipeline so that every code push to a designated branch builds your app and deploys it to TestFlight — no manual Xcode archiving required.

**Your project details (referenced throughout):**

| Detail | Value |
|---|---|
| Bundle ID | `steven.Porch` |
| Team ID | `77F3383U2A` |
| Scheme | `Porch` |
| Xcode version | 26.1.1 |
| iOS deployment target | 26.1 |
| GitHub repo | `stevenrichter16/Porch` |

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Apple Developer Account Setup](#2-apple-developer-account-setup)
3. [Create an App Store Connect API Key](#3-create-an-app-store-connect-api-key)
4. [Register Your App in App Store Connect](#4-register-your-app-in-app-store-connect)
5. [Install and Configure Fastlane](#5-install-and-configure-fastlane)
6. [Set Up Fastlane Match (Code Signing)](#6-set-up-fastlane-match-code-signing)
7. [Create the Fastlane Deploy Lane](#7-create-the-fastlane-deploy-lane)
8. [Test Locally (Optional but Recommended)](#8-test-locally-optional-but-recommended)
9. [Set Up GitHub Actions](#9-set-up-github-actions)
10. [Configure GitHub Secrets](#10-configure-github-secrets)
11. [TestFlight: Adding Yourself as a Tester](#11-testflight-adding-yourself-as-a-tester)
12. [Trigger Your First Automated Build](#12-trigger-your-first-automated-build)
13. [Installing the Build on Your Phone](#13-installing-the-build-on-your-phone)
14. [Speeding Up Iteration](#14-speeding-up-iteration)

---

## 1. Prerequisites

Before starting, make sure you have:

- [ ] An **Apple Developer Program** membership ($99/year) — you already have Team ID `77F3383U2A`, so this should be active
- [ ] **Xcode** installed on your Mac (for initial Fastlane Match setup)
- [ ] **Homebrew** installed (`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`)
- [ ] A **GitHub account** with your Porch repo (`stevenrichter16/Porch`)
- [ ] An **iPhone or iPad** with iOS 16+ for testing via TestFlight

---

## 2. Apple Developer Account Setup

If you haven't already, confirm your Apple Developer membership is active:

1. Go to [developer.apple.com](https://developer.apple.com)
2. Sign in with your Apple ID
3. Click **Account** → verify your membership status shows "Active"
4. Note your **Team ID** — yours is `77F3383U2A` (visible under Membership Details)

---

## 3. Create an App Store Connect API Key

This key lets CI systems authenticate with Apple without 2FA prompts. This is the single most important step for automation.

1. Go to [App Store Connect](https://appstoreconnect.apple.com)
2. Click **Users and Access** (top nav)
3. Click the **Integrations** tab, then **App Store Connect API**
4. Click **Generate API Key** (or the `+` button)
5. Name it something like `Porch CI`
6. Set the role to **App Manager** (needs permission to upload builds)
7. Click **Generate**

**After generating, you will see three values. Save all three — you can only download the key file once:**

| Value | Where to find it | Example |
|---|---|---|
| **Issuer ID** | Shown at the top of the API Keys page | `12345678-abcd-efgh-ijkl-123456789012` |
| **Key ID** | Shown in the key's row | `ABC1234DEF` |
| **Private Key (.p8 file)** | Click **Download** immediately | `AuthKey_ABC1234DEF.p8` |

Store the `.p8` file somewhere safe (e.g., `~/.appstoreconnect/private_keys/`). **You cannot re-download it.**

```bash
mkdir -p ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_ABC1234DEF.p8 ~/.appstoreconnect/private_keys/
```

---

## 4. Register Your App in App Store Connect

TestFlight requires your app to exist as an App Store Connect record.

1. Go to [App Store Connect](https://appstoreconnect.apple.com) → **Apps**
2. Click the `+` button → **New App**
3. Fill in:
   - **Platform:** iOS
   - **Name:** `Porch` (or whatever you want displayed)
   - **Primary Language:** English (U.S.)
   - **Bundle ID:** Select `steven.Porch` from the dropdown
     - If it doesn't appear, you need to register it first at [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) → click `+` → App IDs → enter `steven.Porch`
   - **SKU:** `porch-app` (any unique string, for your reference only)
   - **Access:** Full Access
4. Click **Create**

Your app now exists in App Store Connect and can receive TestFlight builds.

---

## 5. Install and Configure Fastlane

Fastlane automates building, signing, and uploading your app.

### Install Fastlane

```bash
# Install via Homebrew (recommended)
brew install fastlane

# Verify installation
fastlane --version
```

### Initialize Fastlane in your project

```bash
cd /path/to/Porch

# Create the fastlane directory and initial files
mkdir -p fastlane
```

Create the **Appfile** — this tells Fastlane about your app:

```bash
cat > fastlane/Appfile << 'EOF'
app_identifier("steven.Porch")
apple_id("YOUR_APPLE_ID_EMAIL@example.com")
team_id("77F3383U2A")
itc_team_id("77F3383U2A")
EOF
```

Replace `YOUR_APPLE_ID_EMAIL@example.com` with the Apple ID email tied to your developer account.

---

## 6. Set Up Fastlane Match (Code Signing)

Match stores your signing certificates and provisioning profiles in a private Git repo so CI can access them without manual intervention.

### Create a private repo for certificates

1. Go to GitHub → **New Repository**
2. Name it `porch-certificates` (or similar)
3. Make it **Private**
4. Don't initialize with README
5. Click **Create**

### Initialize Match

```bash
cd /path/to/Porch
fastlane match init
```

When prompted:
- **Storage mode:** Select `git`
- **URL of the Git repo:** `https://github.com/stevenrichter16/porch-certificates.git`

This creates `fastlane/Matchfile`.

### Generate certificates and profiles

```bash
# Generate App Store distribution certificate + profile
fastlane match appstore

# You'll be prompted for:
# - Passphrase: Choose something strong, save it (you'll need it for CI)
# - Apple ID credentials: Enter your Apple ID email and password
```

This creates:
- A distribution certificate in your Apple Developer account
- An App Store provisioning profile
- Both are encrypted and stored in your `porch-certificates` repo

**Save the Match passphrase** — you'll need it for GitHub Actions secrets.

---

## 7. Create the Fastlane Deploy Lane

Create the Fastfile that defines your build and deploy process:

```bash
cat > fastlane/Fastfile << 'FASTFILE'
default_platform(:ios)

platform :ios do

  desc "Build and upload to TestFlight"
  lane :beta do
    # Set up CI-specific keychain (only runs on CI)
    if is_ci
      setup_ci
    end

    # Load App Store Connect API key
    api_key = app_store_connect_api_key(
      key_id: ENV["ASC_KEY_ID"],
      issuer_id: ENV["ASC_ISSUER_ID"],
      key_content: ENV["ASC_KEY_CONTENT"],
      is_key_content_base64: true
    )

    # Fetch signing certificates and profiles
    match(
      type: "appstore",
      readonly: is_ci,
      api_key: api_key
    )

    # Increment build number (based on latest TestFlight build)
    increment_build_number(
      build_number: latest_testflight_build_number(api_key: api_key) + 1
    )

    # Build the app
    build_app(
      project: "Porch.xcodeproj",
      scheme: "Porch",
      export_method: "app-store",
      export_options: {
        provisioningProfiles: {
          "steven.Porch" => "match AppStore steven.Porch"
        }
      }
    )

    # Upload to TestFlight
    upload_to_testflight(
      api_key: api_key,
      skip_waiting_for_build_processing: true
    )
  end

end
FASTFILE
```

### Create a Gemfile for consistent Fastlane versions

```bash
cat > Gemfile << 'EOF'
source "https://rubygems.org"

gem "fastlane"
EOF

bundle install
```

---

## 8. Test Locally (Optional but Recommended)

Before setting up CI, verify the pipeline works on your Mac:

```bash
cd /path/to/Porch

# Set environment variables for the API key
export ASC_KEY_ID="your_key_id_here"
export ASC_ISSUER_ID="your_issuer_id_here"
export ASC_KEY_CONTENT=$(base64 < ~/.appstoreconnect/private_keys/AuthKey_YOUR_KEY_ID.p8)

# Run the beta lane
bundle exec fastlane beta
```

If successful, you'll see a build appear in App Store Connect → TestFlight within 10-30 minutes.

**Common issues at this stage:**

| Problem | Fix |
|---|---|
| "No matching provisioning profiles found" | Run `fastlane match appstore` again (without `readonly`) |
| "The bundle identifier does not match" | Check that `steven.Porch` matches what's in Xcode project settings |
| "Unable to upload: app not found" | Complete Step 4 (register app in App Store Connect) |
| "Code signing error" | Open Xcode → Porch target → Signing & Capabilities → make sure automatic signing is OFF and the Match profile is selected |

---

## 9. Set Up GitHub Actions

Create the workflow file that runs on every push:

```bash
mkdir -p .github/workflows
```

Create `.github/workflows/testflight.yml`:

```yaml
name: Deploy to TestFlight

on:
  push:
    branches:
      - main
      - 'release/*'
  workflow_dispatch:  # Allows manual triggering from GitHub UI

concurrency:
  group: testflight-${{ github.ref }}
  cancel-in-progress: true

jobs:
  deploy:
    runs-on: macos-15  # Required for Xcode 16+
    timeout-minutes: 30

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Select Xcode version
        run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

      - name: Install Ruby and Bundler
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.2'
          bundler-cache: true

      - name: Install Fastlane dependencies
        run: bundle install

      - name: Deploy to TestFlight
        env:
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          ASC_KEY_CONTENT: ${{ secrets.ASC_KEY_CONTENT }}
          MATCH_GIT_URL: ${{ secrets.MATCH_GIT_URL }}
          MATCH_PASSWORD: ${{ secrets.MATCH_PASSWORD }}
          MATCH_GIT_BASIC_AUTHORIZATION: ${{ secrets.MATCH_GIT_BASIC_AUTHORIZATION }}
        run: bundle exec fastlane beta

      - name: Upload build logs on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: build-logs
          path: |
            ~/Library/Logs/gym/*.log
            fastlane/report.xml
```

> **Note on Xcode version:** The `macos-15` runner comes with Xcode 16.x pre-installed. If your project requires Xcode 26.1.1 (as specified in your project), you may need to wait for GitHub to offer that runner, or use a self-hosted runner or Codemagic. For now, you may need to adjust your deployment target to what's available on CI.

---

## 10. Configure GitHub Secrets

Go to your GitHub repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**

Add each of these secrets:

| Secret Name | Value | How to get it |
|---|---|---|
| `ASC_KEY_ID` | Your API Key ID | From Step 3 (e.g., `ABC1234DEF`) |
| `ASC_ISSUER_ID` | Your Issuer ID | From Step 3 |
| `ASC_KEY_CONTENT` | Base64-encoded `.p8` key | Run: `base64 < ~/.appstoreconnect/private_keys/AuthKey_YOUR_KEY_ID.p8` |
| `MATCH_GIT_URL` | Your certificates repo URL | `https://github.com/stevenrichter16/porch-certificates.git` |
| `MATCH_PASSWORD` | The passphrase you chose in Step 6 | The passphrase from `fastlane match init` |
| `MATCH_GIT_BASIC_AUTHORIZATION` | Base64-encoded `username:PAT` | See below |

### Creating MATCH_GIT_BASIC_AUTHORIZATION

This lets Fastlane Match clone your private certificates repo on CI:

1. Go to GitHub → **Settings** → **Developer Settings** → **Personal Access Tokens** → **Fine-grained tokens**
2. Click **Generate new token**
3. Name: `Fastlane Match`
4. Repository access: Select **Only select repositories** → choose `porch-certificates`
5. Permissions: **Contents** → Read and write
6. Click **Generate token** and copy it

Then encode it:

```bash
echo -n "stevenrichter16:YOUR_GITHUB_PAT_HERE" | base64
```

Paste the output as the `MATCH_GIT_BASIC_AUTHORIZATION` secret.

---

## 11. TestFlight: Adding Yourself as a Tester

### What is TestFlight?

TestFlight is Apple's official beta testing platform. It lets you install pre-release builds of your app on real devices without going through App Store review (for internal testers).

### Internal vs External Testers

| | Internal Testers | External Testers |
|---|---|---|
| Who | People with App Store Connect roles on your team | Anyone with an email/invite link |
| Max | 100 | 10,000 |
| Review required? | **No** — builds available immediately | Yes (first build per version) |
| Setup | Just add them in App Store Connect | Requires a beta group + review |

**You want Internal Testing.** It skips review entirely.

### Add yourself as an internal tester

1. Go to [App Store Connect](https://appstoreconnect.apple.com) → **Apps** → **Porch**
2. Click the **TestFlight** tab
3. In the left sidebar, under **Internal Testing**, click `+` to create a group
4. Name it `Dev Team` (or whatever you want)
5. Click **Add Testers** → add your Apple ID email
6. **Enable "Automatic Distribution"** — this sends every new build to this group automatically

That's it. Every build that uploads successfully will automatically be available to you.

### Install TestFlight on your phone

1. Open the **App Store** on your iPhone
2. Search for **TestFlight**
3. Download and install it (it's free, made by Apple)
4. Open TestFlight — you'll see your apps here once a build is available

---

## 12. Trigger Your First Automated Build

Once everything above is configured:

```bash
cd /path/to/Porch

# Make sure you're on main (or your configured trigger branch)
git checkout main

# Make a small change (or just an empty commit to test)
git commit --allow-empty -m "ci: trigger first TestFlight build"

# Push
git push origin main
```

### Monitor the build

1. Go to GitHub → your repo → **Actions** tab
2. You should see the "Deploy to TestFlight" workflow running
3. Click into it to watch the live logs
4. The whole process takes ~10-20 minutes

### If it fails

Check the logs in the Actions tab. Common first-run issues:

| Error | Fix |
|---|---|
| "No signing certificate" | Re-run `fastlane match appstore` locally, push changes to certs repo |
| "Authentication failed" | Double-check `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT` secrets |
| "No provisioning profile" | Make sure the bundle ID in App Store Connect matches `steven.Porch` exactly |
| "Xcode not found" | The runner may not have your exact Xcode version; adjust the `xcode-select` step |

---

## 13. Installing the Build on Your Phone

Once the build uploads and Apple processes it (10-30 minutes after upload):

1. You'll get a **push notification** from TestFlight (if notifications are enabled)
2. Open the **TestFlight** app on your phone
3. You'll see **Porch** listed
4. Tap **Install** (first time) or **Update** (subsequent builds)
5. The app installs and you can launch it normally

### Enabling auto-updates (somewhat unreliable)

1. Open TestFlight
2. Tap on **Porch**
3. Toggle **Automatic Updates** on
4. Note: This only works reliably when your phone is on WiFi and charging

### Build expiration

TestFlight builds expire after **90 days**. After that, the app stops launching and you need a new build.

---

## 14. Speeding Up Iteration

The default pipeline (push → CI build → TestFlight processing → manual install) takes **30-60 minutes**. Here are ways to dramatically reduce that:

### Tier 1: Quick Wins (No Extra Cost)

#### A. Cache Swift Package Manager dependencies
Add this to your GitHub Actions workflow before the build step:

```yaml
- name: Cache SPM
  uses: actions/cache@v4
  with:
    path: |
      ~/Library/Developer/Xcode/DerivedData
      .build
    key: spm-${{ hashFiles('Porch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved') }}
```

**Saves: 2-5 minutes per build.**

#### B. Skip TestFlight processing wait
Already configured in the Fastfile above (`skip_waiting_for_build_processing: true`). Fastlane won't block waiting for Apple to process the build.

#### C. Use `workflow_dispatch` for on-demand builds
The workflow already includes this trigger. You can start builds from GitHub's Actions UI or via the GitHub CLI:

```bash
gh workflow run testflight.yml --ref main
```

### Tier 2: Faster Builds (~$15-50/month)

#### D. Self-hosted Mac Mini runner
Use your own Mac or a cloud Mac Mini as a GitHub Actions runner. Build times drop from ~15 minutes to ~3-5 minutes because there's no VM spin-up and dependencies are pre-cached.

**Setup:**
1. Buy/rent a Mac Mini M4 (or use your existing Mac)
2. GitHub repo → Settings → Actions → Runners → **New self-hosted runner**
3. Follow the setup instructions
4. Change `runs-on: macos-15` to `runs-on: self-hosted` in the workflow

**Cloud options:**
- [MacStadium](https://www.macstadium.com/) — from ~$50/month
- [Macly.io](https://macly.io/) — from $14.99/month for dedicated Mac Mini M4

#### E. Codemagic (API-triggered builds)
Codemagic provides Apple Silicon build machines with a simple REST API:

```bash
# Trigger a build programmatically
curl -X POST https://api.codemagic.io/builds \
  -H "Content-Type: application/json" \
  -H "x-auth-token: YOUR_CODEMAGIC_TOKEN" \
  -d '{
    "appId": "YOUR_APP_ID",
    "workflowId": "YOUR_WORKFLOW_ID",
    "branch": "main"
  }'
```

Pay-as-you-go at ~$0.04/minute. Builds run on M2/M4 Pro hardware. An LLM tool could call this API directly.

### Tier 3: Bypass TestFlight Entirely for Dev Builds

#### F. Direct device installation via Xcode (fastest possible)
If you're iterating rapidly and your Mac is nearby:

```bash
# Build and install directly to your connected iPhone
xcodebuild -project Porch.xcodeproj -scheme Porch \
  -destination 'platform=iOS,name=Your iPhone' \
  build install
```

**Time: ~1-3 minutes.** No TestFlight processing delay.

#### G. Use `ios-deploy` for wireless deployment
Install your app over WiFi to a connected device:

```bash
brew install ios-deploy

# Build the app
xcodebuild -project Porch.xcodeproj -scheme Porch \
  -sdk iphoneos -configuration Debug \
  -derivedDataPath build

# Deploy to device
ios-deploy --bundle build/Build/Products/Debug-iphoneos/Porch.app
```

#### H. SwiftUI Previews for UI iteration
For UI changes, SwiftUI Previews in Xcode give instant feedback without building or deploying. Not applicable for backend/networking changes, but covers a large portion of UI work.

### Tier 4: Architectural Changes for Faster Feedback Loops

#### I. Runtime log collector (enables targeted fixes)
Add a lightweight log drain to the app that sends structured events to a server. The LLM can read these logs to understand what's failing without waiting for you to report bugs.

```swift
// Example: POST structured logs to your server
func reportEvent(_ event: String, metadata: [String: String] = [:]) {
    var body = metadata
    body["event"] = event
    body["timestamp"] = ISO8601DateFormatter().string(from: Date())
    body["build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

    var request = URLRequest(url: URL(string: "https://your-server.com/logs")!)
    request.httpMethod = "POST"
    request.httpBody = try? JSONEncoder().encode(body)
    URLSession.shared.dataTask(with: request).resume()
}
```

The LLM reads logs → identifies issues → pushes fix → CI builds → you get the fix. Closes the feedback loop.

#### J. Feature flags for instant rollout control
Use a remote config service (Firebase Remote Config, or a simple JSON endpoint) to toggle features without rebuilding:

```swift
// Check a flag before showing a feature
if RemoteConfig.shared.isEnabled("new_chat_ui") {
    NewChatView()
} else {
    LegacyChatView()
}
```

The LLM can update flag values server-side. Changes take effect on next app launch — no build needed.

#### K. Server-driven UI for zero-build iteration
Move parts of the UI definition to your server. The app fetches a layout spec (JSON) and renders it dynamically. Changes to the server response instantly change the app. This is a significant architectural investment but eliminates the build cycle entirely for supported UI.

### Summary: Iteration Speed Comparison

| Method | Push-to-phone time | Cost |
|---|---|---|
| GitHub Actions → TestFlight | 30-60 min | Free (2000 min/mo) |
| Codemagic → TestFlight | 20-40 min | ~$0.04/min |
| Self-hosted runner → TestFlight | 15-35 min | $15-50/mo |
| Direct Xcode install (USB/WiFi) | 1-3 min | Free |
| Feature flags (no build needed) | Instant | Free-$25/mo |
| Server-driven UI (no build needed) | Instant | Hosting costs |

**Recommended starting point:** Set up the GitHub Actions pipeline first (Steps 1-13). Once it's working, add the runtime log collector (Tier 4-I) to close the feedback loop. Then consider self-hosted runners or Codemagic if build times become a bottleneck.
