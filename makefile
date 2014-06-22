#------------------------------------------------------------------------------
# For escaping commas/spaces in strings being passed as function parameters -> $(,), $(space)
#------------------------------------------------------------------------------
, := ,
null :=
space := $(null) #
define \n


endef
#------------------------------------------------------------------------------

# Default is a debug build
ifndef $(BUILD)
	BUILD:=debug
endif

# validate it's a known build variant
variants := debug release perf pic
building := $(if $(filter $(variants),$(BUILD)),1,0)
ifneq "$(building)" "1"
    $(error Invalid BUILD variant, specify one of [$(subst $(space),$(,) ,$(strip $(variants)))])
endif

#------------------------------------------------------------------------------
# Macro setup
#------------------------------------------------------------------------------

COMPILER_FLAGS = -Wall -Wextra -Werror -Wundef -Wno-system-headers -Wfloat-equal -Wpointer-arith
RELEASE_FLAGS = -O3 -ggdb1 -DNDEBUG
DEBUG_FLAGS = -ggdb3 -DDEBUG

ARCH:=$(shell /usr/bin/arch)
OS:=$(shell uname | tr [A-Z] [a-z])
MULTI_ARCH:=$(ARCH)-$(OS)-gnu
GLIBC_VER:=$(shell /lib/$(MULTI_ARCH)/libc.so.6 | head -1 | cut -f10 -d' ' | cut -f1 -d,)
GCC_VER := gcc-4.8.2

BUILD_TARGET=$(ARCH)/$(GLIBC_VER)/$(GCC_VER)

#RPATH := /lori/lib64

# SDK_PREFIX := /sdk
# SDK_INC_DIR := $(SDK_PREFIX)/include
# SDK_BIN_DIR := $(SDK_PREFIX)/$(ARCH)/$(GLIBC_VER)
# SDK_LIB_DIR := $(SDK_BIN_DIR)/lib

#CXX=$(SDK_BIN_DIR)/$(GCC_VER)/bin/g++

SDK_PREFIX := /usr
SDK_INC_DIR := $(SDK_PREFIX)/include
SDK_BIN_DIR := $(SDK_PREFIX)/bin
SDK_LIB_DIR := $(SDK_PREFIX)/lib/$(MULTI_ARCH)

CXX=$(SDK_BIN_DIR)/g++

AR=ar
ARFLAGS=crus

BASE_DIR := $(CURDIR)
WORKSPACE_NAME := $(shell basename `pwd`)
BUILD_DIR := /tmp/$(USER)/$(WORKSPACE_NAME)/$(BUILD_TARGET)/$(BUILD)
SRC_DIR := $(BASE_DIR)
OBJ_DIR := $(BUILD_DIR)/obj
DEP_DIR := $(BUILD_DIR)/dep
LIB_DIR := $(BUILD_DIR)/lib/
BIN_DIR := $(BUILD_DIR)/bin/
TEST_DIR := $(BUILD_DIR)/test/
EXAMPLE_DIR := $(BUILD_DIR)/example/
SYM_LINK_DIR = $(ARCH)-$(GLIBC_VER)-$(GCC_VER)-$(BUILD)
INSTALL_DIR := $(BASE_DIR)/install/$(SYM_LINK_DIR)

# search for all module makefiles
modules := $(shell find . -name module.mk | xargs echo)

binaries :=
test_binaries :=
example_binaries :=
libraries :=
lib_sources :=
bin_sources :=
lib_symlinks :=
bin_symlinks :=
test_symlinks :=
example_symlinks :=

#
# Third party stuff
#

python_version := 2.7.3
python_inc_dir := $(SDK_INC_DIR)/python-$(python_version)/python

boost_version := 1.53.0
boost_inc_dir := $(SDK_INC_DIR)/boost-$(boost_version)

# versioned boost libs
#boost_libs :=\
#    -lboost_filesystem-$(boost_version) \
#   -lboost_system-$(boost_version) \
#    -lboost_regex-$(boost_version)
#boost_python_libs :=\
#   -lboost_python-$(boost_version) \
#   -lpython-$(python_version) \
#   -lutil

# unversioned boost libs
boost_libs :=\
    -lboost_filesystem \
	-lboost_system \
    -lboost_regex
boost_python_libs :=\
	-lboost_python \
	-lpython-$(python_version) \
	-lutil

# no boost libs
#boost_libs :=

gtest_version := 1.6.0
gtest_inc_dir := external/gtest-$(gtest_version) external/gtest-$(gtest_version)/include
#gtest_libs := -lgtest_main-$(gtest_version) -lgtest-$(gtest_version)
gtest_libs := -lgtest_main -lgtest

gperf_version := 2.0
# versioned tcmalloc
# tcmalloc_libs := \
#    -ltcmalloc-$(gperf_version)
# unversioned tcmalloc
tcmalloc_libs := \
   -ltcmalloc
# no tcmalloc
# tcmalloc_libs :=

sdk_inc_dirs := $(boost_inc_dir) $(python_inc_dir) $(gtest_inc_dir)

#ccache_bin := $(SDK_DIR)/ccache/bin/ccache
#ccache_dir := $(BUILD_DIR)/.ccache

CPPFLAGS += $(addprefix -isystem,$(sdk_inc_dirs)) -m64 -std=c++11
CPPFLAGS += $(COMPILER_FLAGS) -D_GLIBCXX_USE_NANOSLEEP -D_REENTRANT

rpath_subst=-Wl,-rpath
linkpath    = $(addprefix $(rpath_subst),$(linkdirs)) $(addprefix -L,$(linkdirs))

#OUR_CXX := CCACHE_DIR=$(ccache_dir) CCACHE_COMPRESS=TRUE $(ccache_bin) $(CXX)
OUR_CXX := $(CXX)

has_pcap=$(shell if [ -e /usr/include/pcap/pcap.h ]; then echo 1; fi)

#------------------------------------------------------------------------------

ifeq "$(BUILD)" "debug"
    CPPFLAGS += $(DEBUG_FLAGS)
endif

ifeq "$(BUILD)" "release"
    CPPFLAGS += $(RELEASE_FLAGS)
endif

ifeq "$(BUILD)" "perf"
    CPPFLAGS += -$(RELEASE_FLAGS) -D_ENABLE_PROBES
endif

ifeq "$(BUILD)" "pic"
    tcmalloc_libs :=
    CPPFLAGS += $(DEBUG_FLAGS) -fPIC
endif

#################
#
# Misc functions
#
##################

#------------------------------------------------------------------------------
# Converts a source path to an object path
# Usage:
#   $(call src-to-obj, source-file-list, outdir)
#------------------------------------------------------------------------------
src-to-obj = $(addprefix $(OBJ_DIR)/,$(subst .cpp,.o,$(subst .cc,.o,$(filter %.cpp %.cc,$1))))

#------------------------------------------------------------------------------
# Returns the current subdirectory
#	only to be used when working through the list of module.mk files
#	  works by stripping off module.mk from the last entry in the MAKEFILE_LIST
# Usage:
#   $(subdir)
#------------------------------------------------------------------------------
subdir = $(patsubst %/module.mk,%, $(word $(words $(MAKEFILE_LIST)),$(MAKEFILE_LIST)))

#------------------------------------------------------------------------------
# Control compiler output verbosity,
# so that warnings are not lost in compiler line noise.
# params:
#   1: build command
# 	2: abbreviated command string in terse mode
#------------------------------------------------------------------------------
build_cmd = \
    echo "\
         $(if $(findstring $(VERBOSE),1 true yes),\
             $(1),\
             $(2))";\
    $(1)

######################################################################################
#
# Static libraries
#
######################################################################################

# Returns a static library Makefile segment (as a string) that can be eval'd. For calling by other make-lib functions.
# Expected that lib name is not qualified with subdir
# Usage: $(call make-lib, <lib-name>, <source-file-list>)
define make-lib
    libraries += $(addprefix $(addprefix $(LIB_DIR)lib,$1),.a)
    lib_sources += $2

    $(addprefix $(addprefix $(LIB_DIR)lib,$1),.a): $(call src-to-obj, $2)
	$(shell mkdir -p $(LIB_DIR))
	@$(call build_cmd,$(AR) $(ARFLAGS) $$@ $$^,AR $$@)
endef

#------------------------------------------------------------------------------
# create a static library using all cpp files in current directory
# params:
#   1: library name
#------------------------------------------------------------------------------
define make-lib-allcpp
    $(call make-lib,$1,$(shell ls $(subdir)/*.cpp))
endef

#------------------------------------------------------------------------------
# create a static library using all cpp files in current directory and all subdirectories
# params:
#   1: library name
#------------------------------------------------------------------------------
define make-lib-recursive-allcpp
    $(call make-lib,$1,$(shell find $(subdir) -name "*.cpp" -print | xargs echo))
endef

#------------------------------------------------------------------------------
# create a static library using all cpp files in all listed directories
# params:
#   1: library name
#   2: directories to search
#------------------------------------------------------------------------------
define make-lib-subdirs-allcpp
    $(call make-lib,$1,$(foreach dir,$2,$(shell ls $(subdir)/$(dir)/*.cpp)))
endef

#------------------------------------------------------------------------------
# create a static library using a list of source files
# params:
#   1: library name
#   2: source files
#------------------------------------------------------------------------------
define make-lib-srclist
    $(call make-lib,$1,$(addsuffix $(strip $2), $(subdir)/))
endef

######################################################################################
#
# Shared libraries
#
######################################################################################

#------------------------------------------------------------------------------
# create a shared library
# params:
#   1: library name
#   2: static library this shared library is being built from (entire library is used [--whole-archive])
#   3: static libraries this library depends on (to be linked in)
#   4: shared libraries this library depends on (to be linked in) [typically 3rd party libs]
# Usage:
#   $(call make-slib, <library-name> <entire static lib> <dep static libs> <thirdparty shared libs>)
#------------------------------------------------------------------------------
define make-slib
	lib_name := $(addprefix $(addprefix $(LIB_DIR)lib,$1),.so)
    libraries += $(lib_name)
    lib_sources += $2
    lib_symlinks += $(subdir)/$(SYM_LINK_DIR)

    $(addprefix $(addprefix $(LIB_DIR)lib,$1),.so): $(addsuffix .a,$(addprefix $(LIB_DIR)lib,$3))
	$(shell mkdir -p $(LIB_DIR))
	@$(call build_cmd,$(OUR_CXX) -shared -L/usr/lib -L$(SDK_LIB_DIR)/pic -L$(LIB_DIR) -Wl$(,)--whole-archive $(addsuffix .a,$(addprefix $(LIB_DIR)lib,$2)) -Wl$(,)--no-whole-archive -Wl$(,)-Bstatic $(addprefix -l,$3) $(linkpath) -L$(LIB_DIR) -Wl$(,)-Bdynamic $(boost_libs) $(tcmalloc_libs) -lpthread -lrt -rdynamic -o $$@,LINK SO $$@)
	$(shell mkdir -p $(INSTALL_DIR)/lib)
	@$(call build_cmd, ln -fs $$@ $(INSTALL_DIR)/lib,INSTALL $(INSTALL_DIR)/lib/$(strip $(lib_name)))
endef

######################################################################################
#
# Binaries
#
######################################################################################

# Returns a binary Makefile segment (as a string) that can be eval'd
# params:
#   1: binary name
#   2: source list
#   3: internal shared libraries this binary depends on
#   4: internal static libraries this binary depends on
#   5: 3rd party shared libraries this binary depends on
#   6: 3rd party static libraries this binary depends on
# usage:
#   $(call make-bin, <binary-name>, <source-list>, <deplibs-so>, <deplibs-a>, <thirdparty-libs-so>, <thirdparty-libs-a>)
define make-bin
    binaries += $(addprefix $(BIN_DIR),$1)
    bin_sources += $2
    bin_symlinks += $(subdir)/$(SYM_LINK_DIR)

    $(addprefix $(BIN_DIR),$1): $(call src-to-obj,$2) $(addsuffix .so,$(addprefix $(LIB_DIR)lib,$3)) $(addsuffix .a,$(addprefix $(LIB_DIR)lib,$4))
	$(shell mkdir -p $(BIN_DIR))
	@$(call build_cmd,$(OUR_CXX) $(call src-to-obj,$2) -L/usr/lib -L$(SDK_LIB_DIR) -L$(LIB_DIR) -Wl$(,)-Bstatic $(addprefix -l,$4) $(addprefix -l,$6) -Wl$(,)-Bdynamic -Wl$(,)-rpath$(,)$(RPATH) $(linkpath) -L$(LIB_DIR) $(boost_libs) $(tcmalloc_libs) -lpthread -lrt $(addprefix -l,$3) $(addprefix -l,$5) -rdynamic -o $$@,LINK BIN $$@)
	$(shell mkdir -p $(INSTALL_DIR)/bin)
	@$(call build_cmd, ln -fs $$@ $(INSTALL_DIR)/bin,INSTALL $(INSTALL_DIR)/bin/$(strip $1))
endef

#------------------------------------------------------------------------------
# Returns a binary Makefile segment (as a string) that can be eval'd
# Usage: $(call make-bin-allcpp, <test-binary-name>, <deplibs-so>, <deplibs-a>, <thirdparty-libs-so>, <thirdparty-libs-a>)
#------------------------------------------------------------------------------
define make-bin-allcpp
    $(call make-bin,$1,$(shell ls $(subdir)/*.cpp),$2,$3,$4,$5)
endef

######################################################################################
#
# Test binaries
#
######################################################################################

# Returns a test binary Makefile segment (as a string) that can be eval'd
# Usage: $(call make-testbin, <test-binary-name>, <source-list>, <deplibs-so>, <deplibs-a>, <thirdparty-libs-so>, <thirdparty-libs-a>)
define make-testbin
    test_binaries += $(addprefix $(TEST_DIR),$1)
    bin_sources += $2
    test_symlinks += $(subdir)/$(SYM_LINK_DIR)

    $(addprefix $(TEST_DIR),$1): $(call src-to-obj,$2) $(addsuffix .so,$(addprefix $(LIB_DIR)lib,$3)) $(addsuffix .a,$(addprefix $(LIB_DIR)lib,$4))
    $(shell mkdir -p $(TEST_DIR))
	@$(call build_cmd,$(OUR_CXX) -DUNIT_TEST $(call src-to-obj,$2) -L/usr/lib -L$(SDK_LIB_DIR) -L$(LIB_DIR) -Wl$(,)-Bstatic $(addprefix -l,$4) $(addprefix -l,$6) -Wl$(,)-Bdynamic -Wl$(,)-rpath$(,)$(RPATH) $(linkpath) -L$(LIB_DIR) $(boost_libs) $(gtest_libs) -lpthread -lrt $(addprefix -l,$3) $(addprefix -l,$5) -rdynamic -o $$@,LINK TEST $$@)
	$(shell mkdir -p $(INSTALL_DIR)/test)
	@$(call build_cmd, ln -fs $$@ $(INSTALL_DIR)/test,INSTALL $(INSTALL_DIR)/test/$(strip $1))
endef

# Returns a test binary Makefile segment (as a string) that can be eval'd
# Usage: $(call make-testbin-allcpp, <test-binary-name>, <deplibs-so>, <deplibs-a>, <thirdparty-libs-so>, <thirdparty-libs-a>)
define make-testbin-allcpp
    $(call make-testbin,$1,$(shell ls $(subdir)/*.cpp),$2,$3,$4,$5)
endef

#------------------------------------------------------------------------------
# Example binaries
#------------------------------------------------------------------------------

# Returns a test binary Makefile segment (as a string) that can be eval'd
# Usage: $(call make-testbin, <test-binary-name>, <source-list>, <deplibs-so>, <deplibs-a>, <thirdparty-libs-so>, <thirdparty-libs-a>)
define make-example-bin
    example_binaries += $(addprefix $(EXAMPLE_DIR),$1)
    bin_sources += $2
    example_symlinks += $(subdir)/$(SYM_LINK_DIR)

    $(addprefix $(EXAMPLE_DIR),$1): $(call src-to-obj,$2) $(addsuffix .so,$(addprefix $(libdir)lib,$3)) $(addsuffix .a,$(addprefix $(libdir)lib,$4))
	$(shell mkdir -p $(EXAMPLE_DIR))
	@$(call build_cmd,$(OUR_CXX) $(call src-to-obj,$2) -L$(sdk_lib_dir) -L$(libdir) -Wl$(,)-Bstatic $(addprefix -l,$4) $(addprefix -l,$6) -Wl$(,)-Bdynamic -Wl$(,)-rpath$(,)$(RPATH) $(linkpath) -L$(libdir) $(boost_libs) -lpthread -lrt $(addprefix -l,$3) $(addprefix -l,$5) -rdynamic -o $$@,LINK EXAMPLE $$@)
	$(shell mkdir -p $(INSTALL_DIR)/example)
	@$(call build_cmd, ln -fs $$@ $(INSTALL_DIR)/example,INSTALL $(INSTALL_DIR)/example/$(strip $1))
endef

# Returns a test binary Makefile segment (as a string) that can be eval'd
# Usage: $(call make-testbin-allcpp, <test-binary-name>, <deplibs-so>, <deplibs-a>, <thirdparty-libs-so>, <thirdparty-libs-a>)
define make-example-bin-allcpp
    $(call make-example-bin,$1,$(shell ls $(subdir)/*.cpp),$2,$3,$4,$5)
endef

######################################################################################

##################
#
# Rules
#
##################

vpath %.h $(include_dirs)

all:
# Pull in the rules for each module
include $(modules)

# Compile a list of dependency files we want to generate
lib_objects := $(call src-to-obj,$(lib_sources))
bin_objects := $(call src-to-obj,$(bin_sources))
deps := $(subst $(OBJ_DIR),$(DEP_DIR),$(subst .o,.d,$(lib_objects)))
deps += $(subst $(OBJ_DIR),$(DEP_DIR),$(subst .o,.d,$(bin_objects)))

ifeq "$(MK-DEBUG)" "1"
    $(warning [MAKECMDGOALS]:$(subst ${space},${\n}    , $(strip $(MAKECMDGOALS))))
    $(warning [lib_sources]:$(subst ${space},${\n}    , $(strip $(lib_sources))))
    $(warning [bin_sources]:$(subst ${space},${\n}    , $(strip $(bin_sources))))
    $(warning [deps]:$(subst ${space},${\n}    , $(strip $(deps))))
endif

# Only include the generated dependency files if we are building
building := $(if $(filter clean% clobber%,$(MAKECMDGOALS)),0,1)
ifeq "$(building)" "1"
    -include $(deps)
endif

##################
#
# Pattern rules
#
##################

$(OBJ_DIR)/%.o: $(SRC_DIR)/%.cpp
	$(shell mkdir -p $(dir $@))
	@$(call build_cmd,$(OUR_CXX) $(CFLAGS) $(CPPFLAGS) -I$(BASE_DIR) -I. -o $@ -c $(filter %.cpp,$^),COMPILE $(filter %.cpp,$^))

$(OBJ_DIR)/%.o: $(SRC_DIR)/%.cc
	$(shell mkdir -p $(dir $@))
	@$(call build_cmd,$(OUR_CXX) $(CFLAGS) $(CPPFLAGS) -I$(BASE_DIR) -I. -o $@ -c $(filter %.cc,$^),COMPILE $(filter %.cc,$^))

$(DEP_DIR)/%.d: $(SRC_DIR)/%.cpp
	$(shell mkdir -p $(dir $@))
	@$(call build_cmd,$(OUR_CXX) $(CFLAGS) $(CPPFLAGS) $(TARGET_ARCH) -MM -I. $< > $@,DEPGEN $(filter %.cpp,$^))
	@sed -i '1s\^\$(subst dep,obj,$(dir $@))\' $@

$(DEP_DIR)/%.d: $(SRC_DIR)/%.cc
	$(shell mkdir -p $(dir $@))
	@$(call build_cmd,$(OUR_CXX) $(CFLAGS) $(CPPFLAGS) $(TARGET_ARCH) -MM -I. $< > $@,DEPGEN $(filter %.cc,$^))
	@sed -i '1s\^\$(subst dep,obj,$(dir $@))\' $@

##################
#
# Phony targets
#
##################

.PHONY: all
all: binaries

.PHONY: binaries
binaries: libs $(binaries) $(test_binaries) $(example_binaries)

.PHONY: libs
libs: $(libraries)

.PHONY: clean
clean: clean-lib clean-test clean-bin clean-obj clean-dep clean-install

.PHONY: clobber
clobber:
	rm -rf $(BUILD_DIR)/

.PHONY: clean-obj
clean-obj:
	@echo "CLEAN OBJ"
	@rm -rf $(lib_objects) $(bin_objects)

.PHONY: clean-dep
clean-dep:
	@echo "CLEAN DEPS"
	@rm -rf $(deps)

.PHONY: clean-lib
clean-lib:
	@echo "CLEAN LIB"
	@rm -rf $(lib_objects) $(lib_symlinks)

.PHONY: clean-test
clean-test:
	@echo "CLEAN TEST"
	@rm -rf $(test_binaries) $(example_binaries) $(test_symlinks) $(example_symlinks)

.PHONY: clean-bin
clean-bin:
	@echo "CLEAN BIN"
	@rm -rf $(binaries) $(bin_symlinks)

.PHONY: clean-install
clean-install:
	@echo "CLEAN INSTALL"
	@rm -rf $(INSTALL_DIR)

.PHONY: test
# Need to echo here so we don't attempt to run the output of the tests
test:
	$(foreach testbin,$(test_binaries),$(testbin) && ) echo "tests completed"

.PHONY: info
info:
	@echo "binaries: $(binaries)"
	@echo "bin_sources: $(bin_sources)"
	@echo "bin_objects: $(bin_objects)"
	@echo "bin_symlinks: $(bin_symlinks)"
	@echo "libraries: $(libraries)"
	@echo "lib_sources: $(lib_sources)"
	@echo "lib_objects: $(lib_objects)"
	@echo "lib_symlinks: $(lib_symlinks)"
	@echo "test_binaries: $(test_binaries)"
	@echo "test_symlinks: $(test_symlinks)"
	@echo "example_binaries: $(example_binaries)"
	@echo "example_symlinks: $(example_symlinks)"
	@echo "deps: $(deps)"
	@echo "MAKEFILE_LIST: $(MAKEFILE_LIST)"
	@echo "CPPFLAGS: $(CPPFLAGS)"


