export AM_HOME := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../../abstract-machine)
NAME = coremark
SRCS = $(shell find src/ -name "*.c")
include $(AM_HOME)/Makefile
