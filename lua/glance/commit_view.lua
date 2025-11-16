glance = require("glance")
local Buffer = require("glance.buffer")
local LineBuffer = require('glance.line_buffer')
local md5 = require('glance.md5')

local diff_add_matcher = vim.regex('^+')
local diff_delete_matcher = vim.regex('^-')

local notify = require("notify")

-- @class CommitOverviewFile
-- @field path the path to the file relative to the git root
-- @field changes how many changes were made to the file
-- @field insertions insertion count visualized as list of `+`
-- @field deletions deletion count visualized as list of `-`

-- @class CommitOverview
-- @field summary a short summary about what happened 
-- @field files a list of CommitOverviewFile
-- @see CommitOverviewFile
local CommitOverview = {}

-- @class CommitInfo
-- @field oid the oid of the commit
-- @field author_name the name of the author
-- @field author_email the email of the author
-- @field author_date when the author commited
-- @field committer_name the name of the committer
-- @field committer_email the email of the committer
-- @field committer_date when the committer commited
-- @field description a list of lines
-- @field diffs a list of diffs
-- @see Diff
local CommitInfo = {}

-- @return the abbreviation of the oid
function CommitInfo:abbrev()
	return self.oid:sub(1, 12)
end

local function parse_diff(output)
	local header = {}
	local hunks = {}
	local is_header = true

	for i=1,#output do
		if is_header and output[i]:match('^@@.*@@') then
			is_header = false
		end

		if is_header then
			table.insert(header, output[i])
		else
			table.insert(hunks, output[i])
		end
	end

	local file = ""
	local kind = "modified"

	if #header == 4 then
		file = header[1]:match("diff %-%-git a/%S+ b/(%S+)")
	elseif #header == 2 then
		file = header[2]:match("%+%+%+ /tmp/(.+).patch")
	else
		kind = header[2]:match("(.*) mode %d+")
		if kind == "new file" then
			file = header[1]:match("diff %-%-git a/%S+ b/(%S+)")
		elseif kind == "deleted" then
			file = header[1]:match("diff %-%-git a/(%S+) b/%S+")
		end
	end

	local diff = {
		lines = hunks,
		file = file,
		kind = kind,
		headers = header,
		hunks = {}
	}

	local len = #hunks

	local hunk = nil

	local hunk_content = ''
	for i=1,len do
		local line = hunks[i]
		if not vim.startswith(line, "+++") then
			local index_from, index_len, disk_from, disk_len = line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')

			if index_from then
				if hunk ~= nil then
					hunk.hash = md5.sumhexa(hunk_content)
					hunk_content = ''
					table.insert(diff.hunks, hunk)
				end
				hunk = {
					index_from = tonumber(index_from),
					index_len = tonumber(index_len) or 1,
					disk_from = tonumber(disk_from),
					disk_len = tonumber(disk_len) or 1,
					line = line,
					diff_from = i,
					diff_to = i
				}
			else
				hunk_content = hunk_content .. '\n' .. line
				hunk.diff_to = hunk.diff_to + 1
			end
		end
	end

	if hunk then
		hunk.hash = md5.sumhexa(hunk_content)
		table.insert(diff.hunks, hunk)
	end

	return diff
end
local M = {}

local function parse_commit_overview(raw)
	local overview = {
		summary = vim.trim(raw[#raw]),
		files = {}
	}

	for i = 2, #raw - 1 do
	local file = {}
		if raw[i] ~= "" then
			file.path, file.changes, file.insertions, file.deletions = raw[i]:match(" (.*)%s+|%s+(%d+) ?(%+*)(%-*)")
			table.insert(overview.files, file)
		end
	end

	setmetatable(overview, { __index = CommitOverview })

	return overview
end

local function parse_commit_info(raw_info, diffonly)
	local idx = 0

	local function peek()
		return raw_info[idx+1]
	end

	local function advance()
		idx = idx + 1
		return raw_info[idx]
	end

	local info = {}

	if not diffonly then
		info.oid = advance():match("commit (%w+)")
		if vim.startswith(peek(), "Merge: ") then advance() end
		info.author_name, info.author_email = advance():match("Author:%s*(.+) <(.+)>")
		info.author_date = advance():match("AuthorDate:%s*(.+)")
		info.committer_name, info.committer_email = advance():match("Commit:%s*(.+) <(.+)>")
		info.committer_date = advance():match("CommitDate:%s*(.+)")
		info.description = {}

		-- skip empty line
		advance()

		local line = advance()
		while line ~= "" and line ~= nil do
			line = line:gsub("\r", "")
			table.insert(info.description, line)
			line = advance()
		end
	end

	local raw_diff_info = {}

	info.diffs = {}
	local line = advance()
	while line do
		table.insert(raw_diff_info, line)
		line = advance()
		if line == nil or vim.startswith(line, "diff") then
			local diff = parse_diff(raw_diff_info)
			table.insert(info.diffs, diff)
			info.diffs[diff.file] = diff
			raw_diff_info = {}
		end
	end

	setmetatable(info, { __index = CommitInfo })

	return info
end

local function parse_upstream_commit(raw_info)
	local idx = 0

	local function advance()
		idx = idx + 1
		return raw_info[idx]
	end

	local line = advance()
	while line do
		if vim.startswith(line, "commit ") then
			commit_id = line:match("commit (%w+)")
			return commit_id
		end
		line = advance()
	end
	return nil
end

function M:set_scrollbind_view(view)
	self.view_scrollbind = view
end

function M.sort_diffs_file(view1, view2)
	local diffs1 = view1.commit_info.diffs
	local diffs2 = view2.commit_info.diffs
	local both_diffs = {}
	local single_diffs = {}

	for _, diff in ipairs(diffs1) do
		if diffs2[diff.file] then
			table.insert(both_diffs, diff)
		else
			table.insert(single_diffs, diff)
		end
	end
	for _, diff in ipairs(single_diffs) do
		table.insert(both_diffs, diff)
	end
	view1.commit_info.diffs = both_diffs

	both_diffs = {}
	single_diffs = {}
	for _, diff in ipairs(diffs2) do
		if diffs1[diff.file] then
			table.insert(both_diffs, diff)
		else
			table.insert(single_diffs, diff)
		end
	end
	for _, diff in ipairs(single_diffs) do
		table.insert(both_diffs, diff)
	end
	view2.commit_info.diffs = both_diffs
end

-- @class CommitViewBuffer
-- @field is_open whether the buffer is currently shown
-- @field commit_info CommitInfo
-- @field commit_overview CommitOverview
-- @field buffer Buffer
-- @see CommitInfo
-- @see Buffer

--- Creates a new CommitViewBuffer
-- @param commit_id the id of the commit
-- @return CommitViewBuffer
function M.new(commit_id, opts)
	local git_cmd = "git show --format=fuller"
	if opts.diff_context ~= nil then
		git_cmd = git_cmd .. " -U" .. opts.diff_context
	end
	git_cmd = git_cmd .. " " .. commit_id

	local output = vim.fn.systemlist(git_cmd)
	if vim.v.shell_error ~= 0 then
		return nil
	end
	local commit_info = parse_commit_info(output, false)

	output = vim.fn.systemlist("git show --stat --oneline " .. commit_id)
	if vim.v.shell_error ~= 0 then
		return nil
	end
	local commit_overview = parse_commit_overview(output)

	local instance = {
		is_open = false,
		name = "glance://commit/single/" .. commit_id,
		commit_id = commit_id,
		commit_info = commit_info,
		commit_overview = commit_overview,
		buffer = nil,
		view_scrollbind = nil,
	}

	setmetatable(instance, { __index = M })

	return instance
end

function M.new_pr_alldiff(commit_from, commit_to, parent_log)
	local output = vim.fn.systemlist("git diff " .. commit_from .. ".." .. commit_to)
	if vim.v.shell_error ~= 0 then
		return nil
	end
	local commit_info = parse_commit_info(output, true)

	local instance = {
		is_open = false,
		name = "glance://commit/alldiff/" .. commit_from .. "-" .. commit_to,
		commit_info = commit_info,
		parent_log = parent_log,
		buffer = nil,
		view_scrollbind = nil,
	}

	setmetatable(instance, { __index = M })

	return instance
end

function M.get_upstream_commit(commit_id)
	local upstream_commit_id = parse_upstream_commit(vim.fn.systemlist("git log --format=%B -n 1 " .. commit_id))

	return upstream_commit_id
end

function M:get_first_hunk_line()
	return self.first_hunk_line
end

local function patchdiff_full_compose(commit_id)
	local commit_patch_path = "/tmp/" .. commit_id .. ".patch"
	local commit_patch_cmd = "git show --output=" .. commit_patch_path .. " " .. commit_id

	return {patch_cmd = commit_patch_cmd, patch_path = commit_patch_path}
end

local function patchdiff_diffonly_compose(commit_id)
	local commit_patch_path = "/tmp/" .. commit_id .. ".patch"
	local commit_patch_cmd = "git diff --output=" .. commit_patch_path .. " " .. commit_id .. "^.." .. commit_id

	return {patch_cmd = commit_patch_cmd, patch_path = commit_patch_path}
end

function M.new_patchdiff(commit)
	local commit_id = commit.hash
	local upstream_commit_id = parse_upstream_commit(vim.fn.systemlist("git log --format=%B -n 1 " .. commit_id))

	if upstream_commit_id == nil then
		local upstream_commit = glance.comparelist_find_commit(commit)
		if upstream_commit then
			upstream_commit_id = upstream_commit.hash
		end
	end

	if upstream_commit_id == nil then
		vim.notify("Not a backport commit", vim.log.levels.ERROR, {})
		return nil
	end

	local config = glance.config
	local cmd_compose_func = patchdiff_full_compose
	if config.patchdiff == "diffonly" then
		cmd_compose_func = patchdiff_diffonly_compose
	end

	local backport = cmd_compose_func(commit_id)
	local upstream = cmd_compose_func(upstream_commit_id)

	vim.fn.system(upstream.patch_cmd)
	vim.fn.system(backport.patch_cmd)

	local output = vim.fn.systemlist("diff -u " .. upstream.patch_path .. " " .. backport.patch_path)
	local commit_info = parse_commit_info(output, true)

	local instance = {
		is_open = false,
		name = "glance://commit/patchdiff/" .. upstream_commit_id .. "-" .. commit_id,
		commit_id = commit_id,
		upstream_commit_id = upstream_commit_id,
		commit_info = commit_info,
		buffer = nil,
	}

	setmetatable(instance, { __index = M })

	return instance
end

function M:close()
	if self.is_open == false then
		return
	end
	self.is_open = false
	self.buffer:close()
	self.buffer = nil

	local buddy = self.view_scrollbind
	self.view_scrollbind = nil

	if buddy == nil or buddy.buffer == nil then
		return
	end

	if buddy.buffer.exists(buddy.name) then
		buddy:close()
	end
end

local function diff_get_newfile_pos(commit_info, line, strict)
	for _, diff in ipairs(commit_info.diffs) do
		local diff_hunk_start_line = diff.start_line + #diff.headers
		if line >= diff.start_line and line < diff_hunk_start_line then
			if not strict then
				return { file = diff.file, file_pos = 1, text = "" }
			else
				return nil
			end
		end
		if line >= diff_hunk_start_line and line <= diff.end_line then
			for _, hunk in ipairs(diff.hunks) do
				if line > hunk.start_line and line <= hunk.end_line then
					local offset = line - hunk.start_line
					offset = hunk.diff_from + offset
					local text = diff.lines[offset]
					local file_pos = hunk.disk_from
					for i=hunk.diff_from+1,offset do
						text = diff.lines[i]
						if not vim.startswith(text, "-") then
							file_pos = file_pos + 1
						end
					end
					file_pos = file_pos - 1
					return { file = diff.file, file_pos = file_pos, text = diff.lines[offset], }
				end
			end
		end
	end
	if strict then
		return nil
	end
	return { file = commit_info.diffs[1].file, file_pos = commit_info.diffs[1].hunks[1].disk_from, text = "" }
end

function M:open(usr_opts)
	if self.is_open then
		return
	end

	local opts = usr_opts or {}
	self.is_open = true
	self.buffer = Buffer.create {
		name = self.name,
		filetype = opts.filetype or "GlanceCommit",
		kind = "vsplit",
		mappings = {
			n = {
				["q"] = function()
					self:close()
				end,
				["<c-o>"] = function()
					if not self.commit_id then
						vim.notify("Dont know which commit to checkout", vim.log.levels.ERROR, {})
						return
					end
					local answer = vim.fn.confirm("Checkout this commit to workspace?", "&yes\n&no")
					if answer ~= 1 then
						return
					end
					local line = vim.fn.line '.'
					local pos = diff_get_newfile_pos(self.commit_info, line, false)
					vim.cmd("!git checkout --detach " .. self.commit_id)
					vim.cmd("edit " .. pos.file)
					vim.cmd("norm " .. pos.file_pos.. "G")
				end,
				["<c-r>"] = function()
					if not self.parent_log then
						vim.notify("Not a alldiff view, can't create comment", vim.log.levels.ERROR, {})
						return
					end
					local answer = vim.fn.confirm("Create a comment for this PR?", "&yes\n&no")
					if answer ~= 1 then
						return
					end
					local line = vim.fn.line '.'
					local pos = diff_get_newfile_pos(self.commit_info, line, true)
					if not pos or pos.file_pos == 0 then
						vim.notify("Not in diff section, can't create comment", vim.log.levels.ERROR, {})
						return
					end
					if not vim.startswith(pos.text, "+") then
						vim.notify("Not newfile line", vim.log.levels.ERROR, {})
						return
					end
					self.parent_log:do_pr_comment(pos.file, pos.file_pos)
				end
			}
		},
	}
end

local highlight_maps = {
	Commit = {
		diffadd = "GlanceCommitDiffAdd",
		diffdel = "GlanceCommitDiffDelete",
		hunkheader = "GlanceCommitHunkHeader",
		filepath = "GlanceCommitFilePath",
		viewheader = "GlanceCommitViewHeader",
		commitdesc = "GlanceCommitDesc",
		headerfield = "GlanceCommitHeaderField",
		summary = "GlanceCommitSummary",
	},
	PatchDiff = {
		diffadd = "GlancePatchDiffAdd",
		diffdel = "GlancePatchDiffDelete",
		diffaddhl = "PRDiffAdd",
		diffdelhl = "PRDiffDel",
		hunkheader = "GlancePatchDiffHunkHeader",
		filepath = "GlancePatchDiffFilePath",
		viewheader = "GlancePatchDiffViewHeader",
		headerfield = "GlancePatchDiffHeaderField",
	},
}

function M:initialize()
	local buffer = self.buffer
	if buffer == nil then
		return
	end

	local output = LineBuffer.new()
	local info = self.commit_info
	local overview = self.commit_overview
	local signs = {}
	local highlights = {}

	local function add_sign(name)
		signs[#output] = name
	end

	local function add_highlight(from, to, name)
		table.insert(highlights, {
			line = #output - 1,
			from = from,
			to = to,
			name = name
		})
	end

	local hl_map = {}
	if vim.bo.filetype == "GlancePatchDiff" then
		hl_map = highlight_maps.PatchDiff
	else
		hl_map = highlight_maps.Commit
	end

	if vim.bo.filetype == "GlanceCommit" and not self.parent_log then
		output:append("Commit " .. self.commit_id)
		add_sign(hl_map.viewheader) -- 'GlanceCommitViewHeader'
		output:append("<remote>/<branch> " .. info.oid)
		output:append("Author:     " .. info.author_name .. " <" .. info.author_email .. ">")
		add_sign(hl_map.headerfield)
		output:append("AuthorDate: " .. info.author_date)
		add_sign(hl_map.headerfield)
		output:append("Commit:     " .. info.committer_name .. " <" .. info.committer_email .. ">")
		add_sign(hl_map.headerfield)
		output:append("CommitDate: " .. info.committer_date)
		add_sign(hl_map.headerfield)
		output:append("")
		for _, line in ipairs(info.description) do
			output:append(line)
			add_sign(hl_map.commitdesc) -- 'GlanceCommitDesc'
		end
		output:append("")
		output:append(overview.summary)
		add_sign(hl_map.summary)
		for _, file in ipairs(overview.files) do
			local insertions = file.insertions or ""
			local deletions = file.deletions or ""
			local changes = file.changes or ""
			output:append(
				file.path .. " | " .. changes ..
				" " .. insertions .. deletions
			)
			local from = 0
			local to = #file.path
			add_highlight(from, to, hl_map.filepath) -- "GlanceFilePath"
			from = to + 3
			to = from + #tostring(changes)
			add_highlight(from, to, "Number")
			from = to + 1
			to = from + #insertions
			add_highlight(from, to, hl_map.diffadd) -- "GlanceDiffAdd"
			from = to
			to = from + #deletions
			add_highlight(from, to, hl_map.diffdel) -- "GlanceDiffDelete"
		end
		output:append("")
	elseif vim.bo.filetype == "GlancePatchDiff" and not self.parent_log then
		output:append("PatchDiff " .. self.commit_id)
		add_sign(hl_map.viewheader) -- 'GlanceCommitViewHeader'

		output:append("Upstream: " .. self.upstream_commit_id)
		add_sign(hl_map.headerfield)
		output:append("")
	end

	for _, diff in ipairs(info.diffs) do
		diff.start_line = #output + 1
		for _, header in ipairs(diff.headers) do
			output:append(header)
		end
		if self.first_hunk_line == nil then
			self.first_hunk_line = #output + 1
		end
		for _, hunk in ipairs(diff.hunks) do
			output:append(diff.lines[hunk.diff_from])
			hunk.start_line = #output
			add_sign(hl_map.hunkheader) -- 'GlanceHunkHeader'
			for i=hunk.diff_from + 1, hunk.diff_to do
				local l = diff.lines[i]
				output:append(l)
				if diff_add_matcher:match_str(l) then
					if vim.bo.filetype ~= "GlancePatchDiff" or
						vim.startswith(l, "+index ") or
						vim.startswith(l, "+@@ ") or
						vim.startswith(l, "+diff ") or
						vim.startswith(l, "+commit ") or
						vim.startswith(l, "++++ ") or
						vim.startswith(l, "+--- ")
					then
						add_sign(hl_map.diffadd)
					else
						add_sign(hl_map.diffaddhl)
					end
				elseif diff_delete_matcher:match_str(l) then
					if vim.bo.filetype ~= "GlancePatchDiff" or
						vim.startswith(l, "-index ") or
						vim.startswith(l, "-@@ ") or
						vim.startswith(l, "-diff ") or
						vim.startswith(l, "-commit ") or
						vim.startswith(l, "-+++ ") or
						vim.startswith(l, "---- ")
					then
						add_sign(hl_map.diffdel)
					else
						add_sign(hl_map.diffdelhl)
					end
				end
			end
			hunk.end_line = #output
		end
		diff.end_line = #output
	end
	if #info.diffs == 0 and vim.bo.filetype == "GlancePatchDiff" then
		output:append("No Difference!")
		add_sign(hl_map.hunkheader)
	end
	buffer:replace_content_with(output)

	for line, name in pairs(signs) do
		buffer:place_sign(line, name, "hl")
	end

	for _, hi in ipairs(highlights) do
		buffer:add_highlight(
			hi.line,
			hi.from,
			hi.to,
			hi.name
		)
	end

	buffer:set_option("modifiable", false)
	buffer:set_option("readonly", true)

end

return M
