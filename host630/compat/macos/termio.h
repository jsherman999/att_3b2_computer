/*
 * System V <termio.h> for macOS: the SVR3/SVR4 struct termio and its flag values,
 * with TCGETA/TCSETA/TCSETAW/TCSETAF/TCFLSH ioctls translated to termios.
 * The 630 SDP host tools (dmdld, dmdversion, jx, ...) index tables by
 * (c_cflag & CBAUD), so the SysV baud encoding matters, not just the flags.
 */
#ifndef _COMPAT_TERMIO_H
#define _COMPAT_TERMIO_H

#include <sys/ioctl.h>
#include <stdarg.h>

/* Pull the native definitions in under private names. */
#define termios __mac_termios
#include <termios.h>
#undef termios

#undef IGNBRK
#undef BRKINT
#undef IGNPAR
#undef PARMRK
#undef INPCK
#undef ISTRIP
#undef INLCR
#undef IGNCR
#undef ICRNL
#undef IXON
#undef IXANY
#undef IXOFF
#undef OPOST
#undef ONLCR
#undef CSIZE
#undef CS5
#undef CS6
#undef CS7
#undef CS8
#undef CSTOPB
#undef CREAD
#undef PARENB
#undef PARODD
#undef HUPCL
#undef CLOCAL
#undef ISIG
#undef ICANON
#undef ECHO
#undef ECHOE
#undef ECHOK
#undef ECHONL
#undef NOFLSH
#undef VINTR
#undef VQUIT
#undef VERASE
#undef VKILL
#undef VEOF
#undef VEOL
#undef VMIN
#undef VTIME
#undef NCC
#undef B0
#undef B50
#undef B75
#undef B110
#undef B134
#undef B150
#undef B200
#undef B300
#undef B600
#undef B1200
#undef B1800
#undef B2400
#undef B4800
#undef B9600
#undef B19200
#undef B38400
#undef EXTA
#undef EXTB

#define NCC 8
struct termio {
	unsigned short c_iflag, c_oflag, c_cflag, c_lflag;
	char c_line;
	unsigned char c_cc[NCC];
};

#define IGNBRK	0000001
#define BRKINT	0000002
#define IGNPAR	0000004
#define PARMRK	0000010
#define INPCK	0000020
#define ISTRIP	0000040
#define INLCR	0000100
#define IGNCR	0000200
#define ICRNL	0000400
#define IUCLC	0001000
#define IXON	0002000
#define IXANY	0004000
#define IXOFF	0010000

#define OPOST	0000001
#define ONLCR	0000004

#define CBAUD	0000017
#define CSIZE	0000060
#define CS5	0
#define CS6	0000020
#define CS7	0000040
#define CS8	0000060
#define CSTOPB	0000100
#define CREAD	0000200
#define PARENB	0000400
#define PARODD	0001000
#define HUPCL	0002000
#define CLOCAL	0004000

#define ISIG	0000001
#define ICANON	0000002
#define XCASE	0000004
#define ECHO	0000010
#define ECHOE	0000020
#define ECHOK	0000040
#define ECHONL	0000100
#define NOFLSH	0000200

#define VINTR	0
#define VQUIT	1
#define VERASE	2
#define VKILL	3
#define VEOF	4
#define VEOL	5
#define VMIN	4
#define VTIME	5

#define B0	0
#define B50	1
#define B75	2
#define B110	3
#define B134	4
#define B150	5
#define B200	6
#define B300	7
#define B600	8
#define B1200	9
#define B1800	10
#define B2400	11
#define B4800	12
#define B9600	13
#define B19200	14
#define B38400	15
#define EXTA	B19200
#define EXTB	B38400

#define TCGETA	(('T'<<8)|1)
#define TCSETA	(('T'<<8)|2)
#define TCSETAW	(('T'<<8)|3)
#define TCSETAF	(('T'<<8)|4)
#define TCFLSH	(('T'<<8)|7)

static const speed_t __termio_speeds[16] = {
	0, 50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400, 4800, 9600, 19200, 38400
};

struct __termio_map { unsigned short sysv; unsigned long mac; };
static const struct __termio_map __termio_iflags[] = {
	{0000001, 0x00000001}, {0000002, 0x00000002}, {0000004, 0x00000004}, {0000010, 0x00000008},
	{0000020, 0x00000010}, {0000040, 0x00000020}, {0000100, 0x00000040}, {0000200, 0x00000080},
	{0000400, 0x00000100}, {0002000, 0x00000200}, {0004000, 0x00000800}, {0010000, 0x00000400},
	{0, 0}
};
static const struct __termio_map __termio_oflags[] = {
	{0000001, 0x00000001}, {0000004, 0x00000002}, {0, 0}
};
static const struct __termio_map __termio_cflags[] = {
	{0000100, 0x00000400}, {0000200, 0x00000800}, {0000400, 0x00001000}, {0001000, 0x00002000},
	{0002000, 0x00004000}, {0004000, 0x00008000}, {0, 0}
};
static const struct __termio_map __termio_lflags[] = {
	{0000001, 0x00000080}, {0000002, 0x00000100}, {0000010, 0x00000008}, {0000020, 0x00000002},
	{0000040, 0x00000004}, {0000100, 0x00000010}, {0000200, 0x80000000}, {0, 0}
};

static unsigned long __termio_tomac(const struct __termio_map *m, unsigned short v)
{
	unsigned long r = 0;
	for (; m->sysv; m++) if (v & m->sysv) r |= m->mac;
	return r;
}
static unsigned long __termio_mask(const struct __termio_map *m)
{
	unsigned long r = 0;
	for (; m->sysv; m++) r |= m->mac;
	return r;
}
static unsigned short __termio_tosysv(const struct __termio_map *m, unsigned long v)
{
	unsigned short r = 0;
	for (; m->sysv; m++) if (v & m->mac) r |= m->sysv;
	return r;
}

static int __termio_get(int fd, struct termio *t)
{
	struct __mac_termios m;
	int i;
	speed_t sp;
	if (tcgetattr(fd, &m) == -1) return -1;
	t->c_iflag = __termio_tosysv(__termio_iflags, m.c_iflag);
	t->c_oflag = __termio_tosysv(__termio_oflags, m.c_oflag);
	t->c_lflag = __termio_tosysv(__termio_lflags, m.c_lflag);
	t->c_cflag = __termio_tosysv(__termio_cflags, m.c_cflag);
	switch (m.c_cflag & 0x300) {
	case 0x100: t->c_cflag |= CS6; break;
	case 0x200: t->c_cflag |= CS7; break;
	case 0x300: t->c_cflag |= CS8; break;
	}
	/* Pseudo-terminals report 9600; anything unusual is treated as the fastest. */
	sp = cfgetospeed(&m);
	for (i = 15; i > 0 && __termio_speeds[i] != sp; i--) ;
	if (i == 0 && sp != 0) i = B38400;
	t->c_cflag |= i;
	t->c_line = 0;
	t->c_cc[VINTR] = m.c_cc[8];	/* VINTR */
	t->c_cc[VQUIT] = m.c_cc[9];	/* VQUIT */
	t->c_cc[VERASE] = m.c_cc[3];	/* VERASE */
	t->c_cc[VKILL] = m.c_cc[5];	/* VKILL */
	if (m.c_lflag & 0x100) {	/* ICANON: EOF/EOL */
		t->c_cc[VEOF] = m.c_cc[0];
		t->c_cc[VEOL] = m.c_cc[1];
	} else {			/* VMIN/VTIME share the slots */
		t->c_cc[VMIN] = m.c_cc[16];
		t->c_cc[VTIME] = m.c_cc[17];
	}
	t->c_cc[6] = t->c_cc[7] = 0;
	return 0;
}

static int __termio_set(int fd, int how, const struct termio *t)
{
	struct __mac_termios m;
	if (tcgetattr(fd, &m) == -1) return -1;
	/* Flags SysV has no name for (IEXTEN, ECHOCTL, ...) are left as they were. */
	m.c_iflag = (m.c_iflag & ~__termio_mask(__termio_iflags)) | __termio_tomac(__termio_iflags, t->c_iflag);
	m.c_oflag = (m.c_oflag & ~__termio_mask(__termio_oflags)) | __termio_tomac(__termio_oflags, t->c_oflag);
	m.c_lflag = (m.c_lflag & ~__termio_mask(__termio_lflags)) | __termio_tomac(__termio_lflags, t->c_lflag);
	m.c_cflag = (m.c_cflag & ~(__termio_mask(__termio_cflags) | 0x300))
		| __termio_tomac(__termio_cflags, t->c_cflag) | ((unsigned long)((t->c_cflag & CSIZE) >> 4) << 8);
	cfsetspeed(&m, __termio_speeds[t->c_cflag & CBAUD]);
	m.c_cc[8] = t->c_cc[VINTR];
	m.c_cc[9] = t->c_cc[VQUIT];
	m.c_cc[3] = t->c_cc[VERASE];
	m.c_cc[5] = t->c_cc[VKILL];
	if (t->c_lflag & ICANON) {
		m.c_cc[0] = t->c_cc[VEOF];
		m.c_cc[1] = t->c_cc[VEOL];
	} else {
		m.c_cc[16] = t->c_cc[VMIN];
		m.c_cc[17] = t->c_cc[VTIME];
	}
	return tcsetattr(fd, how, &m);
}

static int __termio_ioctl(int fd, unsigned long req, ...)
{
	va_list ap;
	int r;
	va_start(ap, req);
	switch (req) {
	case TCGETA:  r = __termio_get(fd, va_arg(ap, struct termio *)); break;
	case TCSETA:  r = __termio_set(fd, TCSANOW, va_arg(ap, struct termio *)); break;
	case TCSETAW: r = __termio_set(fd, TCSADRAIN, va_arg(ap, struct termio *)); break;
	case TCSETAF: r = __termio_set(fd, TCSAFLUSH, va_arg(ap, struct termio *)); break;
	case TCFLSH: {
		int q = va_arg(ap, int);
		r = tcflush(fd, q == 0 ? TCIFLUSH : q == 1 ? TCOFLUSH : TCIOFLUSH);
		break;
	}
	case TIOCEXCL: case TIOCNXCL:
		r = ioctl(fd, req);
		break;
	default:
		r = ioctl(fd, req, va_arg(ap, void *));
		break;
	}
	va_end(ap);
	return r;
}
#define ioctl __termio_ioctl

#endif
