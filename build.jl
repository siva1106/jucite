using Pkg

println("🧹 Building clean, registry-verified Project.toml & Manifest.toml...")
rm("Manifest.toml"; force=true)

# Reset Project.toml to clean header only
write("Project.toml", """
name = "Jucite"
uuid = "d4e8a1b2-9c3f-4a5e-8b7d-2f1e3c4b5a6d"
authors = ["RectoPress"]
version = "1.0.0"
""")

pkgs = Set{String}([
    "SQLite", "DataFrames", "HTTP", "JSON3", "Oxygen", "Blink", "DBInterface",
    "Logging", "Dates", "Random", "Sockets", "UUIDs", "Base64", "SHA", "Printf",
    "Downloads", "TOML", "Serialization", "InteractiveUtils"
])

# Scan src/Jucite.jl for any other 'using' or 'import' packages
code = read("src/Jucite.jl", String)
for line in split(code, '\n')
    m = match(r"^\s*(?:using|import)\s+([A-Za-z0-9_,\s]+)", line)
    if m !== nothing
        for p in split(m.captures[1], ',')
            pkg = strip(split(strip(p), ':')[1])
            pkg = strip(split(pkg, '.')[1])
            if !isempty(pkg) && !(pkg in ["Base", "Core", "Main", "Jucite"])
                push!(pkgs, String(pkg))
            end
        end
    end
end

# Let Julia's official Package Manager add all packages with their exact Registry UUIDs!
Pkg.activate(".")
Pkg.add(collect(pkgs))
Pkg.resolve()
Pkg.instantiate()
Pkg.precompile()

# Switch to global environment to run PackageCompiler
Pkg.activate()
Pkg.add("PackageCompiler")
using PackageCompiler

println("🚀 Compiling Jucite Julia Engine & Dependencies into Machine Code...")

create_app(".", "JuciteApp";
    executables = ["Jucite" => "julia_main"],
    force = true,
    include_lazy_artifacts = true
)

println("📁 Bundling HTML UI and Official Logos into Executable...")
cp("src", joinpath("JuciteApp", "bin", "src"); force=true)

println("✅ Standalone Bundle Ready!")
