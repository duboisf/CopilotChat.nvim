---@diagnostic disable-next-line: undefined-global
local vim = vim
local log = require("plenary.log")
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

local stdio = require("CopilotChat.mcp.transport.stdio")

---@class MCP.Tool A tool that can be called
---@field name string The name of the tool
---@field description string A description of the tool
---@field inputSchema table The JSON schema for the tool's input

---@class MCP.ToolResult
---@field err any|nil Error message or nil if successful
---@field result any|nil Result of the tool

---@class MCP.Client
---@field initialized boolean Whether the client has been initialized
---@field transport MCP.Transport.Stdio The transport layer used to communicate with the server
---@field capabilities table Client capabilities
---@field server_capabilities table Server capabilities
---@field server_info table Server information
---@field protocol_version string Protocol version used
local M = {}

---@async
---Creates a new MCP client.
---@param command string[] Command to use for the MCP server, or a server ID
---@return string? error Error message if the client could not be created
---@return MCP.Client? client The MCP client
---@nodiscard
function M:new(command)
  local self = setmetatable({}, { __index = M })

  local err, transport = stdio:new(command)
  if err then
    return err, nil
  end

  ---@cast transport MCP.Transport.Stdio
  self.transport = transport
  self.initialized = false
  self.capabilities = {
    sampling = {},
    roots = {
      listChanged = true
    }
  }
  self.server_capabilities = {}
  self.server_info = {}
  self.protocol_version = "2024-11-05"

  return nil, self
end

---@async
---Start the client and initialize the connection to the server.
---@return MCP.Transport.ResponseError? error The error received form the server
---@return any? result The result of the initialization
---@nodiscard
function M:start()
  dlog.debug("called start2")
  -- Initialize the server
  local client_info = {
    name = "mcp.nvim",
    version = "0.1.0" -- Replace with actual version
  }

  local err, result = self.transport:request_sync("initialize", {
    clientInfo = client_info,
    protocolVersion = self.protocol_version,
    capabilities = self.capabilities
  })
  if err then
    log.error("Failed to initialize MCP server: " .. vim.inspect(err))
    return err, nil
  end

  dlog.debug("MCP server initialized: " .. vim.inspect(result))
  self.server_capabilities = result.capabilities
  self.server_info = result.serverInfo
  self.protocol_version = result.protocolVersion
  self.initialized = true

  -- Send initialized notification
  self.transport:notify("notifications/initialized", {})
  return nil, result
end

---Stop the client.
function M:stop()
  if not self.transport then
    return
  end
  self.transport:stop()
  self.initialized = false
end

---@async
---List provided tools
---@return MCP.Transport.ResponseError? # The error received form the server
---@return { tools: MCP.Tool[] }? # The available tools
---@nodiscard
function M:list_tools()
  if not self.initialized then
    error("MCP client not initialized")
  end

  local err, response = self.transport:request_sync("tools/list", nil)
  return err, response and response.tools
end

---Call a tool on the server.
---@param name string Tool name
---@param arguments table Arguments for the tool
---@return MCP.Transport.ResponseError? error The error received form the server
---@return MCP.ToolResult? result The result of the tool
function M:call_tool(name, arguments)
  dlog.debug("called call_tool")
  if not self.initialized then
    error("MCP client not initialized", nil)
  end

  return self.transport:request_sync("tools/call", {
    name = name,
    arguments = arguments or {}
  })
end

---List available resources from the server.
---@param callback function Callback function with (error, resources)
function M:list_resources(callback)
  if not self.initialized then
    callback("MCP client not initialized", nil)
    return
  end

  self.transport:request("resources/list", {}, callback)
end

---Read a resource from the server.
---@param uri string Resource URI
---@param callback function Callback function with (error, contents)
function M:read_resource(uri, callback)
  if not self.initialized then
    callback("MCP client not initialized", nil)
    return
  end

  self.transport:request("resources/read", {
    uri = uri
  }, callback)
end

---Subscribe to updates for a resource.
---@param uri string Resource URI
---@param callback function Callback function with (error, result)
function M:subscribe_resource(uri, callback)
  if not self.initialized then
    callback("MCP client not initialized", nil)
    return
  end

  if not self.server_capabilities.resources or not self.server_capabilities.resources.subscribe then
    callback("Server does not support resource subscriptions", nil)
    return
  end

  self.transport:request("resources/subscribe", {
    uri = uri
  }, callback)
end

---Unsubscribe from updates for a resource.
---@param uri string Resource URI
---@param callback function Callback function with (error, result)
function M:unsubscribe_resource(uri, callback)
  if not self.initialized then
    callback("MCP client not initialized", nil)
    return
  end

  self.transport:request("resources/unsubscribe", {
    uri = uri
  }, callback)
end

---List available prompts from the server.
---@param callback function Callback function with (error, prompts)
function M:list_prompts(callback)
  if not self.initialized then
    callback("MCP client not initialized", nil)
    return
  end

  self.transport:request("prompts/list", {}, callback)
end

---Get a prompt from the server.
---@param name string Prompt name
---@param arguments table|nil Optional arguments for the prompt
---@param callback function Callback function with (error, prompt)
function M:get_prompt(name, arguments, callback)
  if not self.initialized then
    callback("MCP client not initialized", nil)
    return
  end

  self.transport:request("prompts/get", {
    name = name,
    arguments = arguments or {}
  }, callback)
end

---Set the logging level on the server.
---@param level string Logging level (debug, info, notice, warning, error, critical, alert, emergency)
---@param callback function Callback function with (error, result)
function M:set_log_level(level, callback)
  if not self.initialized then
    callback("MCP client not initialized", nil)
    return
  end

  if not self.server_capabilities.logging then
    callback("Server does not support logging level changes", nil)
    return
  end

  self.transport:request("logging/setLevel", {
    level = level
  }, callback)
end

---Register a handler for resource update notifications.
---@param handler function Function to call with (params) when a resource is updated
function M:on_resource_updated(handler)
  self.transport:on_notification("notifications/resources/updated", handler)
end

---Register a handler for resource list changed notifications.
---@param handler function Function to call with (params) when the resource list changes
function M:on_resource_list_changed(handler)
  self.transport:on_notification("notifications/resources/list_changed", handler)
end

---Register a handler for prompt list changed notifications.
---@param handler function Function to call with (params) when the prompt list changes
function M:on_prompt_list_changed(handler)
  self.transport:on_notification("notifications/prompts/list_changed", handler)
end

---Register a handler for tool list changed notifications.
---@param handler function Function to call with (params) when the tool list changes
function M:on_tool_list_changed(handler)
  self.transport:on_notification("notifications/tools/list_changed", handler)
end

---Register a handler for logging messages from the server.
---@param handler function Function to call with (params) when a log message is received
function M:on_log_message(handler)
  self.transport:on_notification("notifications/message", handler)
end

---Request message completion from the server.
---@param ref table Reference object (prompt or resource)
---@param argument table Argument information with name and value
---@param callback function Callback function with (error, completion_result)
function M:complete(ref, argument, callback)
  if not self.initialized then
    callback("MCP client not initialized", nil)
    return
  end

  self.transport:request("completion/complete", {
    ref = ref,
    argument = argument
  }, callback)
end

---Create a message using the client's sampling capability.
---@param params table CreateMessageRequest params
---@param callback function Callback function with (error, message)
function M:create_message(params, callback)
  if not self.initialized then
    callback("MCP client not initialized", nil)
    return
  end

  self.transport:request("sampling/createMessage", params, callback)
end

return M
