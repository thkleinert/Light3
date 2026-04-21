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
    major  = 0,
    minor  = 1,
    revision = 0,
    display = '0.1.0',
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
