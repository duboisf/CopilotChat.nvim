local utils = require('CopilotChat.utils')

local EDITOR_VERSION = 'Neovim/' .. vim.version().major .. '.' .. vim.version().minor .. '.' .. vim.version().patch

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

local cached_github_token = nil

local function config_path()
  local config = vim.fs.normalize('$XDG_CONFIG_HOME')
  if config and vim.uv.fs_stat(config) then
    return config
  end
  if vim.fn.has('win32') > 0 then
    config = vim.fs.normalize('$LOCALAPPDATA')
    if not config or not vim.uv.fs_stat(config) then
      config = vim.fs.normalize('$HOME/AppData/Local')
    end
  else
    config = vim.fs.normalize('$HOME/.config')
  end
  if config and vim.uv.fs_stat(config) then
    return config
  end
end

--- Get the github copilot oauth cached token (gu_ token)
---@return string
local function get_github_token()
  if cached_github_token then
    return cached_github_token
  end

  -- loading token from the environment only in GitHub Codespaces
  local token = os.getenv('GITHUB_TOKEN')
  local codespaces = os.getenv('CODESPACES')
  if token and codespaces then
    cached_github_token = token
    return token
  end

  -- loading token from the file
  local config_path = config_path()
  if not config_path then
    error('Failed to find config path for GitHub token')
  end

  -- token can be sometimes in apps.json sometimes in hosts.json
  local file_paths = {
    config_path .. '/github-copilot/hosts.json',
    config_path .. '/github-copilot/apps.json',
  }

  for _, file_path in ipairs(file_paths) do
    local file_data = utils.read_file(file_path)
    if file_data then
      local parsed_data = utils.json_decode(file_data)
      if parsed_data then
        for key, value in pairs(parsed_data) do
          if string.find(key, 'github.com') then
            cached_github_token = value.oauth_token
            return value.oauth_token
          end
        end
      end
    end
  end

  error('Failed to find GitHub token')
end

---@class CopilotChat.Provider.model
---@field id string
---@field name string
---@field tokenizer string?
---@field max_input_tokens number?
---@field max_output_tokens number?

---@class CopilotChat.Provider.agent
---@field id string
---@field name string
---@field description string?

---@class CopilotChat.Provider.embed
---@field index number
---@field embedding table<number>

---@class CopilotChat.Provider.options
---@field model CopilotChat.Provider.model
---@field agent CopilotChat.Provider.agent?
---@field temperature number?
---@field tools table

---@class CopilotChat.Provider.input
---@field role string
---@field content string

---@class CopilotChat.Provider.reference
---@field name string
---@field url string

---@class CopilotChat.Provider.ToolCall
---@field tool string
---@field arguments table
---@field result table
---@field error string

---@class CopilotChat.Provider.output
---@field content string
---@field tool_calls CopilotChat.ToolCall[]
---@field finish_reason string?
---@field total_tokens number?
---@field references table<CopilotChat.Provider.reference>?

---@class CopilotChat.Provider
---@field disabled nil|boolean
---@field get_headers nil|fun():table<string, string>,number?
---@field get_agents nil|fun(headers:table):table<CopilotChat.Provider.agent>
---@field get_models nil|fun(headers:table):table<CopilotChat.Provider.model>
---@field embed nil|string|fun(inputs:table<string>, headers:table):table<CopilotChat.Provider.embed>
---@field prepare_input nil|fun(inputs:table<CopilotChat.Provider.input>, opts:CopilotChat.Provider.options):table
---@field prepare_output nil|fun(output:table, opts:CopilotChat.Provider.options):CopilotChat.Provider.output
---@field get_url nil|fun(opts:CopilotChat.Provider.options):string

---@type table<string, CopilotChat.Provider>
local M = {}

M.copilot = {
  embed = 'copilot_embeddings',

  ---@async
  get_headers = function()
    local thread = coroutine.running()
    if not thread then
      error('get_headers must be called from a coroutine')
    end

    local err = nil
    local resp = nil
    utils.curl_get('https://api.github.com/copilot_internal/v2/token', {
        json_response = true,
        headers = {
          ['Authorization'] = 'Token ' .. get_github_token(),
        },
      },
      function(response, error)
        resp = response
        err = error
        coroutine.resume(thread)
      end
    )

    coroutine.yield()

    if err then
      error(err)
    end

    return {
          ['Authorization'] = 'Bearer ' .. resp.body.token,
          ['Editor-Version'] = EDITOR_VERSION,
          ['Editor-Plugin-Version'] = 'CopilotChat.nvim/*',
          ['Copilot-Integration-Id'] = 'vscode-chat',
        },
        resp.body.expires_at
  end,

  ---@async
  get_agents = function(headers)
    local thread = coroutine.running()
    if not thread then
      error('get_agents must be called from a coroutine')
    end

    local resp = nil
    local err = nil
    utils.curl_get('https://api.githubcopilot.com/agents', {
        json_response = true,
        headers = headers,
      },
      function(response, error)
        resp = response
        err = error
        coroutine.resume(thread)
      end
    )

    coroutine.yield()

    dlog.debug('get_agents response')
    if err then
      error(err)
    end

    return vim.tbl_map(function(agent)
      return {
        id = agent.slug,
        name = agent.name,
        description = agent.description,
      }
    end, resp.body.agents)
  end,

  ---@async
  get_models = function(headers)
    local thread = coroutine.running()
    if not thread then
      error('get_models must be called from a coroutine')
    end

    local resp = nil
    local err = nil
    utils.curl_get('https://api.githubcopilot.com/models', {
      json_response = true,
      headers = headers,
    }, function(response, error)
      err = error
      resp = response
      coroutine.resume(thread)
    end)

    coroutine.yield()

    dlog.debug('get_models response')
    if err then
      error(err)
    end

    local models = vim
        .iter(resp.body.data)
        :filter(function(model)
          return model.capabilities.type == 'chat'
        end)
        :map(function(model)
          return {
            id = model.id,
            name = model.name,
            tokenizer = model.capabilities.tokenizer,
            max_input_tokens = model.capabilities.limits.max_prompt_tokens,
            max_output_tokens = model.capabilities.limits.max_output_tokens,
            policy = not model['policy'] or model['policy']['state'] == 'enabled',
            version = model.version,
          }
        end)
        :totable()

    local version_map = {}
    for _, model in ipairs(models) do
      if not version_map[model.version] or #model.id < #version_map[model.version] then
        version_map[model.version] = model.id
      end
    end

    models = vim.tbl_map(function(id)
      return vim.tbl_filter(function(model)
        return model.id == id
      end, models)[1]
    end, vim.tbl_values(version_map))

    for _, model in ipairs(models) do
      if not model.policy then
        dlog.debug('policy not enabled for model', model.id)
        utils.curl_post('https://api.githubcopilot.com/models/' .. model.id .. '/policy', {
          headers = headers,
          json_request = true,
          body = { state = 'enabled' },
        })
      end
    end

    dlog.debug('get_models return')
    return models
  end,

  prepare_input = function(inputs, opts)
    local is_o1 = vim.startswith(opts.model.id, 'o1')

    inputs = vim.tbl_map(function(input)
      if is_o1 then
        if input.role == 'system' then
          input.role = 'user'
        end
      end

      return input
    end, inputs)

    local out = {
      messages = inputs,
      model = opts.model.id,
    }

    if not is_o1 then
      out.n = 1
      out.top_p = 1
      out.stream = true
      out.temperature = opts.temperature
    end

    if opts.model.max_output_tokens then
      out.max_tokens = opts.model.max_output_tokens
    end

    out.tools = opts.tools

    return out
  end,

  prepare_output = function(output)
    local references = {}

    if output.copilot_references then
      for _, reference in ipairs(output.copilot_references) do
        local metadata = reference.metadata
        if metadata and metadata.display_name and metadata.display_url then
          table.insert(references, {
            name = metadata.display_name,
            url = metadata.display_url,
          })
        end
      end
    end

    local message
    if output.choices and #output.choices > 0 then
      message = output.choices[1]
    else
      message = output
    end

    local content = message.message and message.message.content or message.delta and message.delta.content

    local tool_calls = message.message and message.message.tool_calls or message.delta and message.delta.tool_calls or {}

    local usage = message.usage and message.usage.total_tokens or output.usage and output.usage.total_tokens

    local finish_reason = message.finish_reason or message.done_reason or output.finish_reason or output.done_reason

    return {
      content = content,
      tool_calls = tool_calls,
      finish_reason = finish_reason,
      total_tokens = usage,
      references = references,
    }
  end,

  get_url = function(opts)
    if opts.agent then
      return 'https://api.githubcopilot.com/agents/' .. opts.agent.id .. '?chat'
    end

    return 'https://api.githubcopilot.com/chat/completions'
  end,
}

M.github_models = {
  embed = 'copilot_embeddings',

  get_headers = function()
    return {
      ['Authorization'] = 'Bearer ' .. get_github_token(),
      ['x-ms-useragent'] = EDITOR_VERSION,
      ['x-ms-user-agent'] = EDITOR_VERSION,
    }
  end,

  ---@async
  get_models = function(headers)
    local thread = coroutine.running()
    if not thread then
      error('github_models.get_models must be called from a coroutine')
    end
    local resp, err = nil, nil
    utils.curl_post('https://api.catalog.azureml.ms/asset-gallery/v1.0/models', {
      headers = headers,
      json_request = true,
      json_response = true,
      body = {
        filters = {
          { field = 'freePlayground', values = { 'true' },   operator = 'eq' },
          { field = 'labels',         values = { 'latest' }, operator = 'eq' },
        },
        order = {
          { field = 'displayName', direction = 'asc' },
        },
      },
    }, function(response, error)
      resp = response
      err = error
      coroutine.resume(thread)
    end)

    coroutine.yield()

    if err then
      error(err)
    end

    return vim
        .iter(resp.body.summaries)
        :filter(function(model)
          return vim.tbl_contains(model.inferenceTasks, 'chat-completion')
        end)
        :map(function(model)
          return {
            id = model.name,
            name = model.displayName,
            tokenizer = 'o200k_base',
            max_input_tokens = model.modelLimits.textLimits.inputContextWindow,
            max_output_tokens = model.modelLimits.textLimits.maxOutputTokens,
          }
        end)
        :totable()
  end,

  prepare_input = M.copilot.prepare_input,
  prepare_output = M.copilot.prepare_output,

  get_url = function()
    return 'https://models.inference.ai.azure.com/chat/completions'
  end,
}

M.copilot_embeddings = {
  get_headers = M.copilot.get_headers,

  ---@async
  embed = function(inputs, headers)
    local thread = coroutine.running()
    if not thread then
      error('copilot_embeddings.embed must be called from a coroutine')
    end
    local resp, err = nil, nil
    utils.curl_post('https://api.githubcopilot.com/embeddings', {
      headers = headers,
      json_request = true,
      json_response = true,
      body = {
        dimensions = 512,
        input = inputs,
        model = 'text-embedding-3-small',
      },
    }, function(response, error)
      resp = response
      err = error
      coroutine.resume(thread)
    end)

    coroutine.yield()

    if err then
      error(err)
    end

    return resp.body.data
  end,
}

return M
