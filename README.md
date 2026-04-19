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
signing-helper/sign.js   ← Node.js script on your Mac
  │
  │  returns presigned URL (already signed, no auth headers needed)
  ▼
S3-compatible bucket     ← plain HTTP PUT, no credentials in Lua
```

The signing helper runs locally — your credentials never leave your machine.

---

## Requirements

- **Lightroom Classic** 6 or later
- **Node.js** 18 or later (for the signing helper)
- An S3-compatible bucket (Cloudflare R2, AWS S3, etc.)

---

## Installation

### 1. Clone the repo

```bash
git clone https://github.com/thkleinert/Light3.git
cd Light3
```

### 2. Install the signing helper

```bash
cd signing-helper
npm install
```

Make the script executable and optionally link it globally:

```bash
chmod +x sign.js
npm link          # creates /usr/local/bin/light3-sign
```

Verify it works:

```bash
echo '{"endpoint":"https://example.com","bucket":"test","region":"auto","accessKeyId":"key","secretAccessKey":"secret","key":"photo.jpg","method":"PUT"}' \
  | node sign.js
# → prints a presigned URL
```

### 3. Install the Lightroom plugin

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
2. In the **Publish Services** panel (left sidebar), find **Light3 (S3)** and click **Set Up…**
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
| Signing helper | Full path to `light3-sign` or `sign.js` | `/usr/local/bin/light3-sign` |

---

## Publishing photos

1. In the Publish Services panel, right-click your Light3 service → **Create Published Collection**.
2. Name the collection (e.g. `Familie Maier 2026`). This name becomes a path segment in the bucket.
3. Drag photos into the collection.
4. Click **Publish**.

Photos are uploaded to:
```
<bucket>/<prefix><collection-name>/<filename>
```

For example, with prefix `galleries/` and collection `Familie Maier 2026`:
```
my-photos/galleries/Familie_Maier_2026/IMG_1234.jpg
```

(Spaces and special characters in collection names are replaced with `_`.)

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

Settings:

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

Settings:

| Field | Value |
|---|---|
| Endpoint URL | `https://s3.<region>.amazonaws.com` |
| Region | `us-east-1` (or your bucket's region) |
| Access Key ID | IAM access key |
| Secret Access Key | IAM secret key |

### Backblaze B2

1. In B2, create an **Application Key** with read/write access to your bucket.
2. Note the S3-compatible endpoint shown in the bucket details.

Settings:

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
│   └── S3Upload.lua            # Upload/delete via presigned URLs
└── signing-helper/
    ├── sign.js                 # Presigned URL generator
    ├── package.json
    └── test/
        ├── sign.test.js        # Unit tests for sign.js
        └── integration.test.js # Integration test (needs real credentials)
```

---

## Troubleshooting

**"No signing helper configured"**
→ Set the **Signing helper** field in the publish service settings to the full path of `light3-sign` (or `node /path/to/sign.js`).

**"Signing helper failed (exit 1)"**
→ Run the helper manually to see the error:
```bash
echo '{"endpoint":"...","bucket":"...","region":"auto","accessKeyId":"...","secretAccessKey":"...","key":"test.jpg","method":"PUT"}' \
  | /usr/local/bin/light3-sign
```

**HTTP 403 on upload**
→ The presigned URL was generated successfully but the bucket rejected the request. Check:
- Credentials have write permission on the bucket
- The endpoint URL is correct (no trailing slash)
- For R2: the S3-compatible API is enabled on the bucket

**HTTP 404 on upload**
→ The bucket does not exist or the endpoint is wrong.

**Photos keep showing as "modified" after publish**
→ Lightroom uses the returned `photoId` to track publish state. This is the S3 key. If the key prefix or collection name changes between publishes, Lightroom loses track. Avoid renaming collections after the first publish.

---

## Development

### Running tests

```bash
cd signing-helper
npm test
```

### Reloading the plugin in Lightroom

After editing `.lua` files:
**File → Plug-in Manager → select Light3 → Reload Plug-in**

No build step is required.

### Contributing

Pull requests welcome. Keep the signing helper dependency-light (only `@aws-sdk` packages) and the Lua code compatible with Lightroom Classic SDK 6+.
