local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local Device = require("device")
local logger = require("logger")
local ffi = require("ffi")
local DocSettings = require("docsettings")
local ReadHistory = require("readhistory")
local _ = require("gettext")

-- Table de cache globale pour les IDs JNI (évite les fuites de mémoire et lenteurs)
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

    local ok, android = pcall(require, "android")
    if ok then
        self.android = android
        logger.info("OnyxSync: Android module loaded")
    else
        logger.err("OnyxSync: Cannot load android module")
    end
end

-- Initialise et garde en mémoire les méthodes Java pour gagner en performance
function OnyxSync:ensureJniCache(jni)
    if JNI_CACHE.initialized then return end

    local env = jni.env
    -- On crée une GlobalRef pour la classe car les local refs expirent
    local local_cv_class = env[0].FindClass(env, "android/content/ContentValues")
    JNI_CACHE.cv_class = env[0].NewGlobalRef(env, local_cv_class)
    env[0].DeleteLocalRef(env, local_cv_class)

    -- Les MethodIDs sont stables, pas besoin de GlobalRef
    JNI_CACHE.cv_init = env[0].GetMethodID(env, JNI_CACHE.cv_class, "<init>", "()V")
    JNI_CACHE.put_string = env[0].GetMethodID(env, JNI_CACHE.cv_class, "put", "(Ljava/lang/String;Ljava/lang/String;)V")
    JNI_CACHE.put_int = env[0].GetMethodID(env, JNI_CACHE.cv_class, "put", "(Ljava/lang/String;Ljava/lang/Integer;)V")
    JNI_CACHE.put_long = env[0].GetMethodID(env, JNI_CACHE.cv_class, "put", "(Ljava/lang/String;Ljava/lang/Long;)V")

    JNI_CACHE.initialized = true
    logger.info("OnyxSync: JNI Cache initialized")
end

function OnyxSync:updateOnyxProgress(path, progress, timestamp, reading_status)
    if not self.android or not self.android.app or not self.android.app.activity then
        return 0, "Android module not available"
    end

    local max_retries = 2
    local attempt = 0
    local final_rows = 0
    local success = false

    while attempt <= max_retries and not success do
        attempt = attempt + 1
        local status, result = pcall(function()
            return self.android.jni:context(self.android.app.activity.vm, function(jni)
                self:ensureJniCache(jni)
                local env = jni.env
                local activity = self.android.app.activity.clazz

                local function delete_local(ref)
                    if ref ~= nil then env[0].DeleteLocalRef(env, ref) end
                end

                -- Content Resolver & URI
                local resolver = jni:callObjectMethod(activity, "getContentResolver", "()Landroid/content/ContentResolver;")
                local uri_str = env[0].NewStringUTF(env, "content://com.onyx.content.database.ContentProvider/Metadata")
                local uri = jni:callStaticObjectMethod("android/net/Uri", "parse", "(Ljava/lang/String;)Landroid/net/Uri;", uri_str)

                -- WHERE clause
                local escaped_path = path:gsub("'", "''")
                local where_clause = "nativeAbsolutePath='" .. escaped_path .. "'"
                local where_string = env[0].NewStringUTF(env, where_clause)

                -- ContentValues instance
                local values = env[0].NewObject(env, JNI_CACHE.cv_class, JNI_CACHE.cv_init)

                -- Status
                local key_status = env[0].NewStringUTF(env, "readingStatus")
                local status_val = jni:callStaticObjectMethod("java/lang/Integer", "valueOf", "(I)Ljava/lang/Integer;", ffi.new("int32_t", reading_status))
                env[0].CallVoidMethod(env, values, JNI_CACHE.put_int, key_status, status_val)
                delete_local(key_status); delete_local(status_val)

                if reading_status ~= 0 then
                    if progress then
                        local k = env[0].NewStringUTF(env, "progress")
                        local v = env[0].NewStringUTF(env, progress)
                        env[0].CallVoidMethod(env, values, JNI_CACHE.put_string, k, v)
                        delete_local(k); delete_local(v)
                    end
                    if timestamp then
                        local k = env[0].NewStringUTF(env, "lastAccess")
                        local v = jni:callStaticObjectMethod("java/lang/Long", "valueOf", "(J)Ljava/lang/Long;", ffi.new("int64_t", timestamp))
                        env[0].CallVoidMethod(env, values, JNI_CACHE.put_long, k, v)
                        delete_local(k); delete_local(v)
                    end
                end

                -- Execute Update
                local rows = jni:callIntMethod(resolver, "update", "(Landroid/net/Uri;Landroid/content/ContentValues;Ljava/lang/String;[Ljava/lang/String;)I", uri, values, where_string, nil)

                -- Cleanup
                delete_local(uri_str); delete_local(uri); delete_local(values); delete_local(where_string); delete_local(resolver)
                return rows
            end)
        end)

        if status and result and result ~= -1 then
            success = true
            final_rows = result
        else
            logger.warn("OnyxSync: Attempt " .. attempt .. " failed. Service may be busy.")
            if attempt <= max_retries then ffi.C.usleep(150000) end -- Attendre 150ms
        end
    end

    return final_rows
end

function OnyxSync:doSync()
    if not self.ui or not self.ui.document or not self.view or not Device:isAndroid() then return end

    local curr_page = self.view.state.page or 1
    local total_pages = self.ui.document:getPageCount() or 1
    local flow = self.ui.document:getPageFlow(curr_page)
    
    if flow ~= 0 then return end -- Ne pas sync les notes de bas de page

    local total_in_flow = self.ui.document:getTotalPagesInFlow(flow)
    local page_in_flow = self.ui.document:getPageNumberInFlow(curr_page)

    local summary = self.ui.doc_settings:readSetting("summary")
    local status = summary and summary.status
    local reading_status = (status == "complete" or page_in_flow == total_in_flow) and 2 or 1
    
    local progress = page_in_flow .. "/" .. total_in_flow
    local timestamp = os.time() * 1000

    local rows = self:updateOnyxProgress(self.ui.document.file, progress, timestamp, reading_status)
    if rows > 0 then
        self.last_synced_page = curr_page
        logger.info("OnyxSync: Progress updated (" .. progress .. ")")
    end
end

function OnyxSync:onPageUpdate()
    local curr_page = self.view.state.page or 1
    -- Sync toutes les 5 pages minimum pour ne pas tuer le service Onyx
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

-- Events de fermeture
function OnyxSync:onCloseDocument() self:immediateSync() end
function OnyxSync:onSuspend() self:immediateSync() end
function OnyxSync:updateAllBooks()
    if not Device:isAndroid() then
        UIManager:show(InfoMessage:new {
            text = _("This feature is only available on Android devices"),
        })
        return
    end

    local lfs = require("libs/libkoreader-lfs")
    local FileManager = require("apps/filemanager/filemanager")

    local book_files = {}
    local start_dir = FileManager.instance and FileManager.instance.file_chooser and
        FileManager.instance.file_chooser.path or lfs.currentdir()

    logger.info("OnyxSync: Current directory =", start_dir)

    if not start_dir or lfs.attributes(start_dir, "mode") ~= "directory" then
        UIManager:show(InfoMessage:new {
            text = _("Could not access current directory"),
        })
        return
    end

    UIManager:show(InfoMessage:new {
        text = _("Scanning for books..."),
        timeout = 2,
    })

    -- Scan only current directory (no recursion)
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
        UIManager:show(InfoMessage:new {
            text = _("No books found in current directory"),
        })
        return
    end

    UIManager:show(InfoMessage:new {
        text = _("Preparing book data..."),
        timeout = 2,
    })

    -- Prepare all book data first
    local book_data = {}
    for i, path in ipairs(book_files) do
        local prep_ok, prep_err = pcall(function()
            local doc_settings = DocSettings:open(path)
            if not doc_settings then
                return
            end

            local summary = doc_settings:readSetting("summary")
            local percent_finished = doc_settings:readSetting("percent_finished")

            -- Get actual last read timestamp from history
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
                reading_status = reading_status
            })

            doc_settings:close()
        end)

        if not prep_ok then
            logger.err("OnyxSync: Error preparing book", i, ":", tostring(prep_err))
        end
    end

    logger.info("OnyxSync: Prepared data for", #book_data, "books")

    if #book_data == 0 then
        UIManager:show(InfoMessage:new {
            text = _("Could not prepare book data"),
        })
        return
    end

    UIManager:show(InfoMessage:new {
        text = _("Updating Onyx metadata..."),
        timeout = 2,
    })

    -- Update books sequentially with delays
    local updated_count = 0
    local skipped_count = 0

    for i, book in ipairs(book_data) do
        local rows = self:updateOnyxProgress(book.path, book.progress, book.timestamp, book.reading_status)

        if rows > 0 then
            updated_count = updated_count + 1
            logger.info("OnyxSync: ✓ Updated book", i, "of", #book_data)
        else
            skipped_count = skipped_count + 1
            logger.warn("OnyxSync: ✗ Failed to update book", i, "of", #book_data)
        end

        -- Small delay between updates
        if i < #book_data then
            ffi.C.usleep(50000) -- 50ms
        end

        -- GC every 10 books
        if i % 10 == 0 then
            collectgarbage("collect")
        end
    end

    UIManager:show(InfoMessage:new {
        text = string.format(_("Updated %d books, skipped %d"), updated_count, skipped_count),
        timeout = 3,
    })

    logger.info("OnyxSync: Bulk update completed - updated:", updated_count, "skipped:", skipped_count)
end

function OnyxSync:addToMainMenu(menu_items)
    -- Only show in file browser, not when a document is open
    if self.ui.document then
        return
    end

    menu_items.onyx_sync = {
        text = _("Onyx Progress Sync"),
        sub_item_table = {
            {
                text = _("Scan and update all books in current directory"),
                keep_menu_open = true,
                callback = function()
                    self:updateAllBooks()
                end,
            },
        },
    }
end

return OnyxSync