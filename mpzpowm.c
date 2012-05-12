/* Simple utility program to raise one very large integer to
 * another large integer's power, modulo another very large
 * integer, using the GNU Multi-Precision library.
 *
 * This program assumes all arguments are formatted correctly,
 * and has undefined behaviour if called inappropriately.
 *
 * Usage: mpzpowm base exponent modulus
 * Output: (base^exponent)%modulus
 * All inputs and outputs are (case-insensitive) unsigned
 * hexadecimal integers with NO "0x" prefix.
 *
 * Compile with (FreeBSD):
 *   cc -I/usr/local/include -O3 -fwhole-program <file> \
 *     -L/usr/local/lib -lgmp -o /usr/local/bin/mpzpowm
 */

#include <stdio.h>
#include <gmp.h>

int main(int argc, const char* argv[]) {
  mpz_t base, exponent, modulus;
  if (argc != 4) return 1;
  mpz_init_set_str(base,        argv[1], 16);
  mpz_init_set_str(exponent,    argv[2], 16);
  mpz_init_set_str(modulus,     argv[3], 16);
  mpz_powm(base, base, exponent, modulus);
  mpz_out_str(NULL, 16, base);

  //Don't bother freeing anything
  return 0;
}
