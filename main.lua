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

function OnyxSync:updateOnyxProgress(path, progress, timestamp)
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

            logger.dbg("OnyxSync: WHERE =", where_clause)

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

            -- readingStatus (Integer)
            local status_val = jni:callStaticObjectMethod(
                "java/lang/Integer",
                "valueOf",
                "(I)Ljava/lang/Integer;",
                ffi.new("int32_t", 1)
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

            -- Try UPDATE first
            local rows = jni:callIntMethod(
                resolver,
                "update",
                "(Landroid/net/Uri;Landroid/content/ContentValues;Ljava/lang/String;[Ljava/lang/String;)I",
                uri, values, where_string, nil
            )

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

                rows = (insert_uri ~= nil) and 1 or 0

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

function OnyxSync:syncNow()
    if not self.ui or not self.ui.document or not self.view then
        return
    end

    if not Device:isAndroid() then
        return
    end

    local path = self.ui.document.file
    local curr_page = self.view.state.page or 1
    local total_pages = self.ui.document:getPageCount() or 1
    local progress = curr_page .. "/" .. total_pages
    local timestamp = os.time() * 1000

    logger.info("OnyxSync: Syncing", path, "-", progress)

    local rows = self:updateOnyxProgress(path, progress, timestamp)

    if rows > 0 then
        logger.info("OnyxSync: SUCCESS!")
        UIManager:show(InfoMessage:new{
            text = "Synced: " .. progress,
            timeout = 2,
        })
    else
        logger.warn("OnyxSync: No rows updated")
        UIManager:show(InfoMessage:new{
            text = "Sync failed - check logs",
            timeout = 3,
        })
    end
end

function OnyxSync:onCloseDocument()
    logger.info("OnyxSync: Document closing")
    self:syncNow()
end

function OnyxSync:onSaveSettings()
    logger.info("OnyxSync: Settings saving")
    self:syncNow()
end

return OnyxSync
