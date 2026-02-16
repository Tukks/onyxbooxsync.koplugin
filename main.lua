local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local Device = require("device")
local logger = require("logger")
local ffi = require("ffi")
local DocSettings = require("docsettings")
local ReadHistory = require("readhistory")
local _ = require("gettext")

local OnyxSync = WidgetContainer:extend {
    name = "onyx_sync",
    is_doc_only = false,
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

-- readingStatus (Integer): 0=NEW, 1=READING, 2=FINISHED
function OnyxSync:updateOnyxProgress(path, progress, timestamp, reading_status)
    if not self.android or not self.android.app or not self.android.app.activity then
        return 0, "Android module not available"
    end

    local status, result = pcall(function()
        return self.android.jni:context(self.android.app.activity.vm, function(jni)
            local env = jni.env
            local activity = self.android.app.activity.clazz

            local function delete_local(ref)
                if ref ~= nil then
                    env[0].DeleteLocalRef(env, ref)
                end
            end

            local resolver = jni:callObjectMethod(
                activity, "getContentResolver",
                "()Landroid/content/ContentResolver;"
            )

            local uri_string = env[0].NewStringUTF(env,
                "content://com.onyx.content.database.ContentProvider/Metadata")
            local uri = jni:callStaticObjectMethod(
                "android/net/Uri", "parse",
                "(Ljava/lang/String;)Landroid/net/Uri;",
                uri_string
            )

            local escaped_path = path:gsub("'", "''")
            local where_clause = "nativeAbsolutePath='" .. escaped_path .. "'"
            local where_string = env[0].NewStringUTF(env, where_clause)

            logger.info("OnyxSync: Updating WHERE =", where_clause)
            logger.info("OnyxSync: File path =", path)

            -- ContentValues
            local cv_class = env[0].FindClass(env, "android/content/ContentValues")
            local cv_init = env[0].GetMethodID(env, cv_class, "<init>", "()V")
            local put_string = env[0].GetMethodID(env, cv_class,
                "put", "(Ljava/lang/String;Ljava/lang/String;)V")
            local put_int = env[0].GetMethodID(env, cv_class,
                "put", "(Ljava/lang/String;Ljava/lang/Integer;)V")
            local put_long = env[0].GetMethodID(env, cv_class,
                "put", "(Ljava/lang/String;Ljava/lang/Long;)V")

            local values = env[0].NewObject(env, cv_class, cv_init)

            -- readingStatus (always set)
            local key_status = env[0].NewStringUTF(env, "readingStatus")
            local status_val = jni:callStaticObjectMethod(
                "java/lang/Integer", "valueOf",
                "(I)Ljava/lang/Integer;",
                ffi.new("int32_t", reading_status)
            )
            env[0].CallVoidMethod(env, values, put_int, key_status, status_val)
            delete_local(key_status)
            delete_local(status_val)

            -- If readingStatus is 0 (NEW/unread), explicitly set progress and lastAccess to NULL
            if reading_status == 0 then
                local key_progress = env[0].NewStringUTF(env, "progress")
                env[0].CallVoidMethod(env, values, put_string, key_progress, nil)
                delete_local(key_progress)

                local key_time = env[0].NewStringUTF(env, "lastAccess")
                env[0].CallVoidMethod(env, values, put_long, key_time, nil)
                delete_local(key_time)
            else
                -- Only set progress and lastAccess if book has been read
                if progress then
                    local key_progress = env[0].NewStringUTF(env, "progress")
                    local val_progress = env[0].NewStringUTF(env, progress)
                    env[0].CallVoidMethod(env, values, put_string, key_progress, val_progress)
                    delete_local(key_progress)
                    delete_local(val_progress)
                end

                if timestamp then
                    local key_time = env[0].NewStringUTF(env, "lastAccess")
                    local time_val = jni:callStaticObjectMethod(
                        "java/lang/Long", "valueOf",
                        "(J)Ljava/lang/Long;",
                        ffi.new("int64_t", timestamp)
                    )
                    env[0].CallVoidMethod(env, values, put_long, key_time, time_val)
                    delete_local(key_time)
                    delete_local(time_val)
                end
            end

            -- Simple UPDATE
            local rows = jni:callIntMethod(
                resolver, "update",
                "(Landroid/net/Uri;Landroid/content/ContentValues;Ljava/lang/String;[Ljava/lang/String;)I",
                uri, values, where_string, nil
            )
            -- Log if provider signaled error / exception
            if env[0].ExceptionCheck(env) ~= 0 then
                logger.err("OnyxSync: Java exception during update()")
                env[0].ExceptionDescribe(env)
                env[0].ExceptionClear(env)
            end

            if rows == -1 then
                logger.warn("OnyxSync: update() returned -1 (provider error)")
            end
            -- Cleanup
            delete_local(uri_string)
            delete_local(uri)
            delete_local(values)
            delete_local(where_string)
            delete_local(resolver)
            delete_local(cv_class)

            logger.info("OnyxSync: Update returned", rows, "row(s)")
            return rows
        end)
    end)

    if not status then
        logger.err("OnyxSync: JNI error:", result)
        return 0
    end

    return result or 0
end

function OnyxSync:immediateSync()
    UIManager:unschedule(self.doSync)
    self:doSync()
end

function OnyxSync:scheduleSync()
    UIManager:unschedule(self.doSync)
    UIManager:scheduleIn(3, self.doSync, self)
end

function OnyxSync:doSync()
    if not self.ui or not self.ui.document or not self.view then
        return
    end

    if not Device:isAndroid() then
        return
    end

    local path = self.ui.document.file
    local curr_page = self.view.state.page or 1
    local total_pages = self.ui.document:getPageCount() or 1

    -- Skip sync if not in main flow (e.g., footnotes, cover pages)
    local flow = self.ui.document:getPageFlow(curr_page)
    if flow ~= 0 then
        logger.info("OnyxSync: Skipping sync - not in main flow")
        return
    end

    -- Get actual page numbers within the flow
    local total_pages_in_flow = self.ui.document:getTotalPagesInFlow(flow)
    local page_in_flow = self.ui.document:getPageNumberInFlow(curr_page)

    -- Check completion status
    local summary = self.ui.doc_settings:readSetting("summary")
    local status = summary and summary.status

    local reading_status = 0
    if status == "complete" or page_in_flow == total_pages_in_flow then
        reading_status = 2
    elseif status == "reading" then
        reading_status = 1
    end
    local progress = page_in_flow .. "/" .. total_pages_in_flow
    local timestamp = os.time() * 1000

    logger.info("OnyxSync: Syncing", path, "-", progress, "status:", reading_status)

    local rows = self:updateOnyxProgress(path, progress, timestamp, reading_status)

    if rows > 0 then
        logger.info("OnyxSync: SUCCESS!")
    else
        logger.warn("OnyxSync: No rows updated")
    end
end

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

function OnyxSync:onPageUpdate()
    self:scheduleSync()
end

function OnyxSync:onCloseDocument()
    logger.info("OnyxSync: Document closing")
    self:immediateSync()
end

function OnyxSync:onSaveSettings()
    logger.info("OnyxSync: Settings saving")
    self:immediateSync()
end

function OnyxSync:onSuspend()
    logger.info("OnyxSync: App going to background")
    self:immediateSync()
end

function OnyxSync:onEndOfBook()
    logger.info("OnyxSync: End of book reached")
    self:immediateSync()
end

return OnyxSync
