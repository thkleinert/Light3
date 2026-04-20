# Light3

Lightroom Classic publish plugin for S3-compatible storage.

Works with **Cloudflare R2**, **AWS S3**, **Backblaze B2**, **MinIO**, and any other S3-compatible endpoint.

---

## Overview

Light3 adds a **Publish Service** to Lightroom Classic. You organise photos into published collections; hitting **Publish** uploads them to your S3 bucket. Removing a photo from a collection deletes it from the bucket. Lightroom tracks which photos are up-to-date and only re-uploads changed ones.

### Architecture

Lightroom's scripting environment (Lua) has no native crypto, so AWS Signature V4 signing can't be done inside the plugin. Light3 solves this with a two-part design:

```
Lightroom (Lua plugin)
  │
  │  calls
  ▼
light3.lrplugin/light3-sign   ← signing helper bundled in the plugin
  │
  │  returns presigned URL (already signed, no auth headers needed)
  ▼
S3-compatible bucket          ← plain HTTP PUT via curl, no credentials in Lua
```

The signing helper runs locally — your credentials never leave your machine.

---

## Requirements

- **Lightroom Classic** 6 or later
- An S3-compatible bucket (Cloudflare R2, AWS S3, etc.)

---

## Installation

### 1. Download the plugin

Go to the [Releases page](https://github.com/thkleinert/Light3/releases) and download the latest `light3-vX.Y.Z.lrplugin.zip`. Unzip it — you'll get a `light3.lrplugin` folder with the signing helper already bundled inside.

### 2. Install the Lightroom plugin

Option A — copy to the standard plugins folder:

```bash
cp -r light3.lrplugin \
  ~/Library/Application\ Support/Adobe/Lightroom/Modules/
```

Option B — symlink (easier to update):

```bash
ln -s "$(pwd)/light3.lrplugin" \
  ~/Library/Application\ Support/Adobe/Lightroom/Modules/light3.lrplugin
```

Option C — add manually in Lightroom:
**File → Plug-in Manager → Add** → select the `light3.lrplugin` folder.

Restart Lightroom after installing.

---

## Setting up a Publish Service

1. Open the **Library** module.
2. In the **Publish Services** panel (left sidebar), find **Light3** and click **Set Up…**
3. Fill in the connection settings (see table below).
4. Click **Save**.

| Field | Description | Example |
|---|---|---|
| Endpoint URL | Base URL of your S3-compatible service | `https://abc123.r2.cloudflarestorage.com` |
| Bucket | Bucket name | `my-photos` |
| Region | AWS region or `auto` for R2 | `auto` |
| Access Key ID | S3 access key | `abc123def456` |
| Secret Access Key | S3 secret key | (hidden) |
| Key prefix | Optional path prefix inside the bucket | `galleries/` |
| File naming | Template for S3 filenames (see below) | `<sequence>_<collection>` |

---

## Publishing photos

### Collections and collection sets

Create collections and optionally group them in collection sets. Light3 mirrors the full hierarchy as S3 path segments:

```
<bucket>/<prefix>/<CollectionSet>/.../<Collection>/<filename>
```

For example, with prefix `galleries/`, collection set `Weddings`, and collection `Smith 2026`:

```
my-photos/galleries/Weddings/Smith_2026/00001_Smith_2026.jpg
```

### File naming

The **File naming** field in the service settings is a free-form template. Click the token buttons to insert:

| Token | Resolves to |
|---|---|
| `<file>` | Original filename without extension (default) |
| `<sequence>` | Zero-padded position in the publish run, e.g. `00001` |
| `<collection>` | Sanitised collection name |

Examples:
- `<file>` → `DSC_0042.jpg`
- `<sequence>_<collection>` → `00001_Smith_2026.jpg`
- `<sequence>_<file>` → `00001_DSC_0042.jpg`

The file extension is always appended automatically.

### Custom sort order

Photos within a collection can be reordered by drag-and-drop in Lightroom. Light3 respects this order — combined with the `<sequence>` token, the upload sequence matches your Lightroom ordering exactly.

### Re-publishing

Lightroom tracks which photos have been published. If you edit a photo and re-publish, only changed photos are re-uploaded.

### Removing photos

Removing a photo from a published collection and clicking **Publish** deletes the object from the bucket.

---

## Provider-specific setup

### Cloudflare R2

1. In the Cloudflare dashboard, go to **R2 → your bucket → Settings → S3 Auth**.
2. Create an **API token** with *Object Read & Write* permissions.
3. Note your **Account ID** (visible in the R2 overview page).

| Field | Value |
|---|---|
| Endpoint URL | `https://<account-id>.r2.cloudflarestorage.com` |
| Region | `auto` |
| Access Key ID | R2 token Access Key ID |
| Secret Access Key | R2 token Secret Access Key |

### AWS S3

1. Create an IAM user with an inline policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::your-bucket-name/*"
    }
  ]
}
```

2. Create access keys for that user.

| Field | Value |
|---|---|
| Endpoint URL | `https://s3.<region>.amazonaws.com` |
| Region | `us-east-1` (or your bucket's region) |
| Access Key ID | IAM access key |
| Secret Access Key | IAM secret key |

### Backblaze B2

1. In B2, create an **Application Key** with read/write access to your bucket.
2. Note the S3-compatible endpoint shown in the bucket details.

| Field | Value |
|---|---|
| Endpoint URL | `https://s3.<region>.backblazeb2.com` |
| Region | `us-west-004` (from bucket details) |
| Access Key ID | B2 Application Key ID |
| Secret Access Key | B2 Application Key |

---

## File structure

```
Light3/
├── light3.lrplugin/
│   ├── Info.lua                # Plugin manifest
│   ├── S3PublishSupport.lua    # Publish service UI and callbacks
│   ├── S3Upload.lua            # Upload/delete via presigned URLs + curl
│   ├── S3_small.png            # Plugin icon
│   └── light3-sign             # Signing helper binary (built locally or via CI, not in git)
├── signing-helper-go/
│   ├── main.go                 # Presigned URL generator (Go / aws-sdk-go-v2)
│   ├── build.sh                # Builds universal macOS binary and installs locally
│   ├── go.mod
│   └── go.sum
└── .github/workflows/
    ├── release-please.yml      # Automates Release PRs and versioning
    └── release.yml             # Builds binary + zips plugin on release
```

---

## Troubleshooting

**"Signing helper failed (exit …)"**
→ Make sure you downloaded the plugin from the [Releases page](https://github.com/thkleinert/Light3/releases) — the zip includes the pre-built `light3-sign` binary. If you cloned the repo directly, build the binary manually (see **Contributing** below).

**HTTP 403 on upload**
→ The presigned URL was generated but the bucket rejected it. Check:
- Credentials have write permission on the bucket
- Endpoint URL is correct (no trailing slash)
- For R2: the S3-compatible API is enabled on the bucket

**HTTP 404 on upload**
→ The bucket does not exist or the endpoint URL is wrong.

**Photos keep showing as "modified" after publish**
→ Lightroom tracks publish state via the S3 key. If the key prefix, collection name, or file naming template changes between publishes, Lightroom loses track of already-published photos. Avoid changing these settings after the first publish.

---

## Development

### Reloading the plugin in Lightroom

After editing `.lua` files:
**File → Plug-in Manager → select Light3 → Reload Plug-in**

No Lua build step is required.

### Building the signing helper locally

Requires Go 1.22+.

```bash
cd signing-helper-go
bash build.sh --install
```

This builds a universal macOS binary (`dist/light3-sign`) and copies it to both `light3.lrplugin/` and your Lightroom Modules directory. The binary is not checked into git — it is built by the release pipeline and bundled into the release zip automatically.

### Releases

Releases are automated via [release-please](https://github.com/googleapis/release-please). Use [conventional commits](https://www.conventionalcommits.org/) when merging to `main`:

| Prefix | Effect |
|---|---|
| `feat:` | minor version bump |
| `fix:` | patch version bump |
| `feat!:` / `BREAKING CHANGE:` | major version bump |
| `chore:`, `docs:`, `test:` | no version bump |

release-please opens a Release PR automatically. Merging it creates the tag and GitHub release. The release workflow then builds the universal binary and attaches `light3-vX.Y.Z.lrplugin.zip` to the release.

### Contributing

Pull requests welcome. Keep the signing helper dependency-light (only `aws-sdk-go-v2` packages) and the Lua code compatible with Lightroom Classic SDK 5+.
