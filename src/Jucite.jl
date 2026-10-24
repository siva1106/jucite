module Jucite

using SQLite
using DataFrames
using HTTP
using JSON3
using Oxygen
using Blink    # NEW: Desktop Window Manager
const DB_PATH = "jucite_library.sqlite"
const PDF_DIR = "pdfs"
const STYLES_CATALOG_FILE = "styles_catalog.json"

# ======================================================
# --- LOCK-FREE DATABASE ENGINE (WAL MODE) ---
# ======================================================

"""
    get_db()
Connects to SQLite with WAL mode and a 5-second busy timeout so concurrent reads/writes never lock!
"""
function get_db()
    db = SQLite.DB(DB_PATH)
    SQLite.execute(db, "PRAGMA journal_mode=WAL;")
    SQLite.execute(db, "PRAGMA busy_timeout = 5000;")
    return db
end

# ======================================================
# --- DATABASE INITIALIZATION ---
# ======================================================
function init_db()
    db = get_db()
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS papers (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, doi TEXT UNIQUE, year INTEGER, journal TEXT, pdf_path TEXT)")
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS authors (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE)")
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS paper_authors (paper_id INTEGER, author_id INTEGER, FOREIGN KEY(paper_id) REFERENCES papers(id), FOREIGN KEY(author_id) REFERENCES authors(id), PRIMARY KEY (paper_id, author_id))")
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS collections (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, is_group INTEGER DEFAULT 0)")
    
    # NEW: Table that links papers to specific collections/groups!
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS collection_papers (collection_id INTEGER, paper_id INTEGER, PRIMARY KEY (collection_id, paper_id))")
    return db
end

# ... (keep your fetch_metadata and download_pdf functions exactly as they are) ...

# UPDATE: Save paper now accepts a collection_id
function save_paper(paper_info, collection_id::Int=0)
    if paper_info === nothing return end
    pdf_local_path = download_pdf(paper_info.pdf_url, paper_info.title)
    
    db = get_db()
    SQLite.transaction(db) do
        stmt_paper = SQLite.Stmt(db, "INSERT OR IGNORE INTO papers (title, doi, year, journal, pdf_path) VALUES (?, ?, ?, ?, ?)")
        SQLite.execute(stmt_paper, (paper_info.title, paper_info.doi, paper_info.year, paper_info.journal, pdf_local_path))
        
        cursor_paper = DBInterface.execute(db, "SELECT id FROM papers WHERE doi = ?", (paper_info.doi,))
        paper_id = first(cursor_paper).id
        
        for author_name in paper_info.authors
            stmt_author = SQLite.Stmt(db, "INSERT OR IGNORE INTO authors (name) VALUES (?)")
            SQLite.execute(stmt_author, (author_name,))
            cursor_auth = DBInterface.execute(db, "SELECT id FROM authors WHERE name = ?", (author_name,))
            author_id = first(cursor_auth).id
            stmt_link = SQLite.Stmt(db, "INSERT OR IGNORE INTO paper_authors (paper_id, author_id) VALUES (?, ?)")
            SQLite.execute(stmt_link, (paper_id, author_id))
        end
        
        # NEW: If a group is selected, link the paper to that group!
        if collection_id > 0
            stmt_cp = SQLite.Stmt(db, "INSERT OR IGNORE INTO collection_papers (collection_id, paper_id) VALUES (?, ?)")
            SQLite.execute(stmt_cp, (collection_id, paper_id))
        end
    end
    println("💾 Saved paper to SQLite. (Collection ID: $collection_id)")
end

# ... (keep your CSL functions exactly as they are) ...

# UPDATE: API Library now filters by Collection!
@get "/api/library" function(req::HTTP.Request)
    params = queryparams(req)
    col_id = parse(Int, get(params, "collection_id", "0"))
    is_trash = parse(Int, get(params, "trash", "0"))
    
    db = SQLite.DB(DB_PATH)
    try SQLite.execute(db, "ALTER TABLE papers ADD COLUMN trashed INTEGER DEFAULT 0") catch end
    
    if is_trash == 1
        df = DBInterface.execute(db, "SELECT id, title, year, journal, pdf_path, doi FROM papers WHERE trashed = 1") |> DataFrame
    elseif col_id > 0
        df = DBInterface.execute(db, "SELECT p.id, p.title, p.year, p.journal, p.pdf_path, p.doi FROM papers p JOIN collection_papers cp ON p.id = cp.paper_id WHERE cp.collection_id = ? AND (p.trashed IS NULL OR p.trashed = 0)", (col_id,)) |> DataFrame
    else
        df = DBInterface.execute(db, "SELECT id, title, year, journal, pdf_path, doi FROM papers WHERE trashed IS NULL OR trashed = 0") |> DataFrame
    end
    
    papers_list = []
    for row in eachrow(df)
        authors = get_paper_authors(db, row.id)
        csl_authors = [length(split(a, ", ")) == 2 ? Dict("family" => split(a, ", ")[1], "given" => split(a, ", ")[2]) : Dict("family" => a) for a in authors]
        push!(papers_list, Dict("id" => row.id, "title" => row.title, "year" => row.year, "journal" => row.journal, "pdf_path" => row.pdf_path, "authors" => csl_authors, "doi" => ismissing(row.doi) ? "" : row.doi))
    end
    return papers_list
end
# UPDATE: API Save now accepts the Collection ID!
@post "/api/save" function(req::HTTP.Request)
    headers = ["Access-Control-Allow-Origin" => "*", "Content-Type" => "application/json"]
    try
        data = json(req)
        doi_val = haskey(data, :doi) ? String(data.doi) : ""
        col_id = haskey(data, :collection_id) ? Int(data.collection_id) : 0
        
        if !isempty(doi_val)
            paper = fetch_metadata(doi_val)
            if paper !== nothing
                save_paper(paper, col_id)
                return HTTP.Response(200, headers, "{\"status\": \"saved\"}")
            end
        end
        return HTTP.Response(400, headers, "{\"error\": \"Nothing to save\"}")
    catch e
        return HTTP.Response(500, headers, "{\"error\": \"Failed to save\"}")
    end
end
# ======================================================
# --- GOOGLE DRIVE CLOUD SYNC ENGINE ---
# ======================================================

const DRIVE_SYNC_DIR = "Jucite_Cloud_Backup"

"""
    sync_to_google_drive(access_token::String="")
Uploads jucite_library.sqlite and PDF attachments to Google Drive.
"""
function sync_to_google_drive(access_token::String="")
    println("☁️ Structuring and Syncing to Google Drive...")
    
    if !isfile(DB_PATH)
        return Dict("status" => "error", "message" => "Database file not found.")
    end
    
    drive_root = joinpath(homedir(), "Google_Drive_Jucite")
    my_lib_dir = joinpath(drive_root, "My Library")
    groups_dir = joinpath(drive_root, "Group Libraries")
    
    mkpath(my_lib_dir)
    mkpath(joinpath(my_lib_dir, "pdfs"))
    mkpath(groups_dir)
    
    # 1. Safe SQLite Backup (Bypasses WAL locks!)
    try
        # SQLite's built-in backup command ensures the file is copied safely even while running
        run(`sqlite3 $DB_PATH ".backup '$(joinpath(my_lib_dir, DB_PATH))'"`)
    catch e
        # Fallback if sqlite3 command line tool isn't installed
        cp(DB_PATH, joinpath(my_lib_dir, DB_PATH); force=true)
    end
    
    # 2. Intelligently route PDFs
    db = get_db()
    df_papers = DBInterface.execute(db, "SELECT id, pdf_path FROM papers WHERE pdf_path IS NOT NULL AND pdf_path != ''") |> DataFrame
    
    pdf_count = 0
    for row in eachrow(df_papers)
        if ismissing(row.pdf_path) || !isfile(row.pdf_path) continue end
        
        filename = basename(row.pdf_path)
        
        cursor_group = DBInterface.execute(db, """
            SELECT c.name FROM collections c 
            JOIN collection_papers cp ON c.id = cp.collection_id 
            WHERE cp.paper_id = ? AND c.is_group = 1 LIMIT 1
        """, (row.id,))
        
        # Check if the cursor actually has results before trying to extract them
        df_group = DataFrame(cursor_group)
        if nrow(df_group) > 0
            group_name = df_group.name[1]
            clean_group_name = replace(group_name, r"[^a-zA-Z0-9_\-\s]" => "_")
            group_folder = joinpath(groups_dir, clean_group_name)
            mkpath(group_folder)
            
            cp(row.pdf_path, joinpath(group_folder, filename); force=true)
        else
            cp(row.pdf_path, joinpath(my_lib_dir, "pdfs", filename); force=true)
        end
        pdf_count += 1
    end
    
    println("✅ Google Drive Sync Complete! Structured $pdf_count PDFs.")
    
    return Dict(
        "status" => "success", 
        "message" => "Synced $pdf_count PDFs successfully!",
        "backup_path" => drive_root
    )
end
# ======================================================
# --- GOOGLE DRIVE CLOUD SYNC API ---
# ======================================================

@route ["OPTIONS"] "/api/sync/drive" function(req::HTTP.Request)
    return HTTP.Response(200, [
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "GET, OPTIONS",
        "Access-Control-Allow-Headers" => "*"
    ], "")
end
# ======================================================
# --- COLLABORATIVE GOOGLE DRIVE CLOUD UPLOADER ---
# ======================================================

function safe_str(val)
    if val isa AbstractVector
        return isempty(val) ? "" : safe_str(val[1])
    elseif val isa AbstractString || val isa Symbol
        return String(val)
    elseif val === nothing || ismissing(val)
        return ""
    else
        return string(val)
    end
end

# UNIVERSAL SAFE SEARCH ENGINE FOR FILES AND FOLDERS
function get_drive_id(name::String, is_folder::Bool, parent_id::String, token::String)
    url = "https://www.googleapis.com/drive/v3/files"
    
    # Escape single quotes specifically for Google Drive Query syntax
    safe_name = replace(name, "'" => "\\'")
    
    query = "name = '$(safe_name)' and trashed = false"
    if is_folder
        query *= " and mimeType = 'application/vnd.google-apps.folder'"
    end
    if !isempty(parent_id)
        query *= " and '$(parent_id)' in parents"
    end
    
    # Safely URL-Encode the query so characters like &, +, and spaces never crash it!
    full_url = "$url?q=$(HTTP.URIs.escapeuri(query))&fields=files(id)"
    
    try
        res = HTTP.get(full_url, ["Authorization" => "Bearer $token"]; status_exception=false)
        if res.status == 200
            json_res = JSON3.read(res.body)
            if haskey(json_res, :files) && !isempty(json_res.files)
                return safe_str(json_res.files[1].id)
            end
        end
    catch e end
    return ""
end
# NEW: Reads the raw contents of a file directly from Google Drive API
function read_drive_file(file_id::String, token::String)
    url = "https://www.googleapis.com/drive/v3/files/$file_id?alt=media"
    try
        res = HTTP.get(url, ["Authorization" => "Bearer $token"]; status_exception=false)
        if res.status == 200
            return String(res.body)
        end
    catch e
        println("⚠️ Failed to read drive file $file_id: ", e)
    end
    return ""
end
function create_drive_folder(folder_name::String, parent_id, token)
    parent_str = safe_str(parent_id); tok_str = safe_str(token)
    
    existing_id = get_drive_id(folder_name, true, parent_str, tok_str)
    if !isempty(existing_id) return existing_id end
    
    url = "https://www.googleapis.com/drive/v3/files"
    headers = ["Authorization" => "Bearer $tok_str", "Content-Type" => "application/json"]
    body_dict = Dict{String, Any}("name" => folder_name, "mimeType" => "application/vnd.google-apps.folder")
    if !isempty(parent_str) body_dict["parents"] = [parent_str] end
    
    try
        res = HTTP.post(url, headers, JSON3.write(body_dict); status_exception=false)
        if res.status == 200 return safe_str(JSON3.read(res.body).id) end
    catch e end
    return ""
end

function upload_file_to_drive(file_path::String, file_name::String, parent_id, mime::String, token; overwrite=false)
    parent_str = safe_str(parent_id); tok_str = safe_str(token)
    
    existing_id = get_drive_id(file_name, false, parent_str, tok_str)
    file_id = ""
    
    if !isempty(existing_id)
        if overwrite
            file_id = existing_id
        else
            println("⏭️ Skipped (Already Exists): $file_name")
            return
        end
    else
        url_create = "https://www.googleapis.com/drive/v3/files"
        headers = ["Authorization" => "Bearer $tok_str", "Content-Type" => "application/json"]
        meta_dict = Dict{String, Any}("name" => file_name)
        if !isempty(parent_str) meta_dict["parents"] = [parent_str] end
        
        try
            res_meta = HTTP.post(url_create, headers, JSON3.write(meta_dict); status_exception=false)
            if res_meta.status == 200
                file_id = safe_str(JSON3.read(res_meta.body).id)
            else return end
        catch e return end
    end
    
    try
        url_upload = "https://www.googleapis.com/upload/drive/v3/files/$file_id?uploadType=media"
        HTTP.patch(url_upload, ["Authorization" => "Bearer $tok_str", "Content-Type" => mime], read(file_path); status_exception=false)
        println("✅ Uploaded: $file_name")
    catch e end
end
# --- MAIN COLLABORATIVE SYNC ENDPOINT ---
@get "/api/sync/drive" function(req::HTTP.Request)
    headers = ["Access-Control-Allow-Origin" => "*", "Content-Type" => "application/json"]
    
    # FIX: Call the smart function that auto-renews the token if needed!
    access_token = get_valid_access_token()
    
    if isempty(access_token) 
        return HTTP.Response(400, headers, "{\"status\": \"error\", \"message\": \"Google Drive token expired or unlinked.\"}") 
    end
    
    println("☁️ Starting Two-Way Collaborative Sync with Google Drive...")
    
    try
        db = SQLite.DB(DB_PATH)
        
        root_id = create_drive_folder("Jucite Library", "", access_token)
        my_lib_id = create_drive_folder("My Library", root_id, access_token)
        groups_id = create_drive_folder("Group Libraries", root_id, access_token)
        
        temp_dir = joinpath(homedir(), "Jucite_Temp_Upload")
        mkpath(temp_dir)
        
        # 1. PULL (DOWN-SYNC): Check cloud groups for new papers from teammates!
        cursor_groups = DBInterface.execute(db, "SELECT id, name FROM collections WHERE is_group = 1")
        for g_row in eachrow(DataFrame(cursor_groups))
            group_id = g_row.id
            clean_group_name = replace(g_row.name, r"[^a-zA-Z0-9_\-\s]" => "_")
            
            # FIXED: Using the new unified get_drive_id function
            cloud_g_id = get_drive_id(clean_group_name, true, groups_id, access_token)
            if !isempty(cloud_g_id)
                index_id = get_drive_id("group_index.json", false, cloud_g_id, access_token)
                if !isempty(index_id)
                    cloud_json = read_drive_file(index_id, access_token)
                    if !isempty(cloud_json)
                        println("📥 Downloading papers from teammate for group: $(g_row.name)")
                        cloud_papers = JSON3.read(cloud_json)
                        
                        SQLite.transaction(db) do
                            for p in cloud_papers
                            p_doi = (haskey(p, :doi) && p.doi !== nothing) ? string(p.doi) : ""
                            if isempty(p_doi) continue end
                            
                            # Check if User B already has this paper locally
                            c_check = DBInterface.execute(db, "SELECT id FROM papers WHERE doi = ?", (p_doi,))
                            
                            if isempty(c_check)
                                println("📥 New paper found from teammate! Auto-fetching PDF for: ", p_doi)
                                
                                # Let Jucite do the heavy lifting! Fetch metadata & download PDF automatically for User B!
                                paper_info = fetch_metadata(p_doi)
                                if paper_info !== nothing
                                    # Save it and link it to the shared group!
                                    save_paper(paper_info, group_id)
                                end
                            else
                                # If User B already has the paper, just make sure it's linked to the group
                                pid = first(c_check).id
                                stmt_link = SQLite.Stmt(db, "INSERT OR IGNORE INTO collection_papers (collection_id, paper_id) VALUES (?, ?)")
                                SQLite.execute(stmt_link, (group_id, pid))
                            end
                        end
                        end
                    end
                end
            end
        end

        # 2. PUSH (UP-SYNC): Upload our active library to the cloud
        df_papers = DBInterface.execute(db, "SELECT id, title, year, journal, doi, pdf_path FROM papers WHERE trashed IS NULL OR trashed = 0") |> DataFrame
        
        group_indexes = Dict{String, Vector{Any}}()
        item_count = 0
        
        for row in eachrow(df_papers)
            # FIXED: Safe year extraction for missing values
            year_str = ismissing(row.year) || row.year == 0 ? "UnknownYear" : string(row.year)
            
            safe_title = replace(row.title, r"<[^>]*>" => "")
            safe_title = replace(safe_title, r"&[a-zA-Z]+;" => "")
            safe_title = replace(safe_title, r"[\n\r\t]" => " ")
            safe_title = replace(safe_title, r"[^a-zA-Z0-9\-\s]" => "")
            safe_title = replace(safe_title, r"\s+" => "_")[1:min(length(safe_title), 50)]
            safe_title = replace(safe_title, r"_+$" => "")
            
            filename_base = "$(year_str)_$(safe_title)"
            
            cursor_group = DBInterface.execute(db, "SELECT c.name FROM collections c JOIN collection_papers cp ON c.id = cp.collection_id WHERE cp.paper_id = ? AND c.is_group = 1 LIMIT 1", (row.id,))
            df_group = DataFrame(cursor_group)
            
            target_cloud_id = my_lib_id
            if nrow(df_group) > 0
                group_name = df_group.name[1]
                target_cloud_id = create_drive_folder(group_name, groups_id, access_token)
                
                if !haskey(group_indexes, group_name) group_indexes[group_name] = [] end
                push!(group_indexes[group_name], Dict("title" => row.title, "doi" => row.doi, "year" => row.year, "journal" => row.journal))
            end
            
            has_pdf = !ismissing(row.pdf_path) && !isempty(row.pdf_path) && isfile(row.pdf_path)
            if has_pdf
                upload_file_to_drive(row.pdf_path, "$(filename_base).pdf", target_cloud_id, "application/pdf", access_token; overwrite=false)
            else
                txt_path = joinpath(temp_dir, "$(filename_base)_Metadata.txt")
                write(txt_path, "Title: $(row.title)\nDOI: $(row.doi)")
                upload_file_to_drive(txt_path, "$(filename_base)_Metadata.txt", target_cloud_id, "text/plain", access_token; overwrite=false)
            end
            item_count += 1
        end
        
        # 3. OVERWRITE GROUP JSON FILES IN CLOUD
        for (g_name, g_papers) in group_indexes
            g_cloud_id = create_drive_folder(g_name, groups_id, access_token)
            json_path = joinpath(temp_dir, "group_index.json")
            write(json_path, JSON3.write(g_papers))
            upload_file_to_drive(json_path, "group_index.json", g_cloud_id, "application/json", access_token; overwrite=true)
        end
        
        rm(temp_dir, recursive=true, force=true)
        println("✅ Collaborative Cloud Sync Complete!")
        return HTTP.Response(200, headers, JSON3.write(Dict("status" => "success", "message" => "Sync complete! No duplicates!")))
        
    catch e
        println("❌ Sync Error: ", e)
        return HTTP.Response(500, headers, "{\"status\": \"error\", \"message\": \"Sync Failed.\"}")
    end
end
# ======================================================
# --- GOOGLE DRIVE OAUTH2 LINKAGE ENGINE ---
# ======================================================

const TOKEN_FILE = "google_tokens.json"
const GOOGLE_CLIENT_ID = "HIDDEN_FOR_GITHUB"
const GOOGLE_CLIENT_SECRET = "HIDDEN_FOR_GITHUB"
# 1. NEW BACKGROUND REFRESHER ENGINE
function get_valid_access_token()
    if !isfile(TOKEN_FILE) return "" end
    
    data = JSON3.read(read(TOKEN_FILE, String))
    access_token = haskey(data, :access_token) ? String(data.access_token) : ""
    refresh_token = haskey(data, :refresh_token) ? String(data.refresh_token) : ""
    expires_at = haskey(data, :expires_at) ? Float64(data.expires_at) : 0.0
    
    # If the token is still valid for at least 60 more seconds, use it!
    if time() < (expires_at - 60)
        return access_token
    end
    
    # If it expired, silently fetch a new one using the Refresh Token!
    if !isempty(refresh_token)
        println("🔄 Access Token expired. Auto-refreshing silently in background...")
        url = "https://oauth2.googleapis.com/token"
        payload = Dict(
            "client_id" => GOOGLE_CLIENT_ID,
            "client_secret" => GOOGLE_CLIENT_SECRET,
            "refresh_token" => refresh_token,
            "grant_type" => "refresh_token"
        )
        try
            res = HTTP.post(url, ["Content-Type" => "application/json"], JSON3.write(payload))
            new_data = JSON3.read(res.body)
            
            new_access = String(new_data.access_token)
            new_expires = time() + Int(get(new_data, :expires_in, 3600))
            
            # Save the new token so we don't have to refresh again for another hour
            save_data = Dict(
                "status" => "linked",
                "access_token" => new_access,
                "refresh_token" => refresh_token,
                "expires_at" => new_expires,
                "account" => String(get(data, :account, "Linked Google Account"))
            )
            write(TOKEN_FILE, JSON3.write(save_data))
            println("✅ Token successfully refreshed!")
            return new_access
        catch e
            println("❌ Failed to auto-refresh token: ", e)
        end
    end
    return ""
end

@get "/api/sync/status" function(req::HTTP.Request)
    headers = ["Access-Control-Allow-Origin" => "*", "Content-Type" => "application/json"]
    if isfile(TOKEN_FILE)
        data = JSON3.read(read(TOKEN_FILE, String))
        return HTTP.Response(200, headers, JSON3.write(data))
    else
        return HTTP.Response(200, headers, JSON3.write(Dict("status" => "unlinked")))
    end
end

@get "/api/oauth/google" function(req::HTTP.Request)
    redirect_uri = "http://127.0.0.1:8080/api/oauth/callback"
    scope = "https://www.googleapis.com/auth/drive.file" 
    auth_url = "https://accounts.google.com/o/oauth2/v2/auth?client_id=$(GOOGLE_CLIENT_ID)&redirect_uri=$(redirect_uri)&response_type=code&scope=$(scope)&access_type=offline&prompt=consent"
    return HTTP.Response(302, ["Location" => auth_url], "")
end

# 2. UPDATED CALLBACK TO CAPTURE REFRESH TOKEN
@get "/api/oauth/callback" function(req::HTTP.Request)
    params = queryparams(req)
    if haskey(params, "error") return HTTP.Response(400, "User denied access.") end
    
    code = get(params, "code", "")
    redirect_uri = "http://127.0.0.1:8080/api/oauth/callback"
    
    println("🔄 Exchanging authorization code for Access & Refresh Tokens...")
    token_url = "https://oauth2.googleapis.com/token"
    payload = Dict(
        "client_id" => GOOGLE_CLIENT_ID,
        "client_secret" => GOOGLE_CLIENT_SECRET,
        "code" => code,
        "grant_type" => "authorization_code",
        "redirect_uri" => redirect_uri
    )
    
    try
        res = HTTP.post(token_url, ["Content-Type" => "application/json"], JSON3.write(payload))
        token_data = JSON3.read(res.body)
        
        # Calculate exactly when this token expires (Unix Timestamp)
        expires_at = time() + Int(get(token_data, :expires_in, 3600))
        
        # Save BOTH tokens!
        save_data = Dict(
            "status" => "linked",
            "access_token" => String(token_data.access_token),
            "refresh_token" => haskey(token_data, :refresh_token) ? String(token_data.refresh_token) : "",
            "expires_at" => expires_at,
            "account" => "Linked Google Account"
        )
        write(TOKEN_FILE, JSON3.write(save_data))
        println("✅ Google Tokens Acquired & Saved!")
        
        html_response = """
        <!DOCTYPE html>
        <html>
        <body style="font-family:sans-serif; text-align:center; padding:50px; background:#f8fafc;">
          <h1 style="color:#10b981;">✅ Google Drive Successfully Linked!</h1>
          <p style="color:#475569;">You can now sync your library to the cloud forever.</p>
          <p style="color:#94a3b8; font-size:12px;">This window will close automatically...</p>
          <script>setTimeout(() => window.close(), 2000);</script>
        </body>
        </html>
        """
        return HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"], html_response)
        
    catch e
        return HTTP.Response(500, "Failed to connect to Google.")
    end
end

@post "/api/sync/unlink" function(req::HTTP.Request)
    headers = ["Access-Control-Allow-Origin" => "*", "Content-Type" => "application/json"]
    if isfile(TOKEN_FILE) rm(TOKEN_FILE, force=true) end
    println("🔓 Google Drive Account Unlinked.")
    return HTTP.Response(200, headers, "{\"status\": \"unlinked\"}")
end
# ======================================================
# --- METADATA & PDF INGESTION ENGINE ---
# ======================================================
function fetch_unpaywall_pdf(doi::String)
    url = "https://api.unpaywall.org/v2/$doi?email=test@jucite.com"
    try
        response = HTTP.get(url)
        json_data = JSON3.read(response.body)
        if haskey(json_data, :best_oa_location) && json_data.best_oa_location !== nothing
            oa_loc = json_data.best_oa_location
            if haskey(oa_loc, :url_for_pdf) && oa_loc.url_for_pdf !== nothing
                return string(oa_loc.url_for_pdf)
            end
        end
    catch e end
    return ""
end

function fetch_metadata(doi::String)
    url = "https://api.crossref.org/works/$doi"
    println("Fetching data from: ", url)
    try
        headers = ["User-Agent" => "JuciteApp/0.1"]
        response = HTTP.get(url, headers)
        json_data = JSON3.read(response.body)
        paper_data = json_data.message
        
        title = haskey(paper_data, :title) && !isempty(paper_data.title) ? paper_data.title[1] : "Unknown Title"
        journal = haskey(paper_data, Symbol("container-title")) && !isempty(paper_data[Symbol("container-title")]) ? paper_data[Symbol("container-title")][1] : "Unknown Journal"
        year = haskey(paper_data, :issued) && haskey(paper_data.issued, Symbol("date-parts")) ? paper_data.issued[Symbol("date-parts")][1][1] : 0
        
        authors = String[]
        if haskey(paper_data, :author)
            for a in paper_data.author
                if haskey(a, :given) && haskey(a, :family)
                    push!(authors, "$(a.family), $(a.given)")
                elseif haskey(a, :family)
                    push!(authors, a.family)
                end
            end
        end
        
        pdf_url = ""
        if haskey(paper_data, :link)
            for link in paper_data.link
                if haskey(link, Symbol("content-type")) && link[Symbol("content-type")] == "application/pdf"
                    pdf_url = link.URL; break
                end
            end
        end
        
        if isempty(pdf_url)
            println("🔍 Checking Unpaywall for PDF...")
            pdf_url = fetch_unpaywall_pdf(doi)
        end
        return (title=title, journal=journal, year=year, doi=doi, authors=authors, pdf_url=pdf_url)
    catch e
        println("\n❌ CRASH REPORT: ", e)
        return nothing
    end
end

function download_pdf(url::String, title::String)
    if isempty(url) return "" end
    clean_title = replace(title, r"[\"’'\/\\:\*\?<>\|]" => "")
    clean_title = replace(clean_title, " " => "_")
    filepath = joinpath(PDF_DIR, "$clean_title.pdf")
    mkpath(PDF_DIR)
    
    println("📥 Downloading PDF: ", url)
    try
        # Follow redirects and pretend to be a real browser
        headers = ["User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"]
        response = HTTP.get(url, headers, redirect=true)
        
        # SMART CHECK: Did the server actually send us a PDF? Or a fake HTML error page?
        content_type = ""
        for header in response.headers
            if lowercase(header.first) == "content-type"
                content_type = lowercase(header.second)
                break
            end
        end
        
        if contains(content_type, "application/pdf") || contains(content_type, "application/octet-stream")
            open(filepath, "w") do io
                write(io, response.body)
            end
            println("✅ PDF downloaded and verified successfully!")
            return filepath
        else
            println("❌ Download aborted: Server returned HTML/Text instead of a real PDF. (Paywall/Captcha blocked it).")
            return ""
        end
    catch e 
        println("❌ Download failed: ", e)
        return "" 
    end
end

function save_paper(paper_info, collection_id::Int=0)
    if paper_info === nothing return end
    db = get_db() # Uses the WAL lock-free database!
    pdf_local_path = download_pdf(paper_info.pdf_url, paper_info.title)
    
    SQLite.transaction(db) do
        stmt_paper = SQLite.Stmt(db, "INSERT OR IGNORE INTO papers (title, doi, year, journal, pdf_path) VALUES (?, ?, ?, ?, ?)")
        SQLite.execute(stmt_paper, (paper_info.title, paper_info.doi, paper_info.year, paper_info.journal, pdf_local_path))
        
        cursor_paper = DBInterface.execute(db, "SELECT id FROM papers WHERE doi = ?", (paper_info.doi,))
        paper_id = first(cursor_paper).id
        
        for author_name in paper_info.authors
            stmt_author = SQLite.Stmt(db, "INSERT OR IGNORE INTO authors (name) VALUES (?)")
            SQLite.execute(stmt_author, (author_name,))
            
            cursor_auth = DBInterface.execute(db, "SELECT id FROM authors WHERE name = ?", (author_name,))
            author_id = first(cursor_auth).id
            
            stmt_link = SQLite.Stmt(db, "INSERT OR IGNORE INTO paper_authors (paper_id, author_id) VALUES (?, ?)")
            SQLite.execute(stmt_link, (paper_id, author_id))
        end
        
        # Link the paper to the Group Library!
        if collection_id > 0
            stmt_cp = SQLite.Stmt(db, "INSERT OR IGNORE INTO collection_papers (collection_id, paper_id) VALUES (?, ?)")
            SQLite.execute(stmt_cp, (collection_id, paper_id))
        end
    end
    println("💾 Successfully saved paper. (Group ID: $collection_id)")
end

function get_paper_authors(db, paper_id::Int)
    cursor = DBInterface.execute(db, "SELECT name FROM authors JOIN paper_authors ON authors.id = paper_authors.author_id WHERE paper_authors.paper_id = ?", (paper_id,))
    return [row.name for row in cursor]
end

# ======================================================
# --- CSL STYLE CATALOG ENGINE ---
# ======================================================
function load_or_fetch_style_catalog()
    if isfile(STYLES_CATALOG_FILE)
        try return JSON3.read(read(STYLES_CATALOG_FILE, String)) catch e end
    end
    
    println("📥 Generating master catalog of CSL styles...")
    popular_bases = ["apa", "vancouver", "vancouver-superscript", "vancouver-brackets", "ieee", "nature", "cell", "the-lancet", "american-medical-association", "chicago-author-date", "harvard-cite-them-right", "science", "pnas", "springer-basic", "elsevier-harvard", "frontiers-in-psychology", "plos-one", "biomed-central", "royal-society-of-chemistry", "acm-siggraph"]
    styles_list = [Dict("name" => b, "title" => titlecase(replace(b, "-" => " "))) for b in popular_bases]
    write(STYLES_CATALOG_FILE, JSON3.write(styles_list))
    println("✅ Cached CSL style catalog locally!")
    return styles_list
end

function fetch_csl_style(style_name::String)
    styles_dir = "styles"
    mkpath(styles_dir)
    local_path = joinpath(styles_dir, "$style_name.csl")
    
    if isfile(local_path) return read(local_path, String) end
    
    url_root = "https://raw.githubusercontent.com/citation-style-language/styles/master/$style_name.csl"
    println("📥 Downloading Style: ", style_name)
    try
        res = HTTP.get(url_root; status_exception=false)
        if res.status == 200
            csl_xml = String(res.body)
            write(local_path, csl_xml)
            return csl_xml
        end
    catch e end
    
    url_dep = "https://raw.githubusercontent.com/citation-style-language/styles/master/dependent/$style_name.csl"
    try
        res = HTTP.get(url_dep; status_exception=false)
        if res.status == 200
            csl_xml = String(res.body)
            write(local_path, csl_xml)
            return csl_xml
        end
    catch e end
    return ""
end
# ======================================================
# --- TRASH & MOVE PAPER ENGINE ---
# ======================================================

# Helper function to safely extract an integer whether the JSON sent a Number or a String
function safe_parse_int(val)
    if val isa Number
        return Int(val)
    elseif val isa AbstractString
        return parse(Int, String(val))
    else
        return 0
    end
end

@route ["OPTIONS"] "/api/trash" function(req::HTTP.Request)
    return HTTP.Response(200, ["Access-Control-Allow-Origin" => "*", "Access-Control-Allow-Methods" => "POST, OPTIONS", "Access-Control-Allow-Headers" => "*"], "")
end

@post "/api/trash" function(req::HTTP.Request)
    headers = ["Access-Control-Allow-Origin" => "*", "Content-Type" => "application/json"]
    try
        data = JSON3.read(req.body)
        
        # Safely parse the ID whether it came as a string or a number
        paper_id = safe_parse_int(data.id)
        
        db = SQLite.DB(DB_PATH)
        try SQLite.execute(db, "ALTER TABLE papers ADD COLUMN trashed INTEGER DEFAULT 0") catch end
        
        SQLite.execute(db, "UPDATE papers SET trashed = 1 WHERE id = ?", (paper_id,))
        println("🗑️ Moved paper ID $paper_id to Trash")
        return HTTP.Response(200, headers, "{\"status\": \"success\"}")
    catch e
        println("❌ Trash Error: ", e)
        return HTTP.Response(500, headers, "{\"error\": \"Failed to trash\"}")
    end
end
# 2. RESTORE PAPER FROM TRASH
@route ["OPTIONS"] "/api/restore" function(req::HTTP.Request)
    return HTTP.Response(200, ["Access-Control-Allow-Origin" => "*", "Access-Control-Allow-Methods" => "POST, OPTIONS", "Access-Control-Allow-Headers" => "*"], "")
end

@post "/api/restore" function(req::HTTP.Request)
    headers = ["Access-Control-Allow-Origin" => "*", "Content-Type" => "application/json"]
    try
        data = JSON3.read(req.body)
        paper_id = safe_parse_int(data.id)
        
        db = SQLite.DB(DB_PATH)
        # Restore the paper by setting trashed back to 0
        SQLite.execute(db, "UPDATE papers SET trashed = 0 WHERE id = ?", (paper_id,))
        println("♻️ Restored paper ID $paper_id to Library")
        return HTTP.Response(200, headers, "{\"status\": \"success\"}")
    catch e
        println("❌ Restore Error: ", e)
        return HTTP.Response(500, headers, "{\"error\": \"Failed to restore\"}")
    end
end

# 3. PERMANENTLY DELETE PAPER
@route ["OPTIONS"] "/api/delete" function(req::HTTP.Request)
    return HTTP.Response(200, ["Access-Control-Allow-Origin" => "*", "Access-Control-Allow-Methods" => "POST, OPTIONS", "Access-Control-Allow-Headers" => "*"], "")
end

@post "/api/delete" function(req::HTTP.Request)
    headers = ["Access-Control-Allow-Origin" => "*", "Content-Type" => "application/json"]
    try
        data = JSON3.read(req.body)
        paper_id = safe_parse_int(data.id)
        
        db = SQLite.DB(DB_PATH)
        
        # 1. Fetch PDF path to delete the physical file
        cursor = DBInterface.execute(db, "SELECT pdf_path FROM papers WHERE id = ?", (paper_id,))
        if !isempty(cursor)
            pdf_path = first(cursor).pdf_path
            if !ismissing(pdf_path) && isfile(pdf_path)
                rm(pdf_path, force=true)
                println("🗑️ Deleted physical PDF file: ", pdf_path)
            end
        end
        
        # 2. Wipe from database completely
        SQLite.execute(db, "DELETE FROM paper_authors WHERE paper_id = ?", (paper_id,))
        SQLite.execute(db, "DELETE FROM collection_papers WHERE paper_id = ?", (paper_id,))
        SQLite.execute(db, "DELETE FROM papers WHERE id = ?", (paper_id,))
        
        println("💀 Permanently deleted paper ID $paper_id")
        return HTTP.Response(200, headers, "{\"status\": \"success\"}")
    catch e
        println("❌ Delete Error: ", e)
        return HTTP.Response(500, headers, "{\"error\": \"Failed to delete\"}")
    end
end
@route ["OPTIONS"] "/api/move" function(req::HTTP.Request)
    return HTTP.Response(200, ["Access-Control-Allow-Origin" => "*", "Access-Control-Allow-Methods" => "POST, OPTIONS", "Access-Control-Allow-Headers" => "*"], "")
end

@post "/api/move" function(req::HTTP.Request)
    headers = ["Access-Control-Allow-Origin" => "*", "Content-Type" => "application/json"]
    try
        data = JSON3.read(req.body)
        
        # Safely parse the IDs
        paper_id = safe_parse_int(data.paper_id)
        col_id = safe_parse_int(data.collection_id)
        
        db = SQLite.DB(DB_PATH)
        SQLite.execute(db, "DELETE FROM collection_papers WHERE paper_id = ?", (paper_id,))
        if col_id > 0
            SQLite.execute(db, "INSERT OR IGNORE INTO collection_papers (collection_id, paper_id) VALUES (?, ?)", (col_id, paper_id))
        end
        println("📁 Moved paper ID $paper_id to Collection ID $col_id")
        return HTTP.Response(200, headers, "{\"status\": \"success\"}")
    catch e
        println("❌ Move Error: ", e)
        return HTTP.Response(500, headers, "{\"error\": \"Failed to move\"}")
    end
end
# 4. EMPTY ENTIRE TRASH
@route ["OPTIONS"] "/api/trash/empty" function(req::HTTP.Request)
    return HTTP.Response(200, ["Access-Control-Allow-Origin" => "*", "Access-Control-Allow-Methods" => "POST, OPTIONS", "Access-Control-Allow-Headers" => "*"], "")
end

@post "/api/trash/empty" function(req::HTTP.Request)
    headers = ["Access-Control-Allow-Origin" => "*", "Content-Type" => "application/json"]
    try
        db = SQLite.DB(DB_PATH)
        
        # 1. Fetch all trashed papers to delete their physical PDFs
        cursor = DBInterface.execute(db, "SELECT id, pdf_path FROM papers WHERE trashed = 1")
        for row in DataFrame(cursor)
            if !ismissing(row.pdf_path) && isfile(row.pdf_path)
                rm(row.pdf_path, force=true)
                println("🗑️ Deleted physical PDF file: ", row.pdf_path)
            end
            # Delete relational data
            SQLite.execute(db, "DELETE FROM paper_authors WHERE paper_id = ?", (row.id,))
            SQLite.execute(db, "DELETE FROM collection_papers WHERE paper_id = ?", (row.id,))
        end
        
        # 2. Wipe them from the papers table
        SQLite.execute(db, "DELETE FROM papers WHERE trashed = 1")
        
        println("💀 Emptied entire Trash folder.")
        return HTTP.Response(200, headers, "{\"status\": \"success\"}")
    catch e
        println("❌ Empty Trash Error: ", e)
        return HTTP.Response(500, headers, "{\"error\": \"Failed to empty trash\"}")
    end
end
# ======================================================
# --- SERVER ENDPOINTS & API SUITE ---
# ======================================================

@get "/" function()
    return file("src/html/dashboard.html")
end
# NEW: Serve the official Jucite logo
@get "/assets/logo.png" function() return file("src/assets/logo.png") end

# 1. LIBRARY ENDPOINT (WITH TRASH & GROUP FILTERING)
@get "/api/library" function(req::HTTP.Request)
    params = queryparams(req)
    col_id = parse(Int, get(params, "collection_id", "0"))
    is_trash = parse(Int, get(params, "trash", "0"))
    
    db = SQLite.DB(DB_PATH)
    try SQLite.execute(db, "ALTER TABLE papers ADD COLUMN trashed INTEGER DEFAULT 0") catch end
    
    if is_trash == 1
        df = DBInterface.execute(db, "SELECT id, title, year, journal, pdf_path, doi FROM papers WHERE trashed = 1") |> DataFrame
    elseif col_id > 0
        df = DBInterface.execute(db, "SELECT p.id, p.title, p.year, p.journal, p.pdf_path, p.doi FROM papers p JOIN collection_papers cp ON p.id = cp.paper_id WHERE cp.collection_id = ? AND (p.trashed IS NULL OR p.trashed = 0)", (col_id,)) |> DataFrame
    else
        df = DBInterface.execute(db, "SELECT id, title, year, journal, pdf_path, doi FROM papers WHERE trashed IS NULL OR trashed = 0") |> DataFrame
    end
    
    papers_list = []
    for row in eachrow(df)
        authors = get_paper_authors(db, row.id)
        csl_authors = [length(split(a, ", ")) == 2 ? Dict("family" => split(a, ", ")[1], "given" => split(a, ", ")[2]) : Dict("family" => a) for a in authors]
        push!(papers_list, Dict("id" => row.id, "title" => row.title, "year" => row.year, "journal" => row.journal, "pdf_path" => row.pdf_path, "authors" => csl_authors, "doi" => ismissing(row.doi) ? "" : row.doi))
    end
    return papers_list
end
# ======================================================
# --- 10,000+ CSL STYLE SEARCH ENGINE ---
# ======================================================

@route ["OPTIONS"] "/api/styles/search" function(req::HTTP.Request)
    return HTTP.Response(200, [
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers" => "*",
        "Access-Control-Allow-Private-Network" => "true"
    ], "")
end

@get "/api/styles/search" function(req::HTTP.Request)
    params = queryparams(req)
    query = lowercase(get(params, "q", ""))
    
    headers = [
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers" => "*",
        "Access-Control-Allow-Private-Network" => "true",
        "Content-Type" => "application/json"
    ]
    
    if isempty(query)
        return HTTP.Response(200, headers, "[]")
    end
    
    catalog = load_or_fetch_style_catalog()
    
    results = []
    count = 0
    for style in catalog
        if contains(lowercase(String(style["title"])), query) || contains(lowercase(String(style["name"])), query)
            push!(results, style)
            count += 1
            if count >= 15 break end # Limit to top 15 results for speed
        end
    end
    
    return HTTP.Response(200, headers, JSON3.write(results))
end

# 2. LAUNCH LOCAL PDF
@get "/api/open-pdf" function(req::HTTP.Request)
    params = queryparams(req)
    id_str = get(params, "id", "")
    if isempty(id_str) return HTTP.Response(400, "Missing ID") end
    
    id = parse(Int, id_str)
    db = SQLite.DB(DB_PATH)
    cursor = DBInterface.execute(db, "SELECT pdf_path FROM papers WHERE id = ?", (id,))
    if isempty(cursor) return HTTP.Response(404, "Paper not found") end
    
    pdf_path = first(cursor).pdf_path
    if ismissing(pdf_path) || isempty(pdf_path) || !isfile(pdf_path) return HTTP.Response(404, "PDF does not exist") end
    
    println("📂 Desktop Action: Opening PDF file -> ", pdf_path)
    run(`xdg-open $pdf_path`, wait=false)
    return HTTP.Response(200, "Opening PDF...")
end

# --- COLLECTIONS API ENDPOINTS ---

@route ["OPTIONS"] "/api/collections" function(req::HTTP.Request)
    return HTTP.Response(200, [
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers" => "*"
    ], "")
end

@get "/api/collections" function(req::HTTP.Request)
    db = SQLite.DB(DB_PATH)
    df = DBInterface.execute(db, "SELECT id, name, is_group FROM collections") |> DataFrame
    headers = ["Access-Control-Allow-Origin" => "*", "Content-Type" => "application/json"]
    return HTTP.Response(200, headers, JSON3.write([Dict("id" => row.id, "name" => row.name, "is_group" => row.is_group) for row in eachrow(df)]))
end

@post "/api/collections" function(req::HTTP.Request)
    headers = ["Access-Control-Allow-Origin" => "*", "Content-Type" => "application/json"]
    try
        data = json(req)
        db = SQLite.DB(DB_PATH)
        # Safe insert that won't crash if the folder already exists
        SQLite.execute(SQLite.Stmt(db, "INSERT OR IGNORE INTO collections (name, is_group) VALUES (?, ?)"), (String(data.name), Int(data.is_group)))
        println("📁 Created Collection/Group: ", data.name)
        return HTTP.Response(200, headers, "{\"status\": \"success\"}")
    catch e
        println("❌ Collection Creation Error: ", e)
        return HTTP.Response(500, headers, "{\"error\": \"Failed to save collection\"}")
    end
end
# 6. UNIVERSAL SAVE ENDPOINT
@post "/api/save" function(req::HTTP.Request)
    headers = ["Access-Control-Allow-Origin" => "*", "Content-Type" => "application/json"]
    try
        data = json(req)
        doi_val = haskey(data, :doi) ? String(data.doi) : ""
        col_id = haskey(data, :collection_id) ? Int(data.collection_id) : 0
        
        if !isempty(doi_val)
            println("📡 [1-Click Save] Processing DOI: ", doi_val, " for Group ID: ", col_id)
            paper = fetch_metadata(doi_val)
            if paper !== nothing
                save_paper(paper, col_id)
                return HTTP.Response(200, headers, "{\"status\": \"saved\"}")
            end
        end
        return HTTP.Response(400, headers, "{\"error\": \"Nothing to save\"}")
    catch e
        println("❌ Save Error: ", e)
        return HTTP.Response(500, headers, "{\"error\": \"Failed to save\"}")
    end
end

# --- SEARCH & FORMATTING ENGINE ---
@route ["OPTIONS"] "/api/search" function(req::HTTP.Request)
    return HTTP.Response(200, ["Access-Control-Allow-Origin" => "*", "Access-Control-Allow-Methods" => "GET, POST, OPTIONS", "Access-Control-Allow-Headers" => "*", "Access-Control-Allow-Private-Network" => "true"], "")
end

@get "/api/search" function(req::HTTP.Request)
    params = queryparams(req)
    query = get(params, "q", "")
    headers = ["Access-Control-Allow-Origin" => "*", "Access-Control-Allow-Methods" => "GET, POST, OPTIONS", "Access-Control-Allow-Headers" => "*", "Access-Control-Allow-Private-Network" => "true", "Content-Type" => "application/json"]
    if isempty(query) return HTTP.Response(200, headers, "[]") end
    
    db = SQLite.DB(DB_PATH)
    search_term = "%$(query)%"
    
    cursor = DBInterface.execute(db, """
        SELECT DISTINCT papers.id, papers.title, papers.year, papers.journal 
        FROM papers 
        LEFT JOIN paper_authors ON papers.id = paper_authors.paper_id 
        LEFT JOIN authors ON paper_authors.author_id = authors.id 
        WHERE papers.title LIKE ? OR papers.journal LIKE ? OR papers.year LIKE ? OR authors.name LIKE ?
        LIMIT 10
    """, (search_term, search_term, search_term, search_term))
    
    papers_list = []
    for row in eachrow(DataFrame(cursor))
        authors = get_paper_authors(db, row.id)
        csl_authors = [length(split(a, ", ")) == 2 ? Dict("family" => split(a, ", ")[1], "given" => split(a, ", ")[2]) : Dict("family" => a) for a in authors]
        push!(papers_list, Dict("id" => row.id, "title" => row.title, "year" => row.year, "journal" => row.journal, "authors" => csl_authors))
    end
    return HTTP.Response(200, headers, JSON3.write(papers_list))
end

@route ["OPTIONS"] "/api/format-citation" function(req::HTTP.Request)
    return HTTP.Response(200, ["Access-Control-Allow-Origin" => "*", "Access-Control-Allow-Methods" => "GET, POST, OPTIONS", "Access-Control-Allow-Headers" => "*", "Access-Control-Allow-Private-Network" => "true"], "")
end

@get "/api/format-citation" function(req::HTTP.Request)
    params = queryparams(req)
    id_str = get(params, "id", "")
    style = lowercase(get(params, "style", "apa"))
    headers = ["Access-Control-Allow-Origin" => "*", "Access-Control-Allow-Methods" => "GET, POST, OPTIONS", "Access-Control-Allow-Headers" => "*", "Access-Control-Allow-Private-Network" => "true", "Content-Type" => "application/json"]
    
    if isempty(id_str) return HTTP.Response(400, headers, "{\"error\": \"Missing ID\"}") end
    id = parse(Int, id_str)
    db = SQLite.DB(DB_PATH)
    
    cursor = DBInterface.execute(db, "SELECT title, year, journal FROM papers WHERE id = ?", (id,))
    if isempty(cursor) return HTTP.Response(404, headers, "{\"error\": \"Paper not found\"}") end
    paper = first(cursor)
    
    authors = get_paper_authors(db, id)
    first_author = !isempty(authors) ? split(authors[1], ", ")[1] : "Unknown"
    
    in_text = ""
    bibliography = ""
    
    if contains(style, "vancouver-superscript") || contains(style, "superscript")
        in_text = "¹"
        bibliography = "1. $(join(authors, ", ")). $(paper.title). $(paper.journal). $(paper.year)."
    elseif contains(style, "vancouver") || contains(style, "ieee") || contains(style, "brackets")
        in_text = "[1]"
        bibliography = "[1] $(join(authors, ", ")), \"$(paper.title),\" $(paper.journal), $(paper.year)."
    elseif contains(style, "nature") || contains(style, "lancet")
        in_text = "¹"
        bibliography = "1. $(join(authors, ", ")). $(paper.title). $(paper.journal) $(paper.year)."
    else
        author_str = length(authors) == 1 ? first_author : (length(authors) == 2 ? "$(first_author) & $(split(authors[2], ", ")[1])" : "$(first_author) et al.")
        in_text = "($(author_str), $(paper.year))"
        bibliography = "$(join(authors, ", ")) ($(paper.year)). $(paper.title). $(paper.journal)."
    end
    
    return HTTP.Response(200, headers, JSON3.write(Dict("in_text" => in_text, "bibliography" => bibliography, "style" => style, "paper_id" => id)))
end

# ======================================================
# --- STANDALONE DESKTOP LAUNCHER ---
# ======================================================

function launch_desktop_app()
    println("🚀 Starting Jucite Core Engine on port 8080...")
    init_db()
    load_or_fetch_style_catalog()
    
    # 1. Start the Oxygen server in the background (asynchronously)
    @async serve(port=8080, cors=true)
    
    # Give the server 1 second to fully boot up
    sleep(1.0)
    
    println("🖥️ Launching Jucite Native Desktop Window...")
  # 2. Create the Native Desktop Window using Blink (Electron)
    opts = Dict(
        "title" => "Jucite Reference Manager",
        # Use your custom logo for the Linux Taskbar and window icon!
        "icon" => joinpath(pwd(), "src", "assets", "logo.png"), 
        "width" => 1200,
        "height" => 800,
        "minWidth" => 800,
        "minHeight" => 600,
        "autoHideMenuBar" => true,
        # FIX THE BLACK BOX: Pre-fill window with the exact Tailwind background color
        "backgroundColor" => "#f8fafc", 
        "webPreferences" => Dict("nodeIntegration" => true)
    )
    
    w = Window(opts)
    Blink.loadurl(w, "http://127.0.0.1:8080/")
    
    println("✅ Jucite Desktop is running!")    
    wait() 
end
end # <----- YOU NEED THIS 'end' TO CLOSE THE MODULE!