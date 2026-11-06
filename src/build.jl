using Pkg

# 1. Install PackageCompiler dynamically on the GitHub server
Pkg.add("PackageCompiler")
using PackageCompiler

println("🚀 Starting Jucite Compilation...")

# 2. Compile Jucite into an executable folder named 'JuciteApp'
create_app(".", "JuciteApp"; 
    executables = ["Jucite" => "julia_main"],
    force = true,
    include_lazy_artifacts = true # CRUCIAL for Blink.jl/Electron to work!
)

# 3. Copy our HTML, JS, and Assets into the compiled app so the server can find them!
println("📁 Copying web assets to executable directory...")
cp("src", joinpath("JuciteApp", "bin", "src"); force=true)

println("✅ Compilation Complete!")