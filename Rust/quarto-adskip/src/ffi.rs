use crate::engine::{AdSegment, AdSkipEngine, Chapter};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[repr(C)]
pub struct CAdSegment {
    pub start_time: f64,
    pub end_time: f64,
    pub confidence: f32,
    pub reason: *mut c_char,
}

#[repr(C)]
pub struct CAdSegmentList {
    pub segments: *mut CAdSegment,
    pub count: usize,
}

#[repr(C)]
pub struct CChapter {
    pub title: *const c_char,
    pub start_time: f64,
    pub end_time: f64,
}

fn to_c_segment(seg: &AdSegment) -> CAdSegment {
    let c_reason = CString::new(seg.reason.clone())
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw();
    CAdSegment {
        start_time: seg.start_time,
        end_time: seg.end_time,
        confidence: seg.confidence,
        reason: c_reason,
    }
}

fn to_c_segment_list(list: Vec<AdSegment>) -> CAdSegmentList {
    let mut c_segs: Vec<CAdSegment> = list.iter().map(to_c_segment).collect();
    let count = c_segs.len();
    let ptr = c_segs.as_mut_ptr();
    std::mem::forget(c_segs);
    CAdSegmentList {
        segments: ptr,
        count,
    }
}

/// Allocate a new AdSkipEngine instance
#[no_mangle]
pub extern "C" fn adskip_engine_new() -> *mut AdSkipEngine {
    Box::into_raw(Box::new(AdSkipEngine::new()))
}

/// Free an AdSkipEngine instance
#[no_mangle]
pub extern "C" fn adskip_engine_free(engine: *mut AdSkipEngine) {
    if !engine.is_null() {
        unsafe {
            drop(Box::from_raw(engine));
        }
    }
}

/// Check if a chapter title contains sponsor / ad words
#[no_mangle]
pub extern "C" fn adskip_is_ad_chapter(
    engine: *const AdSkipEngine,
    title: *const c_char,
) -> bool {
    if engine.is_null() || title.is_null() {
        return false;
    }
    let engine = unsafe { &*engine };
    let c_str = unsafe { CStr::from_ptr(title) };
    if let Ok(title_str) = c_str.to_str() {
        engine.is_ad_chapter(title_str)
    } else {
        false
    }
}

/// Detect ads from an array of chapters
#[no_mangle]
pub extern "C" fn adskip_detect_chapter_ads(
    engine: *const AdSkipEngine,
    chapters: *const CChapter,
    count: usize,
) -> CAdSegmentList {
    if engine.is_null() || chapters.is_null() || count == 0 {
        return CAdSegmentList {
            segments: std::ptr::null_mut(),
            count: 0,
        };
    }
    let engine = unsafe { &*engine };
    let c_slice = unsafe { std::slice::from_raw_parts(chapters, count) };

    let mut parsed_chapters = Vec::with_capacity(count);
    for c in c_slice {
        let title = if c.title.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(c.title) }
                .to_str()
                .unwrap_or("")
                .to_string()
        };
        parsed_chapters.push(Chapter {
            title,
            start_time: c.start_time,
            end_time: c.end_time,
        });
    }

    let detected = engine.detect_chapter_ads(&parsed_chapters);
    to_c_segment_list(detected)
}

/// Parse WebVTT and detect ad segments
#[no_mangle]
pub extern "C" fn adskip_parse_vtt(
    engine: *const AdSkipEngine,
    vtt: *const c_char,
) -> CAdSegmentList {
    if engine.is_null() || vtt.is_null() {
        return CAdSegmentList {
            segments: std::ptr::null_mut(),
            count: 0,
        };
    }
    let engine = unsafe { &*engine };
    let c_str = unsafe { CStr::from_ptr(vtt) };
    if let Ok(vtt_str) = c_str.to_str() {
        let detected = engine.parse_and_detect_vtt(vtt_str);
        to_c_segment_list(detected)
    } else {
        CAdSegmentList {
            segments: std::ptr::null_mut(),
            count: 0,
        }
    }
}

/// Parse SRT and detect ad segments
#[no_mangle]
pub extern "C" fn adskip_parse_srt(
    engine: *const AdSkipEngine,
    srt: *const c_char,
) -> CAdSegmentList {
    if engine.is_null() || srt.is_null() {
        return CAdSegmentList {
            segments: std::ptr::null_mut(),
            count: 0,
        };
    }
    let engine = unsafe { &*engine };
    let c_str = unsafe { CStr::from_ptr(srt) };
    if let Ok(srt_str) = c_str.to_str() {
        let detected = engine.parse_and_detect_srt(srt_str);
        to_c_segment_list(detected)
    } else {
        CAdSegmentList {
            segments: std::ptr::null_mut(),
            count: 0,
        }
    }
}

/// Feed a live word token (e.g. from SFSpeechRecognizer)
/// Returns true if an ad segment was outputted into out_segment
#[no_mangle]
pub extern "C" fn adskip_feed_word(
    engine: *mut AdSkipEngine,
    word: *const c_char,
    start_time: f64,
    end_time: f64,
    out_segment: *mut CAdSegment,
) -> bool {
    if engine.is_null() || word.is_null() || out_segment.is_null() {
        return false;
    }
    let engine = unsafe { &mut *engine };
    let c_str = unsafe { CStr::from_ptr(word) };
    if let Ok(w) = c_str.to_str() {
        if let Some(seg) = engine.feed_word(w, start_time, end_time) {
            unsafe {
                *out_segment = to_c_segment(&seg);
            }
            return true;
        }
    }
    false
}

/// Reset live streaming tokens
#[no_mangle]
pub extern "C" fn adskip_reset_stream(engine: *mut AdSkipEngine) {
    if !engine.is_null() {
        let engine = unsafe { &mut *engine };
        engine.reset_stream();
    }
}

/// Free a CAdSegment's allocated reason string
#[no_mangle]
pub extern "C" fn adskip_segment_free(seg: *mut CAdSegment) {
    if !seg.is_null() {
        unsafe {
            if !(*seg).reason.is_null() {
                drop(CString::from_raw((*seg).reason));
                (*seg).reason = std::ptr::null_mut();
            }
        }
    }
}

/// Free a list of segments
#[no_mangle]
pub extern "C" fn adskip_segment_list_free(list: CAdSegmentList) {
    if !list.segments.is_null() && list.count > 0 {
        unsafe {
            let slice = std::slice::from_raw_parts_mut(list.segments, list.count);
            for seg in slice {
                if !seg.reason.is_null() {
                    drop(CString::from_raw(seg.reason));
                }
            }
            drop(Vec::from_raw_parts(list.segments, list.count, list.count));
        }
    }
}
