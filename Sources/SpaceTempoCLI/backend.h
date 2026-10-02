#ifndef ST_BACKEND_H
#define ST_BACKEND_H
int st_check(const char *path);
int st_status(void);
int st_apply(double multiplier);
int st_revert(void);
#endif
