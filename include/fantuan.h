#ifndef FANTUAN_H
#define FANTUAN_H

/*
 * fantuan v3 核心接口
 *
 * ft_build 把 hex 源文本汇编成 ELF64 镜像，写入 out。
 * 成功返回镜像字节数；失败返回负数，err 中写入带行号的错误信息。
 *
 * err 缓冲区至少 512 字节。
 */
long ft_build(const char *src, unsigned long srclen,
              const char *entry,
              unsigned char *out, unsigned long outcap,
              char *err);

extern unsigned long ft_label_count;
extern unsigned long ft_byte_count;

#endif
