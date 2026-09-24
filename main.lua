local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local Device = require("device")
local logger = require("logger")
local ffi = require("ffi")
local DocSettings = require("docsettings")
local _ = require("gettext")
local ConfirmBox = require("ui/widget/confirmbox")
local util = require("util")
local MIN_VERSION_CODE = 7 -- minimum APK required versionCode
local COMPANION_PACKAGE = "org.koreader.backgroundonyxsynckoreader"
local COMPANION_RELEASES_URL = "https://github.com/Tukks/onyxbooxsync.koplugin/releases/latest"

local OnyxSync = WidgetContainer:extend {
    name = "onyx_sync",
    is_doc_only = false,
    last_synced_page = 0,
}


local function getCompanionVersionCode()
    local ok, android = pcall(require, "android")
    if not ok or not android or not android.app or not android.app.activity then
        return nil
    end

    local version_code = nil
    pcall(function()
        android.jni:context(android.app.activity.vm, function(jni)
            local env = jni.env
            if env[0].PushLocalFrame(env, 16) ~= 0 then return end

            pcall(function()
                local activity = android.app.activity.clazz
                local activity_class = env[0].GetObjectClass(env, activity)

                local get_pm = env[0].GetMethodID(env, activity_class, "getPackageManager",
                    "()Landroid/content/pm/PackageManager;")
                local pm = env[0].CallObjectMethod(env, activity, get_pm)

                local pm_class = env[0].GetObjectClass(env, pm)
                local get_pi = env[0].GetMethodID(env, pm_class, "getPackageInfo",
                    "(Ljava/lang/String;I)Landroid/content/pm/PackageInfo;")

                local pkg_str = env[0].NewStringUTF(env, COMPANION_PACKAGE)
                local info = env[0].CallObjectMethod(env, pm, get_pi, pkg_str, ffi.cast("jint", 0))

                if env[0].ExceptionCheck(env) == 0 and info ~= nil then
                    -- Get versionCode field from PackageInfo
                    local info_class = env[0].GetObjectClass(env, info)
                    local vc_field = env[0].GetFieldID(env, info_class, "versionCode", "I")
                    version_code = env[0].GetIntField(env, info, vc_field)
                else
                    env[0].ExceptionClear(env)
                end
            end)

            env[0].PopLocalFrame(env, nil)
        end)
    end)

    return version_code
end

function OnyxSync:init()
    logger.info("OnyxSync: Plugin initialized")

    if Device:isAndroid() then
        local vc = getCompanionVersionCode()
        if vc == nil then
            UIManager:show(ConfirmBox:new {
                text = _("OnyxSync companion app is not installed.\nWould you like to download it?"),
                ok_text = _("Download"),
                cancel_text = _("Dismiss"),
                ok_callback = function()
                    Device:openLink(COMPANION_RELEASES_URL)
                end,
            })
            return
        elseif vc < MIN_VERSION_CODE then
            UIManager:show(ConfirmBox:new {
                text = _("OnyxSync companion app is outdated (v" .. vc .. ").\nPlease update to at least v" .. MIN_VERSION_CODE .. "."),
                ok_text = _("Download update"),
                cancel_text = _("Dismiss"),
                ok_callback = function()
                    Device:openLink(COMPANION_RELEASES_URL)
                end,
            })
            return
        end
    end

    self.ui.menu:registerToMainMenu(self)
end

local PUT_EXTRA_SIGNATURES = {
    string = "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;",
    long   = "(Ljava/lang/String;J)Landroid/content/Intent;",
    int    = "(Ljava/lang/String;I)Landroid/content/Intent;",
}

-- Sends a broadcast to the companion app.
-- extras: list of { key, type, value } where type is "string", "long" or "int"
local function sendBroadcast(action, extras)
    local ok, android = pcall(require, "android")
    if not ok or not android or not android.app or not android.app.activity then
        logger.err("OnyxSync: Android module not available")
        return false
    end

    local status, result = pcall(function()
        return android.jni:context(android.app.activity.vm, function(jni)
            local env = jni.env
            if env[0].PushLocalFrame(env, 8 + 2 * #extras) ~= 0 then
                logger.err("OnyxSync: PushLocalFrame failed for", action)
                return false
            end

            local sent, err = pcall(function()
                local activity = android.app.activity.clazz
                local intent_class = env[0].FindClass(env, "android/content/Intent")
                local intent_init = env[0].GetMethodID(env, intent_class, "<init>", "(Ljava/lang/String;)V")
                local intent = env[0].NewObject(env, intent_class, intent_init, env[0].NewStringUTF(env, action))

                local set_package = env[0].GetMethodID(env, intent_class, "setPackage",
                    "(Ljava/lang/String;)Landroid/content/Intent;")
                env[0].CallObjectMethod(env, intent, set_package, env[0].NewStringUTF(env, COMPANION_PACKAGE))

                for _, extra in ipairs(extras) do
                    local key, kind, value = extra[1], extra[2], extra[3]
                    local put_extra = env[0].GetMethodID(env, intent_class, "putExtra", PUT_EXTRA_SIGNATURES[kind])
                    local jvalue
                    if kind == "string" then
                        jvalue = env[0].NewStringUTF(env, value or "")
                    elseif kind == "long" then
                        jvalue = ffi.cast("jlong", value)
                    else
                        jvalue = ffi.cast("jint", value)
                    end
                    env[0].CallObjectMethod(env, intent, put_extra, env[0].NewStringUTF(env, key), jvalue)
                end

                local activity_class = env[0].GetObjectClass(env, activity)
                local send_broadcast = env[0].GetMethodID(env, activity_class, "sendBroadcast",
                    "(Landroid/content/Intent;)V")
                env[0].CallVoidMethod(env, activity, send_broadcast, intent)

                if env[0].ExceptionCheck(env) ~= 0 then
                    env[0].ExceptionClear(env)
                    error("Java exception while sending " .. action)
                end
            end)

            env[0].PopLocalFrame(env, nil)

            if not sent then
                logger.warn("OnyxSync: Failed to send", action, ":", tostring(err))
            end
            return sent
        end)
    end)

    if not status then
        logger.err("OnyxSync: JNI context error:", tostring(result))
        return false
    end
    return result
end

local function updateOnyxProgress(path, progress, timestamp, reading_status, title)
    return sendBroadcast("org.koreader.onyx.SYNC_PROGRESS", {
        { "path", "string", path },
        { "progress", "string", progress },
        { "timestamp", "long", timestamp },
        { "readingStatus", "int", reading_status },
        { "title", "string", title },
    })
end

local JSON_ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\",
    ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

-- Encodes a Lua value as a quoted JSON string
local function jsonString(value)
    local escaped = tostring(value or ""):gsub('[%c"\\]', function(c)
        return JSON_ESCAPES[c] or string.format("\\u%04x", c:byte())
    end)
    return '"' .. escaped .. '"'
end

local function updateOnyxProgressBatch(book_data)
    local entries = {}
    for i, book in ipairs(book_data) do
        entries[i] = string.format(
            '{"path":%s,"progress":%s,"timestamp":%d,"readingStatus":%d,"md5":%s,"title":%s}',
            jsonString(book.path),
            jsonString(book.progress),
            book.timestamp,
            book.reading_status,
            jsonString(book.md5),
            jsonString(book.title)
        )
    end
    local sent = sendBroadcast("org.koreader.onyx.BULK_SYNC", {
        { "bookData", "string", "[" .. table.concat(entries, ",") .. "]" },
    })
    if sent then
        logger.info("OnyxSync: Bulk intent sent with", #book_data, "books")
    end
    return sent
end

local function notifyPageTurn(path, md5, title)
    return sendBroadcast("org.koreader.onyx.PAGE_TURN", {
        { "book_path", "string", path },
        { "md5", "string", md5 },
        { "title", "string", title },
    })
end

function OnyxSync:doSync()
    if not self.ui or not self.ui.document or not self.view or not Device:isAndroid() then return end

    local curr_page = self.view.state.page or 1
    self.last_synced_page = curr_page
    local flow = self.ui.document:getPageFlow(curr_page)
    if flow ~= 0 then return end

    local total_in_flow = self.ui.document:getTotalPagesInFlow(flow)
    local page_in_flow = self.ui.document:getPageNumberInFlow(curr_page)

    local summary = self.ui.doc_settings:readSetting("summary")
    local status = summary and summary.status
    local reading_status = (status == "complete" or page_in_flow == total_in_flow) and 2 or 1

    local progress = page_in_flow .. "/" .. total_in_flow
    local timestamp = os.time() * 1000
    local title = self.ui.doc_props.display_title

    updateOnyxProgress(self.ui.document.file, progress, timestamp, reading_status, title)
end

-- Returns the current book info needed by the PAGE_TURN intent, or nil when no document is open
function OnyxSync:getPageTurnInfo()
    if not self.ui or not self.ui.document or not Device:isAndroid() then return end
    local path = self.ui.document.file
    -- Prefer the checksum cached in doc settings: the statistics plugin keys its
    -- book rows on it, and it no longer matches the file once the file changes
    local md5 = self.ui.doc_settings:readSetting("partial_md5_checksum") or util.partialMD5(path)
    return path, md5, self.ui.doc_props and self.ui.doc_props.display_title
end

-- The statistics plugin keeps page stats in memory and only writes them to its
-- DB periodically. Force a write so the companion app reads up-to-date data.
function OnyxSync:flushStatistics()
    local statistics = self.ui and self.ui.statistics
    if statistics and statistics.insertDB then
        local ok, err = pcall(statistics.insertDB, statistics)
        if not ok then
            logger.warn("OnyxSync: Failed to flush statistics:", tostring(err))
        end
    end
end

function OnyxSync:onPageUpdate()
    local path, md5, title = self:getPageTurnInfo()
    if not path then return end

    notifyPageTurn(path, md5, title)

    local curr_page = self.view.state.page or 1
    if math.abs(curr_page - self.last_synced_page) >= 5 then
        self:scheduleSync()
    end
end

function OnyxSync:scheduleSync()
    UIManager:unschedule(self.doSync)
    UIManager:scheduleIn(3, self.doSync, self)
end

function OnyxSync:immediateSync()
    UIManager:unschedule(self.doSync)
    self:doSync()
end

function OnyxSync:onCloseDocument()
    self:immediateSync()
    -- Statistics plugin writes its DB in its own onCloseDocument, which runs after ours:
    -- send the page turn intent on next tick so the companion app sees the final stats.
    local path, md5, title = self:getPageTurnInfo()
    if path then
        UIManager:nextTick(function()
            notifyPageTurn(path, md5, title)
        end)
    end
end

function OnyxSync:onSuspend()
    self:immediateSync()
    -- Going to the home screen suspends KOReader: flush stats and push them to Onyx now
    local path, md5, title = self:getPageTurnInfo()
    if path then
        self:flushStatistics()
        notifyPageTurn(path, md5, title)
    end
end

function OnyxSync:onEndOfBook()
    logger.info("OnyxSync: End of book reached")
    self:immediateSync()
end

-- Formats progress as "page/total" like doSync, falling back to a percentage
-- when the book's page count is unknown
local function formatProgress(percent_finished, doc_pages)
    if doc_pages and doc_pages > 0 then
        return string.format("%d/%d", math.floor(percent_finished * doc_pages + 0.5), doc_pages)
    end
    return string.format("%.0f/100", percent_finished * 100)
end

local function updateAllBooks()
    if not Device:isAndroid() then
        UIManager:show(InfoMessage:new {
            text = _("This feature is only available on Android devices"),
        })
        return
    end

    local lfs = require("libs/libkoreader-lfs")
    local FileManager = require("apps/filemanager/filemanager")

    local start_dir = FileManager.instance and FileManager.instance.file_chooser and
        FileManager.instance.file_chooser.path or lfs.currentdir()

    logger.info("OnyxSync: Scanning directory =", start_dir)

    if not start_dir or lfs.attributes(start_dir, "mode") ~= "directory" then
        UIManager:show(InfoMessage:new { text = _("Could not access current directory") })
        return
    end

    UIManager:show(InfoMessage:new { text = _("Scanning for books..."), timeout = 2 })

    local book_files = {}
    local supported_formats = {
        -- Ebooks
        epub = true,
        mobi = true,
        fb2  = true,
        pdb  = true,
        doc  = true,
        rtf  = true,
        chm  = true,
        -- Documents
        pdf  = true,
        djvu = true,
        xps  = true,
        -- Comics
        cbz  = true,
        cbt  = true,
        cbr  = true
    }
    for entry in lfs.dir(start_dir) do
        if entry ~= "." and entry ~= ".." then
            local full_path = start_dir .. "/" .. entry
            local attr = lfs.attributes(full_path)
            if attr and attr.mode == "file" then
                local ext = entry:match("%.([^%.]+)$")
                if ext and supported_formats[ext:lower()] then
                    table.insert(book_files, full_path)
                end
            end
        end
    end

    logger.info("OnyxSync: Total books found:", #book_files)

    if #book_files == 0 then
        UIManager:show(InfoMessage:new { text = _("No books found in current directory") })
        return
    end

    UIManager:show(InfoMessage:new { text = _("Preparing book data..."), timeout = 2 })

    local book_data = {}
    for i, path in ipairs(book_files) do
        local prep_ok, prep_err = pcall(function()
            -- No sidecar means KOReader knows nothing about this book: leave its
            -- Onyx progress alone (it may have been read in the Onyx reader)
            if not DocSettings:hasSidecarFile(path) then return end
            local doc_settings = DocSettings:open(path)
            if not doc_settings then return end

            local summary = doc_settings:readSetting("summary")
            local percent_finished = doc_settings:readSetting("percent_finished")
            local doc_pages = doc_settings:readSetting("doc_pages")
            local props = doc_settings:readSetting("doc_props")
            local title = (props and (props.title or props.display_title))
                or ""

            local timestamp = os.time() * 1000
            if summary and summary.modified then
                -- parse "YYYY-MM-DD" into a timestamp
                local y, m, d = summary.modified:match("(%d+)-(%d+)-(%d+)")
                if y then
                    timestamp = os.time({ year = y, month = m, day = d, hour = 12, min = 0, sec = 0 }) * 1000
                end
            end
            local reading_status = 0
            local progress = "0/1"

            if summary then
                if summary.status == "complete" then
                    reading_status = 2
                    progress = "1/1"
                elseif summary.status == "reading" then
                    reading_status = 1
                    if percent_finished then
                        progress = formatProgress(percent_finished, doc_pages)
                    end
                end
            elseif percent_finished and percent_finished > 0 then
                reading_status = 1
                progress = formatProgress(percent_finished, doc_pages)
            end

            table.insert(book_data, {
                path = path,
                progress = progress,
                timestamp = timestamp,
                reading_status = reading_status,
                md5 = doc_settings:readSetting("partial_md5_checksum") or util.partialMD5(path),
                title = title or "",
            })

            doc_settings:close()
        end)

        if not prep_ok then
            logger.err("OnyxSync: Error preparing book", i, ":", tostring(prep_err))
        end
    end

    logger.info("OnyxSync: Prepared data for", #book_data, "books")

    if #book_data == 0 then
        UIManager:show(InfoMessage:new { text = _("Could not prepare book data") })
        return
    end

    UIManager:show(InfoMessage:new { text = _("Updating Onyx metadata..."), timeout = 2 })

    updateOnyxProgressBatch(book_data)

    UIManager:show(InfoMessage:new {
        text = string.format(_("Updated all books")),
        timeout = 3,
    })

    logger.info("OnyxSync: Bulk update completed")
end

function OnyxSync:addToMainMenu(menu_items)
    if self.ui.document then return end

    menu_items.onyx_sync = {
        text = _("Onyx Progress Sync"),
        sub_item_table = {
            {
                text = _("Scan and update all books in current directory"),
                keep_menu_open = true,
                callback = function()
                    updateAllBooks()
                end,
            },
        },
    }
end

return OnyxSync
