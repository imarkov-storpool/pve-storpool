# SPDX-FileCopyrightText: StorPool <support@storpool.com>
# SPDX-License-Identifier: BSD-2-Clause

PVE_MODULES= \
		PVE/HA/Resources/Custom/StorPoolPlugin.pm \
		PVE/Storage/Custom/StorPoolPlugin.pm \


PREFIX?=	   /usr
SHAREDIR?=	   ${PREFIX}/share
PVE_PERL?=	   ${SHAREDIR}/perl5
LIB_SP?=       ${PREFIX}/lib/storpool
OPT_SP_PVE?=   /opt/storpool/pve
SP_PVE_UTILS?= ${OPT_SP_PVE}/sp_pve_utils

BINOWN?=	root
BINGRP?=	root
BINMODE?=	755

SHAREOWN?=	${BINOWN}
SHAREGRP?=	${BINGRP}
SHAREMODE?=	644

INSTALL?=	install
INSTALL_PROGRAM?=	${INSTALL} -o ${BINOWN} -g ${BINGRP} -m ${BINMODE}
INSTALL_DATA?=	${INSTALL} -o ${SHAREOWN} -g ${SHAREGRP} -m ${SHAREMODE}

MKDIR_P?=	mkdir -p -m 755

all:
		# Nothing to do here

install: all
		{ \
			set -e; \
			for relpath in ${PVE_MODULES}; do \
				${MKDIR_P} -- "${DESTDIR}$$(dirname -- "${PVE_PERL}/$$relpath")"; \
				${INSTALL_DATA} -- "lib/$$relpath" "${DESTDIR}${PVE_PERL}/$$relpath"; \
			done; \
			\
			${MKDIR_P} -- "${DESTDIR}${OPT_SP_PVE}"; \
			${INSTALL_PROGRAM} -- set-pve-watchdog "${DESTDIR}${OPT_SP_PVE}/set-pve-watchdog"; \
			\
			${MKDIR_P} -- "${DESTDIR}${SP_PVE_UTILS}"; \
			${INSTALL_DATA}  -- python/src/sp_pve_utils/*.py "${DESTDIR}${SP_PVE_UTILS}"; \
			${INSTALL_DATA} -- sp-watchdog-mux.service "${DESTDIR}/lib/systemd/system/sp-watchdog-mux.service"; \
    		systemctl daemon-reload; \
			if ! systemctl is-active sp-watchdog-mux.service; then \
				systemctl mask --now sp-watchdog-mux.service; \
			fi; \
		}

clean:
		# Nothing to do here

.PHONY:		all install clean
