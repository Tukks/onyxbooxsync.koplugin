local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local Device = require("device")
local logger = require("logger")
local ffi = require("ffi")

local OnyxSync = WidgetContainer:extend{
    name = "OnyxSync",
    is_doc_only = true,
}

function OnyxSync:init()
    logger.info("OnyxSync: Plugin initialized")

    local ok, android = pcall(require, "android")
    if ok then
        self.android = android
        logger.info("OnyxSync: Android module loaded")
    else
        logger.err("OnyxSync: Cannot load android module")
    end
end

function OnyxSync:updateOnyxProgress(path, progress, timestamp, is_completed)
    if not self.android or not self.android.app or not self.android.app.activity then
        return 0, "Android module not available"
    end

    is_completed = is_completed or 0

    local status, result = pcall(function()
        return self.android.jni:context(self.android.app.activity.vm, function(jni)
            local env = jni.env
            local activity = self.android.app.activity.clazz

            local function delete_local(ref)
                if ref ~= nil then
                    env[0].DeleteLocalRef(env, ref)
                end
            end

            -- ContentResolver
            local resolver = jni:callObjectMethod(
                activity,
                "getContentResolver",
                "()Landroid/content/ContentResolver;"
            )

            -- Uri.parse(...)
            local uri_string = env[0].NewStringUTF(env,
                "content://com.onyx.content.database.ContentProvider/Metadata")
            local uri = jni:callStaticObjectMethod(
                "android/net/Uri",
                "parse",
                "(Ljava/lang/String;)Landroid/net/Uri;",
                uri_string
            )

            -- WHERE clause
            local escaped_path = path:gsub("'", "''")
            local where_clause = "nativeAbsolutePath='" .. escaped_path .. "'"
            local where_string = env[0].NewStringUTF(env, where_clause)

            logger.info("OnyxSync: WHERE =", where_clause)
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

            -- progress
            local key_progress = env[0].NewStringUTF(env, "progress")
            local val_progress = env[0].NewStringUTF(env, progress)
            env[0].CallVoidMethod(env, values, put_string, key_progress, val_progress)

            -- readingStatus (Integer): 0=NEW, 1=READING, 2=FINISHED
            local reading_status = (is_completed == 1) and 2 or 1
            local status_val = jni:callStaticObjectMethod(
                "java/lang/Integer",
                "valueOf",
                "(I)Ljava/lang/Integer;",
                ffi.new("int32_t", reading_status)
            )
            local key_status = env[0].NewStringUTF(env, "readingStatus")
            env[0].CallVoidMethod(env, values, put_int, key_status, status_val)

            -- lastAccess (Long)
            local time_val = jni:callStaticObjectMethod(
                "java/lang/Long",
                "valueOf",
                "(J)Ljava/lang/Long;",
                ffi.new("int64_t", timestamp)
            )
            local key_time = env[0].NewStringUTF(env, "lastAccess")
            env[0].CallVoidMethod(env, values, put_long, key_time, time_val)

            -- Try QUERY first to check if row exists
            local projection = nil
            local selection_args = nil
            local sort_order = nil

            local cursor = jni:callObjectMethod(
                resolver,
                "query",
                "(Landroid/net/Uri;[Ljava/lang/String;Ljava/lang/String;[Ljava/lang/String;Ljava/lang/String;)Landroid/database/Cursor;",
                uri, projection, where_string, selection_args, sort_order
            )

            local exists = false
            if cursor ~= nil then
                local count = jni:callIntMethod(cursor, "getCount", "()I")
                logger.info("OnyxSync: Query found", count, "existing row(s)")
                exists = (count > 0)
                jni:callVoidMethod(cursor, "close", "()V")
                delete_local(cursor)
            else
                logger.warn("OnyxSync: Query returned nil cursor")
            end

            -- Try UPDATE if row exists
            local rows = 0
            if exists then
                rows = jni:callIntMethod(
                    resolver,
                    "update",
                    "(Landroid/net/Uri;Landroid/content/ContentValues;Ljava/lang/String;[Ljava/lang/String;)I",
                    uri, values, where_string, nil
                )
                logger.info("OnyxSync: Update returned", rows, "rows")
            end

            -- If no rows updated, INSERT new row
            if rows == 0 then
                logger.info("OnyxSync: No existing row, inserting new metadata")

                -- Add nativeAbsolutePath to ContentValues for INSERT
                local key_path = env[0].NewStringUTF(env, "nativeAbsolutePath")
                local val_path = env[0].NewStringUTF(env, path)
                env[0].CallVoidMethod(env, values, put_string, key_path, val_path)

                -- Insert new row
                local insert_uri = jni:callObjectMethod(
                    resolver,
                    "insert",
                    "(Landroid/net/Uri;Landroid/content/ContentValues;)Landroid/net/Uri;",
                    uri, values
                )

                if insert_uri ~= nil then
                    rows = 1
                    logger.info("OnyxSync: Insert successful, URI:", tostring(insert_uri))
                else
                    rows = 0
                    logger.err("OnyxSync: Insert failed, returned nil URI")
                end

                delete_local(key_path)
                delete_local(val_path)
                delete_local(insert_uri)
            end

            -- Cleanup
            delete_local(uri_string)
            delete_local(uri)
            delete_local(values)
            delete_local(key_progress)
            delete_local(val_progress)
            delete_local(key_status)
            delete_local(status_val)
            delete_local(key_time)
            delete_local(time_val)
            delete_local(where_string)
            delete_local(resolver)
            delete_local(cv_class)

            logger.info("OnyxSync:", rows, "row(s) affected")
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
    local is_completed = (status == "complete" or page_in_flow == total_pages_in_flow) and 1 or 0

    local progress = page_in_flow .. "/" .. total_pages_in_flow
    local timestamp = os.time() * 1000

    logger.info("OnyxSync: Syncing", path, "-", progress, "completed:", is_completed)

    local rows = self:updateOnyxProgress(path, progress, timestamp, is_completed)

    if rows > 0 then
        logger.info("OnyxSync: SUCCESS!")
    else
        logger.warn("OnyxSync: No rows updated")
    end
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