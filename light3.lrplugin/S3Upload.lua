--[[----------------------------------------------------------------------------
S3Upload.lua
Handles uploading and deleting objects in S3-compatible storage.

Strategy: delegate AWS Signature V4 signing to an external helper binary
(signing-helper/light3-sign) which returns a presigned URL. The plugin then
does a plain HTTP PUT to that URL — no crypto needed in Lua.

Fallback: if no signing helper is configured, attempt a direct PUT using the
signing helper via stdin/stdout pipe (same binary, different invocation).
------------------------------------------------------------------------------]]

local LrFileUtils  = import 'LrFileUtils'
local LrHttp       = import 'LrHttp'
local LrTasks      = import 'LrTasks'

local M = {}

-- ---------------------------------------------------------------------------
-- Internal: call the signing helper to get a presigned PUT URL
-- Returns: url (string) or nil, errorMessage (string)
-- ---------------------------------------------------------------------------

local function getPresignedUrl(params, method)
  local helperPath = params.signingHelperPath or ''
  if helperPath == '' then
    return nil, 'No signing helper configured. Please set the helper path in plugin settings.'
  end

  -- Build the command — the helper reads JSON from stdin and writes a URL to stdout
  -- Usage: light3-sign <json-config>
  -- Config fields: endpoint, bucket, region, accessKeyId, secretAccessKey, key, method, expiresIn
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

  -- Escape single quotes in config for shell safety
  config = config:gsub("'", "'\\''")

  -- LrTasks.execute returns only an exit code; capture stdout via a temp file
  local tmpFile = string.format('/tmp/light3_presign_%d.txt', os.time())
  local cmdWithOutput = string.format("echo '%s' | '%s' > '%s' 2>&1", config, helperPath, tmpFile)
  local exitCode = LrTasks.execute(cmdWithOutput)

  if exitCode ~= 0 then
    local errMsg = 'Signing helper failed (exit ' .. tostring(exitCode) .. ')'
    if LrFileUtils.exists(tmpFile) then
      local f = io.open(tmpFile, 'r')
      if f then
        errMsg = errMsg .. ': ' .. (f:read('*all') or '')
        f:close()
      end
      LrFileUtils.delete(tmpFile)
    end
    return nil, errMsg
  end

  local url = nil
  if LrFileUtils.exists(tmpFile) then
    local f = io.open(tmpFile, 'r')
    if f then
      url = f:read('*all')
      f:close()
    end
    LrFileUtils.delete(tmpFile)
  end

  if not url or url == '' then
    return nil, 'Signing helper returned empty URL'
  end

  -- Trim whitespace/newlines
  url = url:match('^%s*(.-)%s*$')
  return url, nil
end

-- ---------------------------------------------------------------------------
-- Upload a file to S3
-- params: localPath, key, endpoint, bucket, region, accessKeyId,
--         secretAccessKey, signingHelperPath
-- Returns: true or false, errorMessage
-- ---------------------------------------------------------------------------

function M.upload(params)
  -- Get presigned PUT URL
  local presignedUrl, err = getPresignedUrl(params, 'PUT')
  if not presignedUrl then
    return false, err
  end

  -- Read file contents
  local f = io.open(params.localPath, 'rb')
  if not f then
    return false, 'Could not open file: ' .. params.localPath
  end
  local fileData = f:read('*all')
  f:close()

  if not fileData then
    return false, 'Could not read file: ' .. params.localPath
  end

  -- Determine MIME type from extension
  local ext = params.localPath:match('%.([^%.]+)$')
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
  local contentType = mimeTypes[(ext or ''):lower()] or 'application/octet-stream'

  -- PUT to presigned URL — no auth headers needed, the URL is already signed
  local result, hdrs = LrHttp.post(
    presignedUrl,
    fileData,
    {
      { field = 'Content-Type', value = contentType },
    },
    'PUT',
    contentType,
    #fileData
  )

  -- S3 returns 200 or 204 on success
  local status = hdrs and hdrs.status
  if status == 200 or status == 204 then
    return true
  else
    local body = result or ''
    return false, string.format('S3 PUT failed (HTTP %s): %s', tostring(status), body:sub(1, 200))
  end
end

-- ---------------------------------------------------------------------------
-- Delete an object from S3
-- params: key, endpoint, bucket, region, accessKeyId, secretAccessKey,
--         signingHelperPath
-- Returns: true or false, errorMessage
-- ---------------------------------------------------------------------------

function M.delete(params)
  local presignedUrl, err = getPresignedUrl(params, 'DELETE')
  if not presignedUrl then
    return false, err
  end

  local result, hdrs = LrHttp.post(
    presignedUrl,
    '',
    {},
    'DELETE',
    'application/octet-stream',
    0
  )

  local status = hdrs and hdrs.status
  if status == 200 or status == 204 or status == 404 then
    -- 404 is fine — object already gone
    return true
  else
    return false, string.format('S3 DELETE failed (HTTP %s)', tostring(status))
  end
end

return M
