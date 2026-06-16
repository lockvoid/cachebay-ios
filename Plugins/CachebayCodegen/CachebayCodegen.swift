import Foundation
import PackagePlugin

/// `swift package cachebay-codegen` — runs `cachebay-cli codegen` to generate
/// the typed Swift for your `.graphql` operations, writing into your package
/// (needs `--allow-writing-to-package-directory`).
///
/// The CLI is a prebuilt Rust binary delivered as a `binaryTarget` artifact
/// bundle (see Package.swift). During CLI development, set `CACHEBAY_CLI_PATH`
/// to a locally-built binary (`cli/target/release/cachebay-cli`) to bypass the
/// bundle entirely.
///
/// Usage:
///   swift package --allow-writing-to-package-directory cachebay-codegen \
///     --schema path/to/schema.graphql \
///     --operations path/to/GraphQL \
///     --output path/to/Generated \
///     [--namespace API] [--config path/to/cachebay.config.json]
@main
struct CachebayCodegen: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        var args = ArgumentExtractor(arguments)
        guard let schema = args.extractOption(named: "schema").last else {
            throw CodegenError("missing required --schema <path>")
        }
        let operations = args.extractOption(named: "operations")
        let output = args.extractOption(named: "output").last ?? "Generated"
        let namespace = args.extractOption(named: "namespace").last
        let config = args.extractOption(named: "config").last

        // Resolve the CLI: a locally-built binary via env (CLI development), else
        // the prebuilt artifact-bundle tool resolved by SwiftPM.
        let cliURL: URL
        if let local = ProcessInfo.processInfo.environment["CACHEBAY_CLI_PATH"], !local.isEmpty {
            cliURL = URL(fileURLWithPath: local)
            Diagnostics.remark("cachebay-codegen: using CACHEBAY_CLI_PATH=\(local)")
        } else {
            cliURL = try context.tool(named: "cachebay-cli").url
        }

        var cliArgs = ["codegen", "--schema", schema, "--output", output]
        if !operations.isEmpty { cliArgs += ["--operations"] + operations }
        if let namespace { cliArgs += ["--namespace", namespace] }
        if let config { cliArgs += ["--config", config] }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = cliArgs
        // Relative --schema/--operations/--output resolve against the package root.
        process.currentDirectoryURL = context.package.directoryURL

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CodegenError("cachebay-cli exited with status \(process.terminationStatus)")
        }
        Diagnostics.remark("cachebay-codegen: wrote \(output)")
    }
}

struct CodegenError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
