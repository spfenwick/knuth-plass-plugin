--[[
Disable the "Current folder not readable. Some content may not be shown."
popup added to the file browser in koreader/koreader@48895cc (#16254).

FileChooser:refreshPath() only shows the InfoMessage when
self.unreadable_path_warned ~= self.path. Marking the current path as
already warned before the original runs suppresses the popup, while
leaving the rest of refreshPath() (listing, sorting, reset of the flag
on readable folders) untouched.

On builds older than 48895cc this is a no-op: the field is simply unused.
]]

local FileChooser = require("ui/widget/filechooser")

local orig_refreshPath = FileChooser.refreshPath

FileChooser.refreshPath = function(self, ...)
    self.unreadable_path_warned = self.path
    return orig_refreshPath(self, ...)
end
