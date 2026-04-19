--[[----------------------------------------------------------------------------
Light3 — Lightroom publish plugin for S3-compatible storage
(AWS S3, Cloudflare R2, Backblaze B2, MinIO, etc.)
------------------------------------------------------------------------------]]

return {

  LrSdkVersion         = 10.0,
  LrSdkMinimumVersion  = 6.0,

  LrToolkitIdentifier  = 'com.thkleinert.light3',
  LrPluginName         = 'Light3 — S3 Publisher',

  VERSION = {
    major  = 0,
    minor  = 1,
    revision = 0,
    display = '0.1.0',
  },

  LrPublishServiceProvider = {
    title            = 'Light3 (S3)',
    file             = 'S3PublishSupport.lua',
    builtInIcon      = 'S3.png',  -- optional, add later
    publishMenuName  = 'Publish to S3',
  },

  LrExportServiceProvider = {
    title = 'Light3 (S3)',
    file  = 'S3PublishSupport.lua',
  },

}
