APP := dist/Sketcher.app

.PHONY: app run run-fg release test clean verify

app:
	scripts/bundle.sh debug

release:
	scripts/bundle.sh release

run: app
	open "$(APP)"

# Foreground run: logs stream to the terminal; Ctrl-C to quit.
run-fg: app
	"$(APP)/Contents/MacOS/Sketcher"

# Command Line Tools ship Testing.framework outside the default search paths.
# Both rpaths are required: without the second, the build succeeds but the test
# binary dies at launch.
CLT_DEV := /Library/Developer/CommandLineTools/Library/Developer
TEST_FLAGS := -Xswiftc -F$(CLT_DEV)/Frameworks \
	-Xlinker -F$(CLT_DEV)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib

test:
	swift test $(TEST_FLAGS)

# End-to-end pixel-fidelity check through the real export pipeline.
verify:
	scripts/verify-render.sh

clean:
	rm -rf .build dist
