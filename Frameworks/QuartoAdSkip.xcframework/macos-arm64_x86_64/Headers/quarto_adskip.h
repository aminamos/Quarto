#ifndef QUARTO_ADSKIP_H
#define QUARTO_ADSKIP_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CAdSegment {
    double start_time;
    double end_time;
    float confidence;
    char *reason;
} CAdSegment;

typedef struct CAdSegmentList {
    CAdSegment *segments;
    size_t count;
} CAdSegmentList;

typedef struct CChapter {
    const char *title;
    double start_time;
    double end_time;
} CChapter;

typedef struct AdSkipEngine AdSkipEngine;

// Lifecycle
AdSkipEngine *adskip_engine_new(void);
void adskip_engine_free(AdSkipEngine *engine);

// Chapter Inspection
bool adskip_is_ad_chapter(const AdSkipEngine *engine, const char *title);
CAdSegmentList adskip_detect_chapter_ads(const AdSkipEngine *engine, const CChapter *chapters, size_t count);

// Transcript Parsers
CAdSegmentList adskip_parse_vtt(const AdSkipEngine *engine, const char *vtt);
CAdSegmentList adskip_parse_srt(const AdSkipEngine *engine, const char *srt);

// Real-Time Word Token Stream
bool adskip_feed_word(AdSkipEngine *engine, const char *word, double start_time, double end_time, CAdSegment *out_segment);
void adskip_reset_stream(AdSkipEngine *engine);

// Memory Clean-up
void adskip_segment_free(CAdSegment *seg);
void adskip_segment_list_free(CAdSegmentList list);

#ifdef __cplusplus
}
#endif

#endif // QUARTO_ADSKIP_H
