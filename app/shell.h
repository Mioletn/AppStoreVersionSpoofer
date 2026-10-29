// app/shell.h — 会话壳对外接口
#ifndef MPSHELL_H
#define MPSHELL_H

// 内嵌 macOS 程序所在目录（<app>/bin）。设了它会顺带把 PATH 指过去。
void mpshell_set_bindir(const char *dir);
// 进会话：循环读 stdin，返回最后一条命令的退出码
int  mpshell_run(int verbose);
// 执行一行（GUI 每次回车调这个），返回退出码
int  mpshell_exec_line(const char *line, int verbose);

#endif
