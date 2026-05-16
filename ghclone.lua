local args = {...}
local repo = args[1]
local branch = args[2] or "master"
local token = args[3]

if not repo then
  print("Usage:")
  print("  ghclone <user/repo> [branch] [token]")
  print()
  print("  First run (saves token to /env):")
  print("    wget run https://raw.githubusercontent.com/Gazdea/ghclone/master/ghclone.lua Gazdea/Aerogugaga master ghp_xxxxx")
  print()
  print("  Subsequent runs:")
  print("    ghclone Gazdea/Aerogugaga")
  return
end

local repoName = repo:match("/(.+)$") or repo
local dest = "projects/" .. repoName
local headers = {["User-Agent"] = "ghclone/1.0"}

-- Read token from /env if not provided as arg
if not token or token == "" then
  if fs.exists("/env") then
    local f = fs.open("/env", "r")
    if f then
      token = f.readAll():gsub("^%s*(.-)%s*$", "%1")
      f.close()
      if token and token ~= "" then
        print("Token: /env")
      end
    end
  end
end

-- Save token if provided as arg
if token and token ~= "" then
  local f = fs.open("/env", "w")
  if f then
    f.write(token)
    f.close()
    print("Token saved to /env")
  else
    print("Warning: cannot write /env")
  end
  headers["Authorization"] = "Bearer " .. token
end

print("== ghclone: " .. repo .. " (" .. branch .. ") => /" .. dest)

local apiUrl = "https://api.github.com/repos/" .. repo .. "/git/trees/" .. branch .. "?recursive=1"
local resp, err = http.get(apiUrl, headers)
if not resp then
  print("Error: " .. tostring(err))
  return
end

local data = resp.readAll()
resp.close()

local ok, tree = pcall(textutils.unserialiseJSON, data)
if not ok or not tree.tree then
  print("Error: invalid API response")
  if tree and tree.message then
    print("  " .. tree.message)
    if tree.message:find("rate limit") then
      print("  Use a token to increase rate limit (5000 req/h)")
    end
    if tree.message:find("Not Found") then
      print("  Check: repo name, branch, and token access")
    end
  end
  return
end

local files = {}
for _, entry in ipairs(tree.tree) do
  if entry.type == "blob" then
    files[#files + 1] = entry.path
  end
end

print("Files: " .. #files)

local ok = 0
local fail = 0
for _, path in ipairs(files) do
  local filePath = dest .. "/" .. path
  local dir = fs.getDir(filePath)

  if not fs.exists(dir) then
    fs.makeDir(dir)
  end

  local rawUrl = "https://raw.githubusercontent.com/" .. repo .. "/" .. branch .. "/" .. path
  local resp2 = http.get(rawUrl)

  if resp2 then
    local content = resp2.readAll()
    resp2.close()

    local f = fs.open(filePath, "w")
    f.write(content)
    f.close()
    ok = ok + 1
  else
    print("  FAIL: " .. path)
    fail = fail + 1
  end
end

print("Done: " .. ok .. " new/updated, " .. fail .. " failed")

if not fs.exists("ghclone") then
  local myUrl = "https://raw.githubusercontent.com/Gazdea/ghclone/master/ghclone.lua"
  local resp3 = http.get(myUrl)
  if resp3 then
    local content = resp3.readAll()
    resp3.close()
    local f = fs.open("ghclone", "w")
    if f then
      f.write(content)
      f.close()
      print("Installed /ghclone")
    end
  end
end
