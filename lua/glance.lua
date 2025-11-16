local curl = require('plenary.curl')

local M = {
	comparelist = {},
	state = {}
}

M.config = {
	patchdiff = "diffonly",
	q_quit_log = "off",
	diff_context = "3",
	gitee = {
		prlist_state = "open",
		prlist_sort = "updated",
	},
}

function M.set_state(bufnr, state)
	M.state[bufnr] = state
end

function M.get_state(bufnr)
	return M.state[bufnr]
end

local function do_glance_log(cmdline, pr)
	local logview = require("glance.log_view").new(cmdline, pr)
	logview:open()
end

function M.comparelist_find_commit(commit)
	for _,c in ipairs(M.comparelist) do
		if commit.message:find(c.message, 1, true) or c.message:find(commit.message, 1, true) then
			return c
		end
	end
	return nil
end

function M.comparelist_add_commit(commit)
	for _,c in ipairs(M.comparelist) do
		if c.hash == commit.hash then
			return
		end
	end
	table.insert(M.comparelist, commit)
end

function M.comparelist_delete_all()
	M.comparelist = {}
end

function M.set_config(config)
	if config.patchdiff == "full" or config.patchdiff == "diffonly" then
		M.config.patchdiff = config.patchdiff
	end
	if config.q_quit_log == "on" or config.q_quit_log == "off" then
		M.config.q_quit_log = config.q_quit_log
	end
	if config.diff_context ~= nil then
		M.config.diff_context = config.diff_context
	end

	if config.gitee then
		M.config.gitee = M.config.gitee or {}
		if config.gitee.token_file then
			local token = vim.fn.systemlist("cat " .. config.gitee.token_file)
			if vim.v.shell_error == 0 then
				M.config.gitee.token = token[1]
			end
		end
		if config.gitee.repo then
			M.config.gitee.repo = config.gitee.repo
		end
		if config.gitee.prlist_state then
			local state = config.gitee.prlist_state
			if state ~= "open" and state ~= "merged" and state ~= "closed" and state ~= "all" then
				vim.notify("incorrect config.gitee.prlist_state: " .. state, vim.log.levels.ERROR, {})
				return
			end
			M.config.gitee.prlist_state = config.gitee.prlist_state
		end
		if config.gitee.prlist_sort then
			local sort = config.gitee.prlist_sort
			if sort ~= "created" and sort ~= "updated" and sort ~= "popularity" and sort ~= "long-running" then
				vim.notify("incorrect config.gitee.prlist_sort: " .. sort, vim.log.levels.ERROR, {})
				return
			end
			M.config.gitee.prlist_sort = config.gitee.prlist_sort
		end
	end
end

local function do_glance_patchdiff(cmdline)
	local config = { patchdiff = string.gsub(cmdline, "%s*(.-)%s*", "%1") }
	M.set_config(config)
end

local function do_glance_q_quit_log(cmdline)
	local config = { q_quit_log = string.gsub(cmdline, "%s*(.-)%s*", "%1") }
	M.set_config(config)
end

local function do_glance_diff_context(cmdline)
	local config = { diff_context = string.gsub(cmdline, "%s*(.-)%s*", "%1") }
	M.set_config(config)
end

local function find_comment_by_id(comments, id)
	for _, comment in ipairs(comments) do
		if comment.id == id then
			return comment
		end
	end
end

function M.get_pr_comments(pr_number)
	local base_url = "https://gitee.com/api/v5/repos/" .. M.config.gitee.repo .. "/pulls/"
	local token = M.config.gitee.token
	local opts = {
		method = "get",
		headers = {
			["Accept"] = "application/json",
			["Connection"] = "keep-alive",
			["Content-Type"] = "\'application/json; charset=utf-8\'",
			["User-Agent"] = "Glance",
		},
		body = {},
	}
	opts.url = base_url .. pr_number .."/comments?access_token=" .. token .. "&number=" .. pr_number .. "&page=1&per_page=100"
	-- vim.notify("url: " .. opts.url, vim.log.levels.INFO, {})
	local response = curl["get"](opts)
	local json = vim.fn.json_decode(response.body)
	local comments = {}
	for _, comment in ipairs(json) do
		if comment.user.login ~= "openeuler-ci-bot" and comment.user.login ~= "openeuler-sync-bot" and comment.user.login ~= "ci-robot" then
			table.insert(comments, comment)
		end

	end
	for _, comment in ipairs(comments) do
		if comment.in_reply_to_id then
			local parent = find_comment_by_id(comments, comment.in_reply_to_id)
			if parent then
				parent.children = parent.children or {}
				table.insert(parent.children, comment)
			else
				comment.in_reply_to_id = nil
			end
		end
	end
	return comments
end

function M.do_glance_pr(cmdline)
	local pr_number = cmdline
	local base_url = "https://gitee.com/api/v5/repos/" .. M.config.gitee.repo .. "/pulls/"
	local token = M.config.gitee.token
	local opts = {
		method = "get",
		headers = {
			["Accept"] = "application/json",
			["Connection"] = "keep-alive",
			["Content-Type"] = "\'application/json; charset=utf-8\'",
			["User-Agent"] = "Glance",
		},
		body = {},
	}
	opts.url = base_url .. pr_number .."?access_token=" .. token .. "&number=" .. pr_number
	-- vim.notify("url: " .. opts.url, vim.log.levels.INFO, {})
	local response = curl["get"](opts)
	local json = vim.fn.json_decode(response.body)
	local desc_body = vim.fn.split(json.body, "\n")
	local pr = {
		number = pr_number,
		labels = json.labels,
		desc_head = {
			url = json.html_url,
			creator = json.head.user.name,
			head = json.head.repo.full_name .. " : " .. json.head.ref,
			base = json.base.repo.full_name .. " : " .. json.base.ref,
			state = json.state,
			created_at = json.created_at,
			updated_at = json.updated_at,
			mergeable = json.mergeable,
			title = json.title,
		},
		desc_body = desc_body,
		user = json.head.user.login,
		url = json.head.repo.html_url,
		branch = json.head.ref,
		sha = json.head.sha,
		base_user = json.base.user.login,
		base_url = json.base.repo.html_url,
		base_branch = json.base.ref,
		base_sha = json.base.sha,
	}
	local source_remote_name = json.head.user.login .. "-" .. json.head.repo.full_name:gsub('/', '-')
	local dest_remote_name = json.base.user.login .. "-" .. json.base.repo.full_name:gsub('/', '-')
	vim.cmd(string.format("!git remote remove %s", source_remote_name))
	vim.cmd(string.format("!git remote add %s %s", source_remote_name, json.head.repo.html_url))
	vim.cmd(string.format("!git remote remove %s", dest_remote_name))
	vim.cmd(string.format("!git remote add %s %s", dest_remote_name, json.base.repo.html_url))
	vim.cmd(string.format("!git fetch %s %s", source_remote_name, json.head.ref))
	vim.cmd(string.format("!git fetch %s %s", dest_remote_name, json.base.ref))

	local commit_from = vim.fn.systemlist(string.format("git merge-base %s %s", json.head.sha, json.base.sha))[1]
	pr.merge_base = commit_from

	do_glance_log("", pr)
end

local function table_concat(t1,t2)
    for i=1,#t2 do
        t1[#t1+1] = t2[i]
    end
    return t1
end

local function prlist_verify_param(param_table, key, value)
	local gitee_params = {
		["state"] = { "open", "closed", "merged", "all" },
		["sort"]  = { "created", "updated", "popularity", "long-running" },
	}

	local key_found = nil
	for k, p in pairs(gitee_params) do
		if key == k then
			key_found = true
			for _, v in ipairs(p) do
				if value == v then
					param_table[key] = value
				end
			end
		end
	end
	if not key_found then
		param_table[key] = value
	end
end

function M.do_glance_prlist(cmdline)
	local howmany = "100"
	local param_table = {}
	if cmdline:match('%S+') then
		for param in vim.gsplit(cmdline, " ", {plain=true}) do
			if param:match('%S+') then
				local key, value = unpack(vim.split(param, "=", {plain=true}))
				if key:match('%S+') then
					if not value or value:match('^%s*$') then
						if tonumber(key) then
							howmany = key
						end
					else
						prlist_verify_param(param_table, key, value)
					end
				end
			end
		end
	end

	local query_state = M.config.gitee.prlist_state
	local query_sort = M.config.gitee.prlist_sort
	if param_table["state"] then
		query_state = param_table["state"]
	end
	if param_table["sort"] then
		query_sort = param_table["sort"]
	end

	local http_param_str = "&state=" .. query_state .. "&sort=" .. query_sort

	if param_table["base"] then
		http_param_str = http_param_str .. "&base=" .. param_table["base"]
	end
	if param_table["milestone_number"] then
		http_param_str = http_param_str .. "&milestone_number=" .. param_table["milestone_number"]
	end
	if param_table["labels"] then
		http_param_str = http_param_str .. "&labels=" .. param_table["labels"]
	end
	if param_table["author"] then
		http_param_str = http_param_str .. "&author=" .. param_table["author"]
	end
	if param_table["assignee"] then
		http_param_str = http_param_str .. "&assignee=" .. param_table["assignee"]
	end

	local base_url = "https://gitee.com/api/v5/repos/" .. M.config.gitee.repo .. "/pulls"
	local token = M.config.gitee.token
	local opts = {
		method = "get",
		headers = {
			["Accept"] = "application/json",
			["Connection"] = "keep-alive",
			["Content-Type"] = "\'application/json; charset=utf-8\'",
			["User-Agent"] = "Glance",
		},
		body = {},
	}
	local json = {}
	local count = 0
	while count*100 < tonumber(howmany) do
		count = count + 1
		opts.url = base_url .. "?access_token=" .. token .. http_param_str .. "&direction=desc&page="..count.."&per_page=100"
		-- vim.notify("url: " .. opts.url, vim.log.levels.INFO, {})
		local response = curl["get"](opts)
		local tmp = vim.fn.json_decode(response.body)
		if #tmp == 0 then
			break
		end
		table_concat(json, tmp)
	end

	local prlist_view = require("glance.prlist_view").new(json, cmdline, true)
	prlist_view:open()
end

local function do_glance_gitee(cmdline)
	local gitee_cmd = vim.split(cmdline, " ")
	local config = {
		gitee = {},
	}
	if gitee_cmd[1] == "repo" then
		config.gitee.repo = gitee_cmd[2]
	elseif gitee_cmd[1] == "token_file" then
		config.gitee.token_file = gitee_cmd[2]
	elseif gitee_cmd[1] == "prlist_state" then
		config.gitee.prlist_state = gitee_cmd[2]
	elseif gitee_cmd[1] == "prlist_sort" then
		config.gitee.prlist_sort = gitee_cmd[2]
	end
	M.set_config(config)
end

local function do_glance_command(user_opts)
	local sub_cmd_str = user_opts.fargs[1]
	local sub_cmd

	if sub_cmd_str == "log" then
		sub_cmd = do_glance_log
	elseif sub_cmd_str == "patchdiff" then
		sub_cmd = do_glance_patchdiff
	elseif sub_cmd_str == "q_quit_log" then
		sub_cmd = do_glance_q_quit_log
	elseif sub_cmd_str == "diff_context" then
		sub_cmd = do_glance_diff_context
	elseif sub_cmd_str == "prlist" then
		sub_cmd = M.do_glance_prlist
	elseif sub_cmd_str == "pr" then
		sub_cmd = M.do_glance_pr
	elseif sub_cmd_str == "gitee" then
		sub_cmd = do_glance_gitee
	else
		return
	end

	local cmdline = ""
	for i, arg in ipairs(user_opts.fargs) do
		if i == 2 then
			cmdline = arg
		elseif i ~= 1 then
			cmdline = cmdline .. " " .. arg
		end
	end

	sub_cmd(cmdline)
end

local function do_gitee_command(user_opts)
	local sub_cmd_str = user_opts.fargs[1]
	local sub_cmd = nil
	local cmdline = ""
	local start_index = 2

	if sub_cmd_str == "prlist" then
		sub_cmd = M.do_glance_prlist
	elseif sub_cmd_str == "pr" then
		sub_cmd = M.do_glance_pr
	else
		sub_cmd = do_glance_gitee
		start_index = 1
	end

	for i, arg in ipairs(user_opts.fargs) do
		if i == start_index then
			cmdline = arg
		elseif i > start_index then
			cmdline = cmdline .. " " .. arg
		end
	end

	sub_cmd(cmdline)
end

function M.setup(opts)
	local config = opts or {}

	M.set_config(config)

	vim.api.nvim_create_user_command( "Glance", do_glance_command, { desc = "Glance Commands", nargs = '+' })
	vim.api.nvim_create_user_command( "Gitee", do_gitee_command, { desc = "Gitee Commands", nargs = '+' })
end

return M
