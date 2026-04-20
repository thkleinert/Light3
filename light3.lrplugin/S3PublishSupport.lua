--[[----------------------------------------------------------------------------
S3PublishSupport.lua
Publish service provider for Light3 — handles Lightroom publish lifecycle.
------------------------------------------------------------------------------]]

local LrColor         = import 'LrColor'
local LrErrors        = import 'LrErrors'
local LrPathUtils     = import 'LrPathUtils'
local LrStringUtils   = import 'LrStringUtils'
local LrView          = import 'LrView'

local S3Upload = require 'S3Upload'

-- Path to the signing helper bundled inside the plugin folder
local signingHelperPath = LrPathUtils.child(_PLUGIN.path, 'light3-sign')

-- ---------------------------------------------------------------------------
-- Filename helpers
-- ---------------------------------------------------------------------------

-- Pad a number to at least `width` digits with leading zeros
local function zeroPad(n, width)
  local s = tostring(n)
  while #s < width do s = '0' .. s end
  return s
end

-- Build the S3 filename based on the selected naming scheme.
-- Schemes:
--   'original'          →  <original_filename>            (e.g. DSC_0042.jpg)
--   'sequence_collection' →  <00001>_<CollectionName>.<ext>  (e.g. 00001_Summer.jpg)
local function buildFilename(scheme, index, total, localPath, collectionName)
  local ext      = LrPathUtils.extension(localPath)
  local basename = LrPathUtils.removeExtension(LrPathUtils.leafName(localPath))
  local dotExt   = (ext and ext ~= '') and ('.' .. ext) or ''

  if scheme == 'sequence_collection' then
    local width = math.max(5, #tostring(total))
    local safe  = (collectionName ~= '') and collectionName or 'photo'
    return zeroPad(index, width) .. '_' .. safe .. dotExt
  end

  -- default: original filename
  return basename .. dotExt
end

-- ---------------------------------------------------------------------------
-- Settings UI
-- ---------------------------------------------------------------------------

local function sectionsForTopOfDialog(f, propertyTable)
  local bind = LrView.bind

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

        -- File naming
        f:separator { fill_horizontal = 1 },
        f:row {
          f:static_text { title = 'File naming', width = 120 },
          f:popup_menu {
            value = bind 'fileNaming',
            items = {
              { title = 'Original filename',              value = 'original' },
              { title = 'Sequence — Collection name',     value = 'sequence_collection' },
            },
          },
        },
        f:row {
          f:static_text { title = '', width = 120 },
          f:static_text {
            title = bind {
              key = 'fileNaming',
              transform = function(v)
                if v == 'sequence_collection' then
                  return 'e.g.  00001_Summer.jpg'
                end
                return 'e.g.  DSC_0042.jpg'
              end,
            },
            text_color = LrColor(0.5, 0.5, 0.5),
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

  local bucket     = LrStringUtils.trimWhitespace(exportSettings.bucket)
  local keyPrefix  = LrStringUtils.trimWhitespace(exportSettings.keyPrefix or '')
  local fileNaming = exportSettings.fileNaming or 'original'
  -- Normalise prefix: ensure trailing slash if non-empty
  if keyPrefix ~= '' and keyPrefix:sub(-1) ~= '/' then
    keyPrefix = keyPrefix .. '/'
  end

  -- Determine collection name (used both for sub-prefix and file naming)
  local collectionName = ''
  local pubCollection  = exportContext.publishedCollection
  if pubCollection then
    collectionName = pubCollection:getName()
    -- sanitise for use as path segment / filename part
    collectionName = collectionName:gsub('[^%w%-_]', '_')
    if collectionName ~= '' then
      keyPrefix = keyPrefix .. collectionName .. '/'
    end
  end

  for i, rendition in exportSession:renditions { stopIfCanceled = true } do
    progressScope:setPortionComplete(i - 1, nPhotos)

    local success, pathOrMessage = rendition:waitForRender()
    if progressScope:isCanceled() then break end

    if success then
      local localPath = pathOrMessage
      local filename  = buildFilename(fileNaming, i, nPhotos, localPath, collectionName)
      local key       = keyPrefix .. filename

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

  progressScope:done()
end

-- ---------------------------------------------------------------------------
-- Delete published photos
-- ---------------------------------------------------------------------------

local function deletePhotosFromPublishedCollection(functionContext, publishSettings, arrayOfPhotoIds)
  for _, photoId in ipairs(arrayOfPhotoIds) do
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
end

-- ---------------------------------------------------------------------------
-- Publish service provider table
-- ---------------------------------------------------------------------------

return {

  supportsIncrementalPublish = 'only',
  supportsCustomSortOrder    = true,
  small_icon                 = 'S3_small.png',

  -- Metadata
  hideSections     = { 'exportLocation' },
  allowFileFormats = { 'JPEG', 'TIFF', 'PNG', 'DNG' },
  allowColorSpaces = nil,  -- all allowed
  canExportVideo   = false,

  -- Settings UI
  sectionsForTopOfDialog = sectionsForTopOfDialog,

  -- Defaults
  exportPresetFields = {
    { key = 'endpoint',        default = '' },
    { key = 'bucket',          default = '' },
    { key = 'region',          default = 'auto' },
    { key = 'accessKeyId',     default = '' },
    { key = 'secretAccessKey', default = '' },
    { key = 'keyPrefix',       default = '' },
    { key = 'fileNaming',      default = 'original' },
  },

  -- Core publish callbacks
  processRenderedPhotos               = processRenderedPhotos,
  deletePhotosFromPublishedCollection = deletePhotosFromPublishedCollection,

  -- Optional: called when a collection is renamed — update the prefix if needed
  renamePublishedCollection = function(publishSettings, info)
    -- No-op for now; keys are not renamed automatically
  end,

}
