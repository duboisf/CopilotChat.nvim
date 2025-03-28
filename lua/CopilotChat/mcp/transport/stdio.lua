local dlog = require('plenary.log').new(
  {
    fmt_msg = function(is_console, mode_name, src_path, src_line, msg)
      local nameupper = mode_name:upper()
      local lineinfo = string.format("%s:%d", src_path:match("([^/]+)$"), src_line)
      if is_console then
        return string.format("[%-6s%s] %s: %s", nameupper, os.date "%H:%M:%S", lineinfo, msg)
      else
        return string.format("[%-6s%s] %s: %s\n", nameupper, os.date(), lineinfo, msg)
      end
    end,
    plugin = "copilot-debug",
    level = "debug",
    outfile = "/tmp/copilot-mcp-debug-logs.txt"
  }, false
)

---@diagnostic disable: missing-fields
local utils = require("CopilotChat.utils")
local log = require("plenary.log")

---@class CopilotChat.mcp.transport.Stdio
---@field command string The command to execute for the MCP server.
---@field job_id number|nil The ID of the job associated with the MCP client.
---@field next_id number The next request ID to use.
---@field pending_requests table<number, fun(...: any): any> A table of pending requests indexed by ID.
---@field notification_handlers table<string, function> A table of notification handlers indexed by event name.
local M = {}

---Creates a new MCPClient instance.
---@param command string The command to execute for the MCP server.
---@return CopilotChat.mcp.transport.Stdio
function M:new(command)
  local self = setmetatable({}, { __index = M })
  self.command = command
  self.job_id = nil
  self.next_id = 1
  self.pending_requests = {}
  self.notification_handlers = {}
  return self
end

---Starts the MCP server process.
function M:start()
  local job_id = vim.fn.jobstart(
    self.command,
    {
      -- change to "pipe" or "file" based on your needs
      on_stdout = function(job_id, data, event)
        if data then
          log.debug("on_stdout: data=", data)
          for _, line in ipairs(data) do
            if line ~= "" then
              local message, err = utils.json_decode(line)
              if err then
                log.error("Failed to decode message: " .. err .. " - " .. line)
                return
              end
              self:handle_message(message)
            end
          end
        end
      end,
      on_stderr = vim.schedule_wrap(function(job_id, data, event)
        log.debug('received stdout data:', job_id, data, event)
        if data then
          for _, line in ipairs(data) do
            log.error("MCP server stderr: " .. line)
          end
        end
      end),
      on_exit = vim.schedule_wrap(function(job_id, code, event)
        log.debug(string.format("MCP server exited with code %d", code))
        self:close()
      end),
      detach = false,
      pty = false,
    }
  )
  if job_id == 0 then
    error("could not start mcp client")
  end
  self.job_id = job_id
end

---Stops the MCP server process.
function M:stop()
  if self.job_id then
    vim.fn.jobstop(self.job_id)
  end
  self:close()
end

---Closes the stdin.
function M:close()
  self.job_id = nil
end

---Sends a request to the MCP server.
---@param method string The method to call.
---@param params table The parameters to pass to the method.
---@param callback fun(...: any): any The callback function to call when the response is received.
function M:request(method, params, callback)
  local id = self.next_id
  self.next_id = self.next_id + 1

  local request = {
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params,
  }

  self.pending_requests[id] = callback

  log.debug('stdio:request: message=', vim.inspect(request))
  local message = vim.json.encode(request) .. "\n"
  log.debug('stdio:request: message=', message)

  local bytes_written = vim.fn.chansend(self.job_id, message)
  if bytes_written == 0 then
    error('failed to send request to mcp server')
  end
end

---Sends a synchronous request to the MCP server.
---@param method string The method to call.
---@param params table The parameters to pass to the method.
---@return string|table|nil, table|nil
function M:request_sync(endpoint, payload)
  local co = coroutine.running()
  if not co then
    error("request_sync must be called within a coroutine")
  end

  local callback_err, callback_result
  self:request(endpoint, payload, function(err, result)
    callback_err = err
    callback_result = result
    coroutine.resume(co)
  end)

  coroutine.yield()
  return callback_err, callback_result
end

---Sends a notification to the MCP server.
---@param method string The method to call.
---@param params table The parameters to pass to the method.
function M:notify(method, params)
  local notification = {
    jsonrpc = "2.0",
    method = method,
    params = params,
  }

  local message = utils.json_encode(notification) .. "\n"
  vim.fn.chansend(self.job_id, message)
end

---Registers a handler for a notification.
---@param method string The method to handle.
---@param handler function The handler function to call when the notification is received.
function M:on_notification(method, handler)
  self.notification_handlers[method] = handler
end

---@alias JsonRPCVersion "2.0"

---@class Transport.Response
---@field jsonrpc JsonRPCVersion The JSON-RPC version.
---@field id number The ID of the request.
---@field result? { [string]: any } The result of the request.
---@field error? {code: any, message: string, data?: any} The error of the request.

---@class Transport.Notification
---@field jsonrpc JsonRPCVersion
---@field method string
---@field params { [string]: any } The result of the request.

---Handles a message received from the MCP server.
---@param message Transport.Response|Transport.Notification The message received from the server.
function M:handle_message(message)
  dlog.debug('mpc msg', message)
  if message.id then
    ---@cast message -Transport.Notification
    -- Handle response
    local callback = self.pending_requests[message.id]
    if callback then
      self.pending_requests[message.id] = nil
      callback(message.error, message.result)
    else
      log.warn("Received response for unknown request ID: " .. message.id)
    end
  else
    ---@cast message -Transport.Response
    local handler = self.notification_handlers[message.method]
    if handler then
      handler(message.params)
    else
      log.warn("Received notification for unknown method: " .. message.method)
    end
  end
end

return M
