import CachebayCodegen
import Foundation

@main
struct CachebayCLI {
    static func main() {
        FileHandle.standardError.write(Data("cachebay-cli: no command implemented yet\n".utf8))
    }
}
