/*
 * libc_min.c -- the few C library functions the firmware needs (FatFs uses
 * them, and the compiler may emit memcpy/memset for struct copies). The
 * firmware is linked with -nostdlib.
 *
 * Loop-to-library-call conversion is switched off here, or the compiler would
 * turn these loops back into calls to themselves.
 */
#include <stddef.h>

/* used: with -flto the calls the compiler emits for struct copies appear only at
   code generation, after LTO would have dropped an unreferenced memcpy. */
#define NO_LIBCALL __attribute__((used, optimize("no-tree-loop-distribute-patterns")))

NO_LIBCALL void *memcpy(void *dst, const void *src, size_t n)
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

NO_LIBCALL void *memmove(void *dst, const void *src, size_t n)
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    if (d < s) { while (n--) *d++ = *s++; }
    else { d += n; s += n; while (n--) *--d = *--s; }
    return dst;
}

NO_LIBCALL void *memset(void *dst, int c, size_t n)
{
    unsigned char *d = dst;
    while (n--) *d++ = (unsigned char)c;
    return dst;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *x = a, *y = b;
    for (; n; n--, x++, y++)
        if (*x != *y) return *x - *y;
    return 0;
}

char *strchr(const char *s, int c)
{
    for (;; s++) {
        if (*s == (char)c) return (char *)s;
        if (!*s) return 0;
    }
}

size_t strlen(const char *s)
{
    size_t n = 0;
    while (s[n]) n++;
    return n;
}
