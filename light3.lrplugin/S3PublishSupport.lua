--[[----------------------------------------------------------------------------
S3PublishSupport.lua
Publish service provider for Light3 — handles Lightroom publish lifecycle.
------------------------------------------------------------------------------]]

local LrApplication   = import 'LrApplication'
local LrColor         = import 'LrColor'
local LrDialogs       = import 'LrDialogs'
local LrErrors        = import 'LrErrors'
local LrPathUtils     = import 'LrPathUtils'
local LrStringUtils   = import 'LrStringUtils'
local LrTasks         = import 'LrTasks'
local LrView          = import 'LrView'

local S3Upload = require 'S3Upload'

-- Path to the signing helper bundled inside the plugin folder
local signingHelperPath = LrPathUtils.child(_PLUGIN.path, 'light3-sign')

local updateOrderJson  -- forward declaration; defined after processRenderedPhotos


-- ---------------------------------------------------------------------------
-- Collection path helper
-- ---------------------------------------------------------------------------

-- Walk the parent chain of a published collection and return the full
-- slash-separated path of collection set names, e.g. "Travel/2024/Summer".
-- Stops when getParent() fails or returns something without getParent itself
-- (i.e. the publish service root).
local function collectionSetPath(collection)
  local parts = {}
  local node  = collection

  while true do
    local parent = node:getParent()
    if parent == nil or parent:type() ~= 'LrPublishedCollectionSet' then break end
    local name = parent:getName():gsub('[^%w%-_ ]', '_')
    if name ~= '' then
      table.insert(parts, 1, name)
    end
    node = parent
  end

  return table.concat(parts, '/')
end

-- ---------------------------------------------------------------------------
-- Filename template engine
-- ---------------------------------------------------------------------------

-- Pad a number to at least `width` digits with leading zeros
local function zeroPad(n, width)
  local s = tostring(n)
  while #s < width do s = '0' .. s end
  return s
end

-- Apply a naming template to produce a filename (without extension).
-- Supported tokens:
--   <sequence>    zero-padded position in the current publish run
--   <collection>  sanitised collection name
--   <file>        original filename without extension
--   <uuid>        Lightroom's permanent internal photo UUID (stable across reorders)
local function applyTemplate(template, index, total, basename, collectionName, uuid)
  local width  = math.max(5, #tostring(total))
  local safe   = (collectionName and collectionName ~= '') and collectionName or 'photo'
  local result = template
  result = result:gsub('<sequence>',   zeroPad(index, width))
  result = result:gsub('<collection>', safe)
  result = result:gsub('<file>',       basename)
  result = result:gsub('<uuid>',       uuid or 'nouuid')
  return result
end

-- Build the final S3 filename from settings + context
local function buildFilename(template, index, total, localPath, collectionName, uuid)
  local ext      = LrPathUtils.extension(localPath)
  local basename = LrPathUtils.removeExtension(LrPathUtils.leafName(localPath))
  local dotExt   = (ext and ext ~= '') and ('.' .. ext) or ''
  local tpl      = (template and template ~= '') and template or '<file>'
  return applyTemplate(tpl, index, total, basename, collectionName, uuid) .. dotExt
end

-- ---------------------------------------------------------------------------
-- Settings UI
-- ---------------------------------------------------------------------------

local function sectionsForTopOfDialog(f, propertyTable)
  local bind = LrView.bind

  -- Helper: append a token to the template field
  local function insertToken(token)
    propertyTable.fileNamingTemplate =
      (propertyTable.fileNamingTemplate or '') .. token
  end

  return {
    {
      title = 'Light3',
      synopsis = bind 'endpoint',

      f:column {
        spacing = f:label_spacing(),

        -- Endpoint
        f:row {
          f:static_text { title = 'Endpoint URL', width = 120 },
          f:edit_field {
            value = bind 'endpoint',
            width_in_chars = 40,
            placeholder_string = 'https://<account>.r2.cloudflarestorage.com',
          },
        },

        -- Bucket
        f:row {
          f:static_text { title = 'Bucket', width = 120 },
          f:edit_field {
            value = bind 'bucket',
            width_in_chars = 30,
            placeholder_string = 'my-photos',
          },
        },

        -- Region
        f:row {
          f:static_text { title = 'Region', width = 120 },
          f:edit_field {
            value = bind 'region',
            width_in_chars = 20,
            placeholder_string = 'auto  (R2) or us-east-1 (S3)',
          },
        },

        -- Access Key
        f:row {
          f:static_text { title = 'Access Key ID', width = 120 },
          f:edit_field {
            value = bind 'accessKeyId',
            width_in_chars = 30,
          },
        },

        -- Secret Key
        f:row {
          f:static_text { title = 'Secret Access Key', width = 120 },
          f:password_field {
            value = bind 'secretAccessKey',
            width_in_chars = 30,
          },
        },

        -- Key prefix (path inside bucket)
        f:row {
          f:static_text { title = 'Key prefix', width = 120 },
          f:edit_field {
            value = bind 'keyPrefix',
            width_in_chars = 30,
            placeholder_string = 'galleries/  (optional)',
          },
        },

        -- File naming template
        f:separator { fill_horizontal = 1 },
        f:row {
          f:static_text { title = 'File naming', width = 120 },
          f:edit_field {
            value           = bind 'fileNamingTemplate',
            width_in_chars  = 30,
            placeholder_string = '<file>',
          },
        },
        f:row {
          f:static_text { title = '', width = 120 },
          f:push_button {
            title  = '<sequence>',
            action = function() insertToken('<sequence>') end,
          },
          f:push_button {
            title  = '<collection>',
            action = function() insertToken('<collection>') end,
          },
          f:push_button {
            title  = '<file>',
            action = function() insertToken('<file>') end,
          },
          f:push_button {
            title  = '<uuid>',
            action = function() insertToken('<uuid>') end,
          },
        },
        f:row {
          f:static_text { title = '', width = 120 },
          f:static_text {
            title      = '<sequence> = 00001   <collection> = GalleryName   <file> = DSC_0042   <uuid> = 4FE7F02E…',
            text_color = LrColor(0.5, 0.5, 0.5),
            fill_horizontal = 1,
          },
        },

      },
    },
  }
end

-- ---------------------------------------------------------------------------
-- Validate settings before export
-- ---------------------------------------------------------------------------

local function validateSettings(propertyTable)
  if LrStringUtils.trimWhitespace(propertyTable.endpoint or '') == '' then
    return false, 'Endpoint URL is required.'
  end
  if LrStringUtils.trimWhitespace(propertyTable.bucket or '') == '' then
    return false, 'Bucket name is required.'
  end
  if LrStringUtils.trimWhitespace(propertyTable.accessKeyId or '') == '' then
    return false, 'Access Key ID is required.'
  end
  if LrStringUtils.trimWhitespace(propertyTable.secretAccessKey or '') == '' then
    return false, 'Secret Access Key is required.'
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Process rendered photos (core publish step)
-- ---------------------------------------------------------------------------

local function processRenderedPhotos(functionContext, exportContext)
  local exportSession  = exportContext.exportSession
  local exportSettings = exportContext.propertyTable
  local nPhotos        = exportSession:countRenditions()

  local progressScope = exportContext:configureProgress {
    title = string.format('Uploading %d photo(s) to S3…', nPhotos),
  }

  -- Validate settings
  local ok, err = validateSettings(exportSettings)
  if not ok then
    LrErrors.throwUserError(err)
  end

  local bucket      = LrStringUtils.trimWhitespace(exportSettings.bucket)
  local keyPrefix   = LrStringUtils.trimWhitespace(exportSettings.keyPrefix or '')
  local fileNamingTemplate = exportSettings.fileNamingTemplate or '<file>'
  -- Normalise prefix: ensure trailing slash if non-empty
  if keyPrefix ~= '' and keyPrefix:sub(-1) ~= '/' then
    keyPrefix = keyPrefix .. '/'
  end

  -- Build the S3 prefix from the full collection set hierarchy + collection name
  -- e.g.  keyPrefix / Travel/2024/Summer / Beach /
  local collectionName = ''
  local pubCollection  = exportContext.publishedCollection
  if pubCollection then
    -- Parent collection sets (may be empty if collection is at the root)
    local setPath = collectionSetPath(pubCollection)
    if setPath ~= '' then
      keyPrefix = keyPrefix .. setPath .. '/'
    end

    -- The collection itself
    collectionName = pubCollection:getName() or ''
    collectionName = collectionName:gsub('[^%w%-_ ]', '_')
    if collectionName ~= '' then
      keyPrefix = keyPrefix .. collectionName .. '/'
    end
  end

  -- Determine full vs partial publish.
  -- getPublishedPhotos() counts photos already tracked by this publish service.
  -- On a first publish it returns 0 (< nPhotos) → isFullPublish = true, which is
  -- correct: the render loop covers everything.
  local alreadyPublished = pubCollection and #(pubCollection:getPublishedPhotos() or {}) or 0
  local isFullPublish    = (nPhotos >= alreadyPublished)

  -- Collect render-loop order and key renames for updateOrderJson
  local renderedKeys = {}
  local keyRenames   = {}   -- { [oldKey] = newKey } for photos whose key changed

  for i, rendition in exportSession:renditions { stopIfCanceled = true } do
    progressScope:setPortionComplete(i - 1, nPhotos)

    local success, pathOrMessage = rendition:waitForRender()
    if progressScope:isCanceled() then break end

    if success then
      local localPath = pathOrMessage
      local uuid      = (rendition.photo and rendition.photo:getRawMetadata('uuid')) or 'nouuid'
      local filename  = buildFilename(fileNamingTemplate, i, nPhotos, localPath, collectionName, uuid)
      local key       = keyPrefix .. filename

      -- Track if this photo had a different key in the previous publish
      local oldKey = rendition.publishedPhotoId
      if oldKey and oldKey ~= '' and oldKey ~= key then
        keyRenames[oldKey] = key
      end

      table.insert(renderedKeys, key)

      progressScope:setCaption('Uploading ' .. filename)

      local uploadOk, uploadErr = S3Upload.upload {
        localPath         = localPath,
        key               = key,
        endpoint          = exportSettings.endpoint,
        bucket            = bucket,
        region            = exportSettings.region or 'auto',
        accessKeyId       = exportSettings.accessKeyId,
        secretAccessKey   = exportSettings.secretAccessKey,
        signingHelperPath = signingHelperPath,
      }

      if uploadOk then
        rendition:recordPublishedPhotoId(key)
        rendition:recordPublishedPhotoUrl(
          exportSettings.endpoint .. '/' .. bucket .. '/' .. key
        )
      else
        rendition:uploadFailed(uploadErr or 'Upload failed')
      end
    else
      rendition:uploadFailed(pathOrMessage)
    end
  end

  LrTasks.execute(string.format(
    "echo 'processRenderedPhotos done: canceled=%s renderedKeys=%d' >> /tmp/light3_debug.txt",
    tostring(progressScope:isCanceled()), #renderedKeys))

  if not progressScope:isCanceled() and #renderedKeys > 0 then
    updateOrderJson(exportSettings, keyPrefix, collectionName, renderedKeys, keyRenames, isFullPublish)
  end

  progressScope:done()
end

-- ---------------------------------------------------------------------------
-- Write an ordered list of S3 keys as order.json to the bucket.
-- ---------------------------------------------------------------------------

local function writeOrderJson(publishSettings, orderedKeys, collectionName)
  if not orderedKeys or #orderedKeys == 0 then return end

  local prefix = orderedKeys[1]:match('^(.*/)') or ''

  LrTasks.execute(string.format(
    "echo 'writeOrderJson: key=%s count=%d' >> /tmp/light3_debug.txt",
    prefix .. 'order.json', #orderedKeys))

  local keyStrings = {}
  for _, k in ipairs(orderedKeys) do
    table.insert(keyStrings, '"' .. k:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"')
  end

  local json = string.format(
    '{"collection":"%s","prefix":"%s","photos":[%s]}',
    (collectionName or ''):gsub('\\', '\\\\'):gsub('"', '\\"'),
    prefix:gsub('\\', '\\\\'):gsub('"', '\\"'),
    table.concat(keyStrings, ',')
  )

  local ok, err = S3Upload.putContent {
    content           = json,
    key               = prefix .. 'order.json',
    endpoint          = publishSettings.endpoint,
    bucket            = publishSettings.bucket,
    region            = publishSettings.region or 'auto',
    accessKeyId       = publishSettings.accessKeyId,
    secretAccessKey   = publishSettings.secretAccessKey,
    signingHelperPath = signingHelperPath,
  }
  LrTasks.execute(string.format(
    "echo 'putContent result: ok=%s err=%s' >> /tmp/light3_debug.txt",
    tostring(ok), tostring(err)))
  if not ok then
    LrDialogs.message('Light3: order.json failed', err or 'unknown error', 'critical')
  end
end

-- ---------------------------------------------------------------------------
-- Build and upload order.json — called directly from processRenderedPhotos.
-- For a full publish the render-loop order is authoritative.
-- For a partial publish the existing order.json is fetched and patched.
-- ---------------------------------------------------------------------------

updateOrderJson = function(publishSettings, prefix, collectionName, renderedKeys, keyRenames, isFullPublish)
  LrTasks.execute(string.format(
    "echo 'updateOrderJson called: prefix=%s isFullPublish=%s keys=%d' >> /tmp/light3_debug.txt",
    tostring(prefix), tostring(isFullPublish), #renderedKeys))
  local finalKeys

  if isFullPublish then
    finalKeys = renderedKeys
  else
    local orderJson = S3Upload.getContent {
      key               = prefix .. 'order.json',
      endpoint          = publishSettings.endpoint,
      bucket            = publishSettings.bucket,
      region            = publishSettings.region or 'auto',
      accessKeyId       = publishSettings.accessKeyId,
      secretAccessKey   = publishSettings.secretAccessKey,
      signingHelperPath = signingHelperPath,
    }

    if not orderJson then
      finalKeys = renderedKeys
    else
      local existingKeys = {}
      local photosJson   = orderJson:match('"photos"%s*:%s*%[(.-)%]')
      if photosJson then
        for k in photosJson:gmatch('"([^"]+)"') do
          table.insert(existingKeys, k)
        end
      end

      local finalSet = {}
      finalKeys = {}

      for _, k in ipairs(existingKeys) do
        local newK = keyRenames[k] or k
        if not finalSet[newK] then
          finalSet[newK] = true
          table.insert(finalKeys, newK)
        end
      end

      for _, k in ipairs(renderedKeys) do
        if not finalSet[k] then
          finalSet[k] = true
          table.insert(finalKeys, k)
        end
      end
    end
  end

  writeOrderJson(publishSettings, finalKeys, collectionName)
end

-- ---------------------------------------------------------------------------
-- Impose sort order (called by Lightroom for custom-sorted collections)
-- order.json is already written by processRenderedPhotos; nothing to do here.
-- ---------------------------------------------------------------------------

local function imposeSortOrderOnPublishedCollection(publishSettings, info)
end

-- ---------------------------------------------------------------------------
-- Delete published photos
-- ---------------------------------------------------------------------------

local function deletePhotosFromPublishedCollection(functionContext, publishSettings, arrayOfPhotoIds)
  -- Build a set of deleted IDs for fast lookup
  local deleted = {}
  for _, photoId in ipairs(arrayOfPhotoIds) do
    deleted[photoId] = true
    S3Upload.delete {
      key               = photoId,
      endpoint          = publishSettings.endpoint,
      bucket            = publishSettings.bucket,
      region            = publishSettings.region or 'auto',
      accessKeyId       = publishSettings.accessKeyId,
      secretAccessKey   = publishSettings.secretAccessKey,
      signingHelperPath = signingHelperPath,
    }
  end

  -- Refresh order.json by reading existing file, filtering out deleted keys.
  local sampleKey = arrayOfPhotoIds[1]
  if sampleKey then
    local prefix    = sampleKey:match('^(.*/)') or ''
    local orderJson = S3Upload.getContent {
      key               = prefix .. 'order.json',
      endpoint          = publishSettings.endpoint,
      bucket            = publishSettings.bucket,
      region            = publishSettings.region or 'auto',
      accessKeyId       = publishSettings.accessKeyId,
      secretAccessKey   = publishSettings.secretAccessKey,
      signingHelperPath = signingHelperPath,
    }

    if orderJson then
      local remainingKeys  = {}
      local collectionName = orderJson:match('"collection"%s*:%s*"([^"]+)"') or ''
      local photosJson     = orderJson:match('"photos"%s*:%s*%[(.-)%]')
      if photosJson then
        for key in photosJson:gmatch('"([^"]+)"') do
          if not deleted[key] then
            table.insert(remainingKeys, key)
          end
        end
      end
      writeOrderJson(publishSettings, remainingKeys, collectionName)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Publish service provider table
-- ---------------------------------------------------------------------------

return {

  supportsIncrementalPublish = 'only',
  supportsCustomSortOrder    = true,
  small_icon                 = 'light3_small.png',

  -- Metadata
  hideSections     = { 'exportLocation', 'fileNaming' },
  allowFileFormats = { 'JPEG', 'TIFF', 'PNG', 'DNG' },
  allowColorSpaces = nil,  -- all allowed
  canExportVideo   = false,

  -- Settings UI
  sectionsForTopOfDialog = sectionsForTopOfDialog,

  -- Defaults
  exportPresetFields = {
    { key = 'endpoint',           default = '' },
    { key = 'bucket',             default = '' },
    { key = 'region',             default = 'auto' },
    { key = 'accessKeyId',        default = '' },
    { key = 'secretAccessKey',    default = '' },
    { key = 'keyPrefix',          default = '' },
    { key = 'fileNamingTemplate', default = '<file>' },
  },

  -- Core publish callbacks
  processRenderedPhotos                    = processRenderedPhotos,
  deletePhotosFromPublishedCollection      = deletePhotosFromPublishedCollection,
  imposeSortOrderOnPublishedCollection     = imposeSortOrderOnPublishedCollection,

  -- Optional: called when a collection is renamed — update the prefix if needed
  renamePublishedCollection = function(publishSettings, info)
    -- No-op for now; keys are not renamed automatically
  end,

}
