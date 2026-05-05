--[[----------------------------------------------------------------------------
Light3 — Lightroom publish plugin for S3-compatible storage
(AWS S3, Cloudflare R2, Backblaze B2, MinIO, etc.)
------------------------------------------------------------------------------]]

return {

  LrSdkVersion         = 5.0,
  LrSdkMinimumVersion  = 5.0,

  LrToolkitIdentifier  = 'com.thkleinert.light3',
  LrPluginName         = 'Light3',

  VERSION = {
    major    = 1,  -- x-release-please-major
    minor    = 2,  -- x-release-please-minor
    revision = 0,  -- x-release-please-patch
    display  = '1.2.0',  -- x-release-please-version
  },

  LrExportServiceProvider = {
    title = 'Light3',
    file  = 'S3PublishSupport.lua',
  },

  LrLibraryMenuItems = {
    {
      title = 'Sync order',
      file  = 'SyncOrder.lua',
    },
  },

}
