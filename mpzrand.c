/* Simple utility program to produce a cryptographically-secure 128-bit
 * random integer.
 *
 * This program ignores all its arguments.
 *
 * Output is a 32-digit hexadecimal integer (uppercase).
 *
 * Compile with (FreeBSD):
 *   cc -O3 -fwhole-program <file> -o /usr/local/bin/mpzrand
 */

#include <stdio.h>

int main(void) {
  unsigned char dat[16];
  char str[33];
  FILE* urandom;
  unsigned i;
  char digits[] = "0123456789ABCDEF";

  str[32] = 0;

  urandom = fopen("/dev/urandom", "rb");
  if (!urandom) return 1;
  fread(dat, sizeof(dat), 1, urandom);
  for (i=0; i<16; ++i) {
    str[2*i+0] = digits[dat[i]>>4];
    str[2*i+1] = digits[dat[i]&15];
  }
  fclose(urandom);

  puts(str);
  return 0;
}
