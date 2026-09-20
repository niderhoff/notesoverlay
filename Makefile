APP := build/NotesOverlay.app

.PHONY: build run install clean release

build:
	./build.sh

run: build
	-pkill -x NotesOverlay
	sleep 0.5
	open $(APP)

install: build
	-pkill -x NotesOverlay
	sleep 0.5
	rm -rf /Applications/NotesOverlay.app
	cp -R $(APP) /Applications/
	open /Applications/NotesOverlay.app

clean:
	rm -rf .build build

release:
	./release.sh $(VERSION)
