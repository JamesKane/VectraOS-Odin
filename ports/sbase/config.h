// ports/sbase/config.h: what sbase's Makefile passes on the command line
// that ports/sbase/port.ndb cannot quote (ADR-0016). PREFIX is where bc -l
// finds bc.library: /boot/share/misc/bc.library, which build installs from
// the port's install= into bootfs.
#define PREFIX "/boot"
