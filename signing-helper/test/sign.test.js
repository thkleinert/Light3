/**
 * Unit tests for sign.js
 *
 * Tests the presigned URL generation logic without hitting a real bucket.
 * Uses Node's built-in test runner (node:test) — no extra deps needed.
 *
 * Run: npm test
 */

import { test, describe, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const SIGN_JS = join(__dirname, '..', 'sign.js')

// ---------------------------------------------------------------------------
// Helper: run sign.js with a given JSON config, returns { stdout, stderr, code }
// ---------------------------------------------------------------------------

function runHelper(config) {
  return new Promise((resolve) => {
    const proc = spawn(process.execPath, [SIGN_JS], {
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    let stdout = ''
    let stderr = ''
    proc.stdout.on('data', d => { stdout += d })
    proc.stderr.on('data', d => { stderr += d })
    proc.on('close', code => resolve({ stdout: stdout.trim(), stderr: stderr.trim(), code }))
    proc.stdin.write(JSON.stringify(config))
    proc.stdin.end()
  })
}

// Minimal valid config for tests (fake credentials — presigning doesn't validate creds)
const BASE_CONFIG = {
  endpoint: 'https://example.r2.cloudflarestorage.com',
  bucket: 'test-bucket',
  region: 'auto',
  accessKeyId: 'test-access-key-id',
  secretAccessKey: 'test-secret-access-key',
  key: 'galleries/test/photo.jpg',
  method: 'PUT',
  expiresIn: 3600,
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('sign.js — happy path', () => {
  test('generates a URL for a PUT request', async () => {
    const { stdout, code } = await runHelper(BASE_CONFIG)
    assert.equal(code, 0, 'should exit 0')
    assert.match(stdout, /^https?:\/\//, 'should output a URL')
  })

  test('generated URL contains the bucket name', async () => {
    const { stdout, code } = await runHelper(BASE_CONFIG)
    assert.equal(code, 0)
    assert.ok(
      stdout.includes('test-bucket'),
      `URL should contain bucket name, got: ${stdout}`
    )
  })

  test('generated URL contains the object key', async () => {
    const { stdout, code } = await runHelper(BASE_CONFIG)
    assert.equal(code, 0)
    // Key may be URL-encoded
    assert.ok(
      stdout.includes('galleries') && stdout.includes('photo.jpg'),
      `URL should contain key segments, got: ${stdout}`
    )
  })

  test('generated URL contains X-Amz-Signature (SigV4)', async () => {
    const { stdout, code } = await runHelper(BASE_CONFIG)
    assert.equal(code, 0)
    assert.ok(
      stdout.includes('X-Amz-Signature') || stdout.includes('x-amz-signature'),
      `URL should contain SigV4 signature param, got: ${stdout}`
    )
  })

  test('generates a URL for a DELETE request', async () => {
    const config = { ...BASE_CONFIG, method: 'DELETE' }
    const { stdout, code } = await runHelper(config)
    assert.equal(code, 0)
    assert.match(stdout, /^https?:\/\//)
  })

  test('defaults method to PUT when omitted', async () => {
    const { method: _, ...config } = BASE_CONFIG
    const { stdout, code } = await runHelper(config)
    assert.equal(code, 0)
    assert.match(stdout, /^https?:\/\//)
  })

  test('defaults expiresIn when omitted', async () => {
    const { expiresIn: _, ...config } = BASE_CONFIG
    const { stdout, code } = await runHelper(config)
    assert.equal(code, 0)
    assert.match(stdout, /^https?:\/\//)
  })

  test('URL contains X-Amz-Expires reflecting expiresIn', async () => {
    const config = { ...BASE_CONFIG, expiresIn: 7200 }
    const { stdout, code } = await runHelper(config)
    assert.equal(code, 0)
    assert.ok(
      stdout.includes('X-Amz-Expires=7200') || stdout.includes('x-amz-expires=7200'),
      `URL should contain X-Amz-Expires=7200, got: ${stdout}`
    )
  })

  test('outputs exactly one line (the URL)', async () => {
    const { stdout, code } = await runHelper(BASE_CONFIG)
    assert.equal(code, 0)
    // stdout is already trimmed; should have no internal newlines
    assert.ok(!stdout.includes('\n'), 'should be a single line')
  })
})

describe('sign.js — input validation', () => {
  test('exits non-zero when endpoint is missing', async () => {
    const { endpoint: _, ...config } = BASE_CONFIG
    const { code, stderr } = await runHelper(config)
    assert.notEqual(code, 0, 'should fail')
    assert.ok(stderr.length > 0, 'should write error to stderr')
  })

  test('exits non-zero when bucket is missing', async () => {
    const { bucket: _, ...config } = BASE_CONFIG
    const { code, stderr } = await runHelper(config)
    assert.notEqual(code, 0)
    assert.ok(stderr.length > 0)
  })

  test('exits non-zero when accessKeyId is missing', async () => {
    const { accessKeyId: _, ...config } = BASE_CONFIG
    const { code, stderr } = await runHelper(config)
    assert.notEqual(code, 0)
    assert.ok(stderr.length > 0)
  })

  test('exits non-zero when secretAccessKey is missing', async () => {
    const { secretAccessKey: _, ...config } = BASE_CONFIG
    const { code, stderr } = await runHelper(config)
    assert.notEqual(code, 0)
    assert.ok(stderr.length > 0)
  })

  test('exits non-zero when key is missing', async () => {
    const { key: _, ...config } = BASE_CONFIG
    const { code, stderr } = await runHelper(config)
    assert.notEqual(code, 0)
    assert.ok(stderr.length > 0)
  })

  test('exits non-zero on invalid JSON input', async () => {
    const proc = spawn(process.execPath, [SIGN_JS], {
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    let code = null
    let stderr = ''
    proc.stderr.on('data', d => { stderr += d })
    await new Promise(resolve => {
      proc.on('close', c => { code = c; resolve() })
      proc.stdin.write('not valid json{{{')
      proc.stdin.end()
    })
    assert.notEqual(code, 0)
    assert.ok(stderr.includes('invalid JSON'), `expected "invalid JSON" in stderr, got: ${stderr}`)
  })

  test('exits non-zero on empty input', async () => {
    const proc = spawn(process.execPath, [SIGN_JS], {
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    let code = null
    await new Promise(resolve => {
      proc.on('close', c => { code = c; resolve() })
      proc.stdin.end()
    })
    assert.notEqual(code, 0)
  })
})

describe('sign.js — URL structure', () => {
  test('URL starts with the configured endpoint', async () => {
    const { stdout, code } = await runHelper(BASE_CONFIG)
    assert.equal(code, 0)
    assert.ok(
      stdout.startsWith(BASE_CONFIG.endpoint),
      `URL should start with endpoint, got: ${stdout}`
    )
  })

  test('different keys produce different URLs', async () => {
    const [r1, r2] = await Promise.all([
      runHelper({ ...BASE_CONFIG, key: 'album1/a.jpg' }),
      runHelper({ ...BASE_CONFIG, key: 'album2/b.jpg' }),
    ])
    assert.equal(r1.code, 0)
    assert.equal(r2.code, 0)
    assert.notEqual(r1.stdout, r2.stdout)
  })

  test('PUT and DELETE produce different URLs for the same key', async () => {
    const [r1, r2] = await Promise.all([
      runHelper({ ...BASE_CONFIG, method: 'PUT' }),
      runHelper({ ...BASE_CONFIG, method: 'DELETE' }),
    ])
    assert.equal(r1.code, 0)
    assert.equal(r2.code, 0)
    assert.notEqual(r1.stdout, r2.stdout)
  })
})
