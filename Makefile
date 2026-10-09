# PCFE 3D World. Metal shader + Objective-C++ window. Output stays in build/.

APP_NAME := PCFE3DWorld
BUILD := build
APP := $(BUILD)/$(APP_NAME).app
BIN := $(APP)/Contents/MacOS/$(APP_NAME)
RES := $(APP)/Contents/Resources

CXX := clang++
SDK := macosx
MIN := 14.0
CXXFLAGS := -std=c++17 -O2 -Wall -Wextra -Isrc -mmacosx-version-min=$(MIN)
APP_FLAGS := $(CXXFLAGS) -fobjc-arc
FRAMEWORKS := -framework Cocoa -framework Metal -framework QuartzCore

.PHONY: all run test clean

all: $(APP)

$(BUILD)/World.air: shaders/World.metal src/body_kind.h
	mkdir -p $(BUILD)
	xcrun -sdk $(SDK) metal -Isrc -c shaders/World.metal -o $(BUILD)/World.air

$(BUILD)/World.metallib: $(BUILD)/World.air
	xcrun -sdk $(SDK) metallib $(BUILD)/World.air -o $(BUILD)/World.metallib

$(BUILD)/$(APP_NAME): src/main.mm src/world_sim.cpp src/mesh.cpp src/world_sim.hpp src/mesh.hpp src/math3d.hpp src/body_kind.h
	mkdir -p $(BUILD)
	$(CXX) $(APP_FLAGS) src/main.mm src/world_sim.cpp src/mesh.cpp -o $(BUILD)/$(APP_NAME) $(FRAMEWORKS)

$(APP): $(BUILD)/$(APP_NAME) $(BUILD)/World.metallib bundle/Info.plist
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(RES)
	cp $(BUILD)/$(APP_NAME) $(BIN)
	cp $(BUILD)/World.metallib $(RES)/World.metallib
	cp bundle/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(BIN)
	codesign --force --sign - $(APP)

run: all
	open $(APP)

$(BUILD)/world_test: src/world_test.cpp src/world_sim.cpp src/mesh.cpp src/world_sim.hpp src/mesh.hpp src/math3d.hpp
	mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) src/world_test.cpp src/world_sim.cpp src/mesh.cpp -o $(BUILD)/world_test

test: $(BUILD)/world_test
	$(BUILD)/world_test

clean:
	rm -rf $(BUILD)
