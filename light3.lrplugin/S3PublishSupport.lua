--[[----------------------------------------------------------------------------
S3PublishSupport.lua
Publish service provider for Light3 — handles Lightroom publish lifecycle.
------------------------------------------------------------------------------]]

local LrBinding      = import 'LrBinding'
local LrColor        = import 'LrColor'
local LrDialogs      = import 'LrDialogs'
local LrErrors       = import 'LrErrors'
local LrFileUtils    = import 'LrFileUtils'
local LrHttp         = import 'LrHttp'
local LrPathUtils    = import 'LrPathUtils'
local LrPrefs        = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'
local LrStringUtils  = import 'LrStringUtils'
local LrTasks        = import 'LrTasks'
local LrView         = import 'LrView'

local S3Upload = require 'S3Upload'

local prefs = LrPrefs.prefsForPlugin()

-- ---------------------------------------------------------------------------
-- Settings UI
-- ---------------------------------------------------------------------------

local function sectionsForTopOfDialog(f, propertyTable)
  local bind = LrView.bind

  return {
    {
      title = 'S3 Connection',
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

        -- Signing helper path
        f:separator { fill_horizontal = 1 },
        f:row {
          f:static_text {
            title = 'Signing helper',
            width = 120,
          },
          f:edit_field {
            value = bind 'signingHelperPath',
            width_in_chars = 40,
            placeholder_string = '/usr/local/bin/light3-sign',
          },
          f:push_button {
            title = 'Browse…',
            action = function()
              local path = LrDialogs.runOpenPanel {
                title = 'Select signing helper',
                canChooseFiles = true,
                canChooseDirectories = false,
                allowsMultipleSelection = false,
              }
              if path and path[1] then
                propertyTable.signingHelperPath = path[1]
              end
            end,
          },
        },

        f:row {
          f:static_text {
            title = '',
            width = 120,
          },
          f:static_text {
            title = 'The signing helper generates presigned upload URLs.\nSee signing-helper/ in the Light3 repo.',
            text_color = LrColor(0.5, 0.5, 0.5),
            height_in_lines = 2,
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
  -- Normalise prefix: ensure trailing slash if non-empty
  if keyPrefix ~= '' and keyPrefix:sub(-1) ~= '/' then
    keyPrefix = keyPrefix .. '/'
  end

  -- Determine collection name for sub-prefix (only in publish context)
  local collectionName = ''
  local pubCollection  = exportContext.publishedCollection
  if pubCollection then
    collectionName = pubCollection:getName()
    -- sanitise for use as path segment
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
      local filename  = LrPathUtils.leafName(localPath)
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
        signingHelperPath = exportSettings.signingHelperPath,
      }

      if uploadOk then
        -- Record the remote ID so Lightroom tracks publish state
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
      key             = photoId,
      endpoint        = publishSettings.endpoint,
      bucket          = publishSettings.bucket,
      region          = publishSettings.region or 'auto',
      accessKeyId     = publishSettings.accessKeyId,
      secretAccessKey = publishSettings.secretAccessKey,
      signingHelperPath = publishSettings.signingHelperPath,
    }
  end
end

-- ---------------------------------------------------------------------------
-- Publish service provider table
-- ---------------------------------------------------------------------------

return {

  -- Metadata
  hideSections         = { 'exportLocation' },
  allowFileFormats     = { 'JPEG', 'TIFF', 'PNG', 'DNG' },
  allowColorSpaces     = nil,  -- all allowed
  canExportVideo       = false,
  small_icon           = 'Resources/S3_small.png',

  -- Settings UI
  sectionsForTopOfDialog = sectionsForTopOfDialog,

  -- Defaults
  exportPresetFields = {
    { key = 'endpoint',          default = '' },
    { key = 'bucket',            default = '' },
    { key = 'region',            default = 'auto' },
    { key = 'accessKeyId',       default = '' },
    { key = 'secretAccessKey',   default = '' },
    { key = 'keyPrefix',         default = '' },
    { key = 'signingHelperPath', default = '' },
  },

  -- Core publish callbacks
  processRenderedPhotos                 = processRenderedPhotos,
  deletePhotosFromPublishedCollection   = deletePhotosFromPublishedCollection,

  -- Optional: called when a collection is renamed — update the prefix if needed
  renamePublishedCollection = function(publishSettings, info)
    -- No-op for now; keys are not renamed automatically
  end,
}
