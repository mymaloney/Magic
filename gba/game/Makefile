#---------------------------------------------------------------------------------------------------------------------
# Butano project for the GBA game. Mirrors the Makefile from Butano's template/ folder.
# LIBBUTANO must point at a checkout of https://github.com/GValiente/butano (the inner "butano" folder).
# Default: gba/butano/butano (see gba/README.md); override with `make LIBBUTANO=/path/to/butano/butano`.
#---------------------------------------------------------------------------------------------------------------------
TARGET      :=  $(notdir $(CURDIR))
BUILD       :=  build
LIBBUTANO   ?=  ../butano/butano
PYTHON      :=  python3
SOURCES     :=  src
INCLUDES    :=  include
DATA        :=
GRAPHICS    :=  graphics
AUDIO       :=  audio
DMGAUDIO    :=  dmg_audio
ROMTITLE    :=  MAGIC GBA
ROMCODE     :=  2MGE
USERFLAGS   :=
USERCXXFLAGS:=
USERASFLAGS :=
USERLDFLAGS :=
USERLIBDIRS :=
USERLIBS    :=
DEFAULTLIBS :=
STACKTRACE  :=
USERBUILD   :=
EXTTOOL     :=

ifndef LIBBUTANOABS
	export LIBBUTANOABS	:=	$(realpath $(LIBBUTANO))
endif

ifeq ($(LIBBUTANOABS),)
$(error Butano not found at "$(LIBBUTANO)". See gba/README.md for setup)
endif

include $(LIBBUTANOABS)/butano.mak
