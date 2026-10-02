#include "backend.h"
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "status"))
    return st_status();
  if ((argc == 2 || argc == 3) && !strcmp(argv[1], "check"))
    return st_check(argc == 3 ? argv[2] : NULL);
  if (argc == 2 && !strcmp(argv[1], "revert"))
    return st_revert();
  if (argc == 3 && !strcmp(argv[1], "apply")) {
    char *end;
    errno = 0;
    double x = strtod(argv[2], &end);
    if (errno || end == argv[2] || *end || !isfinite(x) || x < .25 || x > 1) {
      fprintf(stderr, "Duration factor must be finite and in [0.25, 1].\n");
      return 2;
    }
    return x == 1 ? st_revert() : st_apply(x);
  }
  fprintf(stderr, "Usage: space-tempo-cli status | check [Dock-binary] | apply "
                  "<duration-factor 0.25..1> | revert\n");
  return 2;
}
