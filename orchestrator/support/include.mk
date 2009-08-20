## -*- makefile -*-

######################################################################
## Erlang

ERL := erl
ERLC := $(ERL)c

RFC4627_BIN=$(CURDIR)/../build/opt/erlang-rfc4627
ERLAMQP_BIN=$(CURDIR)/../build/opt/rabbitmq-erlang-client
RABBIT_BIN=$(CURDIR)/../build/opt/rabbitmq
IBROWSE_BIN=$(CURDIR)/../build/opt/ibrowse
MOCHIWEB_BIN=$(CURDIR)/../build/opt/mochiweb


INCLUDE_EXT := $(RFC4627_BIN)/include $(ERLAMQP_BIN)/include $(RABBIT_BIN)/include $(MOCHIWEB_BIN)/include
ERL_PATH_EXT := -pa $(RFC4627_BIN)/ebin -pa $(ERLAMQP_BIN)/ebin -pa $(RABBIT_BIN)/ebin -pa $(IBROWSE_BIN)/ebin -pa $(MOCHIWEB_BIN)/ebin

INCLUDE_DIRS := $(INCLUDE_EXT) include $(wildcard deps/*/include)
EBIN_DIRS := $(wildcard deps/*/ebin)
ERLC_FLAGS := -W $(INCLUDE_DIRS:%=-I %) $(EBIN_DIRS:%=-pa %)

ifndef no_debug_info
  ERLC_FLAGS += +debug_info
endif

ifdef debug
  ERLC_FLAGS += -Ddebug
endif

EBIN_DIR := ebin
DOC_DIR  := doc
EMULATOR := beam

ERL_SOURCES := $(wildcard src/*.erl)
ERL_HEADERS := $(wildcard src/*.hrl) $(wildcard include/*.hrl)
ERL_OBJECTS := $(ERL_SOURCES:src/%.erl=$(EBIN_DIR)/%.$(EMULATOR))
ERL_DOCUMENTS := $(ERL_SOURCES:src/%.erl=$(DOC_DIR)/%.html)
ERL_OBJECTS_LOCAL := $(ERL_SOURCES:src/%.erl=./%.$(EMULATOR))
APP_FILES := $(wildcard src/*.app)
EBIN_FILES = $(ERL_OBJECTS) $(ERL_DOCUMENTS) $(APP_FILES:src/%.app=ebin/%.app)
EBIN_FILES_NO_DOCS = $(ERL_OBJECTS) $(APP_FILES:src/%.app=ebin/%.app)
MODULES = $(ERL_SOURCES:src/%.erl=%)

ERL_PATH_OPTS=-pa $(EBIN_DIR) -pa $(RFC4627_BIN)/ebin -pa $(ERLAMQP_BIN)/ebin -pa $(RABBIT_BIN)/ebin -pa $(IBROWSE_BIN)/ebin $(MOCHIWEB_BIN)/ebin

ebin/%.app: src/%.app
	cp $< $@

$(EBIN_DIR)/%.$(EMULATOR): src/%.erl
	$(ERLC) $(ERLC_FLAGS) -o $(EBIN_DIR) $<

src/%.$(EMULATOR): src/%.erl
	$(ERLC) $(ERLC_FLAGS) -o . $<

$(DOC_DIR)/%.html: src/%.erl
	$(ERL) -noshell -run edoc file $< -run init stop
	mv src/*.html $(DOC_DIR)/