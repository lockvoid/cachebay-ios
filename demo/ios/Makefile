CLI := ../../cli/target/release/cachebay-cli
SCHEMA := ../server/schema.graphql
OPS := HarryPotterDemo/GraphQL
OUT := HarryPotterDemo/Generated

.PHONY: all gen project cli clean

all: gen project

cli:
	cd ../../cli && cargo build --release

gen: cli
	@mkdir -p $(OUT)
	$(CLI) codegen --schema $(SCHEMA) --operations $(OPS) --output $(OUT)

project:
	xcodegen generate

clean:
	rm -rf HarryPotterDemo.xcodeproj $(OUT)
