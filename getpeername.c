/* Simple utility to query getpeername() on stdin
 * and return the IP address and incomming port via stdout.
 *
 * Format is <address> <port>
 *
 * This currently only supports IPv4 and is probably hardwired
 * to FreeBSD-specific behaviour... (ok, it works on Linux too).
 */

#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

int main(void) {
  struct sockaddr addr;
  socklen_t len;
  unsigned i;
  if (!getpeername(STDIN_FILENO, &addr, &len)) {
    for (i=2; i<6; ++i)
      printf("%d%s", ((unsigned)addr.sa_data[i]) & 0xFF, (i < 5? "." : " "));
    printf("%d\n", ((((unsigned)addr.sa_data[0]) & 0xFF) << 8)
                  | (((unsigned)addr.sa_data[1]) & 0xFF));
    return 0;
  } else return 1;
}
