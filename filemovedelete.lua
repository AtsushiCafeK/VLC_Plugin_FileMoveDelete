--[[
 filemovedelete.lua
 VLC 拡張機能: プレイリスト内のファイルを「フォルダ移動」または「ゴミ箱へ移動」する。

 インストール:
   このファイルを VLC の lua/extensions フォルダに置く。
     ユーザー単位: %APPDATA%\vlc\lua\extensions\
     全体        : <VLCインストール先>\lua\extensions\
   VLC を再起動し、メニュー「表示(View)」→「ファイル移動 / ゴミ箱」で起動。

 注意:
   - Lua 拡張は Qt プレイリストの選択状態を取得できないため、本ダイアログ内の
     一覧で操作対象を選択する(複数選択可)。
   - 移動/ゴミ箱処理は Windows の PowerShell を内部で呼び出す。
   - お気に入りフォルダは userdir\lua\extensions\filemovedelete_favorites.txt に
     1 行 1 パスで保存される。「お気に入りに追加」ボタンで現在の移動先を登録。
]]--

local dlg          = nil   -- ダイアログ
local items_widget = nil    -- プレイリスト一覧の list ウィジェット
local path_input   = nil    -- 移動先パスの入力欄
local rename_input = nil    -- 新しいファイル名の入力欄
local status_label = nil    -- ステータス表示
local items        = {}      -- { [id] = { plid=<playlist id>, path=<native>, name=<表示名> } }
local favorites    = {}

--------------------------------------------------------------------------------
-- 拡張機能ディスクリプタ
--------------------------------------------------------------------------------
function descriptor()
    return {
        title       = "ファイル移動 / ゴミ箱",
        version     = "1.0",
        author      = "",
        shortdesc   = "プレイリストのファイルを移動 / ゴミ箱へ",
        description  = "プレイリスト内の動画ファイルを別フォルダへ移動、またはゴミ箱へ送る。",
        capabilities = {}
    }
end

function activate()
    favorites = load_favorites()
    create_dialog()
    refresh_list()
end

function deactivate()
    if dlg then dlg:delete() end
    dlg = nil
end

function close()
    vlc.deactivate()
end

--------------------------------------------------------------------------------
-- ユーティリティ
--------------------------------------------------------------------------------

-- file:// URI を Windows ネイティブパスに変換する。file 以外は nil。
local function uri_to_path(uri)
    if not uri then return nil end
    if uri:sub(1, 7) ~= "file://" then return nil end
    local path = uri:sub(8)            -- "file://" を除去 -> "/C:/..." または "server/share"
    if path:sub(1, 1) == "/" then
        path = path:sub(2)              -- 先頭の "/" を除去 -> "C:/..."
    else
        path = "\\\\" .. path           -- ネットワーク共有 -> \\server\share
    end
    path = vlc.strings.decode_uri(path) -- %20 などをデコード
    path = path:gsub("/", "\\")
    return path
end

local function basename(p)
    return p:match("[^\\]+$") or p
end

-- PowerShell の単一引用符内で使うため ' を '' にエスケープ
local function ps_quote(s)
    return (s:gsub("'", "''"))
end

local function ext_dir()
    return vlc.config.userdatadir() .. "\\lua\\extensions"
end

-- PowerShell スクリプトを「ウィンドウ非表示」で実行し結果文字列を返す。
-- io.popen の標準出力取得に依存せず、結果ファイル経由で受け取る。
-- body は PowerShell の本体。何も出力しなければ "OK"、出力があればそれを返す。
-- 例外時は "ERR:<メッセージ>" を返す。日本語パス対策に UTF-8 BOM 付きで書き出す。
local function run_hidden(body)
    local dir = ext_dir()
    local ps1 = dir .. "\\fmd_tmp.ps1"
    local vbs = dir .. "\\fmd_run.vbs"
    local res = dir .. "\\fmd_result.txt"
    os.remove(res)

    local f = io.open(ps1, "wb")
    if not f then return "ERR:スクリプトを書き出せません" end
    f:write("\239\187\191")  -- UTF-8 BOM (PowerShell に UTF-8 と認識させる)
    f:write("$ErrorActionPreference='Stop'\r\n")
    f:write("$r=''\r\n")
    f:write("try {\r\n")
    f:write("$r = . {\r\n", body, "\r\n} | Out-String\r\n")
    f:write("if([string]::IsNullOrWhiteSpace($r)){$r='OK'}\r\n")
    f:write("} catch { $r='ERR:'+$_.Exception.Message }\r\n")
    f:write("$r.Trim() | Out-File -LiteralPath '", ps_quote(res), "' -Encoding utf8\r\n")
    f:close()

    -- wscript 経由で起動すると powershell ウィンドウが一切表示されない
    local v = io.open(vbs, "wb")
    if not v then return "ERR:起動スクリプトを書き出せません" end
    v:write('Set sh = CreateObject("WScript.Shell")\r\n')
    v:write('sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File ""',
            ps1, '""", 0, True\r\n')
    v:close()

    os.execute('wscript.exe "' .. vbs .. '"')

    local rf = io.open(res, "rb")
    local out = rf and rf:read("*a") or "ERR:結果ファイルがありません"
    if rf then rf:close() end
    out = out:gsub("^\239\187\191", "")             -- BOM 除去
    out = out:gsub("^%s+", ""):gsub("%s+$", "")
    return out
end

local function file_exists(p)
    local f = io.open(p, "r")
    if f then f:close() return true end
    return false
end

local function set_status(msg)
    if status_label then
        status_label:set_text(msg)
        dlg:update()
    end
    vlc.msg.info("[filemovedelete] " .. msg)
end

--------------------------------------------------------------------------------
-- お気に入りフォルダの読み書き
--------------------------------------------------------------------------------
local function favorites_file()
    return vlc.config.userdatadir() .. "\\lua\\extensions\\filemovedelete_favorites.txt"
end

function load_favorites()
    local list = {}
    local f = io.open(favorites_file(), "r")
    if f then
        for line in f:lines() do
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" then table.insert(list, line) end
        end
        f:close()
    end
    return list
end

local function save_favorites()
    local f = io.open(favorites_file(), "w")
    if not f then return end
    for _, p in ipairs(favorites) do f:write(p, "\n") end
    f:close()
end

--------------------------------------------------------------------------------
-- プレイリスト取得
--------------------------------------------------------------------------------
local function collect(node, out)
    if node.children then
        for _, c in ipairs(node.children) do collect(c, out) end
    elseif node.path then
        table.insert(out, node)
    end
end

function refresh_list()
    items = {}
    items_widget:clear()
    local root = vlc.playlist.get("playlist", false)
    local flat = {}
    if root then collect(root, flat) end

    local id = 1
    for _, it in ipairs(flat) do
        local native = uri_to_path(it.path)
        if native then
            items[id] = { plid = it.id, path = native, name = it.name or basename(native) }
            items_widget:add_value(it.name or basename(native), id)
            id = id + 1
        end
    end
    if id == 1 then
        set_status("ローカルファイルがプレイリストにありません。")
    else
        set_status((id - 1) .. " 件のファイル。操作対象を選択してください(複数可)。")
    end
end

--------------------------------------------------------------------------------
-- 操作の実行
--------------------------------------------------------------------------------
local function selected_items()
    local sel = items_widget:get_selection()
    local result = {}
    if sel then
        for id, _ in pairs(sel) do
            if items[id] then table.insert(result, items[id]) end
        end
    end
    return result
end

function do_move()
    local dest = path_input:get_text()
    dest = dest:gsub("^%s+", ""):gsub("%s+$", "")
    if dest == "" then
        set_status("移動先フォルダを指定してください。")
        return
    end
    local sel = selected_items()
    if #sel == 0 then
        set_status("操作対象を選択してください。")
        return
    end

    local ok, fail = 0, 0
    for _, it in ipairs(sel) do
        local target = dest:gsub("\\+$", "") .. "\\" .. basename(it.path)
        if file_exists(target) then
            set_status("既に存在するためスキップ: " .. basename(it.path))
            fail = fail + 1
        else
            local body = "Move-Item -LiteralPath '" .. ps_quote(it.path)
                .. "' -Destination '" .. ps_quote(dest) .. "' -ErrorAction Stop"
            local out = run_hidden(body)
            if out == "OK" then
                ok = ok + 1
                vlc.playlist.delete(it.plid)
            else
                fail = fail + 1
                set_status("移動失敗: " .. basename(it.path) .. " / " .. tostring(out))
                vlc.msg.err("[filemovedelete] move failed: " .. tostring(out))
            end
        end
    end
    refresh_list()
    set_status(string.format("移動完了: 成功 %d / 失敗・スキップ %d", ok, fail))
end

function do_trash()
    local sel = selected_items()
    if #sel == 0 then
        set_status("操作対象を選択してください。")
        return
    end
    local ok, fail = 0, 0
    for _, it in ipairs(sel) do
        local body = "Add-Type -AssemblyName Microsoft.VisualBasic\r\n"
            .. "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile('"
            .. ps_quote(it.path) .. "','OnlyErrorDialogs','SendToRecycleBin')"
        local out = run_hidden(body)
        if out == "OK" then
            ok = ok + 1
            vlc.playlist.delete(it.plid)
        else
            fail = fail + 1
            set_status("ゴミ箱失敗: " .. basename(it.path) .. " / " .. tostring(out))
            vlc.msg.err("[filemovedelete] trash failed: " .. tostring(out))
        end
    end
    refresh_list()
    set_status(string.format("ゴミ箱へ移動: 成功 %d / 失敗 %d", ok, fail))
end

-- 選択中(1件)の現在のファイル名を入力欄に読み込む
function load_selected_name()
    local sel = selected_items()
    if #sel ~= 1 then
        set_status("名前変更は 1 件だけ選択してください。")
        return
    end
    rename_input:set_text(basename(sel[1].path))
    dlg:update()
    set_status("現在名を読み込みました。編集して「名前変更」を押してください。")
end

-- 選択中(1件)のファイルを同じフォルダ内でリネーム
function do_rename()
    local sel = selected_items()
    if #sel ~= 1 then
        set_status("名前変更は 1 件だけ選択してください。")
        return
    end
    local newname = rename_input:get_text():gsub("^%s+", ""):gsub("%s+$", "")
    if newname == "" then
        set_status("新しいファイル名を入力してください。")
        return
    end
    if newname:match('[\\/:%*%?"<>|]') then
        set_status('ファイル名に使用できない文字が含まれています ( \\ / : * ? " < > | )')
        return
    end
    local it = sel[1]
    local folder = it.path:match("^(.*)\\[^\\]+$") or ""
    local newpath = folder .. "\\" .. newname
    if newpath == it.path then
        set_status("名前が変わっていません。")
        return
    end
    if file_exists(newpath) then
        set_status("同名のファイルが既に存在します: " .. newname)
        return
    end
    local body = "Rename-Item -LiteralPath '" .. ps_quote(it.path)
        .. "' -NewName '" .. ps_quote(newname) .. "' -ErrorAction Stop"
    local out = run_hidden(body)
    if out == "OK" then
        -- プレイリストの該当項目を新パスに差し替える
        vlc.playlist.delete(it.plid)
        pcall(function()
            vlc.playlist.enqueue({ { path = vlc.strings.make_uri(newpath) } })
        end)
        refresh_list()
        rename_input:set_text("")
        set_status("名前変更しました: " .. newname)
    else
        set_status("名前変更失敗: " .. tostring(out))
        vlc.msg.err("[filemovedelete] rename failed: " .. tostring(out))
    end
end

function browse_folder()
    local body = "Add-Type -AssemblyName System.Windows.Forms\r\n"
        .. "$f = New-Object System.Windows.Forms.FolderBrowserDialog\r\n"
        .. "if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $f.SelectedPath }"
    local out = run_hidden(body)
    if out and out ~= "" and out ~= "OK" and out:sub(1, 4) ~= "ERR:" then
        path_input:set_text(out)
        dlg:update()
        set_status("移動先: " .. out)
    end
end

function add_favorite()
    local dest = path_input:get_text():gsub("^%s+", ""):gsub("%s+$", "")
    if dest == "" then
        set_status("移動先パスが空です。")
        return
    end
    for _, p in ipairs(favorites) do
        if p == dest then set_status("既に登録済みです。") return end
    end
    table.insert(favorites, dest)
    save_favorites()
    rebuild_dialog()
    set_status("お気に入りに追加: " .. dest)
end

--------------------------------------------------------------------------------
-- ダイアログ構築
--------------------------------------------------------------------------------
function create_dialog()
    if dlg then dlg:delete() end
    dlg = vlc.dialog("ファイル移動 / ゴミ箱")

    local row = 1
    dlg:add_label("<b>操作対象(複数選択可)</b>", 1, row, 4, 1); row = row + 1
    items_widget = dlg:add_list(1, row, 4, 4); row = row + 4

    dlg:add_label("移動先:", 1, row, 1, 1)
    path_input = dlg:add_text_input("", 2, row, 2, 1)
    dlg:add_button("参照...", browse_folder, 4, row, 1, 1); row = row + 1

    -- お気に入りフォルダのボタン(横並び)
    dlg:add_label("お気に入り:", 1, row, 1, 1)
    local col = 2
    for _, fav in ipairs(favorites) do
        local target = fav
        dlg:add_button(fav, function()
            path_input:set_text(target)
            dlg:update()
        end, col, row, 1, 1)
        col = col + 1
        if col > 4 then col = 2; row = row + 1 end
    end
    row = row + 1

    -- ファイル名変更(1 件のみ)
    dlg:add_label("新しい名前:", 1, row, 1, 1)
    rename_input = dlg:add_text_input("", 2, row, 2, 1)
    dlg:add_button("選択名を読込", load_selected_name, 4, row, 1, 1); row = row + 1
    dlg:add_button("名前変更", do_rename, 4, row, 1, 1); row = row + 1

    dlg:add_button("お気に入りに追加", add_favorite, 1, row, 1, 1)
    dlg:add_button("一覧を更新",       refresh_list, 2, row, 1, 1)
    dlg:add_button("フォルダへ移動",   do_move,      3, row, 1, 1)
    dlg:add_button("ゴミ箱へ移動",     do_trash,     4, row, 1, 1)
    row = row + 1

    status_label = dlg:add_label("", 1, row, 4, 1)
    dlg:show()
end

-- お気に入り追加後などにダイアログを作り直す
function rebuild_dialog()
    create_dialog()
    refresh_list()
end
