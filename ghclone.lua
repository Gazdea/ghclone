-- ========================================
-- ghclone v3 — GitHub file browser for CC:T
-- ========================================

-- ========================================
-- CONFIG
-- ========================================
local PER_PAGE = 5
local SELF_URL = "https://raw.githubusercontent.com/Gazdea/ghclone/master/ghclone.lua"
local REPOS_PATH = "/repos"
local ENV_PATH = "/env"

-- ========================================
-- UTILITIES
-- ========================================
local function readFile(p)
  if not fs.exists(p) then return nil end
  local f = fs.open(p, "r")
  if not f then return nil end
  local c = f.readAll()
  f.close()
  return c
end

local function writeFile(p, c)
  local f = fs.open(p, "w")
  if not f then return false end
  f.write(c)
  f.close()
  return true
end

local function trim(s)
  return s:gsub("^%s*(.-)%s*$", "%1")
end

local function split(s, sep)
  local t = {}
  for m in s:gmatch("[^" .. sep .. "]+") do
    t[#t + 1] = m
  end
  return t
end

local function loadRepos()
  local c = readFile(REPOS_PATH)
  if not c then return {} end
  local t = {}
  for line in c:gmatch("[^\r\n]+") do
    line = trim(line)
    if line ~= "" then t[#t + 1] = line end
  end
  return t
end

local function saveRepos(t)
  return writeFile(REPOS_PATH, table.concat(t, "\n"))
end

local function getToken()
  local c = readFile(ENV_PATH)
  if not c then return nil end
  return trim(c)
end

-- ========================================
-- GITHUB API
-- ========================================
local GitHub = {}

function GitHub.authHeaders(token)
  local h = {["User-Agent"] = "ghclone/3.0"}
  if token and token ~= "" then
    h["Authorization"] = "Bearer " .. token
  end
  return h
end

function GitHub.getTree(repo, branch, token)
  local url = "https://api.github.com/repos/" .. repo .. "/git/trees/" .. branch .. "?recursive=1"
  local resp = http.get(url, GitHub.authHeaders(token))
  if not resp then return nil, "HTTP failed" end
  local data = resp.readAll()
  resp.close()
  local ok, tree = pcall(textutils.unserialiseJSON, data)
  if not ok or not tree.tree then
    return nil, (tree and tree.message) or "bad response"
  end
  return tree, nil
end

function GitHub.getFile(url)
  local resp = http.get(url)
  if not resp then return nil end
  local c = resp.readAll()
  resp.close()
  return c
end

-- ========================================
-- STATE
-- ========================================
local SCREENS = {REPO_SELECT = 1, FILE_BROWSER = 2, DOWNLOAD = 3}

local function newState()
  return {
    screen = SCREENS.REPO_SELECT,
    repos = {},
    repo = nil,
    branch = "master",
    token = nil,
    -- File browser
    tree = nil,
    path = "",
    items = {},
    cursor = 1,
    page = 1,
    selected = {},
    -- Download
    downloadQueue = {},
    downloadResults = {},
    downloadRunning = false,
  }
end

function stateGetDirContents(state)
  local dirs, files = {}, {}
  local prefix = state.path ~= "" and (state.path .. "/") or ""
  local seenDirs = {}

  if not state.tree then return dirs, files end

  for _, entry in ipairs(state.tree.tree) do
    if entry.type == "blob" and entry.path:find(prefix, 1, true) == 1 then
      local rest = entry.path:sub(#prefix + 1)
      local slash = rest:find("/")
      if slash then
        local d = rest:sub(1, slash - 1)
        if not seenDirs[d] then
          seenDirs[d] = true
          dirs[#dirs + 1] = {name = d, path = (state.path ~= "" and state.path .. "/" or "") .. d, isDir = true}
        end
      else
        files[#files + 1] = {name = rest, path = entry.path, isDir = false, size = entry.size}
      end
    end
  end

  table.sort(dirs, function(a, b) return a.name < b.name end)
  table.sort(files, function(a, b) return a.name < b.name end)

  local items = {}
  for _, d in ipairs(dirs) do items[#items + 1] = d end
  for _, f in ipairs(files) do items[#items + 1] = f end
  return items
end

function stateGetFilesInDir(state, dirPath)
  local paths = {}
  local prefix = dirPath ~= "" and (dirPath .. "/") or ""
  if not state.tree then return paths end
  for _, entry in ipairs(state.tree.tree) do
    if entry.type == "blob" and entry.path:find(prefix, 1, true) == 1 then
      paths[#paths + 1] = entry.path
    end
  end
  return paths
end

function stateSelectItem(state, item)
  if item.isDir then
    local paths = stateGetFilesInDir(state, item.path)
    local allSelected = true
    for _, p in ipairs(paths) do
      if not state.selected[p] then allSelected = false; break end
    end
    if allSelected then
      for _, p in ipairs(paths) do state.selected[p] = nil end
    else
      for _, p in ipairs(paths) do state.selected[p] = true end
    end
  else
    if state.selected[item.path] then
      state.selected[item.path] = nil
    else
      state.selected[item.path] = true
    end
  end
end

function stateSelectAll(state)
  local items = stateGetDirContents(state)
  if #items == 0 then return end
  local allSelected = true
  for _, item in ipairs(items) do
    if item.isDir then
      local paths = stateGetFilesInDir(state, item.path)
      for _, p in ipairs(paths) do
        if not state.selected[p] then allSelected = false; break end
      end
    else
      if not state.selected[item.path] then allSelected = false; break end
    end
    if not allSelected then break end
  end
  for _, item in ipairs(items) do
    if item.isDir then
      local paths = stateGetFilesInDir(state, item.path)
      for _, p in ipairs(paths) do
        if allSelected then state.selected[p] = nil else state.selected[p] = true end
      end
    else
      if allSelected then state.selected[item.path] = nil else state.selected[item.path] = true end
    end
  end
end

function stateCountSelected(state)
  local n = 0
  for _, _ in pairs(state.selected) do n = n + 1 end
  return n
end

-- ========================================
-- RENDERER
-- ========================================
local Renderer = {}

function Renderer.clear()
  term.clear()
  term.setCursorPos(1, 1)
end

function Renderer.write(y, x, text)
  term.setCursorPos(x or 1, y)
  term.write(text)
end

function Renderer.separator(y, w, char)
  Renderer.write(y, 1, string.rep(char or "-", w))
end

function Renderer.repoSelect(state)
  local w, h = term.getSize()
  Renderer.clear()
  Renderer.write(1, 1, "ghclone - Select repository")
  Renderer.separator(2, w, "=")

  for i, r in ipairs(state.repos) do
    local prefix = (i == state.cursor) and "> " or "  "
    Renderer.write(2 + i, 1, prefix .. "[" .. i .. "] " .. r)
  end

  local y = 2 + #state.repos + 1
  Renderer.write(y, 1, "  [a] Add repository")
  Renderer.write(y + 1, 1, "  [q] Quit")
end

function Renderer.fileBrowser(state)
  local w, h = term.getSize()
  local items = stateGetDirContents(state)
  state.items = items

  Renderer.clear()

  -- Breadcrumbs
  local bc = "ghclone > " .. (state.repo or "")
  if state.path ~= "" then
    for _, part in ipairs(split(state.path, "/")) do
      bc = bc .. " > " .. part
    end
  end
  Renderer.write(1, 1, bc:sub(1, w))

  Renderer.separator(2, w)

  local total = #items
  local pages = math.max(1, math.ceil(total / PER_PAGE))
  if state.page > pages then state.page = pages end
  if state.page < 1 then state.page = 1 end

  local start = (state.page - 1) * PER_PAGE + 1
  local finish = math.min(start + PER_PAGE - 1, total)

  for i = start, finish do
    local item = items[i]
    local y = 2 + (i - start + 1)
    local cur = (i == state.cursor) and ">" or " "
    local sel = state.selected[item.path] and "X" or " "
    local name = item.name
    if item.isDir then name = name .. "/" end
    local line = cur .. "[" .. sel .. "] " .. name
    if #line > w then line = line:sub(1, w) end
    Renderer.write(y, 1, line)
  end

  Renderer.separator(8, w)

  Renderer.write(9, 1, "Page " .. state.page .. "/" .. pages .. "  Sel: " .. stateCountSelected(state))
  local navLine = ""
  if state.page > 1 then navLine = navLine .. "[<] Prev  " end
  if state.page < pages then navLine = navLine .. "[>] Next  " end
  Renderer.write(10, 1, navLine .. "[SPC] Toggle  [a]All  [d]Load  [q]uit")
end

function Renderer.download(state)
  local w, h = term.getSize()
  Renderer.clear()
  Renderer.write(1, 1, "Downloading...")
  Renderer.separator(2, w)

  local queue = state.downloadQueue
  local results = state.downloadResults

  for i, filePath in ipairs(queue) do
    if i > h then break end
    local status = results[filePath]
    if status == true then
      Renderer.write(2 + i, 1, "[X] " .. filePath)
    elseif status == false then
      Renderer.write(2 + i, 1, "[!] " .. filePath .. " FAILED")
    elseif status then
      Renderer.write(2 + i, 1, "[ ] " .. filePath .. " (" .. status .. "%)")
    else
      Renderer.write(2 + i, 1, "[ ] " .. filePath)
    end
  end

  if state.downloadRunning then
    Renderer.write(h, 1, "Downloading... press q to cancel")
  else
    Renderer.write(h, 1, "Done. Press any key to continue")
  end
end

function Renderer.draw(state)
  if state.screen == SCREENS.REPO_SELECT then
    Renderer.repoSelect(state)
  elseif state.screen == SCREENS.FILE_BROWSER then
    Renderer.fileBrowser(state)
  elseif state.screen == SCREENS.DOWNLOAD then
    Renderer.download(state)
  end
end

-- ========================================
-- INPUT HANDLER
-- ========================================
local Input = {}

-- Use CC:T keys API for correct scancodes

function Input.handleRepoSelect(state, event, a1, a2, a3)
  if event == "key" then
    local key = a1
    if key == keys.down then
      if state.cursor < #state.repos then state.cursor = state.cursor + 1 else state.cursor = 1 end
    elseif key == keys.up then
      if state.cursor > 1 then state.cursor = state.cursor - 1 else state.cursor = #state.repos end
    elseif key == keys.enter or key == keys.right or key == keys.kpEnter then
      if #state.repos > 0 then
        state.repo = state.repos[state.cursor]
        state.screen = SCREENS.FILE_BROWSER
        state.path = ""
        state.cursor = 1
        state.page = 1
        state.selected = {}
        local tree, err = GitHub.getTree(state.repo, state.branch, state.token)
        if tree then
          state.tree = tree
        else
          state.screen = SCREENS.REPO_SELECT
        end
      end
    elseif key == keys.a then
      Input.promptAddRepo(state)
    elseif key == keys.q then
      return false
    end
  elseif event == "mouse_click" then
    local mx, my = a2, a3
    local idx = my - 2
    if idx >= 1 and idx <= #state.repos then
      state.cursor = idx
      state.repo = state.repos[state.cursor]
      state.screen = SCREENS.FILE_BROWSER
      state.path = ""
      state.cursor = 1
      state.page = 1
      state.selected = {}
      local tree, err = GitHub.getTree(state.repo, state.branch, state.token)
      if tree then
        state.tree = tree
      else
        state.screen = SCREENS.REPO_SELECT
      end
    end
  end
  return true
end

function Input.promptAddRepo(state)
  Renderer.clear()
  Renderer.write(1, 1, "Enter repo (user/repo): ")
  local input = read()
  if input and input ~= "" then
    input = trim(input)
    local repos = loadRepos()
    local exists = false
    for _, r in ipairs(repos) do
      if r == input then exists = true; break end
    end
    if not exists then
      repos[#repos + 1] = input
      saveRepos(repos)
      state.repos = repos
    end
  end
  Renderer.draw(state)
end

function Input.handleFileBrowser(state, event, a1, a2, a3)
  local items = stateGetDirContents(state)
  state.items = items
  local total = #items
  if total == 0 then total = 1 end
  local pages = math.max(1, math.ceil(total / PER_PAGE))

  if event == "key" then
    local key = a1
    if key == keys.down then
      if state.cursor < total then
        state.cursor = state.cursor + 1
        if state.cursor > state.page * PER_PAGE then
          state.page = state.page + 1
        end
      end
    elseif key == keys.up then
      if state.cursor > 1 then
        state.cursor = state.cursor - 1
        if state.cursor < (state.page - 1) * PER_PAGE + 1 then
          state.page = state.page - 1
        end
      end
    elseif key == keys.left then
      if state.path == "" then
        state.screen = SCREENS.REPO_SELECT
        state.cursor = 1
      else
        local parts = split(state.path, "/")
        table.remove(parts)
        state.path = table.concat(parts, "/")
        state.cursor = 1
        state.page = 1
        state.items = stateGetDirContents(state)
      end
    elseif key == keys.right or key == keys.enter or key == keys.kpEnter then
      local item = items[state.cursor]
      if item and item.isDir then
        state.path = item.path
        state.cursor = 1
        state.page = 1
        state.items = stateGetDirContents(state)
      end
    elseif key == keys.space or key == keys.s then
      local item = items[state.cursor]
      if item then stateSelectItem(state, item) end
    elseif key == keys.a then
      stateSelectAll(state)
    elseif key == keys.d then
      if stateCountSelected(state) > 0 then
        state.downloadQueue = {}
        for p, _ in pairs(state.selected) do
          state.downloadQueue[#state.downloadQueue + 1] = p
        end
        table.sort(state.downloadQueue)
        state.downloadResults = {}
        state.downloadRunning = true
        state.screen = SCREENS.DOWNLOAD
        Input.runDownload(state)
      end
    elseif key == keys.q then
      if state.path == "" then
        state.screen = SCREENS.REPO_SELECT
        state.cursor = 1
      else
        local parts = split(state.path, "/")
        table.remove(parts)
        state.path = table.concat(parts, "/")
        state.cursor = 1
        state.page = 1
        state.items = stateGetDirContents(state)
      end
    end
  elseif event == "mouse_scroll" then
    if a1 == 1 and state.page > 1 then
      state.page = state.page - 1
      state.cursor = (state.page - 1) * PER_PAGE + 1
    elseif a1 == -1 and state.page < pages then
      state.page = state.page + 1
      state.cursor = (state.page - 1) * PER_PAGE + 1
    end
  elseif event == "mouse_click" then
    local mx, my = a2, a3
    local w, h = term.getSize()
    -- Page nav clicks (line 10)
    if my == 10 then
      local onPrev = state.page > 1 and mx <= 12
      local onNext = state.page < pages and mx > 12
      if onPrev then
        state.page = state.page - 1
        state.cursor = (state.page - 1) * PER_PAGE + 1
      elseif onNext then
        state.page = state.page + 1
        state.cursor = (state.page - 1) * PER_PAGE + 1
      end
    else
      -- File list click
      local idx = my - 2
      if idx >= 1 and idx <= PER_PAGE then
        local itemIdx = (state.page - 1) * PER_PAGE + idx
        if itemIdx >= 1 and itemIdx <= #items then
          state.cursor = itemIdx
          local item = items[itemIdx]
          if item then
            if item.isDir then
              state.path = item.path
              state.cursor = 1
              state.page = 1
              state.items = stateGetDirContents(state)
            else
              stateSelectItem(state, item)
            end
          end
        end
      end
    end
  end
  return true
end

-- ========================================
-- DOWNLOADER
-- ========================================
function Input.runDownload(state)
  local queue = state.downloadQueue
  local base = shell.dir()
  if base == "/" then base = "" end

  for i, filePath in ipairs(queue) do
    if not state.downloadRunning then break end

    local url = "https://raw.githubusercontent.com/" .. state.repo .. "/" .. state.branch .. "/" .. filePath
    local fp = base .. "/" .. filePath
    local dir = fs.getDir(fp)

    state.downloadResults[filePath] = 0
    Renderer.download(state)

    if not fs.exists(dir) then fs.makeDir(dir) end

    local content = GitHub.getFile(url)
    if content then
      local f = fs.open(fp, "w")
      if f then
        f.write(content)
        f.close()
        state.downloadResults[filePath] = true
      else
        state.downloadResults[filePath] = false
      end
    else
      state.downloadResults[filePath] = false
    end

    Renderer.download(state)
  end

  state.downloadRunning = false
  Renderer.download(state)

  -- Wait for key press to continue
  while true do
    local ev = os.pullEvent()
    if ev == "key" or ev == "mouse_click" then break end
  end

  state.screen = SCREENS.FILE_BROWSER
  Renderer.draw(state)
end

-- ========================================
-- MAIN
-- ========================================
local function setupState()
  local state = newState()
  state.repos = loadRepos()
  state.token = getToken()
  if not state.token then
    Renderer.clear()
    Renderer.write(1, 1, "ghclone - Setup")
    Renderer.write(2, 1, "GitHub token (ENTER = public only): ")
    local input = read()
    if input and input ~= "" then
      writeFile(ENV_PATH, input)
      state.token = input
    end
  end
  Renderer.write(3, 1, "Branch [master]: ")
  local input = read()
  if input and input ~= "" then state.branch = input end
  return state
end

local function run()
  local state = setupState()

  Renderer.draw(state)

  while true do
    local event, a1, a2, a3 = os.pullEvent()
    local running = true

    if state.screen == SCREENS.REPO_SELECT then
      running = Input.handleRepoSelect(state, event, a1, a2, a3)
    elseif state.screen == SCREENS.FILE_BROWSER then
      running = Input.handleFileBrowser(state, event, a1, a2, a3)
    elseif state.screen == SCREENS.DOWNLOAD then
      -- Download runs in its own pullEvent loop
    end

    if not running then break end
    Renderer.draw(state)
  end

  term.clear()
  term.setCursorPos(1, 1)
end

local function directClone(repo, subdir, branch, token)
  local tree, err = GitHub.getTree(repo, branch, token)
  if not tree then
    print("Error: " .. err)
    return
  end

  local prefix = subdir and (subdir .. "/") or ""
  local files = {}
  for _, e in ipairs(tree.tree) do
    if e.type == "blob" and (not subdir or e.path:find(prefix, 1, true) == 1) then
      files[#files + 1] = e.path
    end
  end

  local base = shell.dir()
  if base == "/" then base = "" end

  print("Files: " .. #files)

  local ok, fail = 0, 0
  for _, path in ipairs(files) do
    local fp = base .. "/" .. path
    local dir = fs.getDir(fp)
    if not fs.exists(dir) then fs.makeDir(dir) end

    local url = "https://raw.githubusercontent.com/" .. repo .. "/" .. branch .. "/" .. path
    local content = GitHub.getFile(url)
    if content then
      local f = fs.open(fp, "w")
      if f then f.write(content) f.close() end
      ok = ok + 1
    else
      fail = fail + 1
    end
  end
  print("Done: " .. ok .. " files" .. (fail > 0 and (", " .. fail .. " failed") or ""))

  -- Self-install
  if not fs.exists("ghclone") then
    local content = GitHub.getFile(SELF_URL)
    if content then
      local f = fs.open("ghclone", "w")
      if f then f.write(content) f.close() end
    end
  end
end

-- Entry point
local args = {...}

if #args == 0 then
  -- Self-install if not saved locally
  if not fs.exists("ghclone") then
    local content = GitHub.getFile(SELF_URL)
    if content then
      local f = fs.open("ghclone", "w")
      if f then f.write(content) f.close() end
    end
  end
  run()
  return
end

if args[1] == "--add" then
  if args[2] then
    local repos = loadRepos()
    repos[#repos + 1] = args[2]
    saveRepos(repos)
    print("Added " .. args[2])
  end
  return
end

if args[1] == "--help" or args[1] == "-h" then
  print("ghclone v3 - GitHub browser for CC:T")
  print()
  print("  ghclone                  Interactive file browser")
  print("  ghclone <user/repo>      Direct clone to current dir")
  print("  ghclone <user/repo>/sub  Clone subdirectory")
  print("  ghclone ... <branch>     Specify branch")
  print("  ghclone --add <user>     Add repo to list")
  print()
  print("Browser keys:")
  print("  [SPC] Toggle selection   [a] Select all")
  print("  [d] Download selected    [q] Back / Quit")
  print("  [<][>] Page navigation   Mouse click supported")
  return
end

-- Direct mode
local raw = args[1]
local branch = args[2] or "master"
local token = args[3] or getToken()

if args[3] and args[3] ~= "" then
  writeFile(ENV_PATH, args[3])
end

local first = raw:find("/")
if not first then
  print("Usage: ghclone <user/repo>[/subdir] [branch] [token]")
  return
end

local rest = raw:sub(first + 1)
local second = rest:find("/")
local repoName, subdir

if second then
  repoName = rest:sub(1, second - 1)
  subdir = rest:sub(second + 1)
  if subdir == "" then subdir = nil end
else
  repoName = rest
  subdir = nil
end

local repo = raw:sub(1, first) .. repoName
local label = subdir and (repo .. "/" .. subdir) or repo
print("== " .. label .. " (" .. branch .. ")")
directClone(repo, subdir, branch, token)
