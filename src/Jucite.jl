module Jucite

using SQLite
using DataFrames
using HTTP
using JSON3
using Oxygen

const DB_PATH = "jucite_library.sqlite"
const PDF_DIR = "pdfs"
const STYLES_DIR = "styles"

# ======================================================
# --- DATABASE INITIALIZATION ---
# ======================================================

function init_db()
    db = SQLite.DB(DB_PATH)
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS papers (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, doi TEXT UNIQUE, year INTEGER, journal TEXT, pdf_path TEXT)")
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS authors (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE)")
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS paper_authors (paper_id INTEGER, author_id INTEGER, FOREIGN KEY(paper_id) REFERENCES papers(id), FOREIGN KEY(author_id) REFERENCES authors(id), PRIMARY KEY (paper_id, author_id))")
    return db
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
    catch e
    end
    return ""
end

function fetch_metadata(doi::String)
    url = "https://api.crossref.org/works/$doi"
    println("Fetching data from: ", url)
    
    try
        headers = ["User-Agent" => "JuciteApp/0.1 (mailto:test@jucite.com)"]
        response = HTTP.get(url, headers)
        
        json_data = JSON3.read(response.body)
        paper_data = json_data.message
        
        title = haskey(paper_data, :title) && !isempty(paper_data.title) ? paper_data.title[1] : "Unknown Title"
        journal = haskey(paper_data, Symbol("container-title")) && !isempty(paper_data[Symbol("container-title")]) ? paper_data[Symbol("container-title")][1] : "Unknown Journal"
        
        year = 0
        if haskey(paper_data, :issued) && haskey(paper_data.issued, Symbol("date-parts"))
            year = paper_data.issued[Symbol("date-parts")][1][1]
        end
        
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
                    pdf_url = link.URL
                    break
                end
            end
        end
        
        if isempty(pdf_url)
            println("🔍 Crossref did not have a PDF link. Checking Unpaywall...")
            pdf_url = fetch_unpaywall_pdf(doi)
        end
        
        return (title=title, journal=journal, year=year, doi=doi, authors=authors, pdf_url=pdf_url)
        
    catch e
        println("\n❌ CRASH REPORT:")
        println(e)
        return nothing
    end
end

function download_pdf(url::String, title::String)
    if isempty(url)
        println("⚠️ No PDF link found for this paper.")
        return ""
    end
    
    clean_title = replace(title, r"[\"’'\/\\:\*\?<>\|]" => "")
    clean_title = replace(clean_title, " " => "_")
    filepath = joinpath(PDF_DIR, "$clean_title.pdf")
    
    mkpath(PDF_DIR)
    
    println("📥 Downloading PDF from: ", url)
    try
        headers = ["User-Agent" => "Mozilla/5.0"]
        response = HTTP.get(url, headers)
        
        open(filepath, "w") do io
            write(io, response.body)
        end
        println("💾 PDF saved successfully at: ", filepath)
        return filepath
    catch e
        println("❌ Failed to download PDF (it might be locked behind a journal paywall).")
        return ""
    end
end

function save_paper(paper_info)
    if paper_info === nothing return end
    
    db = SQLite.DB(DB_PATH)
    pdf_local_path = download_pdf(paper_info.pdf_url, paper_info.title)
    
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
    
    println("💾 Successfully saved paper, PDF, and $(length(paper_info.authors)) authors!")
end

# ======================================================
# --- HELPER FUNCTIONS ---
# ======================================================

function get_paper_authors(db, paper_id::Int)
    cursor = DBInterface.execute(db, """
        SELECT name FROM authors 
        JOIN paper_authors ON authors.id = paper_authors.author_id 
        WHERE paper_authors.paper_id = ?
    """, (paper_id,))
    return [row.name for row in cursor]
end

function format_citation(paper_id::Int, style::String)
    db = SQLite.DB(DB_PATH)
    cursor = DBInterface.execute(db, "SELECT title, year, journal FROM papers WHERE id = ?", (paper_id,))
    if isempty(cursor) return "Error: Paper not found." end
    paper = first(cursor)
    authors = get_paper_authors(db, paper_id)
    
    formatted_authors = isempty(authors) ? "Unknown Author" : (length(authors) == 1 ? authors[1] : "$(authors[1]), et al.")
    
    style_lower = lowercase(style)
    if style_lower == "apa"
        return "$formatted_authors ($(paper.year)). $(paper.title). $(paper.journal)."
    else
        return "$formatted_authors. $(paper.title). $(paper.journal), $(paper.year)."
    end
end
"""
    fetch_csl_style(style_name::String)
Checks local cache. If missing, searches both root and dependent CSL folders on GitHub.
"""
function fetch_csl_style(style_name::String)
    mkpath(STYLES_DIR)
    local_path = joinpath(STYLES_DIR, "$style_name.csl")
    
    # 1. Return local cached CSL file if it exists
    if isfile(local_path)
        return read(local_path, String)
    end
    
    # 2. Try Core Root Directory (apa, vancouver, ieee, etc.)
    url_root = "https://raw.githubusercontent.com/citation-style-language/styles/master/$style_name.csl"
    println("📥 Searching CSL Root Directory on GitHub: ", style_name)
    try
        response = HTTP.get(url_root)
        if response.status == 200
            csl_xml = String(response.body)
            write(local_path, csl_xml)
            return csl_xml
        end
    catch e
        # Ignore error and try dependent folder next
    end
    
    # 3. Fallback: Try Dependent Directory (for 8,500+ specific journals like nature, lancet, etc.)
    url_dep = "https://raw.githubusercontent.com/citation-style-language/styles/master/dependent/$style_name.csl"
    println("🔍 Searching CSL Dependent Directory on GitHub for: ", style_name)
    try
        response = HTTP.get(url_dep)
        if response.status == 200
            csl_xml = String(response.body)
            write(local_path, csl_xml)
            return csl_xml
        end
    catch e
        println("❌ Style '$style_name' not found in root or dependent CSL directories.")
    end
    
    return ""
end
# ======================================================
# --- API ENDPOINTS & ROUTES ---
# ======================================================

# Serve Dashboard UI
@get "/" function()
    return file("src/html/dashboard.html")
end

# Library CSL-JSON Endpoint
@get "/api/library" function()
    db = SQLite.DB(DB_PATH)
    df = DBInterface.execute(db, "SELECT id, title, year, journal, pdf_path FROM papers") |> DataFrame
    
    papers_list = []
    for row in eachrow(df)
        authors = get_paper_authors(db, row.id)
        csl_authors = []
        for author in authors
            parts = split(author, ", ")
            if length(parts) == 2
                push!(csl_authors, Dict("family" => parts[1], "given" => parts[2]))
            else
                push!(csl_authors, Dict("family" => author))
            end
        end
        
        push!(papers_list, Dict(
            "id" => row.id,
            "title" => row.title,
            "year" => row.year,
            "journal" => row.journal,
            "pdf_path" => row.pdf_path,
            "authors" => csl_authors
        ))
    end
    
    return papers_list
end

# Native Linux PDF Launcher
@get "/api/open-pdf" function(req::HTTP.Request)
    params = queryparams(req)
    id_str = get(params, "id", "")
    if isempty(id_str) return HTTP.Response(400, "Missing ID") end
    
    id = parse(Int, id_str)
    db = SQLite.DB(DB_PATH)
    
    cursor = DBInterface.execute(db, "SELECT pdf_path FROM papers WHERE id = ?", (id,))
    if isempty(cursor) return HTTP.Response(404, "Paper not found") end
    
    pdf_path = first(cursor).pdf_path
    if isempty(pdf_path) || !isfile(pdf_path) return HTTP.Response(404, "PDF does not exist") end
    
    println("📂 Desktop Action: Opening PDF file -> ", pdf_path)
    run(`xdg-open $pdf_path`, wait=false)
    return HTTP.Response(200, "Opening PDF...")
end

# Citation Text Endpoint
@get "/api/cite" function(req::HTTP.Request)
    params = queryparams(req)
    id_str = get(params, "id", "")
    style = get(params, "style", "apa")
    if isempty(id_str) return HTTP.Response(400, "Missing ID") end
    
    citation = format_citation(parse(Int, id_str), style)
    return HTTP.Response(200, ["Content-Type" => "text/plain"], citation)
end

# Save Paper Endpoint (From Chrome Extension)
@post "/api/save" function(req::HTTP.Request)
    data = json(req)
    if !haskey(data, :doi) return HTTP.Response(400, "Missing 'doi'") end
    
    doi = data.doi
    println("📡 Received API request to save DOI: ", doi)
    
    paper = fetch_metadata(doi)
    if paper !== nothing
        save_paper(paper)
        return HTTP.Response(200, "Saved successfully: $(paper.title)")
    else
        return HTTP.Response(404, "Could not retrieve metadata")
    end
end
# --- CSL STYLE API ENDPOINT ---
# Usage: GET http://127.0.0.1:8080/api/style?name=vancouver-superscript
@get "/api/style" function(req::HTTP.Request)
    params = queryparams(req)
    style_name = get(params, "name", "apa")
    
    headers = [
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers" => "*",
        "Access-Control-Allow-Private-Network" => "true",
        "Content-Type" => "application/xml"
    ]
    
    csl_xml = fetch_csl_style(style_name)
    
    if isempty(csl_xml)
        return HTTP.Response(404, headers, "Style not found")
    else
        return HTTP.Response(200, headers, csl_xml)
    end
end
# --- WORD PROCESSOR SEARCH ENDPOINTS (WITH PRIVATE NETWORK ACCESS HEADERS) ---

# 1. Handle Chrome Preflight OPTIONS Request
@route ["OPTIONS"] "/api/search" function(req::HTTP.Request)
    return HTTP.Response(200, [
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers" => "*",
        "Access-Control-Allow-Private-Network" => "true"
    ], "")
end

# 2. Main Search Query Endpoint
@get "/api/search" function(req::HTTP.Request)
    params = queryparams(req)
    query = get(params, "q", "")
    
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
    
    db = SQLite.DB(DB_PATH)
    search_term = "%$(query)%"
    
    cursor = DBInterface.execute(db, """
        SELECT DISTINCT papers.id, papers.title, papers.year, papers.journal 
        FROM papers 
        LEFT JOIN paper_authors ON papers.id = paper_authors.paper_id 
        LEFT JOIN authors ON paper_authors.author_id = authors.id 
        WHERE papers.title LIKE ? 
           OR papers.journal LIKE ? 
           OR papers.year LIKE ? 
           OR authors.name LIKE ?
        LIMIT 10
    """, (search_term, search_term, search_term, search_term))
    
    df = DataFrame(cursor)
    
    papers_list = []
    for row in eachrow(df)
        authors = get_paper_authors(db, row.id)
        csl_authors = []
        for author in authors
            parts = split(author, ", ")
            if length(parts) == 2
                push!(csl_authors, Dict("family" => parts[1], "given" => parts[2]))
            else
                push!(csl_authors, Dict("family" => author))
            end
        end
        
        push!(papers_list, Dict(
            "id" => row.id,
            "title" => row.title,
            "year" => row.year,
            "journal" => row.journal,
            "authors" => csl_authors
        ))
    end
    
    json_str = JSON3.write(papers_list)
    return HTTP.Response(200, headers, json_str)
end

# ======================================================
# --- SERVER LAUNCHER ---
# ======================================================

function start_server()
    println("🚀 Starting Jucite Private Server on port 8080...")
    init_db()
    
    @async begin
        sleep(1.5)
        println("🖥️ Opening Dashboard in your browser...")
        run(`xdg-open http://localhost:8080`, wait=false)
    end
    
    serve(port=8080, cors=true)
end

end # end of module