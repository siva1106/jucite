module Jucite

using SQLite
using DataFrames
using HTTP
using JSON3
using Oxygen

const DB_PATH = "jucite_library.sqlite"
const PDF_DIR = "pdfs"

function init_db()
    db = SQLite.DB(DB_PATH)
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS papers (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, doi TEXT UNIQUE, year INTEGER, journal TEXT, pdf_path TEXT)")
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS authors (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE)")
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS paper_authors (paper_id INTEGER, author_id INTEGER, FOREIGN KEY(paper_id) REFERENCES papers(id), FOREIGN KEY(author_id) REFERENCES authors(id), PRIMARY KEY (paper_id, author_id))")
    return db
end

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

function view_library()
    db = SQLite.DB(DB_PATH)
    df = DBInterface.execute(db, "SELECT id, title, year, pdf_path FROM papers") |> DataFrame
    println("\n📚 YOUR JUCITE LIBRARY:")
    display(df)
    println()
end

# ======================================================
# --- NEW UI & DESKTOP INTEGRATION ENDPOINTS ---
# ======================================================

# 1. Serve the dashboard.html file on the root URL (/)
@get "/" function()
    return file("src/html/dashboard.html")
end

# 2. Return the SQLite library rows as JSON data
@get "/api/library" function()
    db = SQLite.DB(DB_PATH)
    df = DBInterface.execute(db, "SELECT id, title, year, journal, pdf_path FROM papers") |> DataFrame
    # Convert the DataFrame to a list of Dictionaries for clean JSON output
    papers_list = [Dict(zip(names(df), row)) for row in eachrow(df)]
    return papers_list
end

# 3. Open the PDF in the native Linux PDF viewer when clicked!
@get "/api/open-pdf" function(req::HTTP.Request)
    params = queryparams(req)
    id_str = get(params, "id", "")
    
    if isempty(id_str)
        return HTTP.Response(400, "Missing ID")
    end
    
    id = parse(Int, id_str)
    db = SQLite.DB(DB_PATH)
    
    # Fetch the PDF path
    cursor = DBInterface.execute(db, "SELECT pdf_path FROM papers WHERE id = ?", (id,))
    if isempty(cursor)
        return HTTP.Response(404, "Paper not found")
    end
    
    pdf_path = first(cursor).pdf_path
    
    if isempty(pdf_path) || !isfile(pdf_path)
        return HTTP.Response(404, "PDF file does not exist locally")
    end
    
    println("📂 Desktop Action: Opening PDF file -> ", pdf_path)
    
    # RUN the native Linux 'xdg-open' command asynchronously!
    # This automatically opens the PDF in the user's default system PDF viewer
    run(`xdg-open $pdf_path`, wait=false)
    
    return HTTP.Response(200, "Opening PDF...")
end

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

function start_server()
    println("🚀 Starting Jucite Private Server on port 8080...")
    init_db()
    
    # AUTOMATICALLY open the default Linux browser to our dashboard!
    # We do this asynchronously so it doesn't block the server startup
    @async begin
        sleep(1.5) # Wait 1.5 seconds for the server to finish starting
        println("🖥️ Opening Dashboard in your browser...")
        run(`xdg-open http://localhost:8080`, wait=false)
    end
    
    serve(port=8080)
end

end # end of module