-- Folders as os.walk and shutil handle them (on w3.fs): every file below a folder, a folder taken out whole, a tree
-- copied over another (files keep their times, as copy2).
--   FS.walk(dir) -> {{path, rel}} (files, folders first-down)   FS.rmtree(dir) -> ok   FS.copytree(src, dst, skip)
--   FS.show(path_or_url, select)   opened as os.startfile does it (a folder in Explorer, a page in the browser); select:
--                                  its folder with the file chosen (explorer /select)
local FS = {}

function FS.walk(dir, out, rel)
  out = out or {}
  for _, e in ipairs(w3.fs.list(dir) or {}) do
    local path = dir .. "\\" .. e.name
    local r = rel and (rel .. "\\" .. e.name) or e.name
    if e.dir then FS.walk(path, out, r) else out[#out + 1] = {path = path, rel = r, name = e.name} end
  end
  return out
end

-- shutil.rmtree(dir, ignore_errors=True)
function FS.rmtree(dir)
  if not w3.fs.isdir(dir) then return false end
  for _, e in ipairs(w3.fs.list(dir) or {}) do
    local path = dir .. "\\" .. e.name
    if e.dir then FS.rmtree(path) else w3.fs.remove(path) end
  end
  return w3.fs.rmdir(dir) ~= nil
end

-- shutil.copytree(src, dst, dirs_exist_ok=True, ignore=...): skip(name) leaves a file or folder out
function FS.copytree(src, dst, skip)
  w3.fs.mkdir(dst)
  for _, e in ipairs(w3.fs.list(src) or {}) do
    if not (skip and skip(e.name)) then
      local s, d = src .. "\\" .. e.name, dst .. "\\" .. e.name
      if e.dir then FS.copytree(s, d, skip) else assert(w3.fs.copy(s, d)) end
    end
  end
end

-- a text file as Python's open(path, "w") writes it: "\n" becomes "\r\n"
function FS.write_text(path, text)
  return w3.fs.write(path, (text:gsub("\n", "\r\n")))
end
function FS.read_text(path)                     -- open(path).read(): "\r\n" back to "\n"
  local s = w3.fs.read(path)
  return s and (s:gsub("\r\n", "\n")) or nil
end

-- (TW3SE's w3.proc.open: w3.proc.run starts every program hidden, Explorer's window too - 22.10.)
function FS.show(path, select)
  if w3.proc and w3.proc.open then return w3.proc.open(tostring(path), {select = select == true}) end
  if w3.proc and w3.proc.run then
    return w3.proc.run(select and ('explorer.exe /select,"' .. path .. '"') or ('explorer.exe "' .. path .. '"'))
  end
end

return FS
