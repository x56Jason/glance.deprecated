local curl = require('plenary.curl')
local glance = require("glance")
local Buffer = require("glance.buffer")
local CommitView = require("glance.commit_view")
local LineBuffer = require('glance.line_buffer')

local M = {
	index = 1,
}

local function space_with_level(level)
	local str = ""
	for i = 1, level do
		str = str .. "    "
	end
	return str
end

local function add_sign(signs, index, name)
	signs[index] = name
end

local function add_highlight(highlights, line, from, to, name)
	table.insert(highlights, {
		line = line - 1,
		from = from,
		to = to,
		name = name
	})
end

local function parse_log(output)
	local output_len = #output
	local commits = {}

	for i=1,output_len do
		local hash, rest = output[i]:match("([a-zA-Z0-9]+) (.*)")
		if hash ~= nil then
			local remote, message = rest:match("^%((.+)%) (.*)")
			if remote == nil then
				message = rest
			end

			local commit = {
				hash = hash,
				remote = remote or "",
				message = message
			}
			table.insert(commits, commit)
		end
	end

	return commits
end

local function get_table_size(t)
    local count = 0
    for _, __ in pairs(t) do
        count = count + 1
    end
    return count
end

function M.new(cmdline, pr)
	local pr_number = pr and pr.number
	local desc_head = pr and pr.desc_head
	local desc_body = pr and pr.desc_body
	local name = "GlanceLog-"

	local commit_limit = "-256"
	if not pr then
		if cmdline ~= "" then
			commit_limit = cmdline
		end
		name = name .. M.index
		M.index = M.index + 1
	else
		commit_limit = pr.merge_base .. ".." .. pr.sha
		cmdline = commit_limit
		name = pr.desc_head.url:gsub("^https?", "glance")
	end
	local cmd = "git log --oneline --no-abbrev-commit --decorate " .. commit_limit
	local raw_output = vim.fn.systemlist(cmd)
	local commits = parse_log(raw_output)
	local commit_start_line = 1
	if desc_body then
		commit_start_line = commit_start_line + 2 + get_table_size(desc_head) + 1 + #desc_body + 1
	end
	local comment_start_line = commit_start_line + get_table_size(commits) + 1

	local comments = {}
	if pr_number then
		comments = glance.get_pr_comments(pr_number)
	end

	local instance = {
		cmdline = cmdline,
		pr = pr,
		name = name,
		pr_number = pr_number,
		labels = pr and pr.labels,
		head = desc_head,
		body = desc_body,
		commits = commits,
		commit_start_line = commit_start_line,
		comments = comments,
		comment_start_line = comment_start_line,
		text = {},
		buffer = nil,
	}

	setmetatable(instance, { __index = M })

	return instance
end

function M:open_alldiff_view()
	if not self.pr then
		vim.notify("Not a pr log", vim.log.levels.WARN, {})
	end
	local view = CommitView.new_pr_alldiff(self.pr.merge_base, self.pr.sha, self)
	if not view then return end
	view:open()
	view:initialize()
end

function M:open_commit_view(commit)
	local view = CommitView.new(commit)
	if (view == nil) then
		vim.notify("Bad commit: " .. commit, vim.log.levels.ERROR, {})
		return
	end
	view:open()
	view:initialize()
end

function M:open_parallel_views(commit)
	local commit_id = commit.hash
	local upstream_commit_id = CommitView.get_upstream_commit(commit_id)

	if upstream_commit_id == nil then
		local upstream_commit = glance.comparelist_find_commit(commit)
		if upstream_commit then
			upstream_commit_id = upstream_commit.hash
		end
	end

	if upstream_commit_id == nil then
		vim.notify("Not a backport commit", vim.log.levels.ERROR, {})
		return
	end

	local view_left = CommitView.new(upstream_commit_id)
	if (view_left == nil) then
		vim.notify("Bad commit: " .. upstream_commit_id, vim.log.levels.ERROR, {})
		return
	end
	local view_right = CommitView.new(commit_id)
	if (view_right == nil) then
		vim.notify("Bad commit: " .. commit_id, vim.log.levels.ERROR, {})
		view_left:close()
		return
	end

	CommitView.sort_diffs_file(view_left, view_right)

	view_left:open({name = "Upstream: " .. upstream_commit_id})
	view_left:initialize()
	vim.cmd("wincmd o")
	vim.cmd(string.format("%d", view_left:get_first_hunk_line()))
	vim.cmd.normal("zz")
	vim.cmd("set scrollbind")

	view_right:open({name = "Backport: " .. commit_id})
	view_right:initialize()
	vim.cmd("wincmd L")
	vim.cmd(string.format("%d", view_right:get_first_hunk_line()))
	vim.cmd.normal("zz")
	vim.cmd("set scrollbind")

	view_left:set_scrollbind_view(view_right)
	view_right:set_scrollbind_view(view_left)
end

function M:open_patchdiff_view(commit)
	local view = CommitView.new_patchdiff(commit)
	if not view then return end
	view:open({filetype="GlancePatchDiff"})
	view:initialize()
end

function M:close()
	glance.set_state(self.buffer.handle, nil)
	self.buffer:close()
	self.buffer = nil
	self.pr = nil
	self.labels = nil
	self.head = nil
	self.body = nil
	self.commits = nil
	self.comments = nil
end

function M:delete_pr_comment(comment)
	local token = glance.config.gitee.token
	local opts = {
		method = "delete",
		headers = {
			["Accept"] = "application/json",
			["User-Agent"] = "Glance",
		},
	}
	opts.url = "https://gitee.com/api/v5/repos/" .. glance.config.gitee.repo .. "/pulls/comments/" .. comment.id
	opts.url = opts.url .. "?access_token=" .. token .. "&id=" .. comment.id
	vim.notify("url: "..opts.url, vim.log.levels.INFO, {})
	local response = curl["delete"](opts)
	vim.notify("response: exit: "..response.exit..", status: "..response.status, vim.log.levels.INFO, {})
	if response.exit ~= 0 then
		vim.notify("response: " .. response.body, vim.log.levels.INFO, {})
		return
	end

	self.comments = glance.get_pr_comments(self.pr_number)
	self.buffer:unlock()
	self.buffer:set_lines(self.comment_start_line-1, -1, false, {})
	self:append_comments(self.comments, 0)
	self.buffer:lock()
end

function M:post_pr_comment(message)
	local pr_number = self.pr_number
	local token = glance.config.gitee.token
	local opts = {
		method = "post",
		url = "https://gitee.com/api/v5/repos/" .. glance.config.gitee.repo .. "/pulls/" .. pr_number .. "/comments?number=" .. pr_number,
		headers = {
			["Accept"] = "application/json",
			["Connection"] = "keep-alive",
			["User-Agent"] = "Glance",
		},
		body = {
			["access_token"] = token,
			["body"] = message,
		},
	}
	if self.comment_file then
		opts.body["path"] = self.comment_file
		opts.body["position"] = self.comment_file_pos
		vim.notify("file: "..self.comment_file, vim.log.levels.INFO, {})
		vim.notify("file_pos: "..self.comment_file_pos, vim.log.levels.INFO, {})
	end
	vim.notify("url: " .. opts.url, vim.log.levels.INFO, {})
	local response = curl["post"](opts)
	vim.notify("response: exit: " .. response.exit .. ", status: " .. response.status, vim.log.levels.INFO, {})
	if response.exit ~= 0 then
		vim.notify("response: " .. response.body, vim.log.levels.INFO, {})
		return nil
	end
	local comment = vim.fn.json_decode(response.body)
	return comment
end

local function concatenate_lines(lines)
	local message = nil
	for _, line in ipairs(lines) do
		if not message then 
			message = line
		else
			message = message .. "\n" .. line
		end
	end
	return message
end

function M:do_pr_comment(file, file_pos)
	self.comment_file = file
	self.comment_file_pos = file_pos
	local config = {
		name = "GlanceComment",
		mappings = {
			n = {
				["<c-p>"] = function()
					local lines = self.comment_buffer:get_lines(0, -1, false)
					local message = concatenate_lines(lines)
					local comment = self:post_pr_comment(message)
					if comment then
						table.insert(self.comments, comment)
						self:append_comments({comment}, 0)
					end
					self.comment_buffer:close()
				end,
			},
		}
	}
	local buffer = Buffer.create(config)
	if buffer == nil then
		return
	end

	self.comment_buffer = buffer
	vim.api.nvim_create_autocmd("BufDelete", {
		buffer = 0,
		callback = function()
			self.comment_buffer = nil
		end,
	})

	vim.cmd('startinsert')
end

local function put_one_comment(output, signs, comment, level)
	comment.created_at = comment.created_at:gsub("T", " ")
	local comment_head = string.format("%d | %s | %s | %s", comment.id, comment.user.login, comment.user.name, comment.created_at)
	local level_space = space_with_level(level)

	output:append(level_space .. "> " .. comment_head)
	add_sign(signs, #output, "GlanceLogCommentHead")
	comment.start_line = #output

	output:append("")
	local comment_body = vim.split(comment.body, "\n")
	for _, line in pairs(comment_body) do
		output:append("  " .. level_space .. line)
	end
	output:append("")
	comment.end_line = #output

	if comment.children then
		local child_level = level + 1
		for _, child in pairs(comment.children) do
			put_one_comment(output, signs, child, child_level)
		end
	end
end

function M:append_comments(comments, level)
	if #comments == 0 then
		return
	end

	local output = LineBuffer.new(self.buffer:get_lines(0, -1, false))
	local signs = {}

	local function table_slice(tbl, first, last, step)
		local sliced = {}

		for i = first or 1, last or #tbl, step or 1 do
			sliced[#sliced+1] = tbl[i]
		end

		return sliced
	end
	local start_line = #output + 1
	for _, comment in pairs(comments) do
		if not comment.in_reply_to_id then
			put_one_comment(output, signs, comment, level)
		end
	end
	local end_line = #output

	local lines = table_slice(output, start_line, end_line)
	self.buffer:unlock()
	self.buffer:set_lines(start_line - 1, end_line - 1, false, lines)

	for line, name in pairs(signs) do
		self.buffer:place_sign(line, name, "hl")
	end
	self.buffer:lock()
	vim.cmd("syntax on")
end

function M:get_cursor_comment(line)
	for _, comment in ipairs(self.comments) do
		if line >= comment.start_line and line <= comment.end_line then
			return comment
		end
	end
	return nil
end

function M:update_one_commit(line, select)
	local commits = self.commits
	local commit_start_line = self.commit_start_line
	local index = line - commit_start_line + 1
	local commit = commits[index]
	local output = ""

	commit.in_comparelist = true

	if commit.remote == "" then
		output = string.sub(commit.hash, 1, 12) .. " " .. commit.message
	else
		output = string.sub(commit.hash, 1, 12) .. " (" .. commit.remote .. ") " .. commit.message
	end
	self.buffer:unlock()
	self.buffer:set_lines(line-1, line, false, {output})

	local from = 0
	local to = 12 -- length of abrev commit_id
	local hl_name = "GlanceLogCompareList"
	if select then
		hl_name = "GlanceLogSelect"
	end
	self.buffer:add_highlight(line-1, from, to, hl_name)
	from = to + 1
	if commit.remote ~= "" then
		to = from + #commit.remote + 2
		self.buffer:add_highlight(line-1, from, to, "GlanceLogRemote")
		from = to + 1
	end
	to = from + #commit.message
	self.buffer:add_highlight(line-1, from, to, "GlanceLogSubject")
	self.buffer:lock()
end

function M.comparelist_add_commit_range()
	local bufnr = vim.api.nvim_get_current_buf()
	local log_view = glance.get_state(bufnr)
	local commits = log_view.commits
	local commit_start_line = log_view.commit_start_line
	local commit_count = get_table_size(log_view.commits)
	local vstart = vim.fn.getpos('v')
	local vend = vim.fn.getpos('.')
	local start_row = vstart[2]
	local end_row = vend[2]
	if start_row > end_row then
		start_row = end_row
		end_row = vstart[2]
	end
	if start_row < commit_start_line then
		start_row = commit_start_line
	end
	if end_row >= commit_start_line + commit_count then
		end_row = commit_start_line + commit_count - 1
	end
	if end_row < start_row then
		end_row = start_row
	end

	for i=start_row,end_row do
		local commit = commits[i]
		glance.comparelist_add_commit(commit)
		log_view:update_one_commit(i)
	end
end

function M:create_buffer()
	local commits = self.commits
	local commit_start_line = self.commit_start_line
	local commit_count = get_table_size(self.commits)
	local function do_list_parallel()
		local line = vim.fn.line '.'
		if line >= commit_start_line and line < commit_start_line + commit_count then
			line = line - commit_start_line + 1
			local commit = commits[line]
			self:open_parallel_views(commit)
			return
		end
		vim.notify("Not a commit", vim.log.levels.WARN)
	end
	local function do_patchdiff()
		local line = vim.fn.line '.'
		if line >= commit_start_line and line < commit_start_line + commit_count then
			line = line - commit_start_line + 1
			local commit = commits[line]
			self:open_patchdiff_view(commit)
			return
		end
		vim.notify("Not a commit", vim.log.levels.WARN)
	end
	local config = {
		name = self.name,
		filetype = "GlanceLog",
		bufhidden = "hide",
		mappings = {
			n = {
				["<c-s>"] = function()
					local line = vim.fn.line '.'
					if line < commit_start_line or line >= commit_start_line + commit_count then
						vim.notify("Not a commit", vim.log.levels.WARN)
						return
					end
					local index = line - commit_start_line + 1
					local commit = commits[index]
					glance.comparelist_add_commit(commit)
					self:update_one_commit(line)
				end,
				["<c-t>"] = function()
					self:open_alldiff_view()
				end,
				["<enter>"] = function()
					local line = vim.fn.line '.'
					if line >= commit_start_line and line < commit_start_line + commit_count then
						line = line - commit_start_line + 1
						local commit = commits[line].hash
						self:open_commit_view(commit)
						return
					end
					vim.notify("Not a commit", vim.log.levels.WARN)
				end,
				["l"] = do_list_parallel,
				["2"] = do_list_parallel,
				["p"] = do_patchdiff,
				["e"] = do_patchdiff,
				["<c-r>"] = function()
					if not self.pr_number then
						vim.notify("not a pr", vim.log.levels.WARN, {})
						return
					end
					local answer = vim.fn.confirm("Create a comment for this PR?", "&yes\n&no")
					if answer ~= 1 then
						return
					end
					self:do_pr_comment()
				end,
				["<c-d>"] = function()
					if not self.pr_number then
						vim.notify("not a pr", vim.log.levels.WARN, {})
						return
					end
					local line = vim.fn.line '.'
					local comment = self:get_cursor_comment(line)
					if not comment then
						vim.notify("Cursor not in a comment", vim.log.levels.WARN, {})
						return
					end
					local answer = vim.fn.confirm(string.format("Delete comment (id %d)?", comment.id), "&yes\n&no")
					if answer ~= 1 then
						return
					end
					vim.cmd("redraw")
					vim.print("Deleting comment " .. comment.id .. " ...")
					vim.schedule(function()
						self:delete_pr_comment(comment)
						vim.print("Delete done")
					end)
				end,
				["<F5>"] = function()
					if not self.pr_number then
						vim.notify("not a pr", vim.log.levels.WARN, {})
						return
					end
					local answer = vim.fn.confirm(string.format("Refresh pr %d?", self.pr_number), "&yes\n&no")
					if answer ~= 1 then
						return
					end
					self:close()
					vim.cmd("redraw")
					glance.do_glance_pr(self.pr_number)
				end,
				["q"] = function()
					if glance.config.q_quit_log == "off" then
						return
					end
					self:close()
				end
			}
		},
	}

	local buffer = Buffer.create(config)
	if buffer == nil then
		return
	end
	vim.cmd("wincmd o")

	glance.set_state(buffer.handle, self)

	vim.api.nvim_buf_set_keymap(0, "v", "<c-s>",
		"<cmd>lua require('glance.log_view').comparelist_add_commit_range()<CR><Esc>",
		{noremap = true, silent = true})

	self.buffer = buffer
end

local function put_one_commit(output, highlights, commit)
	if commit.remote == "" then
		output:append(string.sub(commit.hash, 1, 12) .. " " .. commit.message)
	else
		output:append(string.sub(commit.hash, 1, 12) .. " (" .. commit.remote .. ") " .. commit.message)
	end

	local from = 0
	local to = 12 -- length of abrev commit_id
	local hl_name = "GlanceLogCommit"
	if commit.in_comparelist then
		hl_name = "GlanceLogCompareList"
	end
	add_highlight(highlights, #output, from, to, hl_name)
	from = to + 1
	if commit.remote ~= "" then
		to = from + #commit.remote + 2
		add_highlight(highlights, #output, from, to, "GlanceLogRemote")
		from = to + 1
	end
	to = from + #commit.message
	add_highlight(highlights, #output, from, to, "GlanceLogSubject")
end

function M:put_pr_headers(output, highlights, signs)
	local label_hl_name = {
		["openeuler-cla/yes"] = "GlanceLogCLAYes",
		["lgtm"] = "GlanceLogLGTM",
		["ci_successful"] = "GlanceLogCISuccess",
		["sig/Kernel"] = "GlanceLogSigKernel",
		["stat/needs-squash"] = "GlanceLogNeedSquash",
		["Acked"] = "GlanceLogAcked",
		["approved"] = "GlanceLogApproved",
		["newcomer"] = "GlanceLogNewComer",
	}
	local head = "Pull-Request !" .. self.pr_number .. "        "
	local hls = {}
	local from = 0
	local to = #head
	table.insert(hls, {from=from, to=to, name="GlanceLogHeader"})
	for _, label in pairs(self.labels) do
		local label_str = label.name
		head = head .. " | " .. label_str
		from = to + 3
		to = from + #label_str
		if label_hl_name[label_str] then
			table.insert(hls, {from=from, to=to, name=label_hl_name[label_str]})
		end
	end
	output:append(head)
	for _, hl in pairs(hls) do
		add_highlight(highlights, #output, hl.from, hl.to, hl.name)
	end

	output:append("---")

	self.head.created_at = self.head.created_at:gsub("T", " ")
	self.head.updated_at = self.head.updated_at:gsub("T", " ")

	output:append("URL:      " .. self.head.url)
	add_sign(signs, #output, "GlanceLogHeaderField")
	output:append("Creator:  " .. self.head.creator)
	add_sign(signs, #output, "GlanceLogHeaderField")
	output:append("Head:     " .. self.head.head)
	add_sign(signs, #output, "GlanceLogHeaderHead")
	output:append("Base:     " .. self.head.base)
	add_sign(signs, #output, "GlanceLogHeaderBase")
	output:append("Created:  " .. self.head.created_at)
	add_sign(signs, #output, "GlanceLogHeaderField")
	output:append("Updated:  " .. self.head.updated_at)
	add_sign(signs, #output, "GlanceLogHeaderField")
	if self.head.mergeable then
		output:append("Mergable: true")
	else
		output:append("Mergable: false")
	end
	add_sign(signs, #output, "GlanceLogHeaderField")
	output:append("State:    " .. self.head.state)
	add_sign(signs, #output, "GlanceLogHeaderField")
	output:append("Title:    " .. self.head.title)
end

function M:put_pr_body(output)
	for _, line in pairs(self.body) do
		local to = string.find(line, "\r", 1)
		if to then
			line = string.sub(line, 1, to - 1)
		end
		output:append("    " .. line)
	end
end

function M:open_buffer()
	local buffer = self.buffer
	if buffer == nil then
		return
	end

	local output = LineBuffer.new()
	local signs = {}
	local highlights = {}

	if self.body then
		self:put_pr_headers(output, highlights, signs)
		output:append("---")

		self:put_pr_body(output)
		output:append("---")
	end

	for _, commit in pairs(self.commits) do
		put_one_commit(output, highlights, commit)
	end
	output:append("---")

	local level = 0
	for _, comment in pairs(self.comments) do
		if not comment.in_reply_to_id then
			put_one_comment(output, signs, comment, level)
		end
	end

	buffer:replace_content_with(output)

	for line, name in pairs(signs) do
		buffer:place_sign(line, name, "hl")
	end

	for _, hi in ipairs(highlights) do
		buffer:add_highlight(hi.line, hi.from, hi.to, hi.name)
	end
	buffer:set_option("modifiable", false)
	buffer:set_option("readonly", true)

	vim.cmd("setlocal cursorline")

	M.buffer = buffer
	M.highlights = highlights
	vim.api.nvim_create_autocmd({"ColorScheme"}, {
		pattern = { "*" },
		callback = function()
			vim.cmd("syntax on")
		end,
	})
end

function M:open()
	self:create_buffer()
	if self.buffer == nil then
		return
	end

	self:open_buffer()
end

return M
