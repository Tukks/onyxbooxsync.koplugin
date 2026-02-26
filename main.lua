local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local Device = require("device")
local logger = require("logger")
local ffi = require("ffi")
local DocSettings = require("docsettings")
local ReadHistory = require("readhistory")
local _ = require("gettext")
local ConfirmBox = require("ui/widget/confirmbox")
local util = require("util")
local MIN_VERSION_CODE = 2 -- minimum required versionCode
local JNI_CACHE = {
    initialized = false,
    cv_class = nil,
    cv_init = nil,
    put_string = nil,
    put_int = nil,
    put_long = nil,
}

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

                local pkg_str = env[0].NewStringUTF(env, "org.koreader.backgroundonyxsynckoreader")
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
                    Device:openLink("https://github.com/Tukks/onyxbooxsync.koplugin/releases/latest")
                end,
            })
            return
        elseif vc < MIN_VERSION_CODE then
            UIManager:show(ConfirmBox:new {
                text = _("OnyxSync companion app is outdated (v" .. vc .. ").\nPlease update to at least v" .. MIN_VERSION_CODE .. "."),
                ok_text = _("Download update"),
                cancel_text = _("Dismiss"),
                ok_callback = function()
                    Device:openLink("https://github.com/Tukks/onyxbooxsync.koplugin/releases/latest")
                end,
            })
            return
        end
    end

    self.ui.menu:registerToMainMenu(self)
end

local function invalidateJniCache(jni)
    if JNI_CACHE.cv_class ~= nil and jni then
        local env = jni.env
        pcall(function()
            env[0].DeleteGlobalRef(env, JNI_CACHE.cv_class)
        end)
    end
    JNI_CACHE.cv_class = nil
    JNI_CACHE.cv_init = nil
    JNI_CACHE.put_string = nil
    JNI_CACHE.put_int = nil
    JNI_CACHE.put_long = nil
    JNI_CACHE.initialized = false
    logger.info("OnyxSync: JNI cache invalidated")
end

local function ensureJniCache(jni)
    if JNI_CACHE.initialized then return true end

    local env = jni.env

    if JNI_CACHE.cv_class ~= nil then
        pcall(function()
            env[0].DeleteGlobalRef(env, JNI_CACHE.cv_class)
        end)
        JNI_CACHE.cv_class = nil
    end

    local local_cv_class = env[0].FindClass(env, "android/content/ContentValues")
    if local_cv_class == nil then
        logger.err("OnyxSync: Failed to find ContentValues class")
        return false
    end

    JNI_CACHE.cv_class = env[0].NewGlobalRef(env, local_cv_class)
    env[0].DeleteLocalRef(env, local_cv_class)

    JNI_CACHE.cv_init    = env[0].GetMethodID(env, JNI_CACHE.cv_class, "<init>", "()V")
    JNI_CACHE.put_string = env[0].GetMethodID(env, JNI_CACHE.cv_class, "put", "(Ljava/lang/String;Ljava/lang/String;)V")
    JNI_CACHE.put_int    = env[0].GetMethodID(env, JNI_CACHE.cv_class, "put", "(Ljava/lang/String;Ljava/lang/Integer;)V")
    JNI_CACHE.put_long   = env[0].GetMethodID(env, JNI_CACHE.cv_class, "put", "(Ljava/lang/String;Ljava/lang/Long;)V")

    if not JNI_CACHE.cv_init or not JNI_CACHE.put_string or not JNI_CACHE.put_int or not JNI_CACHE.put_long then
        logger.err("OnyxSync: Failed to resolve one or more JNI method IDs")
        invalidateJniCache(jni)
        return false
    end

    JNI_CACHE.initialized = true
    logger.info("OnyxSync: JNI Cache initialized")
    return true
end
local function sendSyncIntent(jni, android, path, progress, timestamp, reading_status)
    local env = jni.env

    if env[0].PushLocalFrame(env, 20) ~= 0 then
        logger.err("OnyxSync: PushLocalFrame failed for intent")
        return false
    end

    local intent_ok, intent_err = pcall(function()
        local activity = android.app.activity.clazz

        -- Create Intent class and constructor
        local intent_class = env[0].FindClass(env, "android/content/Intent")
        local intent_init = env[0].GetMethodID(env, intent_class, "<init>", "(Ljava/lang/String;)V")

        -- Create action string
        local action_str = env[0].NewStringUTF(env, "org.koreader.onyx.SYNC_PROGRESS")

        -- Create new Intent with action
        local intent = env[0].NewObject(env, intent_class, intent_init, action_str)

        -- Get setPackage method
        local set_package_method = env[0].GetMethodID(env, intent_class, "setPackage",
            "(Ljava/lang/String;)Landroid/content/Intent;")

        -- Set the target package
        local package_str = env[0].NewStringUTF(env, "org.koreader.backgroundonyxsynckoreader")
        env[0].CallObjectMethod(env, intent, set_package_method, package_str)

        -- Get putExtra methods
        local put_extra_string = env[0].GetMethodID(env, intent_class, "putExtra",
            "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;")
        local put_extra_long = env[0].GetMethodID(env, intent_class, "putExtra",
            "(Ljava/lang/String;J)Landroid/content/Intent;")
        local put_extra_int = env[0].GetMethodID(env, intent_class, "putExtra",
            "(Ljava/lang/String;I)Landroid/content/Intent;")

        -- Add string extras
        local path_key = env[0].NewStringUTF(env, "path")
        local path_val = env[0].NewStringUTF(env, path)
        env[0].CallObjectMethod(env, intent, put_extra_string, path_key, path_val)

        local progress_key = env[0].NewStringUTF(env, "progress")
        local progress_val = env[0].NewStringUTF(env, progress)
        env[0].CallObjectMethod(env, intent, put_extra_string, progress_key, progress_val)

        -- Add long extra for timestamp
        local timestamp_key = env[0].NewStringUTF(env, "timestamp")
        env[0].CallObjectMethod(env, intent, put_extra_long, timestamp_key, ffi.cast("jlong", timestamp))

        -- Add int extra for reading status
        local status_key = env[0].NewStringUTF(env, "readingStatus")
        env[0].CallObjectMethod(env, intent, put_extra_int, status_key, ffi.cast("jint", reading_status))

        -- Get Activity class and sendBroadcast method
        local activity_class = env[0].GetObjectClass(env, activity)
        local send_broadcast = env[0].GetMethodID(env, activity_class, "sendBroadcast",
            "(Landroid/content/Intent;)V")

        -- Send the broadcast
        env[0].CallVoidMethod(env, activity, send_broadcast, intent)

        logger.info("OnyxSync: Intent sent to background service")
    end)

    env[0].PopLocalFrame(env, nil)

    if not intent_ok then
        logger.warn("OnyxSync: Failed to send intent:", tostring(intent_err))
    end

    return intent_ok
end

-- Send bulk sync intent
local function sendBulkSyncIntent(jni, android, book_data)
    local env = jni.env

    if env[0].PushLocalFrame(env, 20) ~= 0 then
        logger.err("OnyxSync: PushLocalFrame failed for bulk intent")
        return false
    end

    local intent_ok, intent_err = pcall(function()
        local activity = android.app.activity.clazz

        -- Create Intent class and constructor
        local intent_class = env[0].FindClass(env, "android/content/Intent")
        local intent_init = env[0].GetMethodID(env, intent_class, "<init>", "(Ljava/lang/String;)V")

        -- Create action string
        local action_str = env[0].NewStringUTF(env, "org.koreader.onyx.BULK_SYNC")

        -- Create new Intent with bulk sync action
        local intent = env[0].NewObject(env, intent_class, intent_init, action_str)

        -- Get setPackage method
        local set_package_method = env[0].GetMethodID(env, intent_class, "setPackage",
            "(Ljava/lang/String;)Landroid/content/Intent;")

        -- Set the target package
        local package_str = env[0].NewStringUTF(env, "org.koreader.backgroundonyxsynckoreader")
        env[0].CallObjectMethod(env, intent, set_package_method, package_str)

        -- Convert book_data to JSON string for bulk transfer
        local json_data = "["
        for i, book in ipairs(book_data) do
            if i > 1 then json_data = json_data .. "," end
            json_data = json_data .. string.format(
                '{"path":"%s","progress":"%s","timestamp":%d,"readingStatus":%d}',
                book.path:gsub('"', '\\"'):gsub("\\", "\\\\"), -- Escape quotes and backslashes
                book.progress,
                book.timestamp,
                book.reading_status
            )
        end
        json_data = json_data .. "]"

        -- Get putExtra method for strings
        local put_extra_string = env[0].GetMethodID(env, intent_class, "putExtra",
            "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;")

        -- Add JSON data as string extra
        local data_key = env[0].NewStringUTF(env, "bookData")
        local data_val = env[0].NewStringUTF(env, json_data)
        env[0].CallObjectMethod(env, intent, put_extra_string, data_key, data_val)

        -- Get Activity class and sendBroadcast method
        local activity_class = env[0].GetObjectClass(env, activity)
        local send_broadcast = env[0].GetMethodID(env, activity_class, "sendBroadcast",
            "(Landroid/content/Intent;)V")

        -- Send the broadcast
        env[0].CallVoidMethod(env, activity, send_broadcast, intent)

        logger.info("OnyxSync: Bulk intent sent with", #book_data, "books")
    end)

    env[0].PopLocalFrame(env, nil)

    if not intent_ok then
        logger.warn("OnyxSync: Failed to send bulk intent:", tostring(intent_err))
    end

    return intent_ok
end


local function updateOnyxProgress(path, progress, timestamp, reading_status)
    local ok, android = pcall(require, "android")
    if not ok or not android or not android.app or not android.app.activity then
        logger.err("OnyxSync: Android module not available")
        return 0
    end

    local status, result = pcall(function()
        return android.jni:context(android.app.activity.vm, function(jni)
            JNI_CACHE.initialized = false
            if not ensureJniCache(jni) then return -1 end
            return sendSyncIntent(jni, android, path, progress, timestamp, reading_status)
        end)
    end)

    if not status then
        logger.err("OnyxSync: JNI context error:", tostring(result))
        JNI_CACHE.initialized = false
        return -1
    end

    return result or 0
end

local function updateOnyxProgressBatch(book_data)
    local ok, android = pcall(require, "android")
    if not ok or not android or not android.app or not android.app.activity then
        logger.err("OnyxSync: Android module not available")
        return 0, 0
    end


    local status, err = pcall(function()
        android.jni:context(android.app.activity.vm, function(jni)
            if not ensureJniCache(jni) then
                logger.err("OnyxSync: JNI cache initialization failed")
                return
            end

            sendBulkSyncIntent(jni, android, book_data)
            -- for i, book in ipairs(book_data) do
            -- updateOnyxProgress(book.path, book.progress, book.timestamp, book.reading_status)
            -- end
        end)
    end)

    if not status then
        logger.err("OnyxSync: Batch JNI error:", tostring(err))
        JNI_CACHE.initialized = false
    end
end

function OnyxSync:doSync()
    if not self.ui or not self.ui.document or not self.view or not Device:isAndroid() then return end

    local curr_page = self.view.state.page or 1
    local flow = self.ui.document:getPageFlow(curr_page)
    if flow ~= 0 then return end

    local total_in_flow = self.ui.document:getTotalPagesInFlow(flow)
    local page_in_flow = self.ui.document:getPageNumberInFlow(curr_page)

    local summary = self.ui.doc_settings:readSetting("summary")
    local status = summary and summary.status
    local reading_status = (status == "complete" or page_in_flow == total_in_flow) and 2 or 1

    local progress = page_in_flow .. "/" .. total_in_flow
    local timestamp = os.time() * 1000

    updateOnyxProgress(self.ui.document.file, progress, timestamp, reading_status)
end

local function sendPageTurnIntent(jni, android, path, md5, title)
    local env = jni.env

    if env[0].PushLocalFrame(env, 20) ~= 0 then
        return false
    end

    local ok = pcall(function()
        local activity = android.app.activity.clazz

        local intent_class = env[0].FindClass(env, "android/content/Intent")
        local intent_init = env[0].GetMethodID(env, intent_class, "<init>", "(Ljava/lang/String;)V")

        local action_str = env[0].NewStringUTF(env, "org.koreader.onyx.PAGE_TURN")
        local intent = env[0].NewObject(env, intent_class, intent_init, action_str)

        local set_package = env[0].GetMethodID(env, intent_class, "setPackage",
            "(Ljava/lang/String;)Landroid/content/Intent;")

        local package_str = env[0].NewStringUTF(env, "org.koreader.backgroundonyxsynckoreader")
        env[0].CallObjectMethod(env, intent, set_package, package_str)

        local put_extra_string = env[0].GetMethodID(env, intent_class, "putExtra",
            "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;")

        -- Extras attendus par ton onReceive Java
        env[0].CallObjectMethod(env, intent, put_extra_string,
            env[0].NewStringUTF(env, "book_path"),
            env[0].NewStringUTF(env, path))

        env[0].CallObjectMethod(env, intent, put_extra_string,
            env[0].NewStringUTF(env, "md5"),
            env[0].NewStringUTF(env, md5))

        env[0].CallObjectMethod(env, intent, put_extra_string,
            env[0].NewStringUTF(env, "title"),
            env[0].NewStringUTF(env, title or ""))

        local activity_class = env[0].GetObjectClass(env, activity)
        local send_broadcast = env[0].GetMethodID(env, activity_class,
            "sendBroadcast", "(Landroid/content/Intent;)V")

        env[0].CallVoidMethod(env, activity, send_broadcast, intent)
    end)

    env[0].PopLocalFrame(env, nil)
    return ok
end
function OnyxSync:onPageUpdate()
    local path = self.ui.document.file
    local md5 = util.partialMD5(self.ui.document.file)
    local title = path

    local ok, android = pcall(require, "android")
    if ok and android then
        android.jni:context(android.app.activity.vm, function(jni)
            sendPageTurnIntent(jni, android, path, md5, title)
        end)
    end

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
    JNI_CACHE.initialized = false
    logger.info("OnyxSync: Cache invalidated on document close")
end

function OnyxSync:onSuspend()
    logger.info("OnyxSync: Suspending - invalidating JNI cache")
    JNI_CACHE.initialized = false
    self:immediateSync()
end

function OnyxSync:onResume()
    logger.info("OnyxSync: Resuming - JNI cache will be rebuilt on next sync")
    JNI_CACHE.initialized = false
end

function OnyxSync:onEndOfBook()
    logger.info("OnyxSync: End of book reached")
    self:immediateSync()
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
    for entry in lfs.dir(start_dir) do
        if entry ~= "." and entry ~= ".." then
            local full_path = start_dir .. "/" .. entry
            local attr = lfs.attributes(full_path)
            if attr and attr.mode == "file" then
                local ext = entry:match("%.([^%.]+)$")
                if ext and (ext:lower() == "epub" or ext:lower() == "pdf") then
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
            local doc_settings = DocSettings:open(path)
            if not doc_settings then return end

            local summary = doc_settings:readSetting("summary")
            local percent_finished = doc_settings:readSetting("percent_finished")

            local timestamp = os.time() * 1000
            local history_ok, history_item = pcall(ReadHistory.getFileLastRead, ReadHistory, path)
            if history_ok and history_item and history_item.time then
                timestamp = history_item.time * 1000
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
                        progress = string.format("%.0f/100", percent_finished * 100)
                    end
                end
            elseif percent_finished and percent_finished > 0 then
                reading_status = 1
                progress = string.format("%.0f/100", percent_finished * 100)
            end

            table.insert(book_data, {
                path = path,
                progress = progress,
                timestamp = timestamp,
                reading_status = reading_status,
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

    JNI_CACHE.initialized = false
    logger.info("OnyxSync: Invalidated cache before batch update")

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
