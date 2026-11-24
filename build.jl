using Pkg

println("🧹 Resolving fresh dependencies for this OS & Julia version...")
rm("Manifest.toml"; force=true)
Pkg.activate(".")
Pkg.resolve()
Pkg.instantiate()
Pkg.precompile()

# Switch to global environment to install and run PackageCompiler
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
