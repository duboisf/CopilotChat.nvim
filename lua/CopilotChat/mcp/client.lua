---@diagnostic disable-next-line: undefined-global
local vim = vim
local log = require("plenary.log")
local stdio = require("CopilotChat.mcp.transport.stdio")

---@class CopilotChat.mcp.Client
---@field initialized boolean Whether the client has been initialized
---@field transport CopilotChat.mcp.transport.Stdio The transport layer used to communicate with the server
---@field capabilities table Client capabilities
---@field server_capabilities table Server capabilities
---@field server_info table Server information
---@field protocol_version string Protocol version used
local M = {}

---Creates a new MCP client.
---@param command string Command to use for the MCP server, or a server ID
---@return CopilotChat.mcp.Client
function M:new(command)
  local self = setmetatable({}, { __index = M })

  self.transport = stdio:new(command)
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

  return self
end

---Start the client and initialize the connection to the server.
---@param callback function Callback function with (error, result) once the server is initialized
function M:start(callback)
  log.debug("Starting MCP client")
  self.transport:start()

  -- Initialize the server
  local client_info = {
    name = "copilot-chat.nvim",
    version = "0.1.0" -- Replace with actual version
  }

  self.transport:request("initialize", {
    clientInfo = client_info,
    protocolVersion = self.protocol_version,
    capabilities = self.capabilities
  }, function(err, result)
    if err then
      log.error("Failed to initialize MCP server: " .. vim.inspect(err))
      callback(err, nil)
      return
    end

    log.debug("MCP server initialized: " .. vim.inspect(result))
    self.server_capabilities = result.capabilities
    self.server_info = result.serverInfo
    self.protocol_version = result.protocolVersion
    self.initialized = true

    -- Send initialized notification
    -- self.transport:notify("notifications/initialized", {})
    callback(nil, result)
  end)
end

---Stop the client.
function M:stop()
  if not self.transport then
    return
  end

  self.transport:stop()
  self.initialized = false
end

---@class Tool
---@field name string The name of the tool
---@field description string A description of the tool
---@field inputSchema table The JSON schema for the tool's input

---List available tools from the server.
---@param callback fun(err: string|nil, tools: CopilotChat.mcp.Tool[]|nil) Callback function with (error, tools)
function M:list_tools(callback)
  if not self.initialized then
    callback("MCP client not initialized", nil)
    return
  end

  self.transport:request("tools/list", nil, callback)
end

---@class CopilotChat.mcp.ToolResult
---@field err any|nil Error message or nil if successful
---@field result any|nil Result of the tool

---Call a tool on the server.
---@param name string Tool name
---@param arguments table Arguments for the tool
---@param callback fun(err?: , foo) Callback function with (error, result)
function M:call_tool(name, arguments, callback)
  if not self.initialized then
    callback("MCP client not initialized", nil)
    return
  end

  self.transport:request("tools/call", {
    name = name,
    arguments = arguments or {}
  }, callback)
end

--- Call a tool on the server synchronously.
--- This function must be called within a coroutine.
--- @param name string Tool name
--- @param arguments table Arguments for the tool
--- @return string|table|nil err, table|nil result
function M:call_tool_sync(name, arguments)
  local co = coroutine.running()
  if not co then
    error("call_tool_sync must be called within a coroutine")
  end

  ---@type CopilotChat.mcp.ToolResult
  local res = {}
  self:call_tool(name, arguments, function(err, result)
    res = { err = err, result = result }
    coroutine.resume(co)
  end)

  coroutine.yield()
  return res.err, res.result
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
