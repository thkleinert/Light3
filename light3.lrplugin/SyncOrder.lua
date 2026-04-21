--[[----------------------------------------------------------------------------
SyncOrder.lua
Library menu action: marks all photos in the active published collection
as "to be re-published", so the next Publish run triggers
imposeSortOrderOnPublishedCollection with the correct full sort order.

Use this after reordering photos with a naming scheme that does not use
<sequence> (where keys don't change on reorder and Lightroom won't
automatically schedule a re-publish).
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrDialogs     = import 'LrDialogs'
local LrTasks       = import 'LrTasks'

LrTasks.startAsyncTask(function()

  local collection = nil
  for _, source in ipairs(LrApplication.activeCatalog():getActiveSources()) do
    if source:type() == 'LrPublishedCollection' then
      collection = source
      break
    end
  end

  if not collection then
    LrDialogs.message('Light3', 'Please select a published collection first.', 'info')
    return
  end

  local photos = collection:getPublishedPhotos() or {}
  if #photos == 0 then
    LrDialogs.message('Light3', 'No published photos found in this collection.', 'info')
    return
  end

  -- Mark every photo in the collection for re-publication.
  -- The next Publish click will trigger imposeSortOrderOnPublishedCollection
  -- with info.photoIds in the correct Lightroom sort order.
  LrApplication.activeCatalog():withWriteAccessDo('Mark photos for re-publish', function()
    for _, pubPhoto in ipairs(photos) do
      pubPhoto:setEditedFlag(true)
    end
  end)

  LrDialogs.message('Light3',
    string.format('%d photo(s) marked for re-publish.\nClick Publish to update order.json.', #photos),
    'info')

end)
