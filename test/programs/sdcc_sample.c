/* Sample program for comparing z80asm with sdasz80 on SDCC output.
   Only locals and constants, so everything lands in the _CODE area. */

typedef unsigned char u8;
typedef unsigned int u16;

struct point {
    u8 x;
    u8 y;
};

static const u8 table[] = { 3, 1, 4, 1, 5, 9, 2, 6 };
static const char message[] = "hello, z80";

static u16 checksum(const u8 *p, u8 n)
{
    u16 sum = 0;
    while (n--)
        sum = (sum << 1) + *p++;
    return sum;
}

static u8 classify(u8 v)
{
    switch (v) {
    case 0: return 'z';
    case 1: return 'o';
    case 9: return 'n';
    default: return v & 1 ? 'x' : 'e';
    }
}

static u8 length(const char *s)
{
    u8 n = 0;
    while (*s++)
        n++;
    return n;
}

static void move(struct point *p, signed char dx, signed char dy)
{
    p->x += dx;
    p->y += dy;
}

u16 run(void)
{
    struct point pt = { 10, 20 };
    u8 i;
    u16 total = checksum(table, sizeof table);
    for (i = 0; i < sizeof table; i++)
        total += classify(table[i]);
    move(&pt, -3, 5);
    return total + length(message) + pt.x + (pt.y << 8);
}
