/* Service to fascilitate UDP NAT holepunching and global
 * port discovery for Abendstern games.
 *
 * Clients are to send packets to the server on UDP 12544
 * which contain two unsigned 32-bit integers (userid and
 * a proof-of-authenticity given by the server). The port
 * the client is using is recorded in the MySQL database.
 *
 * Compile with (FreeBSD):
 *   cc -O3 -fwhole-program -I/usr/local/include/mysql \
 *     -L/usr/local/lib/mysql -lmysqlclient \
 *     -o /usr/local/bin/holepunchd holepunchd.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <my_global.h>
#include <my_sys.h>
#include <mysql.h>

#define DATABASE "abendstern"
#define PORT 12544
#define HOST "localhost"

struct __attribute__((__packed__)) datagramme_t {
  unsigned userid;
  unsigned secretToken;
};
typedef struct datagramme_t datagramme;

int main(void) {
  MYSQL cxn;
  datagramme input;
  int sock;
  int error;
  struct sockaddr_in addr;
  unsigned port;
  char query[512];
  ssize_t inputSz;
  socklen_t fromlen;

  if (sizeof(datagramme) != 8) {
    fprintf(stderr, "Datagramme struct is wrong size; needed 8, is %d\n", sizeof(datagramme));
    return EXIT_FAILURE;
  }

  my_init();
  mysql_init(&cxn);
  if (!mysql_real_connect(&cxn, HOST, "root", NULL, DATABASE, 0, NULL, 0)) {
    fprintf(stderr, "Could not connect to MySQL database: %s\n", mysql_error(&cxn));
    return EXIT_FAILURE;
  }

  sock = socket(PF_INET, SOCK_DGRAM, IPPROTO_UDP);
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = INADDR_ANY;
  addr.sin_port = htons(PORT);
  fromlen = sizeof(addr);

  if (-1 == bind(sock, (struct sockaddr*)&addr, sizeof(addr))) {
    perror("bind");
    mysql_close(&cxn);
    close(sock);
    return EXIT_FAILURE;
  }

  while (1) {
    inputSz = recvfrom(sock, &input, sizeof(input), 0, (struct sockaddr*)&addr, &fromlen);
    if (inputSz < 0) {
      perror("recvfrom");
      mysql_close(&cxn);
      return EXIT_FAILURE;
    }
    if (inputSz == sizeof(datagramme) && input.secretToken) {
      sprintf(query, "UPDATE accounts SET iportNumber=%u"
                     "WHERE userid=%u AND secretToken=%u",
              (unsigned)addr.sin_port, input.userid, input.secretToken);
      if (error = mysql_query(&cxn, query)) {
        fprintf(stderr, "MySQL returned error: %d\n", error);
        return EXIT_FAILURE;
      }

      /* Send reply of NUL bytes */
      memset(&input, 0, sizeof(input));
      sendto(sock, &input, sizeof(input), 0, (struct sockaddr*)&addr, sizeof(addr));
    }
  }

  close(sock);
  mysql_close(&cxn);

  return EXIT_SUCCESS;
}
