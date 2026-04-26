//! cachebay-cli — GraphQL codegen for the Cachebay Swift runtime.
//!
//! Reads an SDL schema + `*.graphql` operation files, validates them against
//! the schema via `apollo-compiler`, and emits:
//!   • a `CachePlan` literal per operation (pre-baked — no runtime parsing),
//!   • a typed `Data` struct tree per operation (thin `JSONValue` accessors),
//!   • typed `Variables` structs, enums, input objects.
//!
//! The Swift runtime has zero GraphQL-parser dependencies; every operation it
//! sees is a `CachePlan` value produced here at build time.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::Parser;

mod config;
mod emit;
mod errors;
mod load;
mod plan;
mod schema;

#[derive(Parser, Debug)]
#[command(name = "cachebay-cli", version, about = "GraphQL codegen for Cachebay")]
enum Cli {
    /// Generate Swift sources from a schema + operation files.
    Codegen(CodegenArgs),
    /// Print the version and exit.
    Version,
}

#[derive(Parser, Debug)]
struct CodegenArgs {
    /// Path to the GraphQL schema (SDL file).
    #[arg(long, short)]
    schema: PathBuf,

    /// One or more paths to operation files or directories (recursively scanned for *.graphql).
    #[arg(long = "operations", num_args = 1..)]
    operations: Vec<PathBuf>,

    /// Output directory. One Swift file per operation plus a shared module file.
    #[arg(long, short = 'o', default_value = "Generated")]
    output: PathBuf,

    /// Module namespace for generated code (Swift enum). Default: `CachebayGenerated`.
    #[arg(long, default_value = "CachebayGenerated")]
    module: String,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match cli {
        Cli::Codegen(args) => match run_codegen(args) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("{e:?}");
                ExitCode::FAILURE
            }
        },
        Cli::Version => {
            println!("cachebay-cli {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
    }
}

fn run_codegen(args: CodegenArgs) -> anyhow::Result<()> {
    let schema_src = std::fs::read_to_string(&args.schema)
        .map_err(|e| anyhow::anyhow!("reading schema {}: {e}", args.schema.display()))?;
    let operation_files = load::collect_operation_files_excluding(&args.operations, &[args.schema.clone()])?;

    // Build validated HIR via apollo-compiler.
    let ctx = load::build_compiler(&schema_src, &operation_files)?;
    if !ctx.diagnostics.is_empty() {
        for d in &ctx.diagnostics {
            eprintln!("{d}");
        }
        anyhow::bail!("{} GraphQL diagnostic(s)", ctx.diagnostics.len());
    }

    // Build a cachebay plan per operation.
    let plans = plan::build_plans(&ctx)?;
    let inputs = schema::collect_referenced_input_types(&ctx);
    let enums = schema::collect_referenced_enums(&ctx);

    // Emit Swift.
    std::fs::create_dir_all(&args.output)?;
    emit::write_all(&plans, &inputs, &enums, &args.output, &args.module)?;

    println!(
        "cachebay-cli: wrote {} operation(s) + {} input type(s) + {} enum(s) to {}",
        plans.len(),
        inputs.len(),
        enums.len(),
        args.output.display()
    );
    Ok(())
}

#[allow(dead_code)]
fn ensure_dir(p: &Path) -> std::io::Result<()> {
    if !p.exists() {
        std::fs::create_dir_all(p)?;
    }
    Ok(())
}
