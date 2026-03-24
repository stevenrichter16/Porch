# Porch: Automated CI/CD to TestFlight Setup Guide

This guide walks you through setting up a fully automated pipeline so that every code push to a designated branch builds your app on your MacBook Pro and deploys it to TestFlight — no manual Xcode archiving required.

Your MacBook Pro M5 (32GB RAM) serves as a self-hosted GitHub Actions runner. This is faster and cheaper than GitHub's hosted macOS runners, uses your exact Xcode version, and keeps dependency caches warm between builds.

**Your project details (referenced throughout):**

| Detail | Value |
|---|---|
| Bundle ID | `steven.Porch` |
| Team ID | `77F3383U2A` |
| Scheme | `Porch` |
| Xcode version | 26.1.1 |
| iOS deployment target | 26.1 |
| GitHub repo | `stevenrichter16/Porch` |
| Build machine | MacBook Pro M5 (32GB RAM) |

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
9. [Set Up Your MacBook as a Self-Hosted Runner](#9-set-up-your-macbook-as-a-self-hosted-runner)
10. [Set Up GitHub Actions Workflow](#10-set-up-github-actions-workflow)
11. [Configure GitHub Secrets](#11-configure-github-secrets)
12. [TestFlight: Adding Yourself as a Tester](#12-testflight-adding-yourself-as-a-tester)
13. [Trigger Your First Automated Build](#13-trigger-your-first-automated-build)
14. [Installing the Build on Your Phone](#14-installing-the-build-on-your-phone)
15. [Speeding Up Iteration](#15-speeding-up-iteration)

---

## 1. Prerequisites

Before starting, make sure you have:

- [ ] An **Apple Developer Program** membership ($99/year) — you already have Team ID `77F3383U2A`, so this should be active
- [ ] **Xcode 26.1.1** installed on your MacBook Pro M5
- [ ] **Homebrew** installed (`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`)
- [ ] A **GitHub account** with your Porch repo (`stevenrichter16/Porch`)
- [ ] An **iPhone or iPad** with iOS 16+ for testing via TestFlight
- [ ] Your **MacBook Pro M5** available to act as a build runner (must be awake and on network when builds trigger)

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

## 9. Set Up Your MacBook as a Self-Hosted Runner

Your MacBook Pro M5 will run builds locally whenever code is pushed. This is significantly faster than GitHub's hosted runners (~2-5 min builds vs ~15 min), uses your exact Xcode version, and costs nothing.

### 9a. Register the runner with GitHub

1. Go to your GitHub repo → **Settings** → **Actions** → **Runners**
2. Click **New self-hosted runner**
3. Select **macOS** and **ARM64**
4. GitHub will show you a set of commands. Run them in Terminal on your MacBook:

```bash
# Create a directory for the runner
mkdir -p ~/actions-runner && cd ~/actions-runner

# Download the runner (GitHub will show you the exact URL — use that one)
curl -o actions-runner-osx-arm64.tar.gz -L https://github.com/actions/runner/releases/download/v2.321.0/actions-runner-osx-arm64-2.321.0.tar.gz

# Extract
tar xzf actions-runner-osx-arm64.tar.gz

# Configure — GitHub will give you the exact token
./config.sh --url https://github.com/stevenrichter16/Porch --token YOUR_TOKEN_HERE
```

When prompted during configuration:
- **Runner group:** Press Enter for default
- **Runner name:** `macbook-m5` (or whatever you want)
- **Labels:** Press Enter for default (adds `self-hosted`, `macOS`, `ARM64`)
- **Work folder:** Press Enter for default (`_work`)

### 9b. Install as a background service (recommended)

This makes the runner start automatically on boot and survive terminal closures:

```bash
cd ~/actions-runner

# Install the service (requires admin password)
sudo ./svc.sh install

# Start the service
sudo ./svc.sh start

# Check status
sudo ./svc.sh status
```

The runner is now running as a launch daemon. It will start automatically when your Mac boots.

**To manage the service later:**

```bash
cd ~/actions-runner
sudo ./svc.sh stop     # Stop the runner
sudo ./svc.sh start    # Start the runner
sudo ./svc.sh status   # Check if running
sudo ./svc.sh uninstall # Remove the service
```

### 9c. Prevent your Mac from sleeping during builds

By default, macOS sleeps after a period of inactivity, which will cause queued builds to stall.

```bash
# Prevent sleep when connected to power (recommended)
sudo pmset -c sleep 0 disksleep 0

# Verify the setting
pmset -g | grep sleep
```

> **If you don't want to disable sleep entirely:** You can skip this and just make sure your Mac is awake when you push code. Builds will queue and run when the Mac wakes up.

### 9d. Verify the runner is connected

1. Go to GitHub repo → **Settings** → **Actions** → **Runners**
2. You should see `macbook-m5` with a green **Idle** status
3. If it shows **Offline**, check that the service is running (`sudo ./svc.sh status`)

---

## 10. Set Up GitHub Actions Workflow

Now create the workflow file that triggers builds on your self-hosted runner.

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
  workflow_dispatch:  # Allows manual triggering from GitHub UI or CLI

concurrency:
  group: testflight-${{ github.ref }}
  cancel-in-progress: true

jobs:
  deploy:
    runs-on: self-hosted  # Runs on your MacBook Pro M5
    timeout-minutes: 30

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Select Xcode version
        run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

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
```

**Why this is simpler than hosted runners:**
- No `ruby/setup-ruby` step needed — your Mac already has Ruby via Homebrew
- No SPM cache step needed — your Mac keeps `DerivedData` warm between builds
- Your exact Xcode version is used (no version mismatch issues)
- Builds take ~2-5 minutes instead of ~15 minutes

---

## 11. Configure GitHub Secrets

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

> **Self-hosted runner note:** GitHub Actions secrets are passed as environment variables to your MacBook during the build. They are not stored on disk permanently, but they do exist in memory during the build. Since this is your personal machine running a private repo, this is fine. If you ever make the repo public, be aware that anyone who submits a PR could potentially run code on your MacBook — keep the repo private.

---

## 12. TestFlight: Adding Yourself as a Tester

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

## 13. Trigger Your First Automated Build

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
4. On your self-hosted MacBook runner, the build should complete in ~2-5 minutes
5. You can also monitor locally — the runner logs to `~/actions-runner/_diag/`

### If it fails

Check the logs in the Actions tab. Common first-run issues:

| Error | Fix |
|---|---|
| "No signing certificate" | Re-run `fastlane match appstore` locally, push changes to certs repo |
| "Authentication failed" | Double-check `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT` secrets |
| "No provisioning profile" | Make sure the bundle ID in App Store Connect matches `steven.Porch` exactly |
| "Xcode not found" | Run `xcode-select -p` on your MacBook to verify the Xcode path |
| Job stays "Queued" | Your MacBook may be asleep or the runner service isn't running — check `sudo ./svc.sh status` in `~/actions-runner` |
| "Runner is offline" | Restart the service: `cd ~/actions-runner && sudo ./svc.sh stop && sudo ./svc.sh start` |

---

## 14. Installing the Build on Your Phone

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

## 15. Speeding Up Iteration

With your MacBook Pro M5 as a self-hosted runner, the build step is already fast (~2-5 minutes). The main bottleneck is now **TestFlight processing** (~10-30 minutes). Here's how to reduce total cycle time further:

### Tier 1: Quick Wins (Already Configured)

#### A. Self-hosted runner with warm caches
Already done — your MacBook keeps `DerivedData` and SPM packages cached between builds. No cold start penalty.

#### B. Skip TestFlight processing wait
Already configured in the Fastfile (`skip_waiting_for_build_processing: true`). The build step finishes as soon as the upload completes.

#### C. Use `workflow_dispatch` for on-demand builds
The workflow already includes this trigger. You can start builds from GitHub's Actions UI or via the GitHub CLI:

```bash
gh workflow run testflight.yml --ref main
```

### Tier 2: Bypass TestFlight Entirely for Dev Builds

#### D. Direct device installation via Xcode (fastest possible)
If you're iterating rapidly and your Mac is nearby:

```bash
# Build and install directly to your connected iPhone
xcodebuild -project Porch.xcodeproj -scheme Porch \
  -destination 'platform=iOS,name=Your iPhone' \
  build install
```

**Time: ~1-3 minutes.** No TestFlight processing delay.

#### E. Use `ios-deploy` for wireless deployment
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

#### F. SwiftUI Previews for UI iteration
For UI changes, SwiftUI Previews in Xcode give instant feedback without building or deploying. Not applicable for backend/networking changes, but covers a large portion of UI work.

### Tier 3: Architectural Changes for Faster Feedback Loops

#### G. Runtime log collector (enables targeted fixes)
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

#### H. Feature flags for instant rollout control
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

#### I. Server-driven UI for zero-build iteration
Move parts of the UI definition to your server. The app fetches a layout spec (JSON) and renders it dynamically. Changes to the server response instantly change the app. This is a significant architectural investment but eliminates the build cycle entirely for supported UI.

### Summary: Iteration Speed Comparison

| Method | Push-to-phone time | Cost |
|---|---|---|
| **MacBook runner → TestFlight (your setup)** | **15-35 min** | **Free** |
| Direct Xcode install (USB/WiFi) | 1-3 min | Free |
| Feature flags (no build needed) | Instant | Free-$25/mo |
| Server-driven UI (no build needed) | Instant | Hosting costs |

> The 15-35 min is dominated by TestFlight processing (~10-30 min), not the build itself (~2-5 min). There's no way to speed up Apple's processing time. The Tier 2 options (direct device install) bypass it entirely.

**Recommended progression:**
1. Get the full pipeline working first (Steps 1-14)
2. Add the runtime log collector (Tier 3-G) to close the feedback loop
3. For rapid dev iteration, use direct Xcode install (Tier 2-D) alongside the TestFlight pipeline
