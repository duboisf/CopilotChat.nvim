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
    level = "debug",
    plugin = "copilot-debug",
    outfile = "/tmp/copilot-mcp-debug-logs.txt",
    use_console = false,
  }, false
)

local log = require("plenary.log")

---@alias JsonRPCVersion "2.0"

---@class MCP.Transport.Response
---@field jsonrpc JsonRPCVersion The JSON-RPC version.
---@field id number The ID of the request.
---@field result? { [string]: any } The result of the request.
---@field error? MCP.Transport.ResponseError The error of the request.

---@alias MCP.Transport.ResponseCallback fun(err?: MCP.Transport.ResponseError, result?: any)

---@class MCP.Transport.ResponseError
---@field code any The error code.
---@field message string The error message.
---@field data? any Additional error data.

---@alias Stdio MCP.Transport.Stdio

---@class MCP.Transport.Notification
---@field jsonrpc JsonRPCVersion
---@field method string
---@field params { [string]: any } The result of the request.

---@alias MCP.Transport.Message MCP.Transport.Response|MCP.Transport.Notification

---@class (exact) MCP.Transport.Stdio
---@field job_id number|nil The ID of the job associated with the MCP client.
---@field next_id number The next request ID to use.
---@field pending_requests { [number]: MCP.Transport.ResponseCallback } A dict of pending requests with their callback functions indexed by request ID.
---@field notification_handlers { [string]: fun(params: { [string]: any}) } A table of notification handlers indexed by event name.
local M = {}

---Handle incoming server data on stdout
---@param self Stdio
---@return fun(job_id: number, data: any, event: string) # The job's on_stdout callback
local function on_stdout(self)
  return function(_, data, _)
    dlog.debug("on_stdout: data=", data)
    for _, line in ipairs(data) do
      if line ~= "" then
        local ok, res = pcall(vim.json.decode, line)
        if not ok then
          log.error(string.format("Failed to decode message, err='%s', line='%s'", res, line))
        else
          ---@cast res MCP.Transport.Message
          self:handle_message(res)
        end
      end
    end
  end
end

---Starts the MCP server process.
---@param self MCP.Transport.Stdio
---@param mcp_server_command string[]
---@return string? error
---@nodiscard
local function start(self, mcp_server_command)
  if type(mcp_server_command) ~= "table" then
    return "start: mcp_server_command must be an array"
  end
  local job_id = vim.fn.jobstart(
    mcp_server_command,
    {
      on_stdout = on_stdout(self),
      on_stderr = vim.schedule_wrap(function(job_id, data, event)
        dlog.debug('received stderr data:', job_id, data, event)
        if data then
          for _, line in ipairs(data) do
            if line ~= "" then
              dlog.error("MCP server stderr: " .. line)
            end
          end
        end
      end),
      on_exit = function(_, code, _)
        log.debug(string.format("MCP server exited with code %d", code))
        self:close()
      end,
      detach = false,
      pty = false,
    }
  )
  if job_id == 0 then
    return "start: invalid jobstart arguments"
  elseif job_id == -1 then
    return string.format("start: '%s' is not executable", mcp_server_command[1])
  end
  dlog.debug('MCP server started with job_id:', job_id)
  self.job_id = job_id
end

---Creates a new MCPClient instance.
---@param mcp_server_command string[] The MCP server command and arguments
---@return string? error
---@return MCP.Transport.Stdio?
---@nodiscard
function M:new(mcp_server_command)
  local self = setmetatable({}, { __index = M })
  self.job_id = nil
  self.next_id = 1
  self.pending_requests = {}
  self.notification_handlers = {}

  local err = start(self, mcp_server_command)
  if err then
    return err, nil
  end
  return nil, self
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
---@param params? table The parameters to pass to the method.
---@param callback MCP.Transport.ResponseCallback  callback function to call when the response is received.
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

  local message = vim.json.encode(request) .. "\n"

  local bytes_written = vim.fn.chansend(self.job_id, message)
  if bytes_written == 0 then
    error('failed to send request to mcp server')
  end
end

---@async
---Sends a request to the MCP server.
---@param method string The method to call.
---@param params? table The parameters to pass to the method.
---@return MCP.Transport.ResponseError? error The error returned by the server.
---@return any? result The result of the request.
function M:request_sync(method, params)
  local thread = coroutine.running()
  if not thread then
    error("request_sync must be called within a coroutine")
  end

  local id = self.next_id
  self.next_id = self.next_id + 1

  local request = {
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params,
  }

  self.pending_requests[id] = function(err, result)
    coroutine.resume(thread, err, result)
  end

  local message = vim.json.encode(request) .. "\n"

  local bytes_written = vim.fn.chansend(self.job_id, message)
  if bytes_written == 0 then
    error('failed to send request to mcp server')
  end

  return coroutine.yield()
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

  local message = vim.json.encode(notification) .. "\n"
  vim.fn.chansend(self.job_id, message)
end

---Registers a handler for a notification.
---@param method string The method to handle.
---@param handler function The handler function to call when the notification is received.
function M:on_notification(method, handler)
  self.notification_handlers[method] = handler
end

---Handle response from server
---@param self Stdio
---@param resp MCP.Transport.Response
local function handle_response(self, resp)
  local callback = self.pending_requests[resp.id]
  if callback then
    self.pending_requests[resp.id] = nil
    callback(resp.error, resp.result)
  else
    log.warn("Received response for unknown request ID: " .. resp.id)
  end
end


---Handle notification from server
---@param self Stdio
---@param notification MCP.Transport.Notification
local function handle_notification(self, notification)
  local handler = self.notification_handlers[notification.method]
  if handler then
    handler(notification.params)
  else
    log.warn("Received notification for unknown method: " .. notification.method)
  end
end

---Handles a message received from the MCP server.
---@param message MCP.Transport.Response|MCP.Transport.Notification The message received from the server.
function M:handle_message(message)
  dlog.debug('Received message from MCP server:', message)
  if message.id then
    ---@cast message MCP.Transport.Response
    handle_response(self, message)
  else
    ---@cast message MCP.Transport.Notification
    handle_notification(self, message)
  end
end

return M
