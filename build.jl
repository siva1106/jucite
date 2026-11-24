using Pkg
# Install PackageCompiler in global temp environment so it doesn't alter Project.toml
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
