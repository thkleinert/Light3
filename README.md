# Light3

Lightroom Classic publish plugin for S3-compatible storage — AWS S3, Cloudflare R2, Backblaze B2, MinIO, and any other S3-compatible endpoint.

## How it works

Light3 uses a two-part architecture to avoid implementing AWS Signature V4 in Lua (Lightroom's sandboxed scripting environment has no native crypto):

1. **`light3.lrplugin`** — the Lightroom plugin itself, written in Lua. Handles the publish UI, collection management, and file uploads via HTTP PUT.
2. **`signing-helper/`** — a small Node.js script (`sign.js`) that generates presigned S3 URLs. The plugin calls this helper for each upload/delete, then PUTs directly to the presigned URL (no auth headers needed).

## Setup

### 1. Install the signing helper

```bash
cd signing-helper
npm install
chmod +x sign.js
# Optional: make it globally accessible
npm link   # creates /usr/local/bin/light3-sign
```

Or build a standalone binary (no Node.js required at runtime):

```bash
npm run pkg
# produces dist/light3-sign  (Intel + Apple Silicon)
```

### 2. Install the Lightroom plugin

Copy (or symlink) the `light3.lrplugin` folder to your Lightroom plugins directory:

```
~/Library/Application Support/Adobe/Lightroom/Modules/light3.lrplugin
```

Or use **Lightroom → File → Plug-in Manager → Add** and point it at the folder.

### 3. Configure a publish service

In Lightroom's **Publish Services** panel (left side of Library module), click **Set Up…** next to **Light3 (S3)** and fill in:

| Field | Example |
|-------|---------|
| Endpoint URL | `https://<account>.r2.cloudflarestorage.com` |
| Bucket | `my-photos` |
| Region | `auto` (R2) or `us-east-1` (S3) |
| Access Key ID | your key |
| Secret Access Key | your secret |
| Key prefix | `galleries/` (optional path prefix inside the bucket) |
| Signing helper | `/usr/local/bin/light3-sign` (or path to `sign.js`) |

### 4. Publish

- Create a **published collection** inside the Light3 service
- Drag photos into it
- Click **Publish**

Each photo is uploaded to `<prefix><collection-name>/<filename>` in your bucket. Removed photos are deleted from the bucket.

## Cloudflare R2 notes

- Set **Region** to `auto`
- Enable **S3-compatible API** in your R2 bucket settings
- Create an **R2 API token** with Object Read & Write permissions
- Use the token's Access Key ID and Secret Access Key

## AWS S3 notes

- Set **Region** to your bucket's region (e.g. `us-east-1`)
- Create an IAM user with `s3:PutObject` and `s3:DeleteObject` permissions on the bucket

## Development

The plugin is pure Lua and requires no build step. Edit the `.lua` files and reload the plugin in Lightroom's Plug-in Manager.

The signing helper requires Node.js ≥ 18.
