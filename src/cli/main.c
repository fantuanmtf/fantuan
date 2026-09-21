/*
 * fantuan v3 —— 用十六进制写 x86-64 机器码的恶搞工具链
 *
 * C 只负责外围：命令行、文件、进程；语言核心在汇编核心模块里
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>

#include "fantuan.h"

#define ERR_SZ 512

static void die(const char *msg)
{
    fprintf(stderr, "fantuan: %s\n", msg);
    exit(1);
}

static void usage(void)
{
    fputs(
        "fantuan 3.0 —— 用十六进制写 x86-64 机器码的恶搞工具链\n"
        "\n"
        "用法:\n"
        "  fantuan build <src.femboy> [-o <out>] [-e <label>]   编译成原生 ELF\n"
        "  fantuan run   <src.femboy> [-e <label>] [-- <args...>]\n"
        "  fantuan check <src.femboy> [-e <label>]              只校验不产出\n"
        "  fantuan dump  <file>                              十六进制转储\n"
        "  fantuan help | version\n"
        "\n"
        "记住: 每个字节行都得自己算 ;CK=hh，标签只能写小写十六进制。\n"
        "这不是给你偷懒用的语言。\n",
        stdout);
}

static unsigned char *read_file(const char *path, unsigned long *len)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "fantuan: 打不开 %s: %s\n", path, strerror(errno));
        return NULL;
    }
    unsigned long cap = 1 << 16, n = 0;
    unsigned char *buf = malloc(cap);
    if (!buf) {
        close(fd);
        return NULL;
    }
    for (;;) {
        if (n == cap) {
            cap *= 2;
            unsigned char *nb = realloc(buf, cap);
            if (!nb) {
                free(buf);
                close(fd);
                return NULL;
            }
            buf = nb;
        }
        ssize_t r = read(fd, buf + n, cap - n);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "fantuan: 读 %s 失败: %s\n", path, strerror(errno));
            free(buf);
            close(fd);
            return NULL;
        }
        if (r == 0)
            break;
        n += (unsigned long)r;
    }
    close(fd);
    *len = n;
    return buf;
}

/* 编译成内存镜像；失败打印错误并返回 NULL */
static unsigned char *compile(const char *srcpath, const char *entry,
                              unsigned long *outlen)
{
    unsigned long srclen = 0;
    unsigned char *src = read_file(srcpath, &srclen);
    if (!src)
        return NULL;
    unsigned long cap = srclen * 8 + 4096;
    unsigned char *img = malloc(cap);
    char err[ERR_SZ];
    if (!img) {
        free(src);
        die("内存不够，穷");
    }
    err[0] = 0;
    long n = ft_build((const char *)src, srclen, entry, img, cap, err);
    free(src);
    if (n < 0) {
        fprintf(stderr, "fantuan: %s\n", err[0] ? err : "编译失败，原因不明");
        free(img);
        return NULL;
    }
    *outlen = (unsigned long)n;
    return img;
}

static char *default_out(const char *src)
{
    const char *base = strrchr(src, '/');
    base = base ? base + 1 : src;
    size_t n = strlen(base);
    if (n > 7 && strcmp(base + n - 7, ".femboy") == 0)
        n -= 7;
    char *out = malloc(n + 1);
    if (!out)
        die("内存不够，穷");
    memcpy(out, base, n);
    out[n] = 0;
    return out;
}

static int write_executable(const char *path, const unsigned char *img,
                            unsigned long len)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0755);
    if (fd < 0) {
        fprintf(stderr, "fantuan: 写不了 %s: %s\n", path, strerror(errno));
        return -1;
    }
    unsigned long off = 0;
    while (off < len) {
        ssize_t w = write(fd, img + off, len - off);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "fantuan: 写 %s 失败: %s\n", path, strerror(errno));
            close(fd);
            return -1;
        }
        off += (unsigned long)w;
    }
    if (fchmod(fd, 0755) != 0)
        fprintf(stderr, "fantuan: chmod 失败: %s\n", strerror(errno));
    close(fd);
    return 0;
}

static int cmd_build(int argc, char **argv)
{
    const char *out = NULL, *entry = "_start", *src = NULL;
    char *outbuf = NULL;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "-o") && i + 1 < argc) {
            out = argv[++i];
        } else if (!strcmp(argv[i], "-e") && i + 1 < argc) {
            entry = argv[++i];
        } else if (!src) {
            src = argv[i];
        } else {
            die("参数太多，我只认识一个源文件");
        }
    }
    if (!src)
        die("没给源文件，编译空气吗？");
    unsigned long len = 0;
    unsigned char *img = compile(src, entry, &len);
    if (!img)
        return 1;
    if (!out) {
        outbuf = default_out(src);
        out = outbuf;
    }
    int rc = write_executable(out, img, len);
    free(img);
    if (rc == 0)
        fprintf(stderr, "fantuan: 生成 %s (%lu 字节)，去跑吧\n", out, len);
    free(outbuf);
    return rc == 0 ? 0 : 1;
}

static int cmd_check(int argc, char **argv)
{
    const char *entry = "_start", *src = NULL;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "-e") && i + 1 < argc)
            entry = argv[++i];
        else if (!src)
            src = argv[i];
        else
            die("参数太多，我只认识一个源文件");
    }
    if (!src)
        die("没给源文件，校验空气吗？");
    unsigned long len = 0;
    unsigned char *img = compile(src, entry, &len);
    if (!img)
        return 1;
    free(img);
    fprintf(stderr, "fantuan: 校验通过，%lu 字节代码、%lu 个标签，居然没写错\n",
            ft_byte_count, ft_label_count);
    return 0;
}

static int cmd_run(int argc, char **argv)
{
    const char *entry = "_start", *src = NULL;
    int rest = 0;
    for (int i = 0; i < argc; i++) {
        if (!src && !strcmp(argv[i], "-e") && i + 1 < argc) {
            entry = argv[++i];
            continue;
        }
        if (!src) {
            src = argv[i];
            rest = i + 1;
            break;
        }
    }
    if (!src)
        die("没给源文件，运行空气吗？");
    if (rest < argc && !strcmp(argv[rest], "--"))
        rest++;

    unsigned long len = 0;
    unsigned char *img = compile(src, entry, &len);
    if (!img)
        return 1;

    char tmpl[] = "/tmp/fantuan-XXXXXX";
    int fd = mkstemp(tmpl);
    if (fd < 0) {
        free(img);
        die("临时文件都建不出来，/tmp 满了吧");
    }
    unsigned long off = 0;
    while (off < len) {
        ssize_t w = write(fd, img + off, len - off);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            free(img);
            close(fd);
            die("写临时文件失败");
        }
        off += (unsigned long)w;
    }
    fchmod(fd, 0755);
    close(fd);
    free(img);

    char **cargv = calloc((size_t)(argc - rest) + 2, sizeof(char *));
    if (!cargv)
        die("内存不够，穷");
    cargv[0] = tmpl;
    for (int i = rest; i < argc; i++)
        cargv[i - rest + 1] = argv[i];

    pid_t pid = fork();
    if (pid == 0) {
        execv(tmpl, cargv);
        _exit(127);
    }
    if (pid < 0)
        die("fork 都失败了，这机器没救了");

    int status = 0;
    waitpid(pid, &status, 0);
    unlink(tmpl);

    if (WIFSIGNALED(status)) {
        fprintf(stderr, "fantuan: 程序被信号 %d 干掉了，活该\n",
                WTERMSIG(status));
        return 128 + WTERMSIG(status);
    }
    int code = WEXITSTATUS(status);
    if (code == 0)
        fprintf(stderr, "fantuan: 退出码 0，居然跑通了\n");
    else
        fprintf(stderr, "fantuan: 退出码 %d，意料之中\n", code);
    return code;
}

static int cmd_dump(int argc, char **argv)
{
    if (argc < 1)
        die("dump 谁？说个文件");
    unsigned long len = 0;
    unsigned char *buf = read_file(argv[0], &len);
    if (!buf)
        return 1;
    for (unsigned long off = 0; off < len; off += 16) {
        printf("%08lx  ", off);
        for (unsigned long i = 0; i < 16; i++) {
            if (off + i < len)
                printf("%02x ", buf[off + i]);
            else
                fputs("   ", stdout);
        }
        fputs(" |", stdout);
        for (unsigned long i = 0; i < 16 && off + i < len; i++) {
            unsigned char c = buf[off + i];
            putchar(c >= 32 && c < 127 ? c : '.');
        }
        puts("|");
    }
    free(buf);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        usage();
        return 1;
    }
    const char *cmd = argv[1];
    if (!strcmp(cmd, "help") || !strcmp(cmd, "-h") || !strcmp(cmd, "--help")) {
        usage();
        return 0;
    }
    if (!strcmp(cmd, "version") || !strcmp(cmd, "-v") || !strcmp(cmd, "--version")) {
        puts("fantuan 3.0.0-alpha");
        return 0;
    }
    if (!strcmp(cmd, "build"))
        return cmd_build(argc - 2, argv + 2);
    if (!strcmp(cmd, "run"))
        return cmd_run(argc - 2, argv + 2);
    if (!strcmp(cmd, "check"))
        return cmd_check(argc - 2, argv + 2);
    if (!strcmp(cmd, "dump"))
        return cmd_dump(argc - 2, argv + 2);
    fprintf(stderr, "fantuan: 不认识子命令 '%s'，看 help\n", cmd);
    return 1;
}
