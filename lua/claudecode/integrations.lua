---
-- Tree integration module for ClaudeCode.nvim
-- Handles detection and selection of files from nvim-tree, neo-tree, and oil.nvim
-- @module claudecode.integrations
local M = {}

--- Get selected files from the current tree explorer
--- @return table|nil files List of file paths, or nil if error
--- @return string|nil error Error message if operation failed
function M.get_selected_files_from_tree()
  local current_ft = vim.bo.filetype

  if current_ft == "NvimTree" then
    return M._get_nvim_tree_selection()
  elseif current_ft == "neo-tree" then
    return M._get_neotree_selection()
  elseif current_ft == "oil" then
    return M._get_oil_selection()
  elseif current_ft == "snacks_picker_list" then
    return M._get_snacks_explorer_selection()
  else
    return nil, "Not in a supported tree buffer (current filetype: " .. current_ft .. ")"
  end
end

--- Get selected files from nvim-tree
--- Supports both multi-selection (marks) and single file under cursor
--- @return table files List of file paths
--- @return string|nil error Error message if operation failed
function M._get_nvim_tree_selection()
  local success, nvim_tree_api = pcall(require, "nvim-tree.api")
  if not success then
    return {}, "nvim-tree not available"
  end

  local files = {}

  local marks = nvim_tree_api.marks.list()

  if marks and #marks > 0 then
    for i, mark in ipairs(marks) do
      if mark.type == "file" and mark.absolute_path and mark.absolute_path ~= "" then
        -- Check if it's not a root-level file (basic protection)
        if not string.match(mark.absolute_path, "^/[^/]*$") then
          table.insert(files, mark.absolute_path)
        end
      end
    end

    if #files > 0 then
      return files, nil
    end
  end

  local node = nvim_tree_api.tree.get_node_under_cursor()
  if node then
    if node.type == "file" and node.absolute_path and node.absolute_path ~= "" then
      -- Check if it's not a root-level file (basic protection)
      if not string.match(node.absolute_path, "^/[^/]*$") then
        return { node.absolute_path }, nil
      else
        return {}, "Cannot add root-level file. Please select a file in a subdirectory."
      end
    elseif node.type == "directory" and node.absolute_path and node.absolute_path ~= "" then
      return { node.absolute_path }, nil
    end
  end

  return {}, "No file found under cursor"
end

--- Get selected files from neo-tree
--- Uses neo-tree's own visual selection method when in visual mode
--- @return table files List of file paths
--- @return string|nil error Error message if operation failed
function M._get_neotree_selection()
  local success, manager = pcall(require, "neo-tree.sources.manager")
  if not success then
    return {}, "neo-tree not available"
  end

  local state = manager.get_state("filesystem")
  if not state then
    return {}, "neo-tree filesystem state not available"
  end

  local files = {}

  -- Use neo-tree's own visual selection method (like their copy/paste feature)
  local mode = vim.fn.mode()

  if mode == "V" or mode == "v" or mode == "\22" then
    local current_win = vim.api.nvim_get_current_win()

    if state.winid and state.winid == current_win then
      -- Use neo-tree's exact method to get visual range (from their get_selected_nodes implementation)
      local start_pos = vim.fn.getpos("'<")[2]
      local end_pos = vim.fn.getpos("'>")[2]

      -- Fallback to current cursor and anchor if marks are not valid
      if start_pos == 0 or end_pos == 0 then
        local cursor_pos = vim.api.nvim_win_get_cursor(0)[1]
        local anchor_pos = vim.fn.getpos("v")[2]
        if anchor_pos > 0 then
          start_pos = math.min(cursor_pos, anchor_pos)
          end_pos = math.max(cursor_pos, anchor_pos)
        else
          start_pos = cursor_pos
          end_pos = cursor_pos
        end
      end

      if end_pos < start_pos then
        start_pos, end_pos = end_pos, start_pos
      end

      local selected_nodes = {}

      for line = start_pos, end_pos do
        local node = state.tree:get_node(line)
        if node then
          -- Add validation for node types before adding to selection
          if node.type and node.type ~= "message" then
            table.insert(selected_nodes, node)
          end
        end
      end

      for i, node in ipairs(selected_nodes) do
        -- Enhanced validation: check for file type and valid path
        if node.type == "file" and node.path and node.path ~= "" then
          -- Additional check: ensure it's not a root node (depth protection)
          local depth = (node.get_depth and node:get_depth()) and node:get_depth() or 0
          if depth > 1 then
            table.insert(files, node.path)
          end
        end
      end

      if #files > 0 then
        return files, nil
      end
    end
  end

  if state.tree then
    local selection = nil

    if state.tree.get_selection then
      selection = state.tree:get_selection()
    end

    if (not selection or #selection == 0) and state.selected_nodes then
      selection = state.selected_nodes
    end

    if selection and #selection > 0 then
      for i, node in ipairs(selection) do
        if node.type == "file" and node.path then
          table.insert(files, node.path)
        end
      end

      if #files > 0 then
        return files, nil
      end
    end
  end

  if state.tree then
    local node = state.tree:get_node()

    if node then
      if node.type == "file" and node.path then
        return { node.path }, nil
      elseif node.type == "directory" and node.path then
        return { node.path }, nil
      end
    end
  end

  return {}, "No file found under cursor"
end

--- Get selected files from oil.nvim
--- Supports both visual selection and single file under cursor
--- @return table files List of file paths
--- @return string|nil error Error message if operation failed
function M._get_oil_selection()
  local success, oil = pcall(require, "oil")
  if not success then
    return {}, "oil.nvim not available"
  end

  local bufnr = vim.api.nvim_get_current_buf() --[[@as number]]
  local files = {}

  -- Check if we're in visual mode
  local mode = vim.fn.mode()
  if mode == "V" or mode == "v" or mode == "\22" then
    -- Visual mode: use the common visual range function
    local visual_commands = require("claudecode.visual_commands")
    local start_line, end_line = visual_commands.get_visual_range()

    -- Get current directory once
    local dir_ok, current_dir = pcall(oil.get_current_dir, bufnr)
    if not dir_ok or not current_dir then
      return {}, "Failed to get current directory"
    end

    -- Process each line in the visual selection
    for line = start_line, end_line do
      local entry_ok, entry = pcall(oil.get_entry_on_line, bufnr, line)
      if entry_ok and entry and entry.name then
        -- Skip parent directory entries
        if entry.name ~= ".." and entry.name ~= "." then
          local full_path = current_dir .. entry.name
          -- Handle various entry types
          if entry.type == "file" or entry.type == "link" then
            table.insert(files, full_path)
          elseif entry.type == "directory" then
            -- Ensure directory paths end with /
            table.insert(files, full_path:match("/$") and full_path or full_path .. "/")
          else
            -- For unknown types, return the path anyway
            table.insert(files, full_path)
          end
        end
      end
    end

    if #files > 0 then
      return files, nil
    end
  else
    -- Normal mode: get file under cursor with error handling
    local ok, entry = pcall(oil.get_cursor_entry)
    if not ok or not entry then
      return {}, "Failed to get cursor entry"
    end

    local dir_ok, current_dir = pcall(oil.get_current_dir, bufnr)
    if not dir_ok or not current_dir then
      return {}, "Failed to get current directory"
    end

    -- Process the entry
    if entry.name and entry.name ~= ".." and entry.name ~= "." then
      local full_path = current_dir .. entry.name
      -- Handle various entry types
      if entry.type == "file" or entry.type == "link" then
        return { full_path }, nil
      elseif entry.type == "directory" then
        -- Ensure directory paths end with /
        return { full_path:match("/$") and full_path or full_path .. "/" }, nil
      else
        -- For unknown types, return the path anyway
        return { full_path }, nil
      end
    end
  end

  return {}, "No file found under cursor"
end

--- Get selected files from snacks.nvim explorer
--- Supports both multi-selection and single file under cursor
--- @return table files List of file paths
--- @return string|nil error Error message if operation failed
function M._get_snacks_explorer_selection()
  local success, snacks = pcall(require, "snacks")
  if not success or not snacks.picker then
    return {}, "snacks.nvim picker not available"
  end

  -- Get active pickers
  local active_pickers = snacks.picker.get and snacks.picker.get()
  if not active_pickers or #active_pickers == 0 then
    return {}, "No active snacks picker found"
  end

  -- Use the most recent picker
  local current_picker = active_pickers[#active_pickers]
  -- if not current_picker or not current_picker.is_active or not current_picker:is_active() then
  --   return {}, "Snacks picker not active"
  -- end

  local files = {}

  -- Try to get selected items first (with fallback to current)
  local selected_items = current_picker.selected and current_picker:selected({ fallback = true })
  if selected_items and #selected_items > 0 then
    for _, item in ipairs(selected_items) do
      if M._is_valid_snacks_file_item(item) then
        local file_path = M._extract_snacks_file_path(item)
        if file_path then
          table.insert(files, file_path)
        end
      end
    end

    if #files > 0 then
      return files, nil
    end
  end

  -- Fallback to current item
  local current_item = current_picker.current and current_picker:current()
  if current_item and M._is_valid_snacks_file_item(current_item) then
    local file_path = M._extract_snacks_file_path(current_item)
    if file_path then
      return { file_path }, nil
    end
  end

  return {}, "No file found under cursor"
end

--- Check if snacks item is a valid file item
--- @param item table The snacks picker item
--- @return boolean true if valid file item
function M._is_valid_snacks_file_item(item)
  if not item then
    return false
  end

  -- Check for file path in the item
  if item.file then
    if type(item.file) == "string" and item.file ~= "" then
      -- Security check: exclude root-level files
      if not string.match(item.file, "^/[^/]*$") then
        return true
      end
    end
  end

  -- Alternative path formats that snacks might use
  if item.path then
    if type(item.path) == "string" and item.path ~= "" then
      if not string.match(item.path, "^/[^/]*$") then
        return true
      end
    end
  end

  return false
end

--- Extract file path from snacks item
--- @param item table The snacks picker item
--- @return string|nil file_path Normalized file path or nil
function M._extract_snacks_file_path(item)
  if not item then
    return nil
  end

  local file_path = item.file or item.path
  if not file_path or file_path == "" then
    return nil
  end

  -- Convert relative paths to absolute if needed
  if not vim.startswith(file_path, "/") then
    local cwd = item.cwd or vim.fn.getcwd()
    file_path = vim.fs.normalize(cwd .. "/" .. file_path)
  end

  return file_path
end

return M
