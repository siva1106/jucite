using Pkg

println("🧹 Building clean, relocatable Project.toml & Manifest.toml (No Blink/WebIO)...")
rm("Manifest.toml"; force=true)

write("Project.toml", """
name = "Jucite"
uuid = "d4e8a1b2-9c3f-4a5e-8b7d-2f1e3c4b5a6d"
authors = ["RectoPress"]
version = "1.0.2"
""")

pkgs = [
    "SQLite", "DataFrames", "HTTP", "JSON3", "Oxygen", "DBInterface",
    "Logging", "Dates", "Random", "Sockets", "UUIDs", "Base64", "SHA", "Printf",
    "Downloads", "TOML", "Serialization", "InteractiveUtils"
]

Pkg.activate(".")
Pkg.add(pkgs)
Pkg.resolve()
Pkg.instantiate()
Pkg.precompile()

Pkg.activate()
Pkg.add("PackageCompiler")
using PackageCompiler

println("🚀 Compiling Jucite Julia Engine into Relocatable Machine Code...")

create_app(".", "JuciteApp";
    executables = ["Jucite" => "julia_main"],
    force = true,
    include_lazy_artifacts = true
)

println("📁 Bundling HTML UI and Official Logos into Executable...")
cp("src", joinpath("JuciteApp", "bin", "src"); force=true)

println("✅ Standalone Bundle Ready!")
