-- Helpers
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

local function loadRepos()
  local c = readFile("/repos")
  if not c then return {} end
  local t = {}
  for line in c:gmatch("[^\r\n]+") do
    line = line:gsub("^%s*(.-)%s*$", "%1")
    if line ~= "" then t[#t + 1] = line end
  end
  return t
end

local function saveRepos(t)
  return writeFile("/repos", table.concat(t, "\n"))
end

local function getToken()
  local c = readFile("/env")
  if not c then return nil end
  return c:gsub("^%s*(.-)%s*$", "%1")
end

-- GitHub API
local function api(repo, branch, token)
  local headers = {["User-Agent"] = "ghclone/1.0"}
  if token and token ~= "" then
    headers["Authorization"] = "Bearer " .. token
  end
  local url = "https://api.github.com/repos/" .. repo .. "/git/trees/" .. branch .. "?recursive=1"
  local resp = http.get(url, headers)
  if not resp then return nil, "HTTP failed" end
  local data = resp.readAll()
  resp.close()
  local ok, tree = pcall(textutils.unserialiseJSON, data)
  if not ok or not tree.tree then
    return nil, (tree and tree.message) or "bad response"
  end
  return tree, nil
end

-- Get top-level directories from a repo
local function getDirs(repo, branch, token)
  local tree, err = api(repo, branch, token)
  if not tree then return nil, err end
  local seen, dirs = {}, {}
  for _, e in ipairs(tree.tree) do
    if e.type == "tree" and not e.path:find("/") and not seen[e.path] then
      seen[e.path] = true
      dirs[#dirs + 1] = e.path
    end
  end
  table.sort(dirs)
  return dirs, nil, tree
end

-- Clone files into current directory
local function clone(repo, subdir, branch, token)
  local tree, err = api(repo, branch, token)
  if not tree then print("Error: " .. err) return false end

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
    local resp = http.get(url)
    if resp then
      local c = resp.readAll()
      resp.close()
      local f = fs.open(fp, "w")
      if f then f.write(c) f.close() end
      ok = ok + 1
    else
      fail = fail + 1
    end
  end

  print("Done: " .. ok .. " files" .. (fail > 0 and (", " .. fail .. " failed") or ""))
  return fail == 0
end

-- Add repo to /repos
local function promptRepo()
  write("Enter repo (user/repo): ")
  local input = read()
  if not input or input == "" then return nil end
  input = input:gsub("^%s*(.-)%s*$", "%1")
  local repos = loadRepos()
  for _, r in ipairs(repos) do
    if r == input then print("Already in list"); return input end
  end
  repos[#repos + 1] = input
  saveRepos(repos)
  print("Added " .. input)
  return input
end

-- Interactive mode
local function interactive()
  print("== ghclone")
  local token = getToken()
  if not token then
    write("GitHub token (or ENTER for public only): ")
    token = read()
    if token and token ~= "" then
      writeFile("/env", token)
      print("Token saved to /env")
    else
      token = nil
    end
  end

  write("Branch [master]: ")
  local branch = read()
  if not branch or branch == "" then branch = "master" end

  while true do
    local repos = loadRepos()
    if #repos == 0 then
      print("No repos in list. Add one:")
      if not promptRepo() then return end
      repos = loadRepos()
    end

    print()
    print("=== ghclone ===")
    for i, r in ipairs(repos) do
      print("  [" .. i .. "] " .. r)
    end
    print("  [a] Add repo")
    print("  [q] Quit")
    write("> ")

    local sel = read()
    if not sel or sel == "" or sel == "q" then return end

    local repo
    if sel == "a" then
      repo = promptRepo()
      if not repo then return end
    else
      local n = tonumber(sel)
      if n and n >= 1 and n <= #repos then
        repo = repos[n]
      else
        print("Invalid")
      end
    end

    if repo then
      local dirs, err = getDirs(repo, branch, token)
      if dirs then
        print()
        print("=== " .. repo .. " ===")
        print("  [ENTER] Clone everything")
        for i, d in ipairs(dirs) do
          print("  [" .. i .. "] " .. d .. "/")
        end
        print("  [b] Back")
        write("> ")

        local s = read()
        if s ~= "b" and s ~= nil then
          local subdir = nil
          if s ~= "" then
            local n = tonumber(s)
            if n and n >= 1 and n <= #dirs then
              subdir = dirs[n]
            else
              print("Invalid")
            end
          end

          if subdir or s == "" then
            local label = subdir and (repo .. "/" .. subdir) or repo
            local from = subdir or repo:match("/(.+)$")
            print("Cloning " .. label .. " -> " .. shell.dir() .. "/" .. from)
            clone(repo, subdir, branch, token)
          end
        end
      else
        print("Error: " .. err)
      end
    end
  end
end

-- Main
local args = {...}

if #args == 0 then
  interactive()
  return
end

if args[1] == "--add" then
  if args[2] then
    local repos = loadRepos()
    repos[#repos + 1] = args[2]
    saveRepos(repos)
    print("Added " .. args[2])
  else
    promptRepo()
  end
  return
end

if args[1] == "--help" or args[1] == "-h" then
  print("ghclone - clone GitHub repos to CC:T")
  print()
  print("  ghclone                        Interactive mode")
  print("  ghclone <user/repo>[/subdir]   Clone to current dir")
  print("  ghclone ... <branch> <token>   Specify branch/token")
  print("  ghclone --add <user/repo>      Add repo to list")
  print("  ghclone --init <token>         Save token to /env")
  return
end

if args[1] == "--init" and args[2] then
  writeFile("/env", args[2])
  print("Token saved to /env")
  return
end

-- Direct mode: ghclone user/repo[/subdir] [branch] [token]
local raw = args[1]
local branch = args[2] or "master"
local token = args[3] or getToken()

if not token and args[3] then
  writeFile("/env", args[3])
  print("Token saved to /env")
  token = args[3]
end

local first = raw:find("/")
if not first then
  print("Usage: ghclone <user/repo>[/subdir] [branch] [token]")
  return
end

local user = raw:sub(1, first - 1)
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

local repo = user .. "/" .. repoName
local label = subdir and (repo .. "/" .. subdir) or repo
print("== " .. label .. " (" .. branch .. ")")
clone(repo, subdir, branch, token)

-- Self-install (only if in current dir and ghclone doesn't exist)
if not fs.exists("ghclone") then
  local url = "https://raw.githubusercontent.com/Gazdea/ghclone/master/ghclone.lua"
  local resp = http.get(url)
  if resp then
    local c = resp.readAll()
    resp.close()
    local f = fs.open("ghclone", "w")
    if f then f.write(c) f.close() end
  end
end
