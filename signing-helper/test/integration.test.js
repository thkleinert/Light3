/**
 * Integration test for sign.js — actually uploads and deletes a small object.
 *
 * Requires real credentials. Set these environment variables before running:
 *
 *   LIGHT3_ENDPOINT        e.g. https://abc123.r2.cloudflarestorage.com
 *   LIGHT3_BUCKET          e.g. my-photos
 *   LIGHT3_REGION          e.g. auto
 *   LIGHT3_ACCESS_KEY_ID
 *   LIGHT3_SECRET_KEY
 *
 * Run:
 *   LIGHT3_ENDPOINT=https://... LIGHT3_BUCKET=... npm run test:integration
 *
 * Skipped automatically when environment variables are not set.
 */

import { test, describe, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const SIGN_JS = join(__dirname, '..', 'sign.js')

const {
  LIGHT3_ENDPOINT: endpoint,
  LIGHT3_BUCKET: bucket,
  LIGHT3_REGION: region = 'auto',
  LIGHT3_ACCESS_KEY_ID: accessKeyId,
  LIGHT3_SECRET_KEY: secretAccessKey,
} = process.env

const credsAvailable = endpoint && bucket && accessKeyId && secretAccessKey

function runHelper(config) {
  return new Promise((resolve) => {
    const proc = spawn(process.execPath, [SIGN_JS], { stdio: ['pipe', 'pipe', 'pipe'] })
    let stdout = ''
    let stderr = ''
    proc.stdout.on('data', d => { stdout += d })
    proc.stderr.on('data', d => { stderr += d })
    proc.on('close', code => resolve({ stdout: stdout.trim(), stderr: stderr.trim(), code }))
    proc.stdin.write(JSON.stringify(config))
    proc.stdin.end()
  })
}

async function presignedPut(key) {
  const { stdout, code } = await runHelper({ endpoint, bucket, region, accessKeyId, secretAccessKey, key, method: 'PUT' })
  assert.equal(code, 0, `sign.js failed: ${stdout}`)
  return stdout
}

async function presignedDelete(key) {
  const { stdout, code } = await runHelper({ endpoint, bucket, region, accessKeyId, secretAccessKey, key, method: 'DELETE' })
  assert.equal(code, 0)
  return stdout
}

describe('integration — real S3 upload/delete', { skip: !credsAvailable && 'Set LIGHT3_* env vars to run integration tests' }, () => {
  const testKey = `light3-integration-test/${Date.now()}.txt`
  const testContent = 'Light3 integration test object'

  test('upload a small text object via presigned PUT URL', async () => {
    const url = await presignedPut(testKey)

    const resp = await fetch(url, {
      method: 'PUT',
      headers: { 'Content-Type': 'text/plain' },
      body: testContent,
    })

    assert.ok(
      resp.status === 200 || resp.status === 204,
      `Expected 200/204, got ${resp.status}: ${await resp.text()}`
    )
  })

  test('delete the uploaded object via presigned DELETE URL', async () => {
    const url = await presignedDelete(testKey)

    const resp = await fetch(url, { method: 'DELETE' })

    assert.ok(
      resp.status === 200 || resp.status === 204 || resp.status === 404,
      `Expected 200/204/404, got ${resp.status}: ${await resp.text()}`
    )
  })
})
