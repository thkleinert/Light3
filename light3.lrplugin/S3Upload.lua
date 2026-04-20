--[[----------------------------------------------------------------------------
S3Upload.lua
Handles uploading and deleting objects in S3-compatible storage.

Strategy: delegate AWS Signature V4 signing to an external helper binary
(signing-helper/light3-sign) which returns a presigned URL. The plugin then
does a plain HTTP PUT/DELETE to that URL via curl — no crypto needed in Lua.
------------------------------------------------------------------------------]]

local LrFileUtils = import 'LrFileUtils'
local LrTasks     = import 'LrTasks'

local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function readFile(path)
  local f = io.open(path, 'r')
  if not f then return '' end
  local s = f:read('*all') or ''
  f:close()
  return s
end

local function tmpPath(tag)
  return string.format('/tmp/light3_%s_%d.txt', tag, os.time())
end

-- Call the signing helper to get a presigned URL.
-- Returns: url (string) or nil, errorMessage (string)
local function getPresignedUrl(params, method)
  local helperPath = params.signingHelperPath or ''
  if helperPath == '' then
    return nil, 'No signing helper path configured.'
  end

  local config = string.format(
    '{"endpoint":"%s","bucket":"%s","region":"%s","accessKeyId":"%s","secretAccessKey":"%s","key":"%s","method":"%s","expiresIn":3600}',
    params.endpoint,
    params.bucket,
    params.region or 'auto',
    params.accessKeyId,
    params.secretAccessKey,
    params.key,
    method or 'PUT'
  )
  config = config:gsub("'", "'\\''")  -- escape single quotes for shell

  local out    = tmpPath('url')
  local cmd    = string.format("echo '%s' | '%s' > '%s' 2>&1", config, helperPath, out)
  local code   = LrTasks.execute(cmd)

  local url = readFile(out)
  LrFileUtils.delete(out)

  if code ~= 0 then
    return nil, string.format('Signing helper failed (exit %d): %s', code, url:sub(1, 200))
  end

  url = url:match('^%s*(.-)%s*$')
  if not url or url == '' then
    return nil, 'Signing helper returned an empty URL'
  end

  return url, nil
end

-- Run a curl command, return (httpStatus, responseBody)
local function curlRequest(curlArgs)
  local statusFile = tmpPath('status')
  local bodyFile   = tmpPath('body')

  -- -o  → response body to bodyFile
  -- -w  → write only the status code to stdout → redirected to statusFile
  local cmd = string.format(
    "curl -s -o '%s' -w '%%{http_code}' %s > '%s' 2>&1",
    bodyFile, curlArgs, statusFile
  )
  LrTasks.execute(cmd)

  local status = tonumber(readFile(statusFile))
  local body   = readFile(bodyFile)
  LrFileUtils.delete(statusFile)
  LrFileUtils.delete(bodyFile)

  return status, body
end

-- ---------------------------------------------------------------------------
-- MIME type lookup
-- ---------------------------------------------------------------------------

local mimeTypes = {
  jpg  = 'image/jpeg',
  jpeg = 'image/jpeg',
  tif  = 'image/tiff',
  tiff = 'image/tiff',
  png  = 'image/png',
  dng  = 'image/x-adobe-dng',
  mp4  = 'video/mp4',
  mov  = 'video/quicktime',
}

-- ---------------------------------------------------------------------------
-- Public: upload a file to S3
-- params: localPath, key, endpoint, bucket, region,
--         accessKeyId, secretAccessKey, signingHelperPath
-- Returns: true  or  false, errorMessage
-- ---------------------------------------------------------------------------

function M.upload(params)
  local presignedUrl, err = getPresignedUrl(params, 'PUT')
  if not presignedUrl then return false, err end

  local ext         = (params.localPath:match('%.([^%.]+)$') or ''):lower()
  local contentType = mimeTypes[ext] or 'application/octet-stream'

  -- curl -T uploads the file as the request body (streaming, no RAM spike)
  local args = string.format(
    "-X PUT -H 'Content-Type: %s' -T '%s' '%s'",
    contentType, params.localPath, presignedUrl
  )
  local status, body = curlRequest(args)

  if status == 200 or status == 204 then
    return true
  else
    return false, string.format('S3 PUT failed (HTTP %s): %s',
      tostring(status), body:sub(1, 200))
  end
end

-- ---------------------------------------------------------------------------
-- Public: download an object from S3 and return its contents as a string
-- params: key, endpoint, bucket, region,
--         accessKeyId, secretAccessKey, signingHelperPath
-- Returns: content (string) or nil on error
-- ---------------------------------------------------------------------------

function M.getContent(params)
  local presignedUrl = getPresignedUrl(params, 'GET')
  if not presignedUrl then return nil end

  local statusFile = tmpPath('getstatus')
  local bodyFile   = tmpPath('get')
  local cmd = string.format(
    "curl -s -o '%s' -w '%%{http_code}' '%s' > '%s' 2>&1",
    bodyFile, presignedUrl, statusFile
  )
  LrTasks.execute(cmd)
  local status = tonumber(readFile(statusFile))
  local body   = readFile(bodyFile)
  LrFileUtils.delete(statusFile)
  LrFileUtils.delete(bodyFile)

  if status == 200 then
    return body
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Public: upload a string as a file to S3
-- params: content, key, endpoint, bucket, region,
--         accessKeyId, secretAccessKey, signingHelperPath
-- Returns: true  or  false, errorMessage
-- ---------------------------------------------------------------------------

function M.putContent(params)
  local tmpFile = tmpPath('content')
  local f = io.open(tmpFile, 'w')
  if not f then return false, 'Could not write temp file for putContent' end
  f:write(params.content or '')
  f:close()

  local presignedUrl, err = getPresignedUrl(params, 'PUT')
  if not presignedUrl then
    LrFileUtils.delete(tmpFile)
    return false, err
  end

  local args = string.format(
    "-X PUT -H 'Content-Type: application/json' -T '%s' '%s'",
    tmpFile, presignedUrl
  )
  local status, body = curlRequest(args)
  LrFileUtils.delete(tmpFile)

  if status == 200 or status == 204 then
    return true
  else
    return false, string.format('S3 PUT failed (HTTP %s): %s',
      tostring(status), body:sub(1, 200))
  end
end

-- ---------------------------------------------------------------------------
-- Public: delete an object from S3
-- params: key, endpoint, bucket, region,
--         accessKeyId, secretAccessKey, signingHelperPath
-- Returns: true  or  false, errorMessage
-- ---------------------------------------------------------------------------

function M.delete(params)
  local presignedUrl, err = getPresignedUrl(params, 'DELETE')
  if not presignedUrl then return false, err end

  local args   = string.format("-X DELETE '%s'", presignedUrl)
  local status = curlRequest(args)

  if status == 200 or status == 204 or status == 404 then
    return true  -- 404 is fine — object already gone
  else
    return false, string.format('S3 DELETE failed (HTTP %s)', tostring(status))
  end
end

return M
