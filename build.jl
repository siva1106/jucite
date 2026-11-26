using Pkg

println("🧹 Resolving fresh dependencies for this OS & Julia version...")
rm("Manifest.toml"; force=true)
Pkg.activate(".")

# Auto-scan src/Jucite.jl for any additional 'using' or 'import' statements
code = read("src/Jucite.jl", String)
for line in split(code, '\n')
    m = match(r"^\s*(?:using|import)\s+([A-Za-z0-9_,\s]+)", line)
    if m !== nothing
        for p in split(m.captures[1], ',')
            pkg = strip(split(strip(p), ':')[1])
            pkg = strip(split(pkg, '.')[1])
            if !isempty(pkg) && !(pkg in ["Base", "Core", "Main", "Jucite"])
                try Pkg.add(String(pkg)) catch end
            end
        end
    end
end

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
