#!/usr/bin/env node
/**
 * light3-sign — signing helper for the Light3 Lightroom plugin
 *
 * Reads a JSON config from stdin, generates a presigned S3 URL, writes it to stdout.
 *
 * Input JSON fields:
 *   endpoint        - e.g. "https://<account>.r2.cloudflarestorage.com"
 *   bucket          - e.g. "my-photos"
 *   region          - e.g. "auto" (R2) or "us-east-1" (S3)
 *   accessKeyId     - S3 access key
 *   secretAccessKey - S3 secret key
 *   key             - object key, e.g. "galleries/family/photo.jpg"
 *   method          - "PUT" or "DELETE"
 *   expiresIn       - seconds until the presigned URL expires (default 3600)
 *
 * Requires: @aws-sdk/s3-request-presigner, @aws-sdk/client-s3
 * Install:  npm install  (in this directory)
 */

import { S3Client, PutObjectCommand, DeleteObjectCommand } from '@aws-sdk/client-s3'
import { getSignedUrl } from '@aws-sdk/s3-request-presigner'

async function main () {
  // Read stdin
  let input = ''
  for await (const chunk of process.stdin) {
    input += chunk
  }

  let config
  try {
    config = JSON.parse(input.trim())
  } catch (e) {
    process.stderr.write('light3-sign: invalid JSON input: ' + e.message + '\n')
    process.exit(1)
  }

  const {
    endpoint,
    bucket,
    region = 'auto',
    accessKeyId,
    secretAccessKey,
    key,
    method = 'PUT',
    expiresIn = 3600,
  } = config

  if (!endpoint || !bucket || !accessKeyId || !secretAccessKey || !key) {
    process.stderr.write('light3-sign: missing required fields (endpoint, bucket, accessKeyId, secretAccessKey, key)\n')
    process.exit(1)
  }

  const client = new S3Client({
    endpoint,
    region,
    credentials: { accessKeyId, secretAccessKey },
    // Required for path-style URLs (needed by R2 and most non-AWS S3)
    forcePathStyle: true,
  })

  let command
  if (method.toUpperCase() === 'DELETE') {
    command = new DeleteObjectCommand({ Bucket: bucket, Key: key })
  } else {
    command = new PutObjectCommand({ Bucket: bucket, Key: key })
  }

  let url
  try {
    url = await getSignedUrl(client, command, { expiresIn: Number(expiresIn) })
  } catch (e) {
    process.stderr.write('light3-sign: failed to generate presigned URL: ' + e.message + '\n')
    process.exit(1)
  }

  process.stdout.write(url + '\n')
}

main().catch(e => {
  process.stderr.write('light3-sign: unexpected error: ' + e.message + '\n')
  process.exit(1)
})
