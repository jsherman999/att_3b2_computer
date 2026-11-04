/* macOS has no STREAMS: pushing modules is a no-op (the ioctls just fail). */
#ifndef _COMPAT_STROPTS_H
#define _COMPAT_STROPTS_H
#define I_PUSH  (('S'<<8)|02)
#define I_LOOK  (('S'<<8)|04)
#define I_FLUSH (('S'<<8)|05)
#define FLUSHR  1
#endif
