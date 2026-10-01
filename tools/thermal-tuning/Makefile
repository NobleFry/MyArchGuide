# thermal-tuning 快捷入口
#   make            显示这个帮助
#   make install    安装/升级（开机 normal 档 + 免密切档）
#   make uninstall  完全卸载
#   make status     查看当前状态（只读）
#   make check      自检（语法/sudoers/systemd/安装状态）
#   make save       省电码字档
#   make normal     日常均衡档
#   make game       游戏档
#   make max        不设限档（CPU 115W / GPU 105W）
#   make diag       游戏期诊断（边玩边记录 180 秒）
ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

.PHONY: help install uninstall status check save normal game max diag

help:
	@grep '^#   make' $(ROOT)/Makefile

install:
	@sudo bash $(ROOT)/install.sh

uninstall:
	@sudo bash $(ROOT)/install.sh --remove

status:
	@$(ROOT)/tempctl

check:
	@bash $(ROOT)/check.sh

save normal game max:
	@sudo $(ROOT)/tempctl $@

diag:
	@bash $(ROOT)/diag.sh 180
