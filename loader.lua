--[[
    Loader Myshi Hub
    Ganti bagian KONFIGURASI di bawah dengan repo GitHub kamu.

    Syarat:
      - Repo PUBLIK. URL raw repo privat akan menghasilkan 404.
      - File stoneit.luau sudah di-upload ke repo tersebut.
      - Path di bawah harus persis sama dengan lokasi file di repo.
]]

local KONFIGURASI = {
    user = "Imyshi",             -- contoh: "ShinobiComplys"
    repo = "myshi-stoneit",      -- contoh: "loaders"
    branch = "main",            -- "main" atau "master"
    path = "stoneit.luau",      -- contoh: "loaders/stoneit.luau"
}

local function bikinUrlRaw(user, repo, branch, path)
    return string.format(
        "https://raw.githubusercontent.com/%s/%s/%s/%s",
        user, repo, branch, path
    )
end

local function bikinUrlJsdelivr(user, repo, branch, path)
    return string.format(
        "https://cdn.jsdelivr.net/gh/%s/%s@%s/%s",
        user, repo, branch, path
    )
end

local function ambilSumber(url)
    local ok, hasil = pcall(function()
        return game:HttpGet(url)
    end)

    if not ok then
        return nil, tostring(hasil)
    end
    if type(hasil) ~= "string" or #hasil < 100 then
        return nil, "respons kosong/terlalu pendek"
    end
    if string.find(hasil, "404: Not Found", 1, true) then
        return nil, "404 (repo privat, path salah, atau branch salah)"
    end
    if string.find(hasil, "<!DOCTYPE html", 1, true) then
        return nil, "URL bukan raw file"
    end

    return hasil
end

if type(loadstring) ~= "function" then
    warn("[Myshi Loader] Executor tidak mendukung loadstring.")
    return
end

local cacheBuster = tostring(os.time())
local daftarUrl = {
    bikinUrlRaw(
        KONFIGURASI.user,
        KONFIGURASI.repo,
        KONFIGURASI.branch,
        KONFIGURASI.path
    ) .. "?v=" .. cacheBuster,
    bikinUrlJsdelivr(
        KONFIGURASI.user,
        KONFIGURASI.repo,
        KONFIGURASI.branch,
        KONFIGURASI.path
    ) .. "?v=" .. cacheBuster,
}

local sumber = nil
local errorTerakhir = nil

for _, url in ipairs(daftarUrl) do
    local isi, err = ambilSumber(url)
    if isi then
        sumber = isi
        break
    end
    errorTerakhir = tostring(err)
end

if not sumber then
    warn("[Myshi Loader] Gagal mengambil script: " .. tostring(errorTerakhir))
    warn("[Myshi Loader] Cek repo publik, branch, dan path file.")
    return
end

local chunk, compileError = loadstring(sumber, "MyshiHub")
if not chunk then
    warn("[Myshi Loader] Script tidak bisa di-compile: " .. tostring(compileError))
    return
end

local ok, runtimeError = pcall(chunk)
if not ok then
    warn("[Myshi Loader] Error saat menjalankan script: " .. tostring(runtimeError))
end
