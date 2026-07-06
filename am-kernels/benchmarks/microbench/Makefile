export AM_HOME := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../../abstract-machine)
NAME = microbench
SRCS = $(shell find src/ -name "*.c" -o -name "*.cc")
include $(AM_HOME)/Makefile
