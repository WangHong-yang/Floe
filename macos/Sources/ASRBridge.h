#include <stdint.h>
typedef struct GTRecognizer GTRecognizer;
GTRecognizer *GTCreate(const char *directory);
GTRecognizer *GTCreateWithHotwords(const char *directory, float score);
void GTDestroy(GTRecognizer *r);
int GTBegin(GTRecognizer *r);
int GTBeginWithHotwords(GTRecognizer *r, const char *hotwords);
void GTAccept(GTRecognizer *r, const float *samples, int32_t count);
void GTFinish(GTRecognizer *r);
char *GTText(GTRecognizer *r);
void GTFreeText(char *text);
void GTCancel(GTRecognizer *r);
