local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local Device = require("device")
local logger = require("logger")
local ffi = require("ffi")
local DocSettings = require("docsettings")
local ReadHistory = require("readhistory")
local _ = require("gettext")

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

function OnyxSync:init()
    logger.info("OnyxSync: Plugin initialized")
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

    JNI_CACHE.cv_init     = env[0].GetMethodID(env, JNI_CACHE.cv_class, "<init>", "()V")
    JNI_CACHE.put_string  = env[0].GetMethodID(env, JNI_CACHE.cv_class, "put", "(Ljava/lang/String;Ljava/lang/String;)V")
    JNI_CACHE.put_int     = env[0].GetMethodID(env, JNI_CACHE.cv_class, "put", "(Ljava/lang/String;Ljava/lang/Integer;)V")
    JNI_CACHE.put_long    = env[0].GetMethodID(env, JNI_CACHE.cv_class, "put", "(Ljava/lang/String;Ljava/lang/Long;)V")

    if not JNI_CACHE.cv_init or not JNI_CACHE.put_string or not JNI_CACHE.put_int or not JNI_CACHE.put_long then
        logger.err("OnyxSync: Failed to resolve one or more JNI method IDs")
        invalidateJniCache(jni)
        return false
    end

    JNI_CACHE.initialized = true
    logger.info("OnyxSync: JNI Cache initialized")
    return true
end

-- Build ContentValues for a book update
local function buildContentValues(jni, progress, timestamp, reading_status)
    local env = jni.env

    local values = env[0].NewObject(env, JNI_CACHE.cv_class, JNI_CACHE.cv_init)

    local key_status = env[0].NewStringUTF(env, "readingStatus")
    local status_val = jni:callStaticObjectMethod("java/lang/Integer", "valueOf",
        "(I)Ljava/lang/Integer;", ffi.new("int32_t", reading_status))
    env[0].CallVoidMethod(env, values, JNI_CACHE.put_int, key_status, status_val)

    if reading_status ~= 0 then
        if progress then
            local k = env[0].NewStringUTF(env, "progress")
            local v = env[0].NewStringUTF(env, progress)
            env[0].CallVoidMethod(env, values, JNI_CACHE.put_string, k, v)
        end
        if timestamp then
            local k = env[0].NewStringUTF(env, "lastAccess")
            local v = jni:callStaticObjectMethod("java/lang/Long", "valueOf",
                "(J)Ljava/lang/Long;", ffi.new("int64_t", timestamp))
            env[0].CallVoidMethod(env, values, JNI_CACHE.put_long, k, v)
        end
    else
        local k1 = env[0].NewStringUTF(env, "progress")
        env[0].CallVoidMethod(env, values, JNI_CACHE.put_string, k1, nil)
        local k2 = env[0].NewStringUTF(env, "lastAccess")
        env[0].CallVoidMethod(env, values, JNI_CACHE.put_long, k2, nil)
    end

    return values
end

-- Acquire a fresh ContentProviderClient, perform the update, then close it.
-- This bypasses any cached dead Binder proxy in ContentResolver.
local function updateOneBook(jni, android, path, progress, timestamp, reading_status)
    local env = jni.env

    if env[0].PushLocalFrame(env, 32) ~= 0 then
        logger.err("OnyxSync: PushLocalFrame failed")
        return -1
    end

    local rows = -1
    local ok, err = pcall(function()
        local activity = android.app.activity.clazz

        -- Get Application context for stability
        local context = jni:callObjectMethod(activity, "getApplicationContext",
            "()Landroid/content/Context;")
        if not context then
            context = activity
        end

        local resolver = jni:callObjectMethod(context, "getContentResolver",
            "()Landroid/content/ContentResolver;")
        if not resolver then
            logger.err("OnyxSync: Failed to get ContentResolver")
            return
        end

        -- Parse the provider URI
        local uri_str = env[0].NewStringUTF(env,
            "content://com.onyx.content.database.ContentProvider/Metadata")
        local uri = jni:callStaticObjectMethod("android/net/Uri", "parse",
            "(Ljava/lang/String;)Landroid/net/Uri;", uri_str)

        -- Acquire a fresh, unstable ContentProviderClient.
        -- "Unstable" means if the provider process dies, our process won't be killed too.
        -- More importantly, this creates a NEW Binder connection each time.
        local client = jni:callObjectMethod(resolver, "acquireUnstableContentProviderClient",
            "(Landroid/net/Uri;)Landroid/content/ContentProviderClient;", uri)

        if not client then
            logger.err("OnyxSync: Failed to acquire ContentProviderClient — provider may be unavailable")
            return
        end

        local update_ok, update_err = pcall(function()
            local escaped_path = path:gsub("'", "''")
            local where_string = env[0].NewStringUTF(env,
                "nativeAbsolutePath='" .. escaped_path .. "'")

            local values = buildContentValues(jni, progress, timestamp, reading_status)

            -- ContentProviderClient.update(Uri, ContentValues, String, String[])
            rows = jni:callIntMethod(client, "update",
                "(Landroid/net/Uri;Landroid/content/ContentValues;Ljava/lang/String;[Ljava/lang/String;)I",
                uri, values, where_string, nil)

            if env[0].ExceptionCheck(env) ~= 0 then
                logger.err("OnyxSync: Java exception during client.update()")
                env[0].ExceptionDescribe(env)
                env[0].ExceptionClear(env)
                rows = -1
            end
        end)

        -- ALWAYS close the client to release the Binder connection
        local close_ok, close_err = pcall(function()
            -- API 24+: close(), older: release()
            -- Try close() first, fall back to release()
            local has_close = env[0].GetMethodID(env,
                env[0].GetObjectClass(env, client), "close", "()V")

            if env[0].ExceptionCheck(env) ~= 0 then
                env[0].ExceptionClear(env)
                has_close = nil
            end

            if has_close then
                env[0].CallVoidMethod(env, client, has_close)
            else
                jni:callVoidMethod(client, "release", "()V")
            end

            if env[0].ExceptionCheck(env) ~= 0 then
                env[0].ExceptionClear(env)
            end

            logger.dbg("OnyxSync: ContentProviderClient closed")
        end)

        if not close_ok then
            logger.warn("OnyxSync: Error closing ContentProviderClient:", tostring(close_err))
        end

        if not update_ok then
            logger.err("OnyxSync: Update pcall error:", tostring(update_err))
            rows = -1
        end
    end)

    env[0].PopLocalFrame(env, nil)

    if not ok then
        logger.err("OnyxSync: updateOneBook pcall error:", tostring(err))
        return -1
    end

    return rows
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
            return updateOneBook(jni, android, path, progress, timestamp, reading_status)
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

    local updated_count = 0
    local skipped_count = 0

    local status, err = pcall(function()
        android.jni:context(android.app.activity.vm, function(jni)
            if not ensureJniCache(jni) then
                logger.err("OnyxSync: JNI cache initialization failed")
                return
            end

            for i, book in ipairs(book_data) do
                local rows = updateOneBook(jni, android,
                    book.path, book.progress, book.timestamp, book.reading_status)

                if rows > 0 then
                    updated_count = updated_count + 1
                    logger.info("OnyxSync: ✓ Updated book", i, "of", #book_data)
                else
                    skipped_count = skipped_count + 1
                    logger.warn("OnyxSync: ✗ Failed book", i, "of", #book_data, "rows =", rows)
                end
            end
        end)
    end)

    if not status then
        logger.err("OnyxSync: Batch JNI error:", tostring(err))
        JNI_CACHE.initialized = false
    end

    return updated_count, skipped_count
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

    local rows = updateOnyxProgress(self.ui.document.file, progress, timestamp, reading_status)
    if rows > 0 then
        self.last_synced_page = curr_page
        logger.info("OnyxSync: Progress updated (" .. progress .. ")")
    elseif rows == 0 then
        logger.warn("OnyxSync: No rows updated (book not in Onyx database?)")
    else
        logger.err("OnyxSync: Update failed")
    end
end

function OnyxSync:onPageUpdate()
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

    local updated_count, skipped_count = updateOnyxProgressBatch(book_data)

    UIManager:show(InfoMessage:new {
        text = string.format(_("Updated %d books, skipped %d"), updated_count, skipped_count),
        timeout = 3,
    })

    logger.info("OnyxSync: Bulk update completed - updated:", updated_count, "skipped:", skipped_count)
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