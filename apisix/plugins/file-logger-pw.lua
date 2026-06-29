--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- NOTA: variante del 'file-logger' oficial de APISIX 3.16.0. Conserva toda su
-- lógica probada (caché del descriptor de fichero, reapertura en rotación de logs,
-- escritura de una sola llamada write) y SOLO cambia una cosa: cada worker de nginx
-- escribe a SU PROPIO fichero, insertando el id del worker en el nombre
-- (p.ej. nfv.log -> nfv-0.log, nfv-1.log...). Así se elimina el posible entrelazado
-- de líneas grandes cuando varios workers escriben a la vez, sin locks ni contención.
--

local log_util     =   require("apisix.utils.log-util")
local core         =   require("apisix.core")
local plugin       =   require("apisix.plugin")
local expr         =   require("resty.expr.v1")
local ngx          =   ngx
local io_open      =   io.open
local is_apisix_or, process = pcall(require, "resty.apisix.process")


local plugin_name = "file-logger-pw"


local schema = {
    type = "object",
    properties = {
        path = {
            type = "string"
        },
        log_format = {type = "object"},
        include_req_body = {type = "boolean", default = false},
        include_req_body_expr = {
            type = "array",
            minItems = 1,
            items = {
                type = "array"
            }
        },
        include_resp_body = {type = "boolean", default = false},
        include_resp_body_expr = {
            type = "array",
            minItems = 1,
            items = {
                type = "array"
            }
        },
        max_req_body_bytes = {type = "integer", minimum = 1, default = 524288},
        max_resp_body_bytes = {type = "integer", minimum = 1, default = 524288},
        match = {
            type = "array",
            maxItems = 20,
            items = {
                type = "array",
            },
        }
    },
}


local metadata_schema = {
    type = "object",
    properties = {
        path = {
            type = "string"
        },
        log_format = {
            type = "object"
        }
    }
}


local _M = {
    version = 0.1,
    priority = 399,
    name = plugin_name,
    schema = schema,
    metadata_schema = metadata_schema
}


local function get_configured_path(conf)
    if conf.path then
        return conf.path
    end

    local metadata = plugin.plugin_metadata(plugin_name)
    if metadata and metadata.value and metadata.value.path then
        return metadata.value.path
    end

    return nil, "property \"path\" is not set in either the plugin conf or the metadata"
end


-- ÚNICA personalización respecto al file-logger oficial: inserta el id del worker
-- en el path para que cada worker escriba a su propio fichero.
--   /usr/local/apisix/logs/nfv.log  ->  /usr/local/apisix/logs/nfv-<id>.log
local function per_worker_path(path)
    local worker_id = ngx.worker.id() or 0
    local p, n = path:gsub("(%.[^./\\]*)$", "-" .. worker_id .. "%1")
    if n == 0 then
        -- el path no tenía extensión: añadimos el sufijo al final
        p = path .. "-" .. worker_id
    end
    return p
end


function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end

    if conf.match then
        local ok, err = expr.new(conf.match)
        if not ok then
            return nil, "failed to validate the 'match' expression: " .. err
        end
    end

    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return ok, err
    end

    local path, err = get_configured_path(conf)
    if not path then
        return nil, err
    end

    return true
end


local open_file_cache
if is_apisix_or then
    -- TODO: switch to a cache which supports inactive time,
    -- so that unused files would not be cached
    local path_to_file = core.lrucache.new({
        type = "plugin",
    })

    local function open_file_handler(conf, handler)
        local file, err = io_open(conf.path, 'a+')
        if not file then
            return nil, err
        end

        -- it will case output problem with buffer when log is larger than buffer
        file:setvbuf("no")

        handler.file = file
        handler.open_time = ngx.now() * 1000
        return handler
    end

    function open_file_cache(conf)
        local last_reopen_time = process.get_last_reopen_ms()

        local handler, err = path_to_file(conf.path, 0, open_file_handler, conf, {})
        if not handler then
            return nil, err
        end

        if handler.open_time < last_reopen_time then
            core.log.notice("reopen cached log file: ", conf.path)
            handler.file:close()

            local ok, err = open_file_handler(conf, handler)
            if not ok then
                return nil, err
            end
        end

        return handler.file
    end
end


local function write_file_data(conf, log_message)
    local path, err = get_configured_path(conf)
    if not path then
        core.log.error(err)
        return
    end

    -- Cada worker a su propio fichero (clave de caché y apertura usan ya el path por-worker)
    path = per_worker_path(path)

    local msg = core.json.encode(log_message)

    local file, err
    local file_conf = {path = path}
    if open_file_cache then
        file, err = open_file_cache(file_conf)
    else
        file, err = io_open(path, 'a+')
    end

    if not file then
        core.log.error("failed to open file: ", path, ", error info: ", err)
    else
        -- file:write(msg, "\n") will call fwrite several times
        -- which will cause problem with the log output
        -- it should be atomic
        msg = msg .. "\n"
        -- write to file directly, no need flush
        local ok, err = file:write(msg)
        if not ok then
            core.log.error("failed to write file: ", path, ", error info: ", err)
        end

        -- file will be closed by gc, if open_file_cache exists
        if not open_file_cache then
            file:close()
        end
    end
end


_M.access = log_util.check_and_read_req_body


function _M.body_filter(conf, ctx)
    log_util.collect_body(conf, ctx)
end


function _M.log(conf, ctx)
    local entry = log_util.get_log_entry(plugin_name, conf, ctx)
    if entry == nil then
        return
    end
    write_file_data(conf, entry)
end


return _M
