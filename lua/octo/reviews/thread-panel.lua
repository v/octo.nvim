local OctoBuffer = require("octo.model.octo-buffer").OctoBuffer
local utils = require "octo.utils"
local window_utils = require "octo.ui.window"
local vim = vim

local M = {}

-- Store the current floating window info
M.current_float = {
  winid = nil,
  outer_winid = nil,
  bufnr = nil,
  line = nil,
}

---Show review threads under cursor if there are any
---@param jump_to_buffer boolean
function M.show_review_threads(jump_to_buffer)
  -- This function is called from a very broad CursorHold event
  -- Check if we are in a diff buffer and otherwise return early
  local bufnr = vim.api.nvim_get_current_buf()
  
  -- If we're currently in the floating thread buffer itself, don't process
  -- This prevents the window from closing when navigating within it
  if M.current_float.bufnr and bufnr == M.current_float.bufnr then
    return
  end
  
  local split, path = utils.get_split_and_path(bufnr)
  if not split or not path then
    -- not on a diff buffer
    M.close_floating_thread_window()
    return
  end

  local review = require("octo.reviews").get_current_review()
  if not review then
    -- cant find an active review
    M.close_floating_thread_window()
    return
  end

  local file = review.layout:get_current_file()
  if not file then
    -- cant find the changed file metadata
    M.close_floating_thread_window()
    return
  end

  local pr = file.pull_request
  local review_level = review:get_level()
  ---@type octo.ReviewThread[]
  local threads = vim.tbl_values(review.threads)
  local line = vim.api.nvim_win_get_cursor(0)[1]

  -- get threads associated with current line
  local threads_at_cursor = {}
  for _, thread in ipairs(threads) do
    if
      review_level == "PR"
      and utils.is_thread_placed_in_buffer(thread, bufnr)
      and thread.startLine <= line
      and thread.line >= line
    then
      table.insert(threads_at_cursor, thread)
    elseif review_level == "COMMIT" then
      for _, comment in ipairs(thread.comments.nodes) do
        if
          review.layout.right.commit == comment.originalCommit.oid
          and utils.is_thread_placed_in_buffer(thread, bufnr)
          and thread.originalLine == line
        then
          table.insert(threads_at_cursor, thread)
          break
        end
      end
    end
  end

  -- render thread buffer if there are threads at the current line
  if #threads_at_cursor > 0 then
    -- If we're already showing threads at this line, don't recreate the window
    if M.current_float.line == line and M.current_float.winid and vim.api.nvim_win_is_valid(M.current_float.winid) then
      if jump_to_buffer then
        vim.api.nvim_set_current_win(M.current_float.winid)
      end
      return
    end
    
    -- Close any existing floating window
    M.close_floating_thread_window()
    
    local thread_buffer = M.create_thread_buffer(threads_at_cursor, pr.repo, pr.number, split, file.path)
    if thread_buffer then
      table.insert(file.associated_bufs, thread_buffer.bufnr)
      thread_buffer:configure()
      
      -- Create floating window with 80% width and height
      local winid, outer_winid = M.create_floating_thread_window(thread_buffer.bufnr)
      
      -- Store the float info
      M.current_float.winid = winid
      M.current_float.outer_winid = outer_winid
      M.current_float.bufnr = thread_buffer.bufnr
      M.current_float.line = line

      -- Set up keymaps for the floating window
      vim.keymap.set("n", "q", function()
        M.close_floating_thread_window()
      end, { buffer = thread_buffer.bufnr, silent = true, noremap = true })

      if jump_to_buffer then
        vim.api.nvim_set_current_win(winid)
      end
      
      vim.api.nvim_buf_call(thread_buffer.bufnr, function()
        vim.cmd [[diffoff!]]
        pcall(vim.cmd.normal, "]c")
      end)
    end
  else
    -- no threads at the current line, close the floating window
    M.close_floating_thread_window()
  end
end

---Close the floating thread window
function M.close_floating_thread_window()
  if M.current_float.winid and vim.api.nvim_win_is_valid(M.current_float.winid) then
    pcall(vim.api.nvim_win_close, M.current_float.winid, true)
  end
  if M.current_float.outer_winid and vim.api.nvim_win_is_valid(M.current_float.outer_winid) then
    pcall(vim.api.nvim_win_close, M.current_float.outer_winid, true)
  end
  M.current_float.winid = nil
  M.current_float.outer_winid = nil
  M.current_float.bufnr = nil
  M.current_float.line = nil
end

---Create a floating window for the thread buffer
---@param bufnr integer
---@return integer winid, integer outer_winid
function M.create_floating_thread_window(bufnr)
  -- Calculate 80% of screen width and height
  local vim_height = vim.o.lines - vim.o.cmdheight
  if vim.o.laststatus ~= 0 then
    vim_height = vim_height - 1
  end
  local vim_width = vim.o.columns

  local width = math.floor(vim_width * 0.8)
  local height = math.floor(vim_height * 0.8)

  -- Calculate offsets to center the window
  local x_offset = math.floor((vim_width - width) / 2)
  local y_offset = math.floor((vim_height - height) / 2)

  local border_width = 1
  local padding = 1
  local header_height = 1
  local header = "Review Thread Comments"

  -- Create outer window (border + header)
  local outer_winid = window_utils.create_border_header_float {
    width = width,
    border_width = border_width,
    padding = padding,
    header = header,
    header_height = header_height,
    height = height,
    y_offset = y_offset,
    x_offset = x_offset,
  }

  -- Create content window
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = y_offset + 2 * border_width + header_height,
    col = x_offset + border_width + padding,
    width = width - 2 * border_width - 2 * padding,
    height = height - 3 * border_width - 2 * header_height,
    focusable = true,
    style = "minimal",
  })
  
  -- Configure window options
  vim.wo[winid].previewwindow = true
  vim.wo[winid].foldcolumn = "0"
  vim.wo[winid].signcolumn = "yes"
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].cursorline = true
  vim.wo[winid].wrap = true

  -- Set up autocmd to close windows when buffer is left
  local augroup = vim.api.nvim_create_augroup("OctoFloatingThread_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "BufLeave", "BufDelete" }, {
    group = augroup,
    buffer = bufnr,
    callback = function()
      M.close_floating_thread_window()
    end,
  })

  -- Add keymap to close on <C-c>
  vim.keymap.set("n", "<C-c>", function()
    M.close_floating_thread_window()
  end, { buffer = bufnr, silent = true, noremap = true, desc = "Close floating thread window" })

  return winid, outer_winid
end

---@param split OctoSplit
---@param file FileEntry
function M.hide_thread_buffer(split, file)
  local alt_buf = file:get_alternative_buf(split)
  local alt_win = file:get_alternative_win(split)
  if vim.api.nvim_win_is_valid(alt_win) and vim.api.nvim_buf_is_valid(alt_buf) then
    local current_alt_bufnr = vim.api.nvim_win_get_buf(alt_win)
    if current_alt_bufnr ~= alt_buf then
      -- if we are not showing the corresponding alternative diff buffer, do so
      vim.api.nvim_win_set_buf(alt_win, alt_buf)

      -- Save cursor position before show_diff (which scrolls to sync windows)
      local current_win = vim.api.nvim_get_current_win()
      local cursor_pos = vim.api.nvim_win_get_cursor(current_win)

      -- show the diff
      file:show_diff()

      -- Restore cursor position (show_diff scrolls which can disrupt cursor)
      if vim.api.nvim_win_is_valid(current_win) then
        pcall(vim.api.nvim_win_set_cursor, current_win, cursor_pos)
      end
    end
  end
end

---Create a thread buffer
---@param threads ReviewThread[]
---@param repo string
---@param number integer
---@param side string
---@param path string
---@return OctoBuffer | nil
function M.create_thread_buffer(threads, repo, number, side, path)
  local current_review = require("octo.reviews").get_current_review()
  if not current_review then
    return
  end

  if not vim.startswith(path, "/") then
    path = "/" .. path
  end
  local line = threads[1].originalStartLine ~= vim.NIL and threads[1].originalStartLine or threads[1].originalLine
  local bufname = string.format("octo://%s/review/%s/threads/%s%s:%d", repo, current_review.id, side, path, line)
  local existing_bufnr = vim.fn.bufnr(bufname)

  if existing_bufnr ~= -1 then
    if vim.api.nvim_buf_is_loaded(existing_bufnr) then
      return octo_buffers[existing_bufnr]
    end

    -- Weird situation, force delete buffer and start from scratch
    vim.api.nvim_buf_delete(existing_bufnr, { force = true })
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, bufname)
  local buffer = OctoBuffer:new {
    bufnr = bufnr,
    number = number,
    repo = repo,
  }
  buffer:render_threads(threads)
  buffer:render_signs()
  vim.api.nvim_buf_call(bufnr, function()
    utils.clear_history()
  end)
  return buffer
end

return M
