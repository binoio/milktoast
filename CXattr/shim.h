/* Extended-attribute calls. Present on both Darwin and Linux, but Swift's
   Glibc module does not re-export <sys/xattr.h>, so it is pulled in here. The
   two platforms disagree on the signatures — see Core/FileStamp.swift. */
#include <sys/xattr.h>
